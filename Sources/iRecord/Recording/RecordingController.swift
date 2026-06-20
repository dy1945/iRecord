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

    /// Folder finished recordings are saved to (defaults to ~/Movies).
    @Published var outputDirectory: URL { didSet { defaults.set(outputDirectory.path, forKey: "outputDir") } }

    // Published live state.
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutputURL: URL?
    @Published var lastErrorMessage: String?

    private let recorder = ScreenRecorder()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var startDate: Date?
    private var accumulatedBeforePause: TimeInterval = 0
    private var sessionHighlightClicks = false

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
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

        let url = Self.makeTempOutputURL(format: .mov)
        recorder.start(configuration: config, outputURL: url)
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

    /// Moves a finished file into the configured output directory with a friendly
    /// name. Falls back to ~/Movies (then the temp location) if the chosen folder
    /// is not writable.
    func moveToOutputDirectory(_ url: URL) -> URL {
        let fm = FileManager.default
        var destDir = outputDirectory
        if !fm.fileExists(atPath: destDir.path) {
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        if !fm.isWritableFile(atPath: destDir.path) {
            destDir = RecordingController.defaultOutputDirectory
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "iRecord Recording \(df.string(from: Date())).\(url.pathExtension)"
        let dest = destDir.appendingPathComponent(name)
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: url, to: dest)
            return dest
        } catch {
            return url
        }
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
            // Hand the raw intermediate to the editor; saving happens after export.
            self.stopTimer()
            self.onFinished?(url)
        }
    }

    nonisolated func recorder(_ recorder: ScreenRecorder, didFailWith error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = error.localizedDescription
            self.stopTimer()
        }
    }
}
