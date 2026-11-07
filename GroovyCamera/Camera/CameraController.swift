@preconcurrency import AVFoundation
import QuartzCore

enum WhiteState: Equatable, Sendable {
    case notSet
    case setting
    /// The result is nil for a setting saved before results were recorded.
    case set(WhiteResult?)
}

struct CameraStatus: Sendable {
    var message: String?
    var white = WhiteState.notSet
    var gains = ColorGains(red: 1, green: 1, blue: 1)
    var exposure = ExposureSetting(duration: 0, iso: 0)
    var exposureBias = 0.0
    var warmth = 0.0
    var lensPosition = 0.0
    var revision = 0
}

/// Runs one camera. White balance and exposure are measured once from the empty white table and
/// then never change. Nothing adjusts live, so the darkness of a record can't affect the shot.
///
/// All camera state is confined to `queue`. Saving runs on its own serial queue, one photo at a
/// time, so a burst of shots waits on disk rather than building up in memory. This class only gets
/// the original onto disk: everything after that belongs to `SessionController`'s queue.
final class CameraController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    /// Delivered on arbitrary queues.
    var onStatus: (@Sendable (CameraStatus) -> Void)?
    /// Delivered on arbitrary queues, once the original is on disk or has failed.
    var onCaptured: (@Sendable (_ ticket: CaptureTicket, _ didSave: Bool) -> Void)?

    private let queue = DispatchQueue(label: "camera")
    private let saveQueue = DispatchQueue(label: "camera.save", qos: .utility)
    private let files: PhotoFiles
    private let lens = Lens.ultraWide
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var status = CameraStatus()
    private var inFlight: [Int64: AVCapturePhotoCaptureDelegate] = [:]

    private var isFocusLocked = false
    /// When Set White started, while the camera is metering the empty table.
    private var meteringStarted: CFTimeInterval?
    /// The locked setting, before the user's exposure adjustment.
    private var whiteSetting: WhiteSetting?
    private var exposureBias = Adjustment.exposure.load()
    private var warmth = Adjustment.warmth.load()
    private var lastSample: CFTimeInterval = 0

    /// How often the table is read while the camera meters it.
    private static let sampleInterval: CFTimeInterval = 0.4
    private static let meteringMinimum: CFTimeInterval = 1
    private static let meteringLimit: CFTimeInterval = 4
    /// 1/15 s showed shake from touching the phone on its tripod. A multiple of 1/60 s also avoids
    /// flicker from 60 Hz lighting.
    private static let longestShutter = 1.0 / 30

    init(files: PhotoFiles) {
        self.files = files
    }

    func start() {
        queue.async { [self] in
            configure()
            guard device != nil else { return }
            session.startRunning()
            publish()
        }
    }

    /// Measures the empty table. Also releases focus, in case the phone has been moved.
    func setWhite() {
        queue.async { [self] in
            guard let device else { return }
            status.white = .setting
            meteringStarted = CACurrentMediaTime()
            isFocusLocked = false
            withConfiguration(device) {
                $0.focusMode = .continuousAutoFocus
                $0.exposureMode = .continuousAutoExposure
                $0.activeMaxExposureDuration = CMTime(seconds: Self.longestShutter(for: $0), preferredTimescale: 1_000_000)
                $0.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            publish()
        }
    }

    /// Makes the locked exposure brighter or darker, in stops from what the camera metered.
    func setExposureBias(_ bias: Double) {
        queue.async { [self] in
            exposureBias = Adjustment.exposure.clamped(bias)
            Adjustment.exposure.save(exposureBias)
            if let whiteSetting { apply(gains: whiteSetting.gains, exposure: whiteSetting.exposure) }
            publish()
        }
    }

    /// Makes the locked white balance warmer or cooler than the camera's own choice.
    func setWarmth(_ steps: Double) {
        queue.async { [self] in
            warmth = Adjustment.warmth.clamped(steps)
            Adjustment.warmth.save(warmth)
            if let whiteSetting { apply(gains: whiteSetting.gains, exposure: whiteSetting.exposure) }
            publish()
        }
    }

    func capture(_ ticket: CaptureTicket) {
        let shutterTime = CACurrentMediaTime()
        queue.async { [self] in
            guard let device else {
                onCaptured?(ticket, false)
                return
            }
            // The tripod height is fixed, so the first shot's focus holds for the rest.
            if !isFocusLocked {
                isFocusLocked = true
                withConfiguration(device) { $0.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition) }
            }
            publish()

            let settings = makePhotoSettings()
            let photoCapture = PhotoCapture(
                ticket: ticket,
                lens: lens,
                shutterTime: shutterTime,
                snapshot: status,
                files: files,
                saveQueue: saveQueue
            ) { [weak self] id, didSave in
                self?.onCaptured?(ticket, didSave)
                self?.queue.async { self?.inFlight[id] = nil }
            }
            inFlight[settings.uniqueID] = photoCapture
            photoOutput.capturePhoto(with: settings, delegate: photoCapture)
        }
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off
        // Side by side on the same back cover, more processing gave clearly sharper print. It costs
        // about half a second per photo at 12 MP, and the shutter doesn't wait for it.
        settings.photoQualityPrioritization = .quality
        return settings
    }

    // MARK: - Setup

    private func configure() {
        guard let camera = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            status.message = "This phone doesn't have that camera"
            publish()
            return
        }

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            status.message = "Couldn't set up the camera"
            publish()
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        // Set White reads the table from this feed.
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(videoOutput)

        let format = Self.bestFormat(of: camera)
        withConfiguration(camera) { device in
            if let format { device.activeFormat = format }
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            // Off, because it brightened the table more with a dark sleeve in frame than a pale one:
            // about 1.2-1.3x with it off, against 1.3-1.7x with it on, on one locked exposure.
            if device.activeFormat.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = false }
            // Keeps the straight edges of a sleeve straight on the ultra-wide.
            if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = true }
            device.focusMode = .continuousAutoFocus
        }
        session.commitConfiguration()

        // Set after committing: the session can pick its own limit while it's being configured.
        if let size = Self.photoSize(from: camera.activeFormat.supportedMaxPhotoDimensions) {
            photoOutput.maxPhotoDimensions = size
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        // On a tripod there's no moment to catch, and it's off in every shot these settings were chosen from.
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = false }

        // Portrait always, whatever the phone reports: lying flat, its orientation is meaningless.
        photoOutput.connection(with: .video)?.videoRotationAngle = 90

        device = camera
        isFocusLocked = false
        status.revision += 1

        if let saved = WhiteSetting.load(for: lens) {
            whiteSetting = saved
            apply(gains: saved.gains, exposure: saved.exposure)
            status.white = .set(saved.result)
        } else {
            withConfiguration(camera) {
                $0.exposureMode = .continuousAutoExposure
                $0.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            status.white = .notSet
        }
    }

    /// Photos are 12 MP, never larger: the finished photo is only 2048 x 2048, so bigger originals
    /// would cost time and storage on every shot.
    private static let maxPhotoArea = 4032 * 3024

    /// The largest size offered within the limit.
    static func photoSize(from sizes: [CMVideoDimensions]) -> CMVideoDimensions? {
        sizes.filter { area($0) <= maxPhotoArea }.max { area($0) < area($1) }
    }

    /// The 4:3 format with the most sensor and the widest view, using the smallest video stream
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
        status.exposureBias = exposureBias
        status.warmth = warmth
        onStatus?(status)
    }

    // MARK: - Setting white

    private static func longestShutter(for device: AVCaptureDevice) -> Double {
        min(max(longestShutter, device.activeFormat.minExposureDuration.seconds), device.activeFormat.maxExposureDuration.seconds)
    }

    /// Restores a saved setting. Both stay fixed until Set White runs again.
    private func apply(gains: ColorGains, exposure metered: ExposureSetting) {
        guard let device else { return }
        let format = device.activeFormat
        let maxGain = Double(device.maxWhiteBalanceGain)
        let minDuration = format.minExposureDuration.seconds
        let maxDuration = format.maxExposureDuration.seconds
        // Brightening can lengthen the shutter only up to the shake limit, unless the metered
        // shutter was already longer.
        let longest = max(Self.longestShutter(for: device), min(metered.duration, maxDuration))
        let exposure = ExposureBias.exposure(
            metered,
            bias: exposureBias,
            isoRange: Double(format.minISO)...Double(format.maxISO),
            durationRange: minDuration...max(longest, minDuration)
        )
        withConfiguration(device) {
            $0.setExposureModeCustom(
                duration: CMTime(seconds: exposure.duration, preferredTimescale: 1_000_000),
                iso: Float(exposure.iso)
            )
            lockGains(Self.gains(gains, warmth: warmth, on: $0), on: $0, maxGain: maxGain)
        }
    }

    /// Moves the gains to correct for a warmer or cooler light, keeping the tint, using the
    /// camera's own conversion between gains and color temperature.
    private static func gains(_ base: ColorGains, warmth: Double, on device: AVCaptureDevice) -> ColorGains {
        guard warmth != 0 else { return base }
        let maxGain = Double(device.maxWhiteBalanceGain)
        var values = device.temperatureAndTintValues(for: AVCaptureDevice.WhiteBalanceGains(
            redGain: Float(min(max(base.red, 1), maxGain)),
            greenGain: Float(min(max(base.green, 1), maxGain)),
            blueGain: Float(min(max(base.blue, 1), maxGain))
        ))
        values.temperature = Float(WarmthBias.temperature(Double(values.temperature), warmth: warmth))
        let shifted = device.deviceWhiteBalanceGains(for: values)
        // The camera needs every gain to be at least 1.
        let smallest = Double(min(shifted.redGain, shifted.greenGain, shifted.blueGain))
        return ColorGains(
            red: Double(shifted.redGain) / smallest,
            green: Double(shifted.greenGain) / smallest,
            blue: Double(shifted.blueGain) / smallest
        )
    }

    private func lockGains(_ gains: ColorGains, on device: AVCaptureDevice, maxGain: Double) {
        device.setWhiteBalanceModeLocked(with: AVCaptureDevice.WhiteBalanceGains(
            redGain: Float(min(max(gains.red, 1), maxGain)),
            greenGain: Float(min(max(gains.green, 1), maxGain)),
            blueGain: Float(min(max(gains.blue, 1), maxGain))
        ))
    }

    /// Waits for the camera's own auto exposure and white balance to settle on the empty table,
    /// then locks both as they are. Nothing changes them after this, so a dark sleeve and a pale
    /// one are shot alike.
    private func advanceWhite(with sample: BackgroundSample, device: AVCaptureDevice, now: CFTimeInterval) {
        guard let meteringStarted else { return }
        let elapsed = now - meteringStarted
        let isSteady = !device.isAdjustingExposure && !device.isAdjustingWhiteBalance
        guard (elapsed >= Self.meteringMinimum && isSteady) || elapsed >= Self.meteringLimit else { return }

        let gains = device.deviceWhiteBalanceGains
        let exposure = ExposureSetting(duration: device.exposureDuration.seconds, iso: Double(device.iso))
        let isOutOfLight = exposure.iso >= Double(device.activeFormat.maxISO) * 0.98
            && exposure.duration >= Self.longestShutter(for: device) * 0.98
        let setting = WhiteSetting(
            gains: ColorGains(red: Double(gains.redGain), green: Double(gains.greenGain), blue: Double(gains.blueGain)),
            exposure: exposure,
            result: CameraLoop.judge(sample, isOutOfLight: isOutOfLight)
        )
        // Locked as a custom exposure and fixed gains, the same way a saved setting is restored at
        // launch, so every session matches exactly.
        whiteSetting = setting
        apply(gains: setting.gains, exposure: setting.exposure)
        setting.save(for: lens)
        self.meteringStarted = nil
        status.white = .set(setting.result)
        publish()
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard status.white == .setting else { return }
        let now = CACurrentMediaTime()
        guard now - lastSample >= Self.sampleInterval, let device, let buffer = sampleBuffer.imageBuffer else { return }
        lastSample = now

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let sample = BackgroundSampler.sample(
            base: UnsafeRawPointer(base),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            layout: .bgra,
            ring: lens.emptyTable
        )
        if let sample { advanceWhite(with: sample, device: device, now: now) }
    }
}

