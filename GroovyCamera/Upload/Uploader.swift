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

    private func scheduleReady() async {
        let liveTasks = Set(await session.allTasks.map(\.taskIdentifier))
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
    }

    private func finished(_ result: UploadEvents.Result) {
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
        case .retry:
            photo.upload = .waiting
        case .needsAttention:
            photo.upload = .needsAttention
        }
        save()
        refreshSummary()
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
