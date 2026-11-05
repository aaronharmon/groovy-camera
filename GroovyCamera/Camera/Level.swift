import CoreMotion
import Foundation
import Observation

/// How far a phone lying screen-up is from flat, in degrees along its short and long axes.
struct LevelReading: Equatable, Sendable {
    var xDegrees: Double
    var yDegrees: Double

    static let toleranceDegrees = 1.5

    init(xDegrees: Double = 0, yDegrees: Double = 0) {
        self.xDegrees = xDegrees
        self.yDegrees = yDegrees
    }

    /// Gravity is in the phone's own axes, with z pointing out of the screen, so a flat, screen-up
    /// phone reads (0, 0, -1).
    init(gravityX: Double, gravityY: Double, gravityZ: Double) {
        xDegrees = atan2(gravityX, -gravityZ) * 180 / .pi
        yDegrees = atan2(gravityY, -gravityZ) * 180 / .pi
    }

    var isLevel: Bool {
        abs(xDegrees) <= Self.toleranceDegrees && abs(yDegrees) <= Self.toleranceDegrees
    }
}

@MainActor
@Observable
final class LevelMonitor {
    private(set) var reading = LevelReading()
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated {
                self?.reading = LevelReading(gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z)
            }
        }
    }
}
