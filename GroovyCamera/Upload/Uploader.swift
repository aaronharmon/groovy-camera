import Foundation
import Observation
import SwiftData

/// Uploads finished photos to R2 through iOS's background uploader, so they keep going while the
/// app is closed or the phone is offline. iOS relaunches the app in the background to report
/// results, and this records them.
///
/// Photos upload only after their record is done, so retakes and discards never reach R2. The R2
/// path is worked out here, at upload time, from the record's folder and the photo's slot.
@MainActor
@Observable
final class Uploader {
    static let sessionIdentifier = "groovycamera.uploads"
    /// Marks the spreadsheet's upload task, followed by the version it carries.
    private static let indexTaskPrefix = "index:"

    struct Summary: Equatable {
        var waiting = 0
        var uploaded = 0
        var needsAttention = 0
    }

    private(set) var summary = Summary()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let files: PhotoFiles
    @ObservationIgnored private let events = UploadEvents()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var isScheduling = false
    @ObservationIgnored private var needsAnotherPass = false
    /// Bumped whenever the spreadsheet's contents change. Stored, so a change made just before the
    /// app closes still gets uploaded.
    @ObservationIgnored private var indexVersion: Int {
        get { UserDefaults.standard.integer(forKey: "photoIndexVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "photoIndexVersion") }
    }
    @ObservationIgnored private var indexUploadedVersion: Int {
        get { UserDefaults.standard.integer(forKey: "photoIndexUploadedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "photoIndexUploadedVersion") }
    }
    @ObservationIgnored private let indexDirectory = URL.applicationSupportDirectory.appending(path: "photo-index", directoryHint: .isDirectory)

    init(context: ModelContext, files: PhotoFiles) {
        self.context = context
        self.files = files
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Delivered on the main queue, so results can't arrive before `onFinished` is set.
        session = URLSession(configuration: configuration, delegate: events, delegateQueue: .main)
        events.onFinished = { [weak self] result in
            MainActor.assumeIsolated { self?.finished(result) }
        }
        events.onAllDelivered = { [weak self] in
            MainActor.assumeIsolated {
                self?.save()
                BackgroundUploads.finishEvents()
            }
        }
        schedule()
    }

    /// Hands every ready photo without a live upload to iOS.
    func schedule() {
        guard !isScheduling else {
            needsAnotherPass = true
            return
        }
        isScheduling = true
        Task {
            await scheduleReady()
            isScheduling = false
            if needsAnotherPass {
                needsAnotherPass = false
                schedule()
            }
        }
    }

    /// After Settings change, photos that gave up get another go.
    func retryAfterSettingsChange() {
        for photo in photos(in: .needsAttention) {
            photo.upload = .waiting
            photo.uploadAttempts = 0
        }
        save()
        schedule()
    }

    /// The photo domain changed, so every link in the spreadsheet did too.
    func photoDomainChanged() {
        indexVersion += 1
        schedule()
    }

    /// Empties the spreadsheet: from now on it lists only records started after this.
    func clearSpreadsheet() {
        PhotoIndexStart.save(Date())
        indexVersion += 1
        schedule()
    }

    /// Clears the phone's copies of photos R2 has confirmed, once they've been kept long enough.
    func clearUploaded() {
        let keepDays = LocalCopies.keepDays
        let keepOriginals = LocalCopies.keepOriginals
        let now = Date()
        for photo in photos(in: .uploaded) where !photo.isCleared {
            guard let record = photo.record, let uploadedAt = photo.uploadedAt,
                  LocalCopies.isDue(uploadedAt: uploadedAt, keepDays: keepDays, now: now) else { continue }
            files.removeUploaded(PhotoLocation(sessionID: record.sessionID, photoID: photo.id), keepingOriginal: keepOriginals)
            photo.isCleared = true
        }
        save()
    }

    private func scheduleReady() async {
        clearUploaded()
        let tasks = await session.allTasks
        let liveTasks = Set(tasks.map(\.taskIdentifier))
        let isIndexUploading = tasks.contains { $0.taskDescription?.hasPrefix(Self.indexTaskPrefix) == true }
        guard let credentials = CredentialStore.load(), credentials.isComplete else {
            refreshSummary()
            return
        }
        let client = R2Client(credentials: credentials)

        for photo in photos(in: .waiting) + photos(in: .uploading) {
            guard photo.state == .processed, let record = photo.record, !record.isOpen else { continue }
            if photo.upload == .uploading, let id = photo.uploadTaskID, liveTasks.contains(id) { continue }

            // iOS cancels background uploads when the app is force-quit, so an "uploading" photo
            // without a live task starts again here.
            let file = files.finishedURL(PhotoLocation(sessionID: record.sessionID, photoID: photo.id))
            let key = R2Client.key(folder: record.folder, slot: photo.slot)
            guard FileManager.default.fileExists(atPath: file.path()), let request = client.photoUpload(key: key) else {
                photo.upload = .needsAttention
                continue
            }
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = photo.id.uuidString
            photo.upload = .uploading
            photo.uploadTaskID = task.taskIdentifier
            photo.uploadSignedAt = Date()
            task.resume()
        }
        save()
        refreshSummary()

        // The spreadsheet goes up once the photos have, so its links all work when it changes.
        if summary.waiting == 0, indexUploadedVersion != indexVersion, !isIndexUploading {
            uploadIndex(with: client)
        }
    }

    private func uploadIndex(with client: R2Client) {
        let domain = PhotoDomain.load()
        guard !domain.isEmpty, let request = client.request(method: "PUT", key: PhotoIndex.key, headers: PhotoIndex.headers) else { return }
        let clearedAt = PhotoIndexStart.load()
        let entries = photos(in: .uploaded).compactMap { photo -> PhotoIndex.Entry? in
            guard let record = photo.record, PhotoIndexStart.lists(recordCreatedAt: record.createdAt, clearedAt: clearedAt) else { return nil }
            return PhotoIndex.Entry(folder: record.folder, slot: photo.slot)
        }
        let version = indexVersion
        // Versioned, so a newer spreadsheet never overwrites a file iOS is still sending.
        let file = indexDirectory.appending(path: "photos-\(version).csv")
        do {
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            try Data(PhotoIndex.csv(entries, domain: domain).utf8).write(to: file, options: .atomic)
        } catch {
            return
        }
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = "\(Self.indexTaskPrefix)\(version)"
        task.resume()
    }

    private func indexFinished(version: Int, result: UploadEvents.Result) {
        try? FileManager.default.removeItem(at: indexDirectory.appending(path: "photos-\(version).csv"))
        // A failure waits for the next pass, which comes with the next upload, Settings change or
        // the app coming to the front.
        if let status = result.status, (200..<300).contains(status) {
            indexUploadedVersion = max(indexUploadedVersion, version)
        }
        if indexUploadedVersion != indexVersion, !result.isCancelled { schedule() }
    }

    private func finished(_ result: UploadEvents.Result) {
        if let description = result.photoID, description.hasPrefix(Self.indexTaskPrefix) {
            if let version = Int(description.dropFirst(Self.indexTaskPrefix.count)) { indexFinished(version: version, result: result) }
            return
        }
        guard let id = result.photoID.flatMap(UUID.init(uuidString:)), let photo = photo(id: id),
              photo.uploadTaskID == result.taskID, photo.upload == .uploading else { return }

        if result.isCancelled {
            // Force-quit or replaced. It starts again on the next pass.
            photo.upload = .waiting
            save()
            refreshSummary()
            return
        }

        let file = photo.record.map { files.finishedURL(PhotoLocation(sessionID: $0.sessionID, photoID: photo.id)) }
        photo.uploadAttempts += 1
        let next = UploadPolicy.next(
            status: result.status,
            etagMatches: file.map { UploadPolicy.etag(result.etag, matches: $0) } ?? false,
            signedAt: photo.uploadSignedAt ?? .distantPast,
            now: Date(),
            attempts: photo.uploadAttempts
        )
        photo.uploadTaskID = nil
        switch next {
        case .uploaded:
            photo.upload = .uploaded
            photo.uploadedAt = Date()
            indexVersion += 1
        case .retry:
            photo.upload = .waiting
        case .needsAttention:
            photo.upload = .needsAttention
        }
        save()
        refreshSummary()
        if next == .uploaded { clearUploaded() }
        if next == .retry { schedule() }
    }

    private func photos(in upload: Photo.Upload) -> [Photo] {
        let value = upload.rawValue
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.uploadStateValue == value }, sortBy: [SortDescriptor(\.capturedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func photo(id: UUID) -> Photo? {
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Counts only photos from finished records that processed, since only those upload.
    private func refreshSummary() {
        let ready = { (photo: Photo) in photo.state == .processed && photo.record?.isOpen == false }
        summary = Summary(
            waiting: (photos(in: .waiting) + photos(in: .uploading)).filter(ready).count,
            uploaded: photos(in: .uploaded).count,
            needsAttention: photos(in: .needsAttention).count
        )
    }

    private func save() {
        try? context.save()
    }
}

/// Receives URLSession's delegate calls and passes them on. A separate object because URLSession
/// keeps a strong reference to its delegate.
final class UploadEvents: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Result {
        var taskID: Int
        /// The photo's id, or the spreadsheet's marker.
        var photoID: String?
        var status: Int?
        var etag: String?
        var isCancelled: Bool
    }

    var onFinished: ((Result) -> Void)?
    var onAllDelivered: (() -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response as? HTTPURLResponse
        onFinished?(Result(
            taskID: task.taskIdentifier,
            photoID: task.taskDescription,
            status: response?.statusCode,
            etag: response?.value(forHTTPHeaderField: "ETag"),
            isCancelled: (error as? URLError)?.code == .cancelled
        ))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onAllDelivered?()
    }
}

/// Holds the completion handler iOS passes when it relaunches the app for upload results. It must
/// be called once they've all been handled, so iOS can snapshot the app and suspend it again.
@MainActor
enum BackgroundUploads {
    static var completionHandler: (() -> Void)?

    static func finishEvents() {
        completionHandler?()
        completionHandler = nil
    }
}
