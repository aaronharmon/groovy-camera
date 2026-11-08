import Foundation

/// What was true when an original was shot, saved next to it so the image pipeline can be re-run
/// on it later.
struct OriginalSidecar: Codable, Equatable, Sendable {
    var sessionID: String
    var photoID: UUID
    var slotNumber: Int
    var capturedAt: Date
    var lens: Lens
    var pixelWidth: Int
    var pixelHeight: Int
    var gains: ColorGains
    var exposure: ExposureSetting
    var lensPosition: Double
    var shutterToProcessedMS: Int
    var shutterToSavedMS: Int
}

/// Where one photo's files live.
struct PhotoLocation: Hashable, Sendable {
    var sessionID: String
    var photoID: UUID
}

/// Keeps each photo's files under `Documents/originals/<session>`, named by id. Their names
/// on R2 are worked out at upload time. `scripts/pull-originals.sh` copies this folder to a Mac.
struct PhotoFiles: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.documentsDirectory.appending(path: "originals", directoryHint: .isDirectory)
    }

    func originalURL(_ location: PhotoLocation) -> URL {
        file(location, suffix: ".heic")
    }

    func finishedURL(_ location: PhotoLocation) -> URL {
        file(location, suffix: "-2048.jpg")
    }

    func thumbnailURL(_ location: PhotoLocation) -> URL {
        file(location, suffix: "-thumb.jpg")
    }

    /// Runs before anything else looks at the photo, so a later crash can't lose it.
    func saveOriginal(_ data: Data, for location: PhotoLocation) throws {
        try Self.write(data, to: originalURL(location))
    }

    func saveSidecar(_ sidecar: OriginalSidecar, for location: PhotoLocation) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.write(encoder.encode(sidecar), to: sidecarURL(location))
    }

    /// Uploads must work on a locked phone, so files stay readable after the first unlock.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Removes one photo's files, and its session folder if that was the last of them.
    func remove(_ location: PhotoLocation) {
        remove([originalURL(location), finishedURL(location), thumbnailURL(location), sidecarURL(location)], in: location)
    }

    /// Clears a photo R2 has confirmed. The original and its sidecar can stay for re-running the
    /// image pipeline.
    func removeUploaded(_ location: PhotoLocation, keepingOriginal: Bool) {
        let copies = [finishedURL(location), thumbnailURL(location)]
        remove(keepingOriginal ? copies : copies + [originalURL(location), sidecarURL(location)], in: location)
    }

    private func remove(_ urls: [URL], in location: PhotoLocation) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        let session = sessionDirectory(location.sessionID)
        if (try? FileManager.default.contentsOfDirectory(atPath: session.path()))?.isEmpty == true {
            try? FileManager.default.removeItem(at: session)
        }
    }

    func removeSession(_ sessionID: String) {
        try? FileManager.default.removeItem(at: sessionDirectory(sessionID))
    }

    private func sidecarURL(_ location: PhotoLocation) -> URL {
        file(location, suffix: ".json")
    }

    private func file(_ location: PhotoLocation, suffix: String) -> URL {
        sessionDirectory(location.sessionID).appending(path: location.photoID.uuidString + suffix)
    }

    private func sessionDirectory(_ sessionID: String) -> URL {
        directory.appending(path: sessionID, directoryHint: .isDirectory)
    }
}
