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

    /// A thin border of table left around a sleeve, as a share of its side, so buyers can see the
    /// edges and corners for wear. It also hides small errors in where the edge was found.
    static let sleeveMargin: CGFloat = 0.03
    /// How far either side of Vision's edge to look for the real one, as a share of the sleeve.
    /// Vision's corners have been measured up to 4% off on real sleeves.
    private static let edgeSearchShare: CGFloat = 0.06
    /// Only the middle of each side is searched, because worn corners and rounded tips mislead.
    private static let edgeSearchLengthShare: CGFloat = 0.7
    private static let edgeSearchSegments = 15
    /// A sleeve is square to well within this, so a bigger difference means an edge was misread.
    private static let maxSnappedAspectError: CGFloat = 0.03
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
        let source: CIImage
        let crop: CGRect
        let kind: CropKind
        switch detected {
        case .sleeve(let quad):
            (source, crop) = straightened(original, quad: quad)
            kind = .sleeve
        case .disc(let square):
            source = original
            crop = CGRect(
                x: square.minX * extent.width,
                y: square.minY * extent.height,
                width: square.width * extent.width,
                height: square.height * extent.height
            )
            kind = .disc
        case nil:
            let side = lens.guideHalfSide * 2 * min(extent.width, extent.height)
            source = original
            crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
            kind = .guideFallback
        }

        guard
            let finished = resized(source, crop: crop),
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

    /// Rotates the sleeve upright and crops to it. This is deliberately not a perspective warp: the
    /// level keeps the phone flat, so a sleeve really is a square, and warping to four noisy
    /// corners makes it look tilted in 3D.
    private static func straightened(_ image: CIImage, quad: RecordQuad) -> (CIImage, CGRect) {
        let extent = image.extent
        let square = quad.fittedSquare(width: extent.width, height: extent.height)
        let upright = CGAffineTransform(translationX: square.center.x, y: square.center.y)
            .rotated(by: -square.radians)
            .translatedBy(x: -square.center.x, y: -square.center.y)
        let rotated = image.transformed(by: upright)
        let snapped = snappedToEdges(rotated, center: square.center, side: square.side)
        let center = snapped.center
        let withMargin = squareAround(center, side: snapped.side * (1 + sleeveMargin * 2))
        // Past the photo's edge there's nothing to show, so a sleeve right at the edge gets no border.
        let crop = isInside(withMargin, of: extent, after: upright) ? withMargin : squareAround(center, side: snapped.side)
        return (rotated, crop)
    }

    private static func squareAround(_ center: CGPoint, side: CGFloat) -> CGRect {
        CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Whether every corner of a crop in the rotated image lands inside the original photo.
    private static func isInside(_ crop: CGRect, of extent: CGRect, after transform: CGAffineTransform) -> Bool {
        let back = transform.inverted()
        return [
            CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY),
        ].allSatisfy { extent.insetBy(dx: -0.5, dy: -0.5).contains($0.applying(back)) }
    }

    /// Vision finds the right rectangle but places it loosely, which leaves a strip of table or
    /// clips the sleeve. This moves each side to where the table really ends, looking inward from
    /// the table so that artwork inside the sleeve can't be mistaken for its edge. It only moves the
    /// crop, so the record's shape is untouched. A side with no clear edge, such as a pale sleeve on
    /// the white table, keeps Vision's position.
    private static func snappedToEdges(_ image: CIImage, center: CGPoint, side: CGFloat) -> (center: CGPoint, side: CGFloat) {
        let half = side / 2
        let band = side * edgeSearchShare
        let length = side * edgeSearchLengthShare

        // Each value is how far the real edge lies inside the outer limit of the search band.
        let leftDepth = edgeDepth(in: image, band: CGRect(x: center.x - half - band, y: center.y - length / 2, width: band * 2, height: length), inwardAxis: .plusX)
        let rightDepth = edgeDepth(in: image, band: CGRect(x: center.x + half - band, y: center.y - length / 2, width: band * 2, height: length), inwardAxis: .minusX)
        let bottomDepth = edgeDepth(in: image, band: CGRect(x: center.x - length / 2, y: center.y - half - band, width: length, height: band * 2), inwardAxis: .plusY)
        let topDepth = edgeDepth(in: image, band: CGRect(x: center.x - length / 2, y: center.y + half - band, width: length, height: band * 2), inwardAxis: .minusY)

        let left = center.x - half + (leftDepth.map { $0 - band } ?? 0)
        let right = center.x + half - (rightDepth.map { $0 - band } ?? 0)
        let bottom = center.y - half + (bottomDepth.map { $0 - band } ?? 0)
        let top = center.y + half - (topDepth.map { $0 - band } ?? 0)

        let width = right - left
        let height = top - bottom
        guard min(width, height) > 0, abs(width - height) / min(width, height) <= maxSnappedAspectError else {
            return (center, side)
        }
        return (CGPoint(x: (left + right) / 2, y: (bottom + top) / 2), min(width, height))
    }

    private enum InwardAxis { case plusX, minusX, plusY, minusY }

    /// Splits the band into segments along the edge, finds the edge in each, and takes the median, so
    /// a scuff or a stray shadow on a few segments doesn't move the crop.
    private static func edgeDepth(in image: CIImage, band: CGRect, inwardAxis: InwardAxis) -> CGFloat? {
        let bounds = band.integral
        guard
            image.extent.contains(bounds),
            let cgImage = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        func brightness(column: Int, row: Int) -> Float {
            let pixel = bytes + row * bytesPerRow + column * 4
            return (Float(pixel[0]) * 0.299 + Float(pixel[1]) * 0.587 + Float(pixel[2]) * 0.114) / 255
        }

        let isHorizontalSearch = inwardAxis == .plusX || inwardAxis == .minusX
        let depthCount = isHorizontalSearch ? width : height
        let alongCount = isHorizontalSearch ? height : width
        // A CGImage's first row is the top of the image, the opposite way to Core Image's y axis.
        let walksForward = inwardAxis == .plusX || inwardAxis == .minusY

        let profiles = (0..<edgeSearchSegments).map { segment -> [Float] in
            let start = alongCount * segment / edgeSearchSegments
            let end = alongCount * (segment + 1) / edgeSearchSegments
            return (0..<depthCount).map { step in
                let depth = walksForward ? step : depthCount - 1 - step
                var total: Float = 0
                for along in start..<end {
                    total += isHorizontalSearch ? brightness(column: depth, row: along) : brightness(column: along, row: depth)
                }
                return total / Float(end - start)
            }
        }
        return RecordEdge.depth(acrossProfiles: profiles).map(CGFloat.init)
    }

    /// Scales evenly to the output size, so the record's shape never changes. The crop comes last
    /// because the resize blends each pixel with its neighbours: cropping first would blend the
    /// empty space past the edge into a dark line around the photo.
    private static func resized(_ image: CIImage, crop: CGRect) -> CIImage? {
        let target = CGFloat(outputSide)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        filter.scale = Float(target / min(crop.width, crop.height))
        filter.aspectRatio = 1
        return filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: target, height: target))
    }
}
