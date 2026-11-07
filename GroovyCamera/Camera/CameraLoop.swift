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

/// Judges the white Set White locked.
///
/// Set White takes whatever the camera's own auto white balance and auto exposure pick on the
/// empty table, and locks them. Correcting the color from the table ourselves was tried and swung
/// past white on the phone; the camera's own choice looks right to the eye, warmth included. So
/// color isn't judged here, only whether the table is usable.
enum CameraLoop {
    /// - Parameter isOutOfLight: auto exposure hit its longest shutter and highest ISO, so the table
    ///   came out darker than the camera wanted.
    static func judge(_ sample: BackgroundSample, isOutOfLight: Bool) -> WhiteResult {
        let problem: WhiteResult.Problem? =
            if sample.clippedFraction > 0.01 {
                .tooBright
            } else if isOutOfLight {
                .tooDim
            } else {
                nil
            }
        return WhiteResult(brightness: sample.brightness, problem: problem)
    }
}
