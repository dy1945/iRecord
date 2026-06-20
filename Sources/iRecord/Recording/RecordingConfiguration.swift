import Foundation
import CoreGraphics
import AVFoundation

/// Which video codec the hardware encoder should target.
enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Output container / export format the user asked for.
enum OutputFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov
    case gif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .gif: return "GIF"
        }
    }

    var fileExtension: String { rawValue }
}

/// What region of the screen the user wants to capture.
enum CaptureTarget: Equatable {
    /// Capture an entire display.
    case display(displayID: CGDirectDisplayID)
    /// Capture a cropped rectangle of a display, in global (top-left origin) display points.
    case area(displayID: CGDirectDisplayID, rect: CGRect)
    /// Capture a single window.
    case window(windowID: CGWindowID)
}

/// Everything the recorder needs to start a session.
struct RecordingConfiguration {
    var target: CaptureTarget
    var fps: Int = 60
    var codec: VideoCodec = .h264
    var outputFormat: OutputFormat = .mp4

    /// Capture system (application) audio. Requires macOS 13+.
    var captureSystemAudio: Bool = false
    /// Capture the default microphone. Uses the macOS 15 SCStream microphone path
    /// when available, otherwise falls back to an AVCaptureSession mic feed.
    var captureMicrophone: Bool = false

    /// Show the mouse cursor in the recording.
    var showsCursor: Bool = true

    /// Draw an animated ripple at each mouse click so taps are visible in the
    /// recording. Implemented via an on-screen overlay that the capture includes.
    var highlightClicks: Bool = false

    /// Average bitrate target in bits/second. 0 means "derive from resolution".
    var bitrate: Int = 0

    /// Desired GIF frame rate when exporting to GIF (kept lower for file size).
    var gifFPS: Int = 15
}
