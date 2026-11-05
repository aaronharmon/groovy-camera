import AVKit
import SwiftData
import SwiftUI

/// The home screen. Opens straight into the viewfinder with a session ready.
struct CameraScreen: View {
    @State private var model: CameraModel
    @State private var isConfirmingDiscard = false

    init(context: ModelContext) {
        _model = State(initialValue: CameraModel(context: context))
    }

    private var session: SessionController { model.session }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.state.currentSlot?.title ?? "All sides shot")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button("Set White") { model.camera.setWhite() }
                    .buttonStyle(.bordered)
                    .disabled(model.status.white == .setting)
            }
            .padding(.horizontal)

            Viewfinder(model: model)

            if let notice {
                Text(notice.text)
                    .font(.subheadline)
                    .foregroundStyle(notice.isWarning ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            ThumbnailStrip(session: session)

            Spacer(minLength: 0)

            controls
        }
        .padding(.bottom, 8)
        .task { await model.start() }
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

    private var notice: (text: String, isWarning: Bool)? {
        if let message = model.status.message { return (message, true) }
        if session.captureFailed { return ("The last photo wasn't saved. Shoot it again.", true) }
        if model.isHot { return ("The phone is hot, so photos will take longer to finish.", true) }
        switch model.status.white {
        case .notSet: return ("Clear the table, then tap Set White.", false)
        case .setting: return ("Setting white…", false)
        case .set(let isNeutral):
            return isNeutral ? nil : ("White isn't fully neutral. Clear the table and try again.", true)
        }
    }
}

/// The square viewfinder with its guides.
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
