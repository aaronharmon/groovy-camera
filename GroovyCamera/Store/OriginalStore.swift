import Foundation

/// What was true when an original was shot, saved next to it so the image pipeline can be re-run
/// on it later.
struct OriginalSidecar: Codable, Equatable, Sendable {
    var sessionID: String
    var shotIndex: Int
    var capturedAt: Date
    var lens: Lens
    var debugOptions: String
    var pixelWidth: Int
    var pixelHeight: Int
    var gains: ColorGains
    var exposure: ExposureSetting
    var lensPosition: Double
    var savedSample: BackgroundSample?
    var cropKind: PhotoPipeline.CropKind?
    var shutterToProcessedMS: Int
    var shutterToSavedMS: Int
}

/// Writes originals under `Documents/originals`, which `scripts/pull-originals.sh` copies to a Mac.
struct OriginalStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.documentsDirectory.appending(path: "originals", directoryHint: .isDirectory)
    }

    func photoURL(sessionID: String, shotIndex: Int, fileExtension: String) -> URL {
        sessionDirectory(sessionID).appending(path: "\(stem(shotIndex)).\(fileExtension)")
    }

    /// Saved before any analysis runs, so a later crash can't lose the photo.
    func savePhoto(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func finishedPhotoURL(sessionID: String, shotIndex: Int) -> URL {
        sessionDirectory(sessionID).appending(path: "\(stem(shotIndex))-2048.jpg")
    }

    func saveSidecar(_ sidecar: OriginalSidecar) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = sessionDirectory(sidecar.sessionID).appending(path: "\(stem(sidecar.shotIndex)).json")
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    private func sessionDirectory(_ sessionID: String) -> URL {
        directory.appending(path: sessionID, directoryHint: .isDirectory)
    }

    private func stem(_ shotIndex: Int) -> String {
        String(format: "%03d", shotIndex)
    }
}
