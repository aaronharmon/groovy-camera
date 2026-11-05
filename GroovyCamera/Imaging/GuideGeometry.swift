import AVFoundation
import CoreGraphics

/// An area between two centered rectangles. Half-sizes are fractions of the frame's short side,
/// along the axes of the portrait viewfinder.
struct GuideRing: Equatable, Sendable {
    var innerHalfWidth: CGFloat
    var innerHalfHeight: CGFloat
    var outerHalfWidth: CGFloat
    var outerHalfHeight: CGFloat

    static func square(innerHalf: CGFloat, outerHalf: CGFloat) -> GuideRing {
        GuideRing(innerHalfWidth: innerHalf, innerHalfHeight: innerHalf, outerHalfWidth: outerHalf, outerHalfHeight: outerHalf)
    }
}

enum Lens: String, CaseIterable, Codable, Sendable {
    /// Needed because the tripod height is fixed and the main lens can't fit a sleeve plus margin.
    case ultraWide
    case main

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .main: .builtInWideAngleCamera
        }
    }

    /// How much of the frame's short side the square viewfinder shows. The ultra-wide sees far
    /// more than the record, including the tripod, so its viewfinder shows only the middle.
    var viewfinderShare: CGFloat {
        switch self {
        case .ultraWide: 0.70
        case .main: 1
        }
    }

    /// Half the side of the square the sleeve goes inside, as a fraction of the frame's short side.
    var guideHalfSide: CGFloat {
        switch self {
        case .ultraWide: 0.32
        case .main: 0.42
        }
    }

    /// How much of the frame's short side a sleeve fills at the tripod's fixed height, measured
    /// from real photos.
    var sleeveShare: CGFloat {
        switch self {
        case .ultraWide: 0.59
        case .main: 0.95
        }
    }

    /// The middle of the viewfinder, for reading the empty white table when setting white.
    var emptyTable: GuideRing {
        .square(innerHalf: 0, outerHalf: viewfinderShare * 0.43)
    }

    /// The margin just outside the guide, which stays white in every photo.
    var aroundGuide: GuideRing {
        .square(innerHalf: guideHalfSide + 0.02, outerHalf: guideHalfSide + 0.06)
    }
}
