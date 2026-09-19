import Foundation
import AppKit
import Combine
import CoreGraphics

/// The app-wide coordinator. Owns the recorder, the user's chosen settings, and
/// publishes state for the SwiftUI control panel and the menu-bar item.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    // Published settings (persisted to UserDefaults).
    @Published var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    @Published var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: "codec") } }
    @Published var outputFormat: OutputFormat { didSet { defaults.set(outputFormat.rawValue, forKey: "format") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "sysAudio") } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "mic") } }
    /// Frame rate the screen is captured at. Output FPS is chosen later, in the editor.
    @Published var captureFPS: Int { didSet { defaults.set(captureFPS, forKey: "captureFPS") } }
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "cursor") } }
    @Published var highlightClicks: Bool { didSet { defaults.set(highlightClicks, forKey: "clicks") } }
    /// Screenshot output: also write the image to the effective screenshot
    /// directory (false, default, keeps it clipboard-only).
    @Published var screenshotAlsoSaves: Bool { didSet { defaults.set(screenshotAlsoSaves, forKey: "shotAlsoSaves") } }
    /// When true (default), screenshots save into the recording folder;
    /// when false, they go to `screenshotDirectory`.
    @Published var screenshotUsesRecordingDir: Bool { didSet { defaults.set(screenshotUsesRecordingDir, forKey: "shotSameAsRec") } }
    /// Screenshot folder used when `screenshotUsesRecordingDir` is off
    /// (defaults to ~/Pictures).
    @Published var screenshotDirectory: URL { didSet { defaults.set(screenshotDirectory.path, forKey: "shotDir") } }
    /// Copy every screenshot to the clipboard (default true).
    @Published var shotCopyToClipboard: Bool { didSet { defaults.set(shotCopyToClipboard, forKey: "shotCopyClip") } }
    /// Image format used when a screenshot is written to disk (default PNG).
    @Published var screenshotImageFormat: ScreenshotFormat { didSet { defaults.set(screenshotImageFormat.rawValue, forKey: "shotFormat") } }
    /// Pre-select the frontmost window when the shot overlay opens (default true).
    @Published var autoSelectFrontWindow: Bool { didSet { defaults.set(autoSelectFrontWindow, forKey: "shotAutoFront") } }
    /// Frame the window under the cursor while hovering in the shot overlay
    /// (default true).
    @Published var hoverFramesWindows: Bool { didSet { defaults.set(hoverFramesWindows, forKey: "shotHoverFrame") } }

    /// Flipped whenever the UI language changes so observed views re-render.
    @Published var uiRefresh = false

    /// Folder finished recordings are saved to (defaults to ~/Movies).
    @Published var outputDirectory: URL { didSet { defaults.set(outputDirectory.path, forKey: "outputDir") } }

    /// Where screenshot files actually land.
    var effectiveScreenshotDirectory: URL {
        screenshotUsesRecordingDir ? outputDirectory : screenshotDirectory
    }

    // Published live state.
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutputURL: URL?
    @Published var lastErrorMessage: String?
    /// Live size of the file being written, polled while recording.
    @Published private(set) var recordingFileSize: Int64 = 0
    /// What the current session captures (for the status chips).
    @Published private(set) var sessionInfo: RecordingSessionInfo?

    /// Summary of the active capture target, shown as status chips.
    struct RecordingSessionInfo {
        enum Mode { case area, window, display }
        let mode: Mode
        let size: CGSize?
    }

    private let recorder = ScreenRecorder()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var startDate: Date?
    private var accumulatedBeforePause: TimeInterval = 0
    private var sessionHighlightClicks = false

    /// Chips reflect the session's actual options (window capture drops clicks).
    var chipsHighlightClicks: Bool { sessionHighlightClicks }
    /// Temp file currently being written; polled for the live size readout.
    private var activeTempURL: URL?
    /// Set by `cancelRecording`: the finished file is deleted, not presented.
    private var discardOnFinish = false

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    }

    static var defaultScreenshotDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? defaultOutputDirectory
    }

    /// Callback fired when a recording finishes (used to open the file / show toast).
    var onFinished: ((URL) -> Void)?

    private init() {
        fps = defaults.object(forKey: "fps") as? Int ?? 60
        codec = VideoCodec(rawValue: defaults.string(forKey: "codec") ?? "") ?? .h264
        outputFormat = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .mp4
        captureSystemAudio = defaults.bool(forKey: "sysAudio")
        captureMicrophone = defaults.bool(forKey: "mic")
        captureFPS = defaults.object(forKey: "captureFPS") as? Int ?? 60
        showsCursor = defaults.object(forKey: "cursor") as? Bool ?? true
        highlightClicks = defaults.bool(forKey: "clicks")
        screenshotAlsoSaves = defaults.bool(forKey: "shotAlsoSaves")
        screenshotUsesRecordingDir = defaults.object(forKey: "shotSameAsRec") as? Bool ?? true
        if let path = defaults.string(forKey: "shotDir") {
            screenshotDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            screenshotDirectory = RecordingController.defaultScreenshotDirectory
        }
        shotCopyToClipboard = defaults.object(forKey: "shotCopyClip") as? Bool ?? true
        screenshotImageFormat = ScreenshotFormat(rawValue: defaults.string(forKey: "shotFormat") ?? "") ?? .png
        autoSelectFrontWindow = defaults.object(forKey: "shotAutoFront") as? Bool ?? true
        hoverFramesWindows = defaults.object(forKey: "shotHoverFrame") as? Bool ?? true
        if let path = defaults.string(forKey: "outputDir") {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = RecordingController.defaultOutputDirectory
        }
        recorder.delegate = self
    }

    var isRecording: Bool {
        switch state {
        case .recording, .paused, .preparing, .finishing: return true
        default: return false
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    // MARK: - Control

    func startRecording(target: CaptureTarget) {
        guard !isRecording else { return }
        lastErrorMessage = nil

        // Kap-style flow: capture a high-quality intermediate (native size, H.264
        // MOV). Output size / fps / format are chosen afterwards in the editor.
        var config = RecordingConfiguration(target: target)
        config.fps = captureFPS
        config.codec = .h264
        config.outputFormat = .mov
        config.captureSystemAudio = captureSystemAudio
        config.captureMicrophone = captureMicrophone
        config.showsCursor = showsCursor
        config.highlightClicks = highlightClicks

        // Click ripples are only meaningful for screen/area capture (a window
        // capture won't include the overlay).
        sessionHighlightClicks = highlightClicks
        if highlightClicks {
            if case .window = target { sessionHighlightClicks = false }
        }

        sessionInfo = Self.makeSessionInfo(for: target)
        recordingFileSize = 0
        discardOnFinish = false

        let url = Self.makeTempOutputURL(format: .mov)
        activeTempURL = url
        recorder.start(configuration: config, outputURL: url)
    }

    private static func makeSessionInfo(for target: CaptureTarget) -> RecordingSessionInfo {
        switch target {
        case .area(_, let rect):
            return RecordingSessionInfo(mode: .area, size: rect.size)
        case .window(let id):
            return RecordingSessionInfo(mode: .window, size: windowSize(id))
        case .display(let id):
            return RecordingSessionInfo(mode: .display,
                                        size: ScreenInfo.nsScreen(for: id)?.frame.size)
        }
    }

    private static func windowSize(_ id: CGWindowID) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return r.size
    }

    /// Stops the recording and throws the captured file away instead of
    /// presenting it in the editor.
    func cancelRecording() {
        guard isRecording else { return }
        discardOnFinish = true
        recorder.stop()
    }

    /// Records the final saved/exported URL after the editor finishes.
    func noteExported(_ url: URL) {
        lastOutputURL = url
    }

    func stopRecording() {
        recorder.stop()
    }

    func togglePause() {
        if isPaused { recorder.resume() } else { recorder.pause() }
    }

    // MARK: - Timer

    private func startTimer() {
        startDate = Date()
        accumulatedBeforePause = 0
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                if case .recording = self.state {
                    self.elapsed = self.accumulatedBeforePause + Date().timeIntervalSince(start)
                }
                if let url = self.activeTempURL,
                   let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                    self.recordingFileSize = size
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
        accumulatedBeforePause = 0
    }

    // MARK: - Output paths

    private static func makeTempOutputURL(format: OutputFormat) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        // GIF is converted from an MP4 first.
        let ext = (format == .gif) ? "mp4" : format.fileExtension
        return dir.appendingPathComponent("iRecord-\(stamp).\(ext)")
    }

    /// Base name for a finished recording, per the settings mockup:
    /// `录屏 2026-09-19 09-01-30` (seconds included to avoid collisions).
    static func recordingBaseName(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(L10n.tr("Recording", "录屏")) \(df.string(from: date))"
    }
}

