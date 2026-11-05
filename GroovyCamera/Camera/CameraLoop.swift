import Foundation

struct ColorGains: Equatable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
}

struct ExposureSetting: Equatable, Sendable, Codable {
    var duration: Double
    var iso: Double
}

struct ExposureLimits: Equatable, Sendable {
    var minDuration: Double
    var maxDuration: Double
    var minISO: Double
    var maxISO: Double
    /// Duration to use when ISO can make up the difference. 1/15 s showed shake from touching the
    /// phone on its tripod. A multiple of 1/60 s avoids flicker from 60 Hz lighting.
    var preferredDuration: Double = 1.0 / 30
}

/// One step of measuring the white table.
///
/// Preview frames already include the current gains and exposure, so each result is a correction
/// to the current values, not an absolute answer. Damping stops it overshooting, since camera
/// changes take a few frames to appear.
enum CameraLoop {
    /// Middle of the 90–95% band: bright, but with headroom so pale sleeves keep their edges.
    static let targetBrightness = 0.925
    static let brightnessBand = 0.90...0.95
    static let neutralTolerance = 0.01
    /// Above this share of clipped pixels, channel ratios can't be trusted.
    private static let clippingLimit = 0.2

    static func nextGains(
        current: ColorGains,
        sample: BackgroundSample,
        maxGain: Double,
        damping: Double = 0.5
    ) -> ColorGains {
        guard sample.clippedFraction <= clippingLimit else { return current }
        let red = linear(sample.red)
        let green = linear(sample.green)
        let blue = linear(sample.blue)
        guard red > 0.01, green > 0.01, blue > 0.01 else { return current }

        let nextRed = current.red * pow(green / red, damping)
        let nextBlue = current.blue * pow(green / blue, damping)
        // The camera requires every gain to be at least 1. Overall brightness is left to the
        // exposure step.
        let smallest = min(nextRed, current.green, nextBlue)
        return ColorGains(
            red: min(nextRed / smallest, maxGain),
            green: min(current.green / smallest, maxGain),
            blue: min(nextBlue / smallest, maxGain)
        )
    }

    static func nextExposure(
        current: ExposureSetting,
        sample: BackgroundSample,
        limits: ExposureLimits,
        damping: Double = 0.6
    ) -> ExposureSetting {
        let factor: Double
        if sample.clippedFraction > clippingLimit {
            // A clipped reading understates how far over it is, so step down by a fixed amount.
            factor = 0.7
        } else {
            let measured = max(linear(sample.brightness), 0.005)
            factor = min(max(pow(linear(targetBrightness) / measured, damping), 0.25), 2)
        }

        let total = current.duration * current.iso * factor
        var duration = clamp(limits.preferredDuration, limits.minDuration, limits.maxDuration)
        var iso = total / duration
        if iso > limits.maxISO {
            iso = limits.maxISO
            duration = clamp(total / iso, limits.minDuration, limits.maxDuration)
        } else if iso < limits.minISO {
            iso = limits.minISO
            duration = clamp(total / iso, limits.minDuration, limits.maxDuration)
        }
        return ExposureSetting(duration: duration, iso: iso)
    }

    static func isSettled(_ sample: BackgroundSample) -> Bool {
        brightnessBand.contains(sample.brightness)
            && sample.neutralError <= neutralTolerance
            && sample.clippedFraction <= 0.01
    }

    /// Converts a gamma-encoded sRGB value to linear light.
    static func linear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
