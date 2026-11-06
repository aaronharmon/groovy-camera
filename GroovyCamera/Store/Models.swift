import Foundation
import SwiftData

/// One LP from first shot to Done. Empty records are never kept.
@Model
final class Record {
    @Attribute(.unique) var id: UUID
    /// The folder its files live in on the phone. The name on R2 is separate, so renames move nothing.
    var sessionID: String
    var createdAt: Date
    var isOpen: Bool
    var skippedSlots: [Int]
    /// "Artist — Title". Nil until a name is found.
    var name: String?
    /// An answer with no distinct album, such as the artist twice. Reading carries on hoping for
    /// better, and this is used only if nothing better turns up, as some albums are self-titled.
    var partialName: String?
    var isNameEdited: Bool = false
    /// Set when the toast ends. The folder is fixed from here on, and uploads may begin.
    var isNameFinal: Bool = false
    /// The folder on R2, worked out only once the name is final.
    var folderSlug: String?
    @Relationship(deleteRule: .cascade, inverse: \Photo.record) var photos: [Photo]

    init(sessionID: String) {
        id = UUID()
        self.sessionID = sessionID
        createdAt = Date()
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
    var isTextRead: Bool = false
    var recognizedLinesData: Data?
    var record: Record?

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

    var recognizedLines: [TextLine] {
        get { recognizedLinesData.flatMap { try? JSONDecoder().decode([TextLine].self, from: $0) } ?? [] }
        set { recognizedLinesData = try? JSONEncoder().encode(newValue) }
    }

    var cropKind: PhotoPipeline.CropKind? {
        get { cropKindValue.flatMap(PhotoPipeline.CropKind.init(rawValue:)) }
        set { cropKindValue = newValue?.rawValue }
    }
}
