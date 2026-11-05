import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GroovyCamera

private let testRing = GuideRing(innerHalfWidth: 0.40, innerHalfHeight: 0.40, outerHalfWidth: 0.48, outerHalfHeight: 0.48)

struct BackgroundSamplerTests {
    /// A frame with a colored background and a black record in the middle of the guide.
    private func frame(
        width: Int,
        height: Int,
        background: (UInt8, UInt8, UInt8),
        layout: PixelLayout = .rgba,
        ring: GuideRing = testRing
    ) -> [UInt8] {
        let short = CGFloat(min(width, height))
        let swap = width > height
        let halfX = Int((swap ? ring.innerHalfHeight : ring.innerHalfWidth) * short)
        let halfY = Int((swap ? ring.innerHalfWidth : ring.innerHalfHeight) * short)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isRecord = abs(x - width / 2) < halfX && abs(y - height / 2) < halfY
                let color = isRecord ? (UInt8(0), UInt8(0), UInt8(0)) : background
                let offset = (y * width + x) * 4
                pixels[offset] = layout == .bgra ? color.2 : color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = layout == .bgra ? color.0 : color.2
            }
        }
        return pixels
    }

    private func sample(_ pixels: [UInt8], width: Int, height: Int, layout: PixelLayout = .rgba, ring: GuideRing = testRing) -> BackgroundSample? {
        pixels.withUnsafeBytes {
            BackgroundSampler.sample(
                base: $0.baseAddress!,
                width: width,
                height: height,
                bytesPerRow: width * 4,
                layout: layout,
                ring: ring
            )
        }
    }

    @Test func readsTheMarginAndIgnoresTheRecord() throws {
        let pixels = frame(width: 300, height: 400, background: (240, 230, 220))
        let result = try #require(sample(pixels, width: 300, height: 400))
        #expect(abs(result.red - 240.0 / 255) < 0.001)
        #expect(abs(result.green - 230.0 / 255) < 0.001)
        #expect(abs(result.blue - 220.0 / 255) < 0.001)
        #expect(result.clippedFraction == 0)
    }

    @Test func readsBGRAChannelsInTheRightOrder() throws {
        let pixels = frame(width: 300, height: 400, background: (240, 230, 220), layout: .bgra)
        let result = try #require(sample(pixels, width: 300, height: 400, layout: .bgra))
        #expect(result.red > result.blue)
    }

    @Test func swapsAxesForLandscapeBuffers() throws {
        let ring = GuideRing(innerHalfWidth: 0.40, innerHalfHeight: 0.20, outerHalfWidth: 0.48, outerHalfHeight: 0.28)
        let pixels = frame(width: 400, height: 300, background: (235, 235, 235), ring: ring)
        let result = try #require(sample(pixels, width: 400, height: 300, ring: ring))
        #expect(abs(result.brightness - 235.0 / 255) < 0.001)
    }

    @Test func aHandCrossingTheMarginDoesNotSkewTheReading() throws {
        var pixels = frame(width: 300, height: 400, background: (235, 235, 235))
        // A dark band across part of the margin.
        for y in 0..<400 {
            for x in 0..<60 {
                let offset = (y * 300 + x) * 4
                (pixels[offset], pixels[offset + 1], pixels[offset + 2]) = (120, 90, 70)
            }
        }
        let result = try #require(sample(pixels, width: 300, height: 400))
        #expect(abs(result.brightness - 235.0 / 255) < 0.001)
    }

    @Test func readsTheMarginAroundTheGuideNotARecordInsideIt() throws {
        // A dark record filling the whole guide, in both buffer orientations.
        for (width, height) in [(300, 400), (400, 300)] {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let short = min(width, height)
            for y in 0..<height {
                for x in 0..<width {
                    let half = Int(Lens.ultraWide.guideHalfSide * CGFloat(short))
                    let inGuide = abs(x - width / 2) < half && abs(y - height / 2) < half
                    let value: UInt8 = inGuide ? 10 : 235
                    let offset = (y * width + x) * 4
                    (pixels[offset], pixels[offset + 1], pixels[offset + 2]) = (value, value, value)
                }
            }
            let result = try #require(sample(pixels, width: width, height: height, ring: Lens.ultraWide.aroundGuide))
            #expect(abs(result.brightness - 235.0 / 255) < 0.001)
        }
    }

    @Test func reportsClipping() throws {
        let pixels = frame(width: 300, height: 400, background: (255, 255, 255))
        let result = try #require(sample(pixels, width: 300, height: 400))
        #expect(result.clippedFraction == 1)
    }

    @Test func analyzesASavedPhoto() throws {
        let width = 300
        let height = 400
        var pixels = frame(width: width, height: height, background: (236, 236, 236))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try #require(context.makeImage())
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let result = try #require(SavedPhotoAnalyzer.analyze(url: url, ring: testRing))
        #expect(abs(result.brightness - 236.0 / 255) < 0.01)
        #expect(result.neutralError < 0.01)
    }
}
