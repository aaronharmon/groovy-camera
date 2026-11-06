import Foundation
import Observation
import SwiftData

/// Everything the camera needs to save one shot.
struct CaptureTicket: Sendable {
    var location: PhotoLocation
    var slot: Slot
}

/// One shot's files, as handed to the processing queue.
struct ProcessingJob: Sendable {
    var location: PhotoLocation
    var original: URL
    var finished: URL
    var thumbnail: URL
}

/// One thumbnail in the session strip.
struct SlotTile: Identifiable, Equatable, Sendable {
    var slot: Slot
    /// Nil when the slot was skipped, which still shows so it can be shot after all.
    var thumbnail: URL?
    var isProcessed: Bool
    var id: Int { slot.number }
}

/// Runs one record at a time from first shot to Done, and works through the photos waiting to be
/// processed.
///
/// A photo's row is saved before the shutter fires, and each step saves its progress, so after a
/// crash every photo can pick up where it was. The queue handles one shot at a time because a
/// full-size image takes a lot of memory to decode. It can fall behind safely: the shutter and
/// Done never wait for it.
@MainActor
@Observable
final class SessionController {
    typealias Processor = @Sendable (ProcessingJob) -> PhotoPipeline.CropKind?

    private(set) var state = SessionState()
    private(set) var tiles: [SlotTile] = []
    /// Set when a shot couldn't be saved, because the slot then needs shooting again.
    private(set) var captureFailed = false

    var canDiscard: Bool { !state.shot.isEmpty }
    var currentRecord: Record? { record }
    /// Called whenever a photo finishes processing or a record closes, which naming may be waiting on.
    var onProgress: (() -> Void)?

    /// A photo that crashes the app gets this many tries, so it can't stop the app from opening.
    private static let maxAttempts = 3

    private let context: ModelContext
    private let files: PhotoFiles
    private let keepOriginals: Bool
    private let processor: Processor
    private var record: Record?
    private var activeJob: Task<Void, Never>?

    init(context: ModelContext, files: PhotoFiles, keepOriginals: Bool = true, processor: @escaping Processor = PhotoProcessor.process) {
        self.context = context
        self.files = files
        self.keepOriginals = keepOriginals
        self.processor = processor
        recoverAfterLaunch()
        processNext()
    }

    // MARK: - Shooting

    /// Saves the shot's row and moves on to the next slot, so the camera can take the photo while
    /// the user is already placing the next record side. Nil when no slot is waiting.
    func beginCapture() -> CaptureTicket? {
        guard let slot = state.currentSlot else { return nil }
        let record = record ?? makeRecord()
        let photo = Photo(slot: slot)
        photo.record = record
        context.insert(photo)
        save()
        state.recordShot(in: slot)
        captureFailed = false
        refresh()
        return CaptureTicket(location: PhotoLocation(sessionID: record.sessionID, photoID: photo.id), slot: slot)
    }

    func captureFinished(_ ticket: CaptureTicket, didSave: Bool) {
        guard let photo = photo(id: ticket.location.photoID) else {
            // Discarded while the camera was still working, so nothing should be left behind.
            files.remove(ticket.location)
            return
        }
        if didSave {
            photo.state = .pending
            removeReplacedPhotos(by: photo)
        } else {
            context.delete(photo)
            captureFailed = true
        }
        save()
        refresh()
        processNext()
    }

    func skip() {
        state.skipCurrent()
        record?.skippedSlots = state.skipped.map(\.number)
        save()
    }

    /// Tapping the slot already picked cancels the retake.
    func select(_ slot: Slot) {
        state.target = state.target == .slot(slot) ? nil : .slot(slot)
    }

    /// Tapping again cancels the extra.
    func toggleExtra() {
        state.target = state.target == .extra ? nil : .extra
    }

    func finish() {
        guard state.canFinish, let record else { return }
        record.isOpen = false
        save()
        startNewSession()
        onProgress?()
    }

    func discard() {
        guard let record else { return }
        files.removeSession(record.sessionID)
        context.delete(record)
        save()
        startNewSession()
    }

    // MARK: - Processing queue

    /// Waits for the queue to run dry.
    func waitUntilProcessed() async {
        while let activeJob { await activeJob.value }
    }

