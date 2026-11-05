import Foundation
import Testing
@testable import GroovyCamera

struct CameraLoopTests {
    private let limits = ExposureLimits(minDuration: 1.0 / 8000, maxDuration: 1.0 / 8, minISO: 50, maxISO: 3200)

    /// Encodes a linear value the way the camera's output does.
    private func encoded(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    /// A pretend camera: warm light on a white background, with output following gains and exposure.
    private func simulatedSample(gains: ColorGains, exposure: ExposureSetting) -> BackgroundSample {
        let light = exposure.duration * exposure.iso * 0.1
        let channel = { (reflected: Double, gain: Double) in min(self.encoded(reflected * gain * light), 1) }
        let red = channel(0.9, gains.red)
        let green = channel(0.6, gains.green)
        let blue = channel(0.3, gains.blue)
        let clipped = [red, green, blue].contains { $0 >= 250.0 / 255 } ? 1.0 : 0.0
        return BackgroundSample(red: red, green: green, blue: blue, clippedFraction: clipped, sampleCount: 1000)
    }

    @Test func convergesToNeutralInsideTheBrightnessBand() {
        var gains = ColorGains(red: 1, green: 1, blue: 1)
        var exposure = ExposureSetting(duration: 1.0 / 60, iso: 200)
        for _ in 0..<30 {
            let sample = simulatedSample(gains: gains, exposure: exposure)
            gains = CameraLoop.nextGains(current: gains, sample: sample, maxGain: 16)
            exposure = CameraLoop.nextExposure(current: exposure, sample: sample, limits: limits)
        }
        let final = simulatedSample(gains: gains, exposure: exposure)
        #expect(CameraLoop.isSettled(final), "\(final)")
    }

    @Test func recoversFromAClippedStart() {
        var gains = ColorGains(red: 1, green: 1, blue: 1)
        var exposure = ExposureSetting(duration: 1.0 / 15, iso: 3200)
        for _ in 0..<60 {
            let sample = simulatedSample(gains: gains, exposure: exposure)
            gains = CameraLoop.nextGains(current: gains, sample: sample, maxGain: 16)
            exposure = CameraLoop.nextExposure(current: exposure, sample: sample, limits: limits)
        }
        let final = simulatedSample(gains: gains, exposure: exposure)
        #expect(CameraLoop.isSettled(final), "\(final)")
    }

    @Test func gainsStayWithinTheCameraRange() {
        let sample = BackgroundSample(red: 0.9, green: 0.5, blue: 0.1, clippedFraction: 0, sampleCount: 1000)
        let gains = CameraLoop.nextGains(current: ColorGains(red: 1, green: 2, blue: 3.9), sample: sample, maxGain: 4)
        for gain in [gains.red, gains.green, gains.blue] {
            #expect(gain >= 1 && gain <= 4)
        }
    }

    @Test func leavesGainsAloneWhenClipped() {
        let current = ColorGains(red: 1.5, green: 1, blue: 2)
        let sample = BackgroundSample(red: 1, green: 1, blue: 0.9, clippedFraction: 0.9, sampleCount: 1000)
        #expect(CameraLoop.nextGains(current: current, sample: sample, maxGain: 16) == current)
    }

    @Test func whiteSettingSurvivesARelaunch() throws {
        let suite = "WhiteSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WhiteSetting.load(for: .ultraWide, from: defaults) == nil)

        let setting = WhiteSetting(
            gains: ColorGains(red: 1, green: 1.2, blue: 3),
            exposure: ExposureSetting(duration: 1.0 / 15, iso: 400),
            isNeutral: true
        )
        setting.save(for: .ultraWide, to: defaults)
        #expect(WhiteSetting.load(for: .ultraWide, from: defaults) == setting)
        #expect(WhiteSetting.load(for: .main, from: defaults) == nil)
    }

    @Test func levelReadsZeroWhenFlatAndScreenUp() {
        let reading = LevelReading(gravityX: 0, gravityY: 0, gravityZ: -1)
        #expect(reading.xDegrees == 0 && reading.yDegrees == 0)
        #expect(reading.isLevel)
    }

    @Test func levelMeasuresTiltOnEachAxisAgainstTheTolerance() {
        let tilted = { (degrees: Double) in (sin(degrees * .pi / 180), -cos(degrees * .pi / 180)) }
        let (slightX, slightZ) = tilted(1)
        let slight = LevelReading(gravityX: slightX, gravityY: 0, gravityZ: slightZ)
        #expect(abs(slight.xDegrees - 1) < 0.001)
        #expect(slight.isLevel)

        let (steepY, steepZ) = tilted(2)
        let steep = LevelReading(gravityX: 0, gravityY: steepY, gravityZ: steepZ)
        #expect(abs(steep.yDegrees - 2) < 0.001)
        #expect(!steep.isLevel)
    }

    @Test func prefersTheFlickerSafeShutterSpeed() {
        let sample = BackgroundSample(red: 0.92, green: 0.92, blue: 0.92, clippedFraction: 0, sampleCount: 1000)
        let exposure = CameraLoop.nextExposure(current: ExposureSetting(duration: 1.0 / 250, iso: 3200), sample: sample, limits: limits)
        #expect(abs(exposure.duration - limits.preferredDuration) < 0.0001)
    }

    @Test func lengthensTheShutterWhenISORunsOut() {
        let sample = BackgroundSample(red: 0.4, green: 0.4, blue: 0.4, clippedFraction: 0, sampleCount: 1000)
        let exposure = CameraLoop.nextExposure(current: ExposureSetting(duration: 1.0 / 15, iso: 3200), sample: sample, limits: limits)
        #expect(exposure.iso == 3200)
        #expect(exposure.duration > limits.preferredDuration)
        #expect(exposure.duration <= limits.maxDuration)
    }

    @Test func settledRequiresBrightNeutralUnclipped() {
        #expect(CameraLoop.isSettled(.init(red: 0.92, green: 0.92, blue: 0.92, clippedFraction: 0, sampleCount: 1)))
        #expect(!CameraLoop.isSettled(.init(red: 0.99, green: 0.99, blue: 0.99, clippedFraction: 0, sampleCount: 1)))
        #expect(!CameraLoop.isSettled(.init(red: 0.95, green: 0.92, blue: 0.89, clippedFraction: 0, sampleCount: 1)))
        #expect(!CameraLoop.isSettled(.init(red: 0.92, green: 0.92, blue: 0.92, clippedFraction: 0.5, sampleCount: 1)))
    }
}
