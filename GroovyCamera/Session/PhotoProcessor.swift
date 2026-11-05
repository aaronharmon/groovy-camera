import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the processing queue does to each shot, away from the main thread.
enum PhotoProcessor {
    private static let thumbnailSide = 240

    /// Nil means the original couldn't be turned into a finished photo. The original stays on disk.
    static func process(_ job: ProcessingJob) -> PhotoPipeline.CropKind? {
        // Releases the decoded image before the next one starts, so two are never in memory together.
        autoreleasepool {
            guard
                let output = PhotoPipeline.process(url: job.original, lens: .ultraWide),
                (try? PhotoFiles.write(output.jpeg, to: job.finished)) != nil
            else { return nil }
            // The strip can live without a thumbnail, so a failure here doesn't fail the photo.
            if let thumbnail = makeThumbnail(of: output.jpeg) {
                try? PhotoFiles.write(thumbnail, to: job.thumbnail)
            }
            return output.cropKind
        }
    }

    static func makeThumbnail(of jpeg: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let output = NSMutableData()
        guard
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
