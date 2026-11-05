import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Turns a full-frame original into the finished listing photo: straightened, cropped to the
/// record, and sized for eBay and Shopify.
enum PhotoPipeline {
    static let outputSide = 2048

    enum CropKind: String, Codable, Sendable {
        case sleeve, disc
        /// Edges weren't found, so the guide area is used as it is.
        case guideFallback
    }

    struct Output: Sendable {
        var jpeg: Data
        var cropKind: CropKind
    }

    /// Trims a sliver inside the detected edge, so no background shows along it.
    private static let edgeInset: CGFloat = 0.005
    private static let detectionMaxSide: CGFloat = 1600

    /// One shared context: creating one per photo is slow and costs memory.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .cacheIntermediates: false,
    ])

    static func process(url: URL, lens: Lens) -> Output? {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        return process(image: image, lens: lens)
    }

    static func process(image: CIImage, lens: Lens) -> Output? {
        let original = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let extent = original.extent

        // A pale sleeve barely stands out from the white table, so if the first look finds nothing,
        // try again with the highlights spread apart.
        let detected = proxy(of: original).flatMap { RecordDetector.detect(in: $0, lens: lens) }
            ?? proxy(of: paleEdgesBoosted(original)).flatMap { RecordDetector.detect(in: $0, lens: lens) }
        let cropped: CIImage?
        let kind: CropKind
        switch detected {
        case .sleeve(let quad):
            cropped = straightened(original, quad: quad)
            kind = .sleeve
        case .disc(let square):
            let rect = CGRect(
                x: square.minX * extent.width,
                y: square.minY * extent.height,
                width: square.width * extent.width,
                height: square.height * extent.height
            )
            cropped = original.cropped(to: rect)
            kind = .disc
        case nil:
            let side = lens.guideHalfSide * 2 * min(extent.width, extent.height)
            cropped = original.cropped(to: CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side))
            kind = .guideFallback
        }

        guard
            let cropped,
            let finished = resized(cropped),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let jpeg = context.jpegRepresentation(
                of: finished,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]
            )
        else { return nil }
        return Output(jpeg: jpeg, cropKind: kind)
    }

    private static func paleEdgesBoosted(_ image: CIImage) -> CIImage {
        let filter = CIFilter.gammaAdjust()
        filter.inputImage = image
        filter.power = 4
        return filter.outputImage ?? image
    }

    private static func proxy(of image: CIImage) -> CGImage? {
        let scale = min(detectionMaxSide / max(image.extent.width, image.extent.height), 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Corrects rotation and keystoning together by mapping the sleeve's corners to a square.
    private static func straightened(_ image: CIImage, quad: RecordQuad) -> CIImage? {
        let extent = image.extent
        let center = CGPoint(
            x: (quad.topLeft.x + quad.topRight.x + quad.bottomRight.x + quad.bottomLeft.x) / 4,
            y: (quad.topLeft.y + quad.topRight.y + quad.bottomRight.y + quad.bottomLeft.y) / 4
        )
        func corner(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x + (center.x - point.x) * edgeInset * 2) * extent.width,
                y: (point.y + (center.y - point.y) * edgeInset * 2) * extent.height
            )
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = corner(quad.topLeft)
        filter.topRight = corner(quad.topRight)
        filter.bottomRight = corner(quad.bottomRight)
        filter.bottomLeft = corner(quad.bottomLeft)
        return filter.outputImage
    }

    /// Scales to exactly the output size. Sleeves are very nearly square, so any stretch is too
    /// small to see.
    private static func resized(_ image: CIImage) -> CIImage? {
        let origin = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let target = CGFloat(outputSide)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = origin
        filter.scale = Float(target / origin.extent.height)
        filter.aspectRatio = Float(origin.extent.height / origin.extent.width)
        return filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: target, height: target))
    }
}
