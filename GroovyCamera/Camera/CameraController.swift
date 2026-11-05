@preconcurrency import AVFoundation
import QuartzCore

enum WhiteState: Equatable, Sendable {
    case notSet
    case setting
    case set(isNeutral: Bool)
}

enum QualityChoice: String, CaseIterable, Sendable {
    case speed, balanced, quality

    var prioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
        case .speed: .speed
        case .balanced: .balanced
        case .quality: .quality
        }
    }
}

/// TEMPORARY: settings exposed in the debug panel while diagnosing photo size and sharpness.
struct CameraDebugOptions: Equatable, Sendable {
    var lens = Lens.ultraWide
    var shutterDenominator = 30
    var quality = QualityChoice.balanced
    var videoFeed = true
    var globalToneMapping = true
    var sRGB = true
    var zeroShutterLag = false
    var jpeg = false
    var photoPreset = false
}

struct CameraStatus: Sendable {
    var message: String?
    var white = WhiteState.notSet
    var gains = ColorGains(red: 1, green: 1, blue: 1)
    var exposure = ExposureSetting(duration: 0, iso: 0)
    var lensPosition = 0.0
    var options = CameraDebugOptions()
    var requestedPhotoSize = ""
    var revision = 0
}

/// Runs one camera. White balance and exposure are measured once from the empty white table and
/// then never change. Nothing adjusts live, so the darkness of a record can't affect the shot.
///
/// All camera state is confined to `queue`. Saving runs on its own serial queue, one photo at a
/// time, so a burst of shots waits on disk rather than building up in memory.
final class CameraController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    /// Delivered on arbitrary queues.
    var onStatus: (@Sendable (CameraStatus) -> Void)?
    /// Delivered on arbitrary queues. Nil means the photo couldn't be captured or saved.
    var onSaved: (@Sendable (OriginalSidecar?) -> Void)?

    private let queue = DispatchQueue(label: "camera")
    private let saveQueue = DispatchQueue(label: "camera.save", qos: .utility)
    private let store = OriginalStore()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var status = CameraStatus()
    private var inFlight: [Int64: AVCapturePhotoCaptureDelegate] = [:]

    private var isFocusLocked = false
    private var lastUpdate: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var settledReadings = 0
    private var target: (gains: ColorGains, exposure: ExposureSetting)?

    private static let updateInterval: CFTimeInterval = 0.2
    private static let settingTimeLimit: CFTimeInterval = 6
    private static let settledReadingsNeeded = 2

    func start() {
        queue.async { [self] in
            configure()
            guard device != nil else { return }
            session.startRunning()
            publish()
            if ProcessInfo.processInfo.arguments.contains("--selftest") { runSelfTest() }
        }
    }

    /// TEMPORARY: applies the debug panel's settings.
    func update(_ options: CameraDebugOptions) {
        queue.async { [self] in
            let previous = status.options
            guard options != previous else { return }
            status.options = options
            let needsReconfigure = options.lens != previous.lens
                || options.videoFeed != previous.videoFeed
                || options.globalToneMapping != previous.globalToneMapping
                || options.sRGB != previous.sRGB
                || options.zeroShutterLag != previous.zeroShutterLag
                || options.photoPreset != previous.photoPreset
            if needsReconfigure {
                configure()
            } else if options.shutterDenominator != previous.shutterDenominator {
                changeShutterKeepingBrightness()
            }
            publish()
        }
    }

    /// Measures the empty table. Also releases focus, in case the phone has been moved.
    func setWhite() {
        queue.async { [self] in
            guard let device else { return }
            status.white = .setting
            deadline = CACurrentMediaTime() + Self.settingTimeLimit
            settledReadings = 0
            target = nil
            isFocusLocked = false
            withConfiguration(device) { $0.focusMode = .continuousAutoFocus }
            publish()
        }
    }

    func capture(sessionID: String, shotIndex: Int) {
        let shutterTime = CACurrentMediaTime()
        queue.async { [self] in
            guard let device else { return }
            // The tripod height is fixed, so the first shot's focus holds for the rest.
            if !isFocusLocked {
                isFocusLocked = true
                withConfiguration(device) { $0.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition) }
            }
            publish()

            let settings = makePhotoSettings()
            let photoCapture = PhotoCapture(
                sessionID: sessionID,
                shotIndex: shotIndex,
                shutterTime: shutterTime,
                fileExtension: status.options.jpeg ? "jpg" : "heic",
                snapshot: status,
                store: store,
                saveQueue: saveQueue
            ) { [weak self] id, sidecar in
                self?.onSaved?(sidecar)
                self?.queue.async { self?.inFlight[id] = nil }
            }
            inFlight[settings.uniqueID] = photoCapture
            photoOutput.capturePhoto(with: settings, delegate: photoCapture)
        }
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: status.options.jpeg ? AVVideoCodecType.jpeg : .hevc])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off
        settings.photoQualityPrioritization = status.options.quality.prioritization
        return settings
    }

    // MARK: - Setup

    private func configure() {
        let options = status.options
        guard let camera = AVCaptureDevice.default(options.lens.deviceType, for: .video, position: .back) else {
            status.message = "This phone doesn't have that camera"
            publish()
            return
        }

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if options.photoPreset { session.sessionPreset = .photo }

        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            status.message = "Couldn't set up the camera"
            publish()
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        if options.videoFeed {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(videoOutput)
        }

        let format = Self.bestFormat(of: camera)
        withConfiguration(camera) { device in
            if !options.photoPreset, let format { device.activeFormat = format }
            let wanted: AVCaptureColorSpace = options.sRGB ? .sRGB : .P3_D65
            if device.activeFormat.supportedColorSpaces.contains(wanted) { device.activeColorSpace = wanted }
            if device.activeFormat.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = options.globalToneMapping }
            // Keeps the straight edges of a sleeve straight on the ultra-wide.
            if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = true }
            device.focusMode = .continuousAutoFocus
        }
        session.commitConfiguration()

        // Set after committing: the session can pick its own limit while it's being configured.
        if let largest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: { Self.area($0) < Self.area($1) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = options.zeroShutterLag }

        // Portrait always, whatever the phone reports: lying flat, its orientation is meaningless.
        photoOutput.connection(with: .video)?.videoRotationAngle = 90

        device = camera
        isFocusLocked = false
        status.requestedPhotoSize = "\(photoOutput.maxPhotoDimensions.width)×\(photoOutput.maxPhotoDimensions.height)"
        status.revision += 1

        if let saved = WhiteSetting.load(for: options.lens) {
            apply(gains: saved.gains, exposure: saved.exposure)
            status.white = .set(isNeutral: saved.isNeutral)
        } else {
            withConfiguration(camera) {
                $0.exposureMode = .continuousAutoExposure
                $0.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            status.white = .notSet
        }
    }

    /// The 4:3 format with the largest photo and the widest view, using the smallest video stream
    /// that's still sharp enough to preview.
    private static func bestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return video.width * 3 == video.height * 4 && video.width >= 1920
            }
            .min { first, second in
                let firstPhoto = first.supportedMaxPhotoDimensions.map(area).max() ?? 0
                let secondPhoto = second.supportedMaxPhotoDimensions.map(area).max() ?? 0
                if firstPhoto != secondPhoto { return firstPhoto > secondPhoto }
                if first.videoFieldOfView != second.videoFieldOfView { return first.videoFieldOfView > second.videoFieldOfView }
                let firstVideo = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                let secondVideo = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                return area(firstVideo) < area(secondVideo)
            }
    }

    private static func area(_ dimensions: CMVideoDimensions) -> Int {
        Int(dimensions.width) * Int(dimensions.height)
    }

    private func withConfiguration(_ device: AVCaptureDevice, _ change: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {
            status.message = "Couldn't configure the camera: \(error.localizedDescription)"
        }
    }

    private func publish() {
        if let device {
            let gains = device.deviceWhiteBalanceGains
            status.gains = ColorGains(red: Double(gains.redGain), green: Double(gains.greenGain), blue: Double(gains.blueGain))
            status.exposure = ExposureSetting(duration: device.exposureDuration.seconds, iso: Double(device.iso))
            status.lensPosition = Double(device.lensPosition)
        }
        onStatus?(status)
    }

    // MARK: - Setting white

    private func exposureLimits(of device: AVCaptureDevice) -> ExposureLimits {
        ExposureLimits(
            minDuration: device.activeFormat.minExposureDuration.seconds,
            maxDuration: min(device.activeFormat.maxExposureDuration.seconds, 1.0 / 8),
            minISO: Double(device.activeFormat.minISO),
            maxISO: Double(device.activeFormat.maxISO),
            preferredDuration: 1.0 / Double(status.options.shutterDenominator)
        )
    }

    private func apply(gains: ColorGains, exposure: ExposureSetting) {
        guard let device else { return }
        let limits = exposureLimits(of: device)
        let maxGain = Double(device.maxWhiteBalanceGain)
        withConfiguration(device) {
            $0.setExposureModeCustom(
                duration: CMTime(seconds: min(max(exposure.duration, limits.minDuration), limits.maxDuration), preferredTimescale: 1_000_000),
                iso: Float(min(max(exposure.iso, limits.minISO), limits.maxISO))
            )
            $0.setWhiteBalanceModeLocked(with: AVCaptureDevice.WhiteBalanceGains(
                redGain: Float(min(max(gains.red, 1), maxGain)),
                greenGain: Float(min(max(gains.green, 1), maxGain)),
                blueGain: Float(min(max(gains.blue, 1), maxGain))
            ))
        }
    }

    /// TEMPORARY: trades shutter against ISO so a debug shutter change needs no new Set White.
    private func changeShutterKeepingBrightness() {
        let lens = status.options.lens
        guard var setting = WhiteSetting.load(for: lens) else { return }
        let total = setting.exposure.duration * setting.exposure.iso
        setting.exposure.duration = 1.0 / Double(status.options.shutterDenominator)
        setting.exposure.iso = total / setting.exposure.duration
        apply(gains: setting.gains, exposure: setting.exposure)
        setting.save(for: lens)
    }

    private func updateSetting(with sample: BackgroundSample, device: AVCaptureDevice, now: CFTimeInterval) {
        settledReadings = CameraLoop.isSettled(sample) ? settledReadings + 1 : 0
        let isDone = settledReadings >= Self.settledReadingsNeeded
        if isDone || now >= deadline {
            let current = device.deviceWhiteBalanceGains
            let setting = WhiteSetting(
                gains: target?.gains ?? ColorGains(red: Double(current.redGain), green: Double(current.greenGain), blue: Double(current.blueGain)),
                exposure: target?.exposure ?? ExposureSetting(duration: device.exposureDuration.seconds, iso: Double(device.iso)),
                isNeutral: isDone
            )
            apply(gains: setting.gains, exposure: setting.exposure)
            setting.save(for: status.options.lens)
            status.white = .set(isNeutral: isDone)
            publish()
            return
        }

        let current = device.deviceWhiteBalanceGains
        let gains = CameraLoop.nextGains(
            current: ColorGains(red: Double(current.redGain), green: Double(current.greenGain), blue: Double(current.blueGain)),
            sample: sample,
            maxGain: Double(device.maxWhiteBalanceGain)
        )
        let exposure = CameraLoop.nextExposure(
            current: ExposureSetting(duration: device.exposureDuration.seconds, iso: Double(device.iso)),
            sample: sample,
            limits: exposureLimits(of: device)
        )
        target = (gains, exposure)
        apply(gains: gains, exposure: exposure)
    }

    // MARK: - Self-test

    /// TEMPORARY: logs the photo size each combination of settings really produces.
    /// Runs only when launched with `--selftest`, and saves nothing.
    private func runSelfTest() {
        let base = CameraDebugOptions()
        func with(_ change: (inout CameraDebugOptions) -> Void) -> CameraDebugOptions {
            var options = base
            change(&options)
            return options
        }
        let combos: [(String, CameraDebugOptions)] = [
            ("baseline-ultrawide", base),
            ("no-video-feed", with { $0.videoFeed = false }),
            ("no-tone-mapping", with { $0.globalToneMapping = false }),
            ("p3", with { $0.sRGB = false }),
            ("zero-shutter-lag", with { $0.zeroShutterLag = true }),
            ("jpeg", with { $0.jpeg = true }),
            ("photo-preset", with { $0.photoPreset = true }),
            ("no-video-no-tone-p3", with { $0.videoFeed = false; $0.globalToneMapping = false; $0.sRGB = false }),
            ("main-baseline", with { $0.lens = .main }),
            ("main-no-video-no-tone-p3", with { $0.lens = .main; $0.videoFeed = false; $0.globalToneMapping = false; $0.sRGB = false }),
            ("back-to-baseline", base),
        ]
        for (index, combo) in combos.enumerated() {
            queue.asyncAfter(deadline: .now() + 2 + Double(index) * 4) { [self] in
                status.options = combo.1
                configure()
                queue.asyncAfter(deadline: .now() + 2.5) { [self] in
                    let settings = makePhotoSettings()
                    let probe = SelfTestProbe(name: combo.0) { [weak self] id in
                        self?.queue.async { self?.inFlight[id] = nil }
                    }
                    inFlight[settings.uniqueID] = probe
                    print("SELFTEST shoot \(combo.0) requested \(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height) active=\(device?.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" } ?? [])")
                    photoOutput.capturePhoto(with: settings, delegate: probe)
                }
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard status.white == .setting else { return }
        let now = CACurrentMediaTime()
        guard now - lastUpdate >= Self.updateInterval, let device, let buffer = sampleBuffer.imageBuffer else { return }
        lastUpdate = now

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let sample = BackgroundSampler.sample(
            base: UnsafeRawPointer(base),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            layout: .bgra,
            ring: status.options.lens.emptyTable
        )
        if let sample { updateSetting(with: sample, device: device, now: now) }
    }
}

