import Foundation

/// How the white table measured once Set White locked, so the screen can show that it worked.
struct WhiteResult: Codable, Equatable, Sendable {
    enum Problem: String, Codable, Sendable {
        case tooDim, tooBright
    }

    /// Gamma-encoded, from 0 to 1. Whatever the camera's auto exposure chose for the empty table.
    var brightness: Double
    var problem: Problem?
}

/// The camera's color and exposure, as its auto modes picked them on the empty white table. The light doesn't
/// change, so this is kept across launches and only set again when the user asks. Each lens keeps
/// its own, because gains and ISO don't carry over between lenses.
struct WhiteSetting: Codable, Equatable, Sendable {
    var gains: ColorGains
    var exposure: ExposureSetting
    /// Nil for a setting saved before results were recorded.
    var result: WhiteResult?

    private static func key(_ lens: Lens) -> String { "whiteSetting.\(lens.rawValue)" }

    static func load(for lens: Lens, from defaults: UserDefaults = .standard) -> WhiteSetting? {
        defaults.data(forKey: key(lens)).flatMap { try? JSONDecoder().decode(WhiteSetting.self, from: $0) }
    }

    func save(for lens: Lens, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key(lens))
        }
    }
}

/// A setting the user nudges with − and +. It's kept across launches and when Set White runs again,
/// so it's chosen once rather than adjusted per photo.
struct Adjustment: Sendable {
    let range: ClosedRange<Double>
    let step: Double
    let key: String

    /// Stops from the exposure the camera metered, which can leave the table brighter or darker
    /// than wanted.
    static let exposure = Adjustment(range: -4...4, step: 0.5, key: "exposureBias")
    /// Steps warmer or cooler than the camera's auto white balance, which leaves warm light
    /// looking warm. See `WarmthBias`.
    static let warmth = Adjustment(range: -20...20, step: 1, key: "warmthBias")

    func clamped(_ value: Double) -> Double {
        min(max((value / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    func load(from defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.double(forKey: key))
    }

    func save(_ value: Double, to defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}

enum WarmthBias {
    /// Steps are even in mireds (a million over kelvin), which matches how big a color change
    /// looks better than kelvin does. Ten is a small but visible step.
    static let miredsPerStep = 10.0

    /// The light temperature the white balance should correct for. Telling the camera the light is
    /// warmer (lower kelvin) makes it add blue, so a negative warmth gives a cooler photo.
    static func temperature(_ kelvin: Double, warmth: Double) -> Double {
        // Floored at 20,000 K so a very cool reading can't divide by zero.
        1_000_000 / max(1_000_000 / kelvin - warmth * miredsPerStep, 50)
    }
}

enum ExposureBias {
    /// The metered exposure moved by `bias` stops. ISO changes first, so the shutter stays as
    /// metered; the shutter takes up whatever ISO can't.
    static func exposure(
        _ metered: ExposureSetting,
        bias: Double,
        isoRange: ClosedRange<Double>,
        durationRange: ClosedRange<Double>
    ) -> ExposureSetting {
        let duration = min(max(metered.duration, durationRange.lowerBound), durationRange.upperBound)
        let light = duration * metered.iso * pow(2, bias)
        let iso = min(max(light / duration, isoRange.lowerBound), isoRange.upperBound)
        return ExposureSetting(
            duration: min(max(light / iso, durationRange.lowerBound), durationRange.upperBound),
            iso: iso
        )
    }
}
