import CoreMedia
import Foundation
import Testing
@testable import GroovyCamera

struct CameraLoopTests {
    @Test func capsPhotosAt12MP() {
        let sizes = [
            CMVideoDimensions(width: 1920, height: 1440),
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 8064, height: 6048),
        ]
        let size = CameraController.photoSize(from: sizes)
        #expect(size?.width == 4032 && size?.height == 3024)
    }

    @Test func passesAWhiteAtWhateverBrightnessAndColor() {
        for level in [0.75, 0.86, 0.93] {
            // Warm, as the camera's own white balance leaves a warm light.
            let sample = BackgroundSample(red: level + 0.03, green: level, blue: level - 0.06, clippedFraction: 0, sampleCount: 1)
            #expect(CameraLoop.judge(sample, isOutOfLight: false).problem == nil)
        }
    }

    @Test func saysWhatsWrongWithAPoorWhite() {
        let dim = BackgroundSample(red: 0.64, green: 0.64, blue: 0.64, clippedFraction: 0, sampleCount: 1)
        #expect(CameraLoop.judge(dim, isOutOfLight: true).problem == .tooDim)

        let clipped = BackgroundSample(red: 0.98, green: 0.98, blue: 0.98, clippedFraction: 0.05, sampleCount: 1)
        #expect(CameraLoop.judge(clipped, isOutOfLight: false).problem == .tooBright)
    }

    @Test func exposureBiasMovesISOFirstThenTheShutter() {
        let metered = ExposureSetting(duration: 1.0 / 60, iso: 400)
        let isoRange = 50.0...3200
        let durationRange = (1.0 / 8000)...(1.0 / 30)

        let darker = ExposureBias.exposure(metered, bias: -1, isoRange: isoRange, durationRange: durationRange)
        #expect(darker == ExposureSetting(duration: 1.0 / 60, iso: 200))

        // Two stops up needs ISO 1600, which is in range, so the shutter stays put.
        let brighter = ExposureBias.exposure(metered, bias: 2, isoRange: isoRange, durationRange: durationRange)
        #expect(brighter == ExposureSetting(duration: 1.0 / 60, iso: 1600))

        // At the ISO limit, the shutter lengthens, but not past the shake limit.
        let dim = ExposureSetting(duration: 1.0 / 60, iso: 2400)
        let limited = ExposureBias.exposure(dim, bias: 2, isoRange: isoRange, durationRange: durationRange)
        #expect(limited.iso == 3200 && abs(limited.duration - 1.0 / 30) < 1e-9)
    }

    @Test func adjustmentsStayInRangeAndInSteps() {
        #expect(Adjustment.exposure.clamped(5) == 4)
        #expect(Adjustment.exposure.clamped(-4.6) == -4)
        #expect(Adjustment.exposure.clamped(0.4) == 0.5)
        #expect(Adjustment.warmth.clamped(-22) == -20)
        #expect(Adjustment.warmth.clamped(2.4) == 2)
    }

    @Test func lessWarmthCorrectsForAWarmerLight() {
        #expect(WarmthBias.temperature(3000, warmth: 0) == 3000)
        // Correcting for a warmer light adds blue, so the photo comes out cooler.
        let cooler = WarmthBias.temperature(3000, warmth: -3)
        #expect(abs(cooler - 1_000_000 / (1_000_000 / 3000.0 + 30)) < 0.001)
        #expect(WarmthBias.temperature(3000, warmth: 3) > 3000)
        #expect(WarmthBias.temperature(30_000, warmth: 10).isFinite)
    }

    @Test func whiteSettingSurvivesARelaunch() throws {
        let suite = "WhiteSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WhiteSetting.load(for: .ultraWide, from: defaults) == nil)

        let setting = WhiteSetting(
            gains: ColorGains(red: 1, green: 1.2, blue: 3),
            exposure: ExposureSetting(duration: 1.0 / 15, iso: 400),
            result: WhiteResult(brightness: 0.92, problem: nil)
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

    @Test func readsASettingSavedBeforeResultsWereRecorded() throws {
        let suite = "WhiteSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"{"gains":{"red":1,"green":1,"blue":2},"exposure":{"duration":0.033,"iso":400},"isNeutral":false}"#
        defaults.set(Data(old.utf8), forKey: "whiteSetting.\(Lens.ultraWide.rawValue)")
        let setting = try #require(WhiteSetting.load(for: .ultraWide, from: defaults))
        #expect(setting.result == nil)
    }
}