/// One photo's trip from shutter to disk.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let ticket: CaptureTicket
    private let lens: Lens
    private let shutterTime: CFTimeInterval
    private let snapshot: CameraStatus
    private let files: PhotoFiles
    private let saveQueue: DispatchQueue
    private let finished: @Sendable (Int64, Bool) -> Void

    init(
        ticket: CaptureTicket,
        lens: Lens,
        shutterTime: CFTimeInterval,
        snapshot: CameraStatus,
        files: PhotoFiles,
        saveQueue: DispatchQueue,
        finished: @escaping @Sendable (Int64, Bool) -> Void
    ) {
        self.ticket = ticket
        self.lens = lens
        self.shutterTime = shutterTime
        self.snapshot = snapshot
        self.files = files
        self.saveQueue = saveQueue
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else {
            finished(id, false)
            return
        }

        let processedTime = CACurrentMediaTime()
        let dimensions = photo.resolvedSettings.photoDimensions
        saveQueue.async { [self] in
            guard (try? files.saveOriginal(data, for: ticket.location)) != nil else {
                finished(id, false)
                return
            }
            let savedTime = CACurrentMediaTime()
            // The original is safe on disk by now, so a failure here can't lose the photo.
            try? files.saveSidecar(
                OriginalSidecar(
                    sessionID: ticket.location.sessionID,
                    photoID: ticket.location.photoID,
                    slotNumber: ticket.slot.number,
                    capturedAt: Date(),
                    lens: lens,
                    pixelWidth: Int(dimensions.width),
                    pixelHeight: Int(dimensions.height),
                    gains: snapshot.gains,
                    exposure: snapshot.exposure,
                    lensPosition: snapshot.lensPosition,
                    shutterToProcessedMS: Int((processedTime - shutterTime) * 1000),
                    shutterToSavedMS: Int((savedTime - shutterTime) * 1000)
                ),
                for: ticket.location
            )
            finished(id, true)
        }
    }
}
