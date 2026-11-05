@preconcurrency import AVFoundation
import Foundation
import Observation

/// Throwaway state for the Milestone 0 test screen.
@MainActor
@Observable
final class SpikeModel {
    let camera = CameraController()
    let level = LevelMonitor()
    private(set) var status = CameraStatus()
    private(set) var savedCount = 0
    private(set) var lastShot: OriginalSidecar?
    private(set) var saveFailed = false
    private(set) var lastFinishedURL: URL?
    private let sessionID = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
    private var shotIndex = 0

    /// TEMPORARY: the debug panel's settings.
    var options = CameraDebugOptions() {
        didSet { camera.update(options) }
    }

    func start() async {
        camera.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        camera.onSaved = { [weak self] sidecar in
            Task { @MainActor in
                guard let self else { return }
                self.saveFailed = sidecar == nil
                if let sidecar {
                    self.savedCount += 1
                    self.lastShot = sidecar
                    self.lastFinishedURL = OriginalStore().finishedPhotoURL(sessionID: sidecar.sessionID, shotIndex: sidecar.shotIndex)
                }
            }
        }
        level.start()
        if await AVCaptureDevice.requestAccess(for: .video) {
            camera.start()
        } else {
            status.message = "Camera access is off. Turn it on in Settings."
        }
    }

    func shoot() {
        shotIndex += 1
        camera.capture(sessionID: sessionID, shotIndex: shotIndex)
    }
}