// MARK: - ScreenRecorderDelegate

extension RecordingController: ScreenRecorderDelegate {
    nonisolated func recorder(_ recorder: ScreenRecorder, didChangeState state: RecorderState) {
        Task { @MainActor in
            let previous = self.state
            self.state = state
            switch state {
            case .recording:
                if case .paused = previous {
                    // resumed
                    if let start = self.startDate {
                        self.accumulatedBeforePause = self.elapsed
                        _ = start
                        self.startDate = Date()
                    }
                } else {
                    self.startTimer()
                    if self.sessionHighlightClicks {
                        ClickHighlighter.shared.start()
                    }
                }
            case .paused:
                self.accumulatedBeforePause = self.elapsed
            case .idle, .failed:
                self.stopTimer()
                self.sessionInfo = nil
                self.activeTempURL = nil
                ClickHighlighter.shared.stop()
            case .finishing:
                ClickHighlighter.shared.stop()
            default:
                break
            }
        }
    }

    nonisolated func recorder(_ recorder: ScreenRecorder, didFinishRecordingTo url: URL) {
        Task { @MainActor in
            self.stopTimer()
            if self.discardOnFinish {
                // Cancelled: delete the partial recording, no editor.
                self.discardOnFinish = false
                self.activeTempURL = nil
                self.recordingFileSize = 0
                try? FileManager.default.removeItem(at: url)
                return
            }
            // Hand the raw intermediate to the editor; saving happens after export.
            self.onFinished?(url)
        }
    }

    nonisolated func recorder(_ recorder: ScreenRecorder, didFailWith error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = error.localizedDescription
            self.discardOnFinish = false
            self.stopTimer()
        }
    }
}
