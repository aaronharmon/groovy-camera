import Foundation

/// The camera's color and exposure, measured once from the empty white table. The light doesn't
/// change, so this is kept across launches and only set again when the user asks. Each lens keeps
/// its own, because gains and ISO don't carry over between lenses.
struct WhiteSetting: Codable, Equatable, Sendable {
    var gains: ColorGains
    var exposure: ExposureSetting
    /// False if the reading never fully settled, for example if something other than the white
    /// table was in the frame, or the light was too warm for the camera's gains.
    var isNeutral: Bool

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
