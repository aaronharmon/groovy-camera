import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import GroovyCamera

struct PhotoPipelineTests {
    private static let frameWidth = 1512
    private static let frameHeight = 2016

    /// A white table with a record on it, rotated by the given angle.
    private func frame(rotationDegrees: CGFloat, draw: (CGContext, CGFloat) -> Void) throws -> CIImage {
        let context = try #require(CGContext(
            data: nil,
            width: Self.frameWidth,
            height: Self.frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight))
        context.translateBy(x: CGFloat(Self.frameWidth) / 2, y: CGFloat(Self.frameHeight) / 2)
        context.rotate(by: rotationDegrees * .pi / 180)
        draw(context, Lens.ultraWide.sleeveShare * CGFloat(Self.frameWidth))
        return CIImage(cgImage: try #require(context.makeImage()))
    }

    private func decoded(_ jpeg: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Brightness of the pixel at a fraction of the way across and down.
    private func brightness(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: -x * width, y: -(1 - y) * height, width: width, height: height))
        return Int(pixel[1])
    }

    @Test(arguments: [0, 4, -8, 15, 25, -35] as [CGFloat])
    func straightensATiltedSleeveToFillTheOutput(degrees: CGFloat) throws {
        let image = try frame(rotationDegrees: degrees) { context, side in
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        }
        let output = try #require(PhotoPipeline.process(image: image, lens: .ultraWide))
        #expect(output.cropKind == .sleeve)

        let result = try decoded(output.jpeg)
        #expect(result.width == 2048 && result.height == 2048)
        // No white table left in any corner.
        for (x, y) in [(0.01, 0.01), (0.99, 0.01), (0.01, 0.99), (0.99, 0.99)] as [(CGFloat, CGFloat)] {
            #expect(try brightness(result, x: x, y: y) < 80, "corner \(x),\(y)")
        }
    }

    @Test(arguments: [10, -30, 40, -40] as [CGFloat])
    func keepsTheTopOfTheRecordUp(degrees: CGFloat) throws {
        let image = try frame(rotationDegrees: degrees) { context, side in
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            // A bright marker in the cover's top-left corner.
            context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: -side * 0.4, y: side * 0.25, width: side * 0.15, height: side * 0.15))
        }
        let output = try #require(PhotoPipeline.process(image: image, lens: .ultraWide))
        #expect(output.cropKind == .sleeve)
        let result = try decoded(output.jpeg)
        #expect(try brightness(result, x: 0.17, y: 0.17) > 150)
        #expect(try brightness(result, x: 0.83, y: 0.17) < 80)
        #expect(try brightness(result, x: 0.17, y: 0.83) < 80)
    }

    @Test func findsTheOuterEdgeNotTheArtworkInside() {
        // Table, then a cream sleeve, then a dark picture printed on it.
        let profile = [Float](repeating: 0.9, count: 40) + [Float](repeating: 0.78, count: 30) + [Float](repeating: 0.1, count: 30)
        #expect(RecordEdge.firstChange(in: profile) == 40)
    }

    @Test func slowFalloffOfLightIsNotAnEdge() {
        let profile = (0..<200).map { 0.9 - Float($0) * 0.0015 }
        #expect(RecordEdge.firstChange(in: profile) == nil)
    }

    @Test func aSpeckOnTheTableIsNotAnEdge() {
        var profile = [Float](repeating: 0.9, count: 100)
        profile[50] = 0.2
        profile[51] = 0.2
        #expect(RecordEdge.firstChange(in: profile) == nil)
    }

    @Test func aSideWithoutAgreementKeepsNoEdge() {
        let edge = [Float](repeating: 0.9, count: 40) + [Float](repeating: 0.2, count: 40)
        let plain = [Float](repeating: 0.9, count: 80)
        #expect(RecordEdge.depth(acrossProfiles: [edge, plain, plain]) == nil)
        #expect(RecordEdge.depth(acrossProfiles: [edge, edge, plain]) == 40)
    }

    /// The two rectangles Vision really proposed for a back cover: the accurate one, and a larger
    /// one with a corner out, which warped the crop when it was chosen.
    @Test func rejectsRectanglesWithACornerOut() {
        func quad(_ tl: (CGFloat, CGFloat), _ tr: (CGFloat, CGFloat), _ br: (CGFloat, CGFloat), _ bl: (CGFloat, CGFloat)) -> RecordQuad {
            func normalized(_ p: (CGFloat, CGFloat)) -> CGPoint { CGPoint(x: p.0 / 1200, y: p.1 / 1600) }
            return RecordQuad(topLeft: normalized(tl), topRight: normalized(tr), bottomRight: normalized(br), bottomLeft: normalized(bl))
        }
        let accurate = quad((240, 1160), (968, 1161), (954, 425), (240, 438))
        let cornerOut = quad((240, 1204), (949, 1101), (954, 425), (256, 438))
        #expect(accurate.isTrueSquare(width: 1200, height: 1600))
        #expect(!cornerOut.isTrueSquare(width: 1200, height: 1600))
    }

    @Test func cropsADiscToASquareAroundIt() throws {
        let image = try frame(rotationDegrees: 0) { context, side in
            context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
            context.fillEllipse(in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        }
        let output = try #require(PhotoPipeline.process(image: image, lens: .ultraWide))
        #expect(output.cropKind == .disc)

        let result = try decoded(output.jpeg)
        #expect(result.width == 2048 && result.height == 2048)
        #expect(try brightness(result, x: 0.02, y: 0.02) > 180)
        #expect(try brightness(result, x: 0.5, y: 0.03) < 80)
        #expect(try brightness(result, x: 0.5, y: 0.5) < 80)
    }

    @Test func fallsBackToTheGuideWhenThereIsNoRecord() throws {
        let image = try frame(rotationDegrees: 0) { _, _ in }
        let output = try #require(PhotoPipeline.process(image: image, lens: .ultraWide))
        #expect(output.cropKind == .guideFallback)
        let result = try decoded(output.jpeg)
        #expect(result.width == 2048 && result.height == 2048)
    }

    /// The resize used to blend in the empty space past the crop, leaving a dark line along the edges.
    @Test func leavesNoDarkLineAlongTheEdges() throws {
        let image = try frame(rotationDegrees: 0) { _, _ in }
        let output = try #require(PhotoPipeline.process(image: image, lens: .ultraWide))
        let result = try decoded(output.jpeg)
        // Fractions that land exactly on the outermost pixels, given how `brightness` samples.
        let onePixel: CGFloat = 1.0 / 2048
        for position in [0.1, 0.5, 0.9] as [CGFloat] {
            #expect(try brightness(result, x: position, y: onePixel) > 200, "top at \(position)")
            #expect(try brightness(result, x: position, y: 1) > 200, "bottom at \(position)")
            #expect(try brightness(result, x: 0, y: position) > 200, "left at \(position)")
            #expect(try brightness(result, x: 1 - onePixel, y: position) > 200, "right at \(position)")
        }
    }

    /// Runs on real photos when they're present, and writes results to review by eye. These stay
    /// out of git, so this does nothing on a fresh clone.
    @Test func processesRealPhotosIfPresent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/originals")
        // Only sessions shot on the ultra-wide, which is what the size check in detection expects.
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: root.path()) else { return }
        let ultraWide = sessions.filter { $0.hasPrefix("2026-") && $0 >= "2026-11-05T011906" }.sorted()
        let outputDirectory = root.appending(path: "pipeline-output")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for sessionName in ultraWide {
            let session = root.appending(path: sessionName)
            let names = try FileManager.default.contentsOfDirectory(atPath: session.path())
            for name in names.sorted() where name.hasSuffix(".heic") {
                let image = try #require(CIImage(contentsOf: session.appending(path: name), options: [.applyOrientationProperty: true]))
                for degrees in [0, -12] as [CGFloat] {
                    let rotated = degrees == 0 ? image : Self.rotated(image, degrees: degrees)
                    let output = try #require(PhotoPipeline.process(image: rotated, lens: .ultraWide))
                    let stem = name.replacingOccurrences(of: ".heic", with: "")
                    let file = "\(sessionName.suffix(6))-\(stem)-tilt\(Int(degrees))-\(output.cropKind.rawValue).jpg"
                    try output.jpeg.write(to: outputDirectory.appending(path: file))
                    print("PIPELINE \(file) \(output.jpeg.count / 1024)KB")
                }
            }
        }
    }

    /// Reports how the white margin around each real photo really came out. These stay out of git,
    /// so this does nothing on a fresh clone.
    @Test func reportsWhiteOnRealPhotosIfPresent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/originals")
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: root.path()) else { return }
        for sessionName in sessions.sorted() where sessionName.hasPrefix("2026-") && sessionName >= "2026-11-05T011906" {
            let session = root.appending(path: sessionName)
            for name in try FileManager.default.contentsOfDirectory(atPath: session.path()).sorted() where name.hasSuffix(".heic") {
                guard let sample = SavedPhotoAnalyzer.analyze(url: session.appending(path: name), ring: Lens.ultraWide.aroundGuide) else { continue }
                let percent = { (value: Double) in Int((value * 100).rounded()) }
                print("WHITE \(sessionName.suffix(6))-\(name) \(percent(sample.red))/\(percent(sample.green))/\(percent(sample.blue)) clipped \(percent(sample.clippedFraction))%")
            }
        }
    }

    /// Rotates about the center and fills the exposed corners with table white.
    private static func rotated(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let extent = image.extent
        let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        let table = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: extent)
        return image.transformed(by: transform).composited(over: table).cropped(to: extent)
    }
}
