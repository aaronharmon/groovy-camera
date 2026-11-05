import CoreGraphics
import Foundation
import ImageIO

enum SavedPhotoAnalyzer {
    /// Measures the white background in a saved photo.
    ///
    /// The live preview and the saved photo pass through different processing, so only this
    /// measurement says whether the result is actually neutral and unclipped. Reads a downsampled
    /// copy so that no full 48 MP image is decoded just to measure the margin.
    static func analyze(url: URL, ring: GuideRing, maxPixelSize: Int = 2000) -> BackgroundSample? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        return pixels.withUnsafeMutableBytes { buffer -> BackgroundSample? in
            guard
                let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return BackgroundSampler.sample(
                base: UnsafeRawPointer(base),
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                layout: .rgba,
                ring: ring
            )
        }
    }
}
