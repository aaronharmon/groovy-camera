import Foundation
import SwiftData

/// One LP from first shot to Done. Empty records are never kept.
@Model
final class Record {
    @Attribute(.unique) var id: UUID
    /// The folder its files live in on the phone. Its folder on R2 is separate.
    var sessionID: String
    var createdAt: Date
    var isOpen: Bool
    var skippedSlots: [Int]
    /// The folder on R2, from the time of the first shot. See `RecordFolder`. Empty only on
    /// records saved before folders were stored, which are filled in at launch.
    var folder: String = ""
    @Relationship(deleteRule: .cascade, inverse: \Photo.record) var photos: [Photo]

    init(sessionID: String, folder: String, createdAt: Date = Date()) {
        id = UUID()
        self.sessionID = sessionID
        self.folder = folder
        self.createdAt = createdAt
        isOpen = true
        skippedSlots = []
        photos = []
    }
}

@Model
final class Photo {
    /// Stored by name rather than number, so a saved photo's meaning can't shift if this changes.
    enum State: String {
        /// The row exists but the camera hasn't finished saving the original.
        case capturing
        /// The original is on disk and waiting for the queue.
        case pending
        case processed
        /// Tried and gave up. The original is kept.
        case failed
    }

    @Attribute(.unique) var id: UUID
    var slotNumber: Int
    var capturedAt: Date
    var stateValue: String
    var attempts: Int
    var cropKindValue: String?
    var record: Record?

    /// Stored by name, like `State`. A photo uploads once its record is done and it's processed.
    enum Upload: String {
        case waiting
        /// Handed to iOS's background uploader.
        case uploading
        /// R2 confirmed it has exactly this file.
        case uploaded
        /// Gave up: the token was refused or it failed too often. Saving Settings tries again.
        case needsAttention
    }

    var uploadStateValue: String = Upload.waiting.rawValue
    var uploadAttempts: Int = 0
    /// The background task now carrying it. A result from any other task is stale.
    var uploadTaskID: Int?
    /// When its upload URL was signed, which tells an expired URL from a refused token.
    var uploadSignedAt: Date?
    var uploadedAt: Date?

    init(slot: Slot) {
        id = UUID()
        slotNumber = slot.number
        capturedAt = Date()
        stateValue = State.capturing.rawValue
        attempts = 0
    }

    var slot: Slot { Slot(number: slotNumber) }

    var state: State {
        get { State(rawValue: stateValue) ?? .failed }
        set { stateValue = newValue.rawValue }
    }

    var upload: Upload {
        get { Upload(rawValue: uploadStateValue) ?? .waiting }
        set { uploadStateValue = newValue.rawValue }
    }

    var cropKind: PhotoPipeline.CropKind? {
        get { cropKindValue.flatMap(PhotoPipeline.CropKind.init(rawValue:)) }
        set { cropKindValue = newValue?.rawValue }
    }
}
