import Foundation
import Observation
import SwiftData

/// Works out each record's name in the background, then settles its final name after Done.
///
/// Reads the front, then the back, then Side A, and stops at the first name that checks out. Most
/// covers need only the first read, and each one costs seconds. Progress is saved after every step,
/// so naming carries on after a relaunch. Done never waits for any of this.
@MainActor
@Observable
final class NamingController {
    typealias Reader = @Sendable (URL) -> [TextLine]
    typealias Extractor = @Sendable ([TextLine]) async -> (artist: String, title: String)?

    /// The closed record whose final name is on show.
    private(set) var toastRecord: Record?

    /// How long the final name stays up before it's locked in and uploads may begin.
    private let toastDuration: Duration
    /// A slow or stuck model mustn't hold up a record's uploads indefinitely.
    private let extractionTimeout: Duration

    private let context: ModelContext
    private let files: PhotoFiles
    private let reader: Reader
    private let extractor: Extractor
    private var activeWork: Task<Void, Never>?
    private var toastTimer: Task<Void, Never>?
    private var isEditingToast = false

    init(
        context: ModelContext,
        files: PhotoFiles,
        toastDuration: Duration = .seconds(4),
        extractionTimeout: Duration = .seconds(20),
        reader: @escaping Reader = TextReader.read,
        extractor: @escaping Extractor = NameExtractor.extract
    ) {
        self.context = context
        self.files = files
        self.toastDuration = toastDuration
        self.extractionTimeout = extractionTimeout
        self.reader = reader
        self.extractor = extractor
        // Anything closed before the app last stopped had its chance at a toast, and a toast must
        // never hold up uploads.
        for record in closedRecordsAwaitingFinalName() where isDoneReading(record) {
            settleName(of: record)
            lockName(of: record)
        }
        save()
        workNext()
    }

    /// Called when something changes that naming might be waiting for.
    func wake() {
        workNext()
        showNextToast()
    }

    func waitUntilIdle() async {
        while let activeWork { await activeWork.value }
    }

    // MARK: - Editing

    /// A name typed by hand is never overwritten by a later read. Clearing it hands naming back.
    func setName(_ name: String, for record: Record) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.name = trimmed.isEmpty ? nil : trimmed
        record.isNameEdited = !trimmed.isEmpty
        save()
        workNext()
    }

    /// Holds the toast open while its name is being fixed.
    func beginEditingToast() {
        isEditingToast = true
        toastTimer?.cancel()
    }

    func endEditingToast() {
        isEditingToast = false
        if let toastRecord { lockName(of: toastRecord) }
        self.toastRecord = nil
        save()
        showNextToast()
    }

    // MARK: - Reading

    private func workNext() {
        guard activeWork == nil else { return }
        guard let photo = nextPhotoToRead(), let record = photo.record else {
            showNextToast()
            return
        }
        let id = photo.id
        let location = PhotoLocation(sessionID: record.sessionID, photoID: id)
        let url = files.finishedURL(location)
        let reader = reader
        activeWork = Task { [weak self] in
            let lines = await Task.detached(priority: .utility) { reader(url) }.value
            await self?.finishRead(of: id, lines: lines)
            self?.activeWork = nil
            self?.workNext()
        }
    }

    private func finishRead(of id: UUID, lines: [TextLine]) async {
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        // The record may have been discarded, or the photo retaken, during the read.
        guard let photo = try? context.fetch(descriptor).first, let record = photo.record else { return }
        let recordID = record.id
        photo.recognizedLines = lines
        photo.isTextRead = true
        save()

        guard needsName(record) else { return }
        let text = readableLines(of: record)
        guard !text.isEmpty, let answer = await extractWithTimeout(from: text) else { return }
        // Fetched again, as the wait gives the user time to type a name or discard the record.
        let current = FetchDescriptor<Record>(predicate: #Predicate { $0.id == recordID })
        guard let latest = try? context.fetch(current).first, needsName(latest) else { return }
        guard NameValidator.isValid(artist: answer.artist, title: answer.title, in: text) else { return }
        let name = "\(answer.artist) — \(answer.title)"
        if NameValidator.isComplete(artist: answer.artist, title: answer.title) {
            latest.name = name
        } else if latest.partialName == nil {
            latest.partialName = name
        }
        save()
    }

    private func extractWithTimeout(from lines: [TextLine]) async -> (artist: String, title: String)? {
        let extractor = extractor
        let timeout = extractionTimeout
        return await withTaskGroup(of: (artist: String, title: String)?.self) { group in
            group.addTask { await extractor(lines) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func needsName(_ record: Record) -> Bool {
        record.name == nil && !record.isNameEdited
    }

    /// In shot order, the sleeve photos and Side A that are ready and unread, for records still
    /// without a name.
    private func nextPhotoToRead() -> Photo? {
        let records = (try? context.fetch(FetchDescriptor<Record>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for record in records where needsName(record) && !record.isNameFinal {
            let photo = record.photos
                .filter { $0.slot.isReadForName && $0.state == .processed && !$0.isTextRead }
                .min { $0.slot < $1.slot }
            if let photo { return photo }
        }
        return nil
    }

    /// Front first. Each photo's lines are shifted past the last, so the text stays in reading order
    /// a photo at a time rather than the lines of the front and back being interleaved.
    private func readableLines(of record: Record) -> [TextLine] {
        record.photos
            .filter(\.slot.isReadForName)
            .sorted { $0.slot < $1.slot }
            .enumerated()
            .flatMap { index, photo in
                photo.recognizedLines.map { TextLine(text: $0.text, height: $0.height, top: $0.top + Double(index)) }
            }
    }

    /// True once nothing more can come of waiting: there's a name, or every photo that could give
    /// one has been read or has failed.
    private func isDoneReading(_ record: Record) -> Bool {
        if !needsName(record) { return true }
        return record.photos
            .filter(\.slot.isReadForName)
            .allSatisfy { $0.state == .failed || $0.isTextRead }
    }

    // MARK: - Settling the final name

    private func closedRecordsAwaitingFinalName() -> [Record] {
        let descriptor = FetchDescriptor<Record>(
            predicate: #Predicate { !$0.isOpen && !$0.isNameFinal },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func showNextToast() {
        guard toastRecord == nil, activeWork == nil else { return }
        guard let record = closedRecordsAwaitingFinalName().first(where: isDoneReading) else { return }
        settleName(of: record)
        save()
        toastRecord = record
        let duration = toastDuration
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toastEnded()
        }
    }

    private func toastEnded() {
        guard !isEditingToast else { return }
        if let toastRecord { lockName(of: toastRecord) }
        toastRecord = nil
        save()
        showNextToast()
    }

    /// With no full name after every read, a repeated artist may be a real self-titled album. Failing
    /// that, the largest text on the front is the best guess left.
    private func settleName(of record: Record) {
        guard needsName(record) else { return }
        let front = record.photos.filter { $0.slot == .sleeveFront }.flatMap(\.recognizedLines)
        record.name = record.partialName ?? ProminentTextRule.name(from: front)
    }

    /// After this the record's folder is fixed and its uploads may begin.
    private func lockName(of record: Record) {
        let others = (try? context.fetch(FetchDescriptor<Record>())) ?? []
        let taken = Set(others.filter { $0.id != record.id }.compactMap(\.folderSlug))
        record.folderSlug = Slug.folder(for: record.name, taken: taken, date: record.createdAt)
        record.isNameFinal = true
    }

    private func save() {
        try? context.save()
    }
}