    private func processNext() {
        guard activeJob == nil, let photo = oldestPendingPhoto() else { return }
        guard photo.attempts < Self.maxAttempts, let sessionID = photo.record?.sessionID else {
            photo.state = .failed
            save()
            refresh()
            processNext()
            return
        }
        // Saved before starting, so a crash during processing counts against this photo.
        photo.attempts += 1
        save()

        let location = PhotoLocation(sessionID: sessionID, photoID: photo.id)
        let job = ProcessingJob(
            location: location,
            original: files.originalURL(location),
            finished: files.finishedURL(location),
            thumbnail: files.thumbnailURL(location)
        )
        let processor = processor
        activeJob = Task.detached(priority: .utility) { [weak self] in
            let cropKind = processor(job)
            await self?.processingFinished(job, cropKind: cropKind)
        }
    }

    private func processingFinished(_ job: ProcessingJob, cropKind: PhotoPipeline.CropKind?) {
        activeJob = nil
        if let photo = photo(id: job.location.photoID) {
            photo.state = cropKind == nil ? .failed : .processed
            photo.cropKind = cropKind
            if cropKind != nil, !keepOriginals { try? FileManager.default.removeItem(at: job.original) }
            save()
        } else {
            // Discarded or replaced while it was being processed.
            files.remove(job.location)
        }
        refresh()
        onProgress?()
        processNext()
    }

    private func oldestPendingPhoto() -> Photo? {
        let pending = Photo.State.pending.rawValue
        var descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.stateValue == pending },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Recovery

    private func recoverAfterLaunch() {
        let capturing = Photo.State.capturing.rawValue
        let interrupted = (try? context.fetch(FetchDescriptor<Photo>(predicate: #Predicate { $0.stateValue == capturing }))) ?? []
        for photo in interrupted {
            let location = photo.record.map { PhotoLocation(sessionID: $0.sessionID, photoID: photo.id) }
            if let location, FileManager.default.fileExists(atPath: files.originalURL(location).path()) {
                // The app died after the photo reached the disk but before it was noted.
                photo.state = .pending
                removeReplacedPhotos(by: photo)
            } else {
                context.delete(photo)
            }
        }
        save()

        let openRecords = (try? context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.isOpen }))) ?? []
        record = openRecords.first { !$0.photos.isEmpty }
        for empty in openRecords where empty.photos.isEmpty {
            context.delete(empty)
        }
        save()
        refresh()
    }

    // MARK: - Helpers

    private func makeRecord() -> Record {
        let record = Record(sessionID: Self.makeSessionID())
        context.insert(record)
        self.record = record
        return record
    }

    /// Read in a folder listing on a Mac, so it sorts by time. The UUID's end keeps it unique, as
    /// two sessions can begin within the same second.
    private static func makeSessionID() -> String {
        let time = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(time)-\(UUID().uuidString.prefix(4))"
    }

    private func startNewSession() {
        record = nil
        state = SessionState()
        tiles = []
        captureFailed = false
    }

    /// A retake leaves the old photo in place until the new one is safely on disk.
    private func removeReplacedPhotos(by newest: Photo) {
        guard let record = newest.record else { return }
        for photo in record.photos where photo.id != newest.id && photo.slotNumber == newest.slotNumber {
            // The new photo may read differently, unless the name was typed by hand.
            if photo.isTextRead, !record.isNameEdited { record.name = nil }
            files.remove(PhotoLocation(sessionID: record.sessionID, photoID: photo.id))
            context.delete(photo)
        }
    }

    private func photo(id: UUID) -> Photo? {
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Rebuilds the shot list from what's stored, so a resumed session behaves exactly like a live one.
    private func refresh() {
        guard let record else { return }
        let photos = record.photos.filter { !$0.isDeleted }
        state.shot = Set(photos.map(\.slot))
        state.skipped = Set(record.skippedSlots.map(Slot.init(number:))).subtracting(state.shot)

        let newestBySlot = Dictionary(photos.map { ($0.slot, $0) }) { first, second in
            first.capturedAt > second.capturedAt ? first : second
        }
        let shotTiles = newestBySlot.map { slot, photo in
            let location = PhotoLocation(sessionID: record.sessionID, photoID: photo.id)
            return SlotTile(
                slot: slot,
                thumbnail: photo.state == .processed ? files.thumbnailURL(location) : nil,
                isProcessed: photo.state == .processed
            )
        }
        let skippedTiles = state.skipped.map { SlotTile(slot: $0, thumbnail: nil, isProcessed: false) }
        tiles = (shotTiles + skippedTiles).sorted { $0.slot < $1.slot }
    }

    private func save() {
        try? context.save()
    }
}
