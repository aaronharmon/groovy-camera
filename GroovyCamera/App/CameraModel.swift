@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftData

/// Connects the camera, the level and the session for the camera screen.
@MainActor
@Observable
final class CameraModel {
    let camera: CameraController
    let level = LevelMonitor()
    let session: SessionController
    private(set) var status = CameraStatus()
    private(set) var isHot = false
    private var thermalObserver: NSObjectProtocol?

    init(context: ModelContext) {
        let files = PhotoFiles()
        camera = CameraController(files: files)
        session = SessionController(context: context, files: files)
    }

    var canShoot: Bool {
        guard session.state.currentSlot != nil else { return false }
        if case .set = status.white { return true }
        return false
    }

    func start() async {
        camera.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        camera.onCaptured = { [weak self] ticket, didSave in
            Task { @MainActor in self?.session.captureFinished(ticket, didSave: didSave) }
        }
        level.start()
        watchTemperature()
        if await AVCaptureDevice.requestAccess(for: .video) {
            camera.start()
        } else {
            status.message = "Camera access is off. Turn it on in Settings."
        }
    }

    func shoot() {
        guard canShoot, let ticket = session.beginCapture() else { return }
        camera.capture(ticket)
    }

    /// The queue keeps running when the phone is hot, so this only explains why it's falling behind.
    private func watchTemperature() {
        let update: @MainActor () -> Void = { [weak self] in
            let state = ProcessInfo.processInfo.thermalState
            self?.isHot = state == .serious || state == .critical
        }
        update()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { update() }
        }
    }
}
