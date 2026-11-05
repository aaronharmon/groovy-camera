import SwiftUI

/// Throwaway Milestone 0 test screen: level the phone, set white once, line up the record, shoot.
struct SpikeView: View {
    @State private var model = SpikeModel()

    private var canShoot: Bool {
        if case .set = model.status.white { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            Viewfinder(model: model)

            HStack(spacing: 12) {
                LevelBubble(reading: model.level.reading)
                FinishedThumbnail(url: model.lastFinishedURL)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusIsWarning ? .red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)

            HStack {
                Button("Set White") { model.camera.setWhite() }
                    .buttonStyle(.bordered)
                    .disabled(model.status.white == .setting)
                Button(action: model.shoot) {
                    Text("Shoot").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canShoot)
            }
            .padding(.horizontal)

            ScrollView {
                DebugPanel(model: model)
                    .padding(.horizontal)
            }
        }
        .task { await model.start() }
    }

    private var statusText: String {
        if let message = model.status.message { return message }
        if model.saveFailed { return "The last photo wasn't saved." }
        switch model.status.white {
        case .notSet:
            return "Clear the table, then tap Set White."
        case .setting:
            return "Setting white…"
        case .set(let isNeutral):
            let white = isNeutral ? "White set" : "White set, but not fully neutral. Clear the table and try again."
            guard model.savedCount > 0 else { return white }
            let crop = model.lastShot?.cropKind == .guideFallback ? "Edges not found, used the guide" : "\(model.savedCount) saved"
            return "\(white) · \(crop)"
        }
    }

    private var statusIsWarning: Bool {
        model.status.message != nil || model.saveFailed || model.status.white == .set(isNeutral: false)
    }
}

/// The square viewfinder with its guides.
private struct Viewfinder: View {
    let model: SpikeModel

    var body: some View {
        let lens = model.status.options.lens
        GeometryReader { geometry in
            let side = geometry.size.width
            let frameWidth = side / lens.viewfinderShare
            ZStack {
                CameraPreview(session: model.camera.session, revision: model.status.revision)
                    .frame(width: frameWidth, height: frameWidth * 4 / 3)
                    .position(x: side / 2, y: side / 2)
                LineUpGuides(guideSide: frameWidth * lens.guideHalfSide * 2)
                    .position(x: side / 2, y: side / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .background(.black)
    }
}

/// A square for sleeves, a circle and center dot for discs, and a crosshair.
private struct LineUpGuides: View {
    let guideSide: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(.yellow, lineWidth: 1.5)
                .frame(width: guideSide, height: guideSide)
            Circle()
                .stroke(.yellow.opacity(0.7), lineWidth: 1)
                .frame(width: guideSide * 0.95, height: guideSide * 0.95)
            Circle()
                .fill(.yellow)
                .frame(width: 5, height: 5)
            Rectangle().fill(.yellow).frame(width: guideSide, height: 0.5)
            Rectangle().fill(.yellow).frame(width: 0.5, height: guideSide)
        }
        .allowsHitTesting(false)
    }
}

/// The last finished photo, so a bad crop shows up before the record is moved.
private struct FinishedThumbnail: View {
    let url: URL?

    var body: some View {
        if let url, let image = UIImage(contentsOfFile: url.path())?.preparingThumbnail(of: CGSize(width: 150, height: 150)) {
            Image(uiImage: image)
                .resizable()
                .frame(width: 56, height: 56)
                .id(url)
        }
    }
}

/// A bubble that floats toward the phone's high side and turns green when level.
private struct LevelBubble: View {
    let reading: LevelReading

    private static let size: CGFloat = 44
    /// The tilt that puts the bubble at the edge of the circle.
    private static let fullScaleDegrees = 6.0

    var body: some View {
        let color: Color = reading.isLevel ? .green : .orange
        let travel = (Self.size - 14) / 2
        ZStack {
            Circle().stroke(color, lineWidth: 2)
            Circle().stroke(color.opacity(0.5), lineWidth: 1)
                .frame(width: Self.size * LevelReading.toleranceDegrees / Self.fullScaleDegrees * 2)
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .offset(
                    x: -Self.scaled(reading.xDegrees) * travel,
                    y: Self.scaled(reading.yDegrees) * travel
                )
        }
        .frame(width: Self.size, height: Self.size)
    }

    private static func scaled(_ degrees: Double) -> CGFloat {
        CGFloat(min(max(degrees / fullScaleDegrees, -1), 1))
    }
}

/// TEMPORARY: controls for diagnosing photo size and sharpness. Remove once they're settled.
private struct DebugPanel: View {
    @Bindable var model: SpikeModel

    var body: some View {
        DisclosureGroup("Debug") {
            VStack(alignment: .leading, spacing: 8) {
                readout

                Picker("Lens", selection: $model.options.lens) {
                    Text("Ultra-wide").tag(Lens.ultraWide)
                    Text("Main").tag(Lens.main)
                }
                .pickerStyle(.segmented)

                Picker("Shutter", selection: $model.options.shutterDenominator) {
                    ForEach([15, 30, 60, 125], id: \.self) { Text("1/\($0)").tag($0) }
                }
                .pickerStyle(.segmented)

                Text(verbatim: "White target (then tap Set White)")
                Picker("White target", selection: $model.options.whiteTargetPercent) {
                    ForEach([80, 85, 88, 92], id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Processing", selection: $model.options.quality) {
                    ForEach(QualityChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Video feed (needed for Set White)", isOn: $model.options.videoFeed)
                Toggle("Global tone mapping", isOn: $model.options.globalToneMapping)
                Toggle("sRGB (off = Display P3)", isOn: $model.options.sRGB)
                Toggle("Zero shutter lag", isOn: $model.options.zeroShutterLag)
                Toggle("JPEG (off = HEIC)", isOn: $model.options.jpeg)
                Toggle("Photo preset", isOn: $model.options.photoPreset)
            }
            .padding(.top, 6)
        }
        .font(.caption.monospacedDigit())
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            let status = model.status
            let shutter = status.exposure.duration > 0 ? Int((1 / status.exposure.duration).rounded()) : 0
            Text(verbatim: "Requested \(status.requestedPhotoSize)")
            Text(verbatim: "Last photo \(model.lastShot.map { "\($0.pixelWidth)×\($0.pixelHeight), saved in \($0.shutterToSavedMS) ms" } ?? "none")")
            Text(verbatim: "ISO \(Int(status.exposure.iso))  1/\(shutter)s  focus \(status.lensPosition.formatted(.number.precision(.fractionLength(2))))")
            Text(verbatim: "Gains \(Self.format(status.gains.red)) / \(Self.format(status.gains.green)) / \(Self.format(status.gains.blue))")
            Text(verbatim: "Level x \(Self.format(model.level.reading.xDegrees))°  y \(Self.format(model.level.reading.yDegrees))°")
        }
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}
