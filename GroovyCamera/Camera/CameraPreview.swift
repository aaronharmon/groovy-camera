@preconcurrency import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Changes whenever the camera is reconfigured, which creates a new preview connection.
    let revision: Int

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        // The preview is larger than the viewfinder and clipped to it, but clipping doesn't stop
        // the hidden part catching taps, and it overlaps the Set White button.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.connection?.videoRotationAngle = 90
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.connection?.videoRotationAngle = 90
        }
    }
}
