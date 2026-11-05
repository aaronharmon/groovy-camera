import CoreGraphics

/// The color of the white background, as gamma-encoded values from 0 to 1.
struct BackgroundSample: Equatable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    /// Share of sampled pixels with a channel at or near its maximum.
    var clippedFraction: Double
    var sampleCount: Int

    var brightness: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    /// Spread between the channels. Zero means perfectly neutral.
    var neutralError: Double { max(red, green, blue) - min(red, green, blue) }
}

enum PixelLayout: Sendable {
    case bgra
    case rgba
}

enum BackgroundSampler {
    /// Channel value treated as clipped. Encoders rarely reach a literal 255.
    private static let clippingLevel = 250

    /// Samples the margin between a guide's inner and outer outlines.
    ///
    /// Uses per-channel medians, so a hand or shadow crossing part of the margin doesn't skew the
    /// result. Sensor buffers are landscape while guides are defined in portrait, so the axes are
    /// swapped whenever the buffer is wider than it is tall.
    static func sample(
        base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        layout: PixelLayout,
        ring: GuideRing,
        targetSampleCount: Int = 20_000
    ) -> BackgroundSample? {
        guard width > 0, height > 0 else { return nil }

        let short = CGFloat(min(width, height))
        let isLandscape = width > height
        let innerX = Int((isLandscape ? ring.innerHalfHeight : ring.innerHalfWidth) * short)
        let innerY = Int((isLandscape ? ring.innerHalfWidth : ring.innerHalfHeight) * short)
        let outerX = Int((isLandscape ? ring.outerHalfHeight : ring.outerHalfWidth) * short)
        let outerY = Int((isLandscape ? ring.outerHalfWidth : ring.outerHalfHeight) * short)

        let centerX = width / 2
        let centerY = height / 2
        let minX = max(centerX - outerX, 0)
        let maxX = min(centerX + outerX, width - 1)
        let minY = max(centerY - outerY, 0)
        let maxY = min(centerY + outerY, height - 1)
        guard minX <= maxX, minY <= maxY else { return nil }

        let outerArea = (maxX - minX + 1) * (maxY - minY + 1)
        let innerArea = 4 * innerX * innerY
        let ringArea = max(outerArea - innerArea, 1)
        let step = max(Int((Double(ringArea) / Double(targetSampleCount)).squareRoot()), 1)

        let redOffset = layout == .bgra ? 2 : 0
        let blueOffset = layout == .bgra ? 0 : 2

        var redCounts = [Int](repeating: 0, count: 256)
        var greenCounts = [Int](repeating: 0, count: 256)
        var blueCounts = [Int](repeating: 0, count: 256)
        var count = 0
        var clipped = 0

        for y in stride(from: minY, through: maxY, by: step) {
            let row = base + y * bytesPerRow
            let insideRows = abs(y - centerY) < innerY
            for x in stride(from: minX, through: maxX, by: step) {
                if insideRows && abs(x - centerX) < innerX { continue }
                let pixel = row + x * 4
                let r = Int(pixel.load(fromByteOffset: redOffset, as: UInt8.self))
                let g = Int(pixel.load(fromByteOffset: 1, as: UInt8.self))
                let b = Int(pixel.load(fromByteOffset: blueOffset, as: UInt8.self))
                redCounts[r] += 1
                greenCounts[g] += 1
                blueCounts[b] += 1
                count += 1
                if r >= clippingLevel || g >= clippingLevel || b >= clippingLevel { clipped += 1 }
            }
        }
        guard count > 0 else { return nil }

        return BackgroundSample(
            red: median(redCounts, total: count),
            green: median(greenCounts, total: count),
            blue: median(blueCounts, total: count),
            clippedFraction: Double(clipped) / Double(count),
            sampleCount: count
        )
    }

    private static func median(_ counts: [Int], total: Int) -> Double {
        var seen = 0
        for (value, valueCount) in counts.enumerated() {
            seen += valueCount
            if seen * 2 >= total { return Double(value) / 255 }
        }
        return 1
    }
}
