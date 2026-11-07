import AVKit
import SwiftData
import SwiftUI

/// The home screen. Opens straight into the viewfinder with a session ready.
struct CameraScreen: View {
    let model: CameraModel
    @State private var isConfirmingDiscard = false
    /// Briefly true after Set White finishes, so a good result is seen rather than just assumed.
    @State private var isShowingWhiteResult = false

    private var session: SessionController { model.session }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.state.currentSlot?.title ?? "All sides shot")
                    .font(.headline.monospacedDigit())
                Spacer()
                if let level = whiteLevel {
                    Text(level.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(level.color)
                }
                Button("Set White") { model.camera.setWhite() }
                    .buttonStyle(.bordered)
                    .disabled(model.status.white == .setting)
            }
            .padding(.horizontal)

            HStack {
                AdjustmentControl(title: "Exposure", value: model.status.exposureBias, adjustment: .exposure) {
                    model.camera.setExposureBias($0)
                }
                Spacer()
                AdjustmentControl(title: "Warmth", value: model.status.warmth, adjustment: .warmth) {
                    model.camera.setWarmth($0)
                }
            }
            .disabled(model.status.white == .setting)
            .padding(.horizontal)

            Viewfinder(model: model)

            if let notice {
                Text(notice.text)
                    .font(.subheadline)
                    .foregroundStyle(notice.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            ThumbnailStrip(session: session)

            Spacer(minLength: 0)

            controls
        }
        .padding(.bottom, 8)
        .task { await model.start() }
        .task(id: isShowingWhiteResult) {
            guard isShowingWhiteResult else { return }
            try? await Task.sleep(for: .seconds(4))
            isShowingWhiteResult = false
        }
        .onChange(of: model.status.white) { old, new in
            if old == .setting, case .set = new { isShowingWhiteResult = true }
        }
        // The volume buttons work as the shutter, which avoids nudging the phone on its tripod.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { model.shoot() }
        }
        .confirmationDialog("Discard this record's photos?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard session", role: .destructive) { session.discard() }
        } message: {
            Text("They'll be deleted from this phone.")
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button(session.state.target == .extra ? "Cancel extra" : "+ Extra") { session.toggleExtra() }
                Spacer()
                if session.state.canSkip {
                    Button("Skip") { session.skip() }
                    Spacer()
                }
                Button("Discard", role: .destructive) { isConfirmingDiscard = true }
                    .disabled(!session.canDiscard)
            }
            .buttonStyle(.bordered)

            HStack {
                LevelBubble(reading: model.level.reading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShutterButton(action: model.shoot)
                    .disabled(!model.canShoot)
                Button("Done", action: session.finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.state.canFinish)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal)
    }

    private var notice: (text: String, color: Color)? {
        if let message = model.status.message { return (message, .red) }
        if session.captureFailed { return ("The last photo wasn't saved. Shoot it again.", .red) }
        if model.isHot { return ("The phone is hot, so photos will take longer to finish.", .red) }
        switch model.status.white {
        case .notSet: return ("Clear the table, then tap Set White.", .secondary)
        case .setting: return ("Setting white. Keep the table clear…", .secondary)
        case .set(let result):
            guard let result else { return nil }
            let percent = Int((result.brightness * 100).rounded())
            switch result.problem {
            case nil: return isShowingWhiteResult ? ("White set: \(percent)%.", .green) : nil
            case .tooDim: return ("The light is dim: white only reaches \(percent)% at the camera's limit. More light would help.", .red)
            case .tooBright: return ("White is clipping. Tap Set White again.", .red)
            }
        }
    }

    /// Always on screen, so it's clear whether white is set and how it measured.
    private var whiteLevel: (text: String, color: Color)? {
        guard case .set(let result) = model.status.white else { return nil }
        guard let result else { return ("White set", .secondary) }
        return ("White \(Int((result.brightness * 100).rounded()))%", result.problem == nil ? .green : .orange)
    }
}

/// A − / + control for one of the user's adjustments to the locked white.
private struct AdjustmentControl: View {
    let title: String
    let value: Double
    let adjustment: Adjustment
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Button { change(value - adjustment.step) } label: { Image(systemName: "minus") }
                .disabled(value <= adjustment.range.lowerBound)
                .accessibilityLabel("Less \(title.lowercased())")
            Text(Self.label(value))
                .monospacedDigit()
                .frame(minWidth: 32)
            Button { change(value + adjustment.step) } label: { Image(systemName: "plus") }
                .disabled(value >= adjustment.range.upperBound)
                .accessibilityLabel("More \(title.lowercased())")
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private static func label(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%+.1f", value).replacingOccurrences(of: ".0", with: "")
    }
}

private struct Viewfinder: View {
    let model: CameraModel

    private var lens: Lens { .ultraWide }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let frameWidth = side / lens.viewfinderShare
            ZStack {
                CameraPreview(session: model.camera.session, revision: model.status.revision)
                    .frame(width: frameWidth, height: frameWidth * 4 / 3)
                    .position(x: side / 2, y: side / 2)
                LineUpGuides(guideSide: frameWidth * lens.guideHalfSide * 2, slotKind: model.session.state.currentSlot?.kind ?? .sleeve)
                    .position(x: side / 2, y: side / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .background(.black)
    }
}

/// A square for sleeves, a circle and center dot for discs, and a crosshair on every shot.
private struct LineUpGuides: View {
    let guideSide: CGFloat
    let slotKind: Slot.Kind

    var body: some View {
        ZStack {
            if slotKind == .disc {
                Circle()
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: guideSide * 0.95, height: guideSide * 0.95)
                Circle()
                    .fill(.yellow)
                    .frame(width: 5, height: 5)
            } else {
                Rectangle()
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: guideSide, height: guideSide)
            }
            Rectangle().fill(.yellow).frame(width: guideSide, height: 0.5)
            Rectangle().fill(.yellow).frame(width: 0.5, height: guideSide)
        }
        .allowsHitTesting(false)
    }
}

/// This session's slots. Tapping one aims the next shot at it, to retake it or shoot one that was
/// skipped. The final crop appears here, so a bad one shows up before the record is moved.
private struct ThumbnailStrip: View {
    let session: SessionController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.tiles) { tile in
                    Button { session.select(tile.slot) } label: {
                        SlotThumbnail(tile: tile, isSelected: session.state.target == .slot(tile.slot))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 64)
    }
}

private struct SlotThumbnail: View {
    let tile: SlotTile
    let isSelected: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url = tile.thumbnail, let image = UIImage(contentsOfFile: url.path()) {
                Image(uiImage: image).resizable()
            }
            if tile.thumbnail == nil {
                Text(String(format: "%02d", tile.slot.number))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .overlay {
            if isSelected { Rectangle().stroke(.yellow, lineWidth: 3) }
        }
        .accessibilityLabel(tile.slot.title)
    }
}

private struct ShutterButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.primary, lineWidth: 3).frame(width: 72, height: 72)
                Circle().fill(isEnabled ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 60, height: 60)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shutter")
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