/// TEMPORARY: reports what the self-test's shots really came out as.
private final class SelfTestProbe: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let name: String
    private let finished: @Sendable (Int64) -> Void

    init(name: String, finished: @escaping @Sendable (Int64) -> Void) {
        self.name = name
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let size = photo.resolvedSettings.photoDimensions
        print("SELFTEST result \(name) \(size.width)x\(size.height) bytes=\(photo.fileDataRepresentation()?.count ?? -1) error=\(String(describing: error))")
        finished(photo.resolvedSettings.uniqueID)
    }
}

/// One photo's trip from shutter to disk.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let sessionID: String
    private let shotIndex: Int
    private let shutterTime: CFTimeInterval
    private let fileExtension: String
    private let snapshot: CameraStatus
    private let store: OriginalStore
    private let saveQueue: DispatchQueue
    private let finished: @Sendable (Int64, OriginalSidecar?) -> Void

    init(
        sessionID: String,
        shotIndex: Int,
        shutterTime: CFTimeInterval,
        fileExtension: String,
        snapshot: CameraStatus,
        store: OriginalStore,
        saveQueue: DispatchQueue,
        finished: @escaping @Sendable (Int64, OriginalSidecar?) -> Void
    ) {
        self.sessionID = sessionID
        self.shotIndex = shotIndex
        self.shutterTime = shutterTime
        self.fileExtension = fileExtension
        self.snapshot = snapshot
        self.store = store
        self.saveQueue = saveQueue
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else {
            finished(id, nil)
            return
        }

        let processedTime = CACurrentMediaTime()
        let dimensions = photo.resolvedSettings.photoDimensions
        saveQueue.async { [self] in
            let url = store.photoURL(sessionID: sessionID, shotIndex: shotIndex, fileExtension: fileExtension)
            guard (try? store.savePhoto(data, to: url)) != nil else {
                finished(id, nil)
                return
            }
            let savedTime = CACurrentMediaTime()

            // The original is safe on disk by now, so a failure here can't lose the photo.
            let finishedURL = store.finishedPhotoURL(sessionID: sessionID, shotIndex: shotIndex)
            let output = PhotoPipeline.process(url: url, lens: snapshot.options.lens)
            if let output {
                try? output.jpeg.write(to: finishedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }

            let sidecar = OriginalSidecar(
                sessionID: sessionID,
                shotIndex: shotIndex,
                capturedAt: Date(),
                lens: snapshot.options.lens,
                debugOptions: String(describing: snapshot.options),
                pixelWidth: Int(dimensions.width),
                pixelHeight: Int(dimensions.height),
                gains: snapshot.gains,
                exposure: snapshot.exposure,
                lensPosition: snapshot.lensPosition,
                savedSample: SavedPhotoAnalyzer.analyze(url: url, ring: snapshot.options.lens.aroundGuide),
                cropKind: output?.cropKind,
                shutterToProcessedMS: Int((processedTime - shutterTime) * 1000),
                shutterToSavedMS: Int((savedTime - shutterTime) * 1000)
            )
            try? store.saveSidecar(sidecar)
            finished(id, sidecar)
        }
    }
}
