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

    /// Runs on real photos when they're present, and writes results to review by eye. These stay
    /// out of git, so this does nothing on a fresh clone.
    @Test func processesRealPhotosIfPresent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/originals")
        let session = root.appending(path: "2026-11-05T011906")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: session.path()) else { return }
        let outputDirectory = root.appending(path: "pipeline-output")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for name in names.sorted() where name.hasSuffix(".heic") {
            let image = try #require(CIImage(contentsOf: session.appending(path: name), options: [.applyOrientationProperty: true]))
            for degrees in [0, 6, -12, 40] as [CGFloat] {
                let rotated = degrees == 0 ? image : Self.rotated(image, degrees: degrees)
                let output = try #require(PhotoPipeline.process(image: rotated, lens: .ultraWide))
                let stem = name.replacingOccurrences(of: ".heic", with: "")
                let file = "\(stem)-tilt\(Int(degrees))-\(output.cropKind.rawValue).jpg"
                try output.jpeg.write(to: outputDirectory.appending(path: file))
                print("PIPELINE \(file) \(output.jpeg.count / 1024)KB")
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
