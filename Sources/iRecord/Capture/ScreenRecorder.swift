import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics
import OSLog

/// High-level recorder state, observable by the UI.
enum RecorderState: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case finishing
    case failed(String)
}

protocol ScreenRecorderDelegate: AnyObject {
    func recorder(_ recorder: ScreenRecorder, didChangeState state: RecorderState)
    func recorder(_ recorder: ScreenRecorder, didFinishRecordingTo url: URL)
    func recorder(_ recorder: ScreenRecorder, didFailWith error: Error)
}

/// Errors surfaced by the recorder.
enum RecorderError: LocalizedError {
    case noShareableContent
    case targetNotFound
    case writerSetupFailed(String)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noShareableContent: return "No shareable screen content is available."
        case .targetNotFound: return "The selected display or window could not be found."
        case .writerSetupFailed(let m): return "Could not set up the video writer: \(m)"
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "There is no active recording."
        }
    }
}

/// The core recording engine.
///
/// Capture path: `SCStream` delivers uncompressed `CMSampleBuffer`s (BGRA pixel
/// buffers backed by IOSurfaces) on a dedicated queue. We hand them straight to
/// `AVAssetWriterInput`s configured for hardware H.264 / HEVC, so the GPU-captured
/// surfaces flow into VideoToolbox with no intermediate copies. This is what keeps
/// output performance high even at 60fps on a Retina display.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    weak var delegate: ScreenRecorderDelegate?

    private let log = Logger(subsystem: "com.irecord.app", category: "ScreenRecorder")

    // Capture
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.irecord.sample", qos: .userInitiated)

    // Writing
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var isPaused = false

    private let stateLock = NSLock()
    private(set) var state: RecorderState = .idle {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.recorder(self, didChangeState: s)
            }
        }
    }

    private var outputURL: URL?
    private var configuration: RecordingConfiguration?

    // MARK: CFR muxer state
    //
    // ScreenCaptureKit only emits frames when the screen changes, so writing
    // frames as they arrive yields a variable-frame-rate file (static content
    // reports as single-digit fps). Instead we keep the latest frame and a
    // timer appends it at a strict cadence — repeating the previous frame
    // when the screen is static — producing a constant-frame-rate file whose
    // duration matches wall-clock time. Paused time is excluded by shifting
    // the wall anchor.
    private var latestVideoFrame: CMSampleBuffer?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cfrTimer: DispatchSourceTimer?
    private var frameDuration = CMTime.invalid
    private var framesWritten = 0
    private var firstFramePTS: CMTime?
    private var wallAnchor: CFAbsoluteTime?
    private var totalPaused: CFAbsoluteTime = 0
    private var pauseBegan: CFAbsoluteTime?
    private var lastVideoPTS: CMTime?

    // MARK: - Public API

    var isRecording: Bool {
        if case .recording = state { return true }
        if case .paused = state { return true }
        return false
    }

    /// Begin a recording session with the given configuration.
    func start(configuration config: RecordingConfiguration, outputURL url: URL) {
        guard !isRecording else {
            delegate?.recorder(self, didFailWith: RecorderError.alreadyRecording)
            return
        }
        self.configuration = config
        self.outputURL = url
        self.state = .preparing
        self.latestVideoFrame = nil
        self.framesWritten = 0
        self.firstFramePTS = nil
        self.wallAnchor = nil
        self.totalPaused = 0
        self.pauseBegan = nil
        self.lastVideoPTS = nil
        self.sessionStarted = false
        self.isPaused = false

        Task {
            do {
                try await self.configureAndStart(config: config, url: url)
            } catch {
                self.handleFailure(error)
            }
        }
    }

    func pause() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard case .recording = state else { return }
        isPaused = true
        pauseBegan = CFAbsoluteTimeGetCurrent()
        state = .paused
    }

    func resume() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard case .paused = state else { return }
        if let began = pauseBegan {
            totalPaused += CFAbsoluteTimeGetCurrent() - began
            pauseBegan = nil
        }
        isPaused = false
        state = .recording
    }

    /// Stop recording and finalize the file.
    func stop() {
        guard isRecording else { return }
        state = .finishing
        Task {
            await self.finish()
        }
    }

    // MARK: - Setup

    private func configureAndStart(config: RecordingConfiguration, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let pixelSize: CGSize
        let scale: CGFloat

        switch config.target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw RecorderError.targetNotFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            scale = Self.backingScale(for: displayID)
            pixelSize = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)

        case .area(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw RecorderError.targetNotFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            scale = Self.backingScale(for: displayID)
            pixelSize = CGSize(width: (rect.width * scale).rounded(.down),
                               height: (rect.height * scale).rounded(.down))

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.targetNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            scale = Self.backingScale(for: CGMainDisplayID())
            pixelSize = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = max(2, Int(pixelSize.width))
        streamConfig.height = max(2, Int(pixelSize.height))
        // Even dimensions are required by most H.264/HEVC encoders.
        if streamConfig.width % 2 != 0 { streamConfig.width -= 1 }
        if streamConfig.height % 2 != 0 { streamConfig.height -= 1 }

        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.queueDepth = 6
        streamConfig.showsCursor = config.showsCursor
        // BGRA, IOSurface-backed — the cheapest path into VideoToolbox.
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))

        // Crop for area capture.
        if case .area(_, let rect) = config.target {
            streamConfig.sourceRect = rect
            streamConfig.scalesToFit = false
        }

        // Audio.
        if config.captureSystemAudio {
            streamConfig.capturesAudio = true
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
            streamConfig.excludesCurrentProcessAudio = true
        }
        if config.captureMicrophone, #available(macOS 15.0, *) {
            streamConfig.captureMicrophone = true
        }

        try setupWriter(config: config, url: url, pixelSize: CGSize(width: streamConfig.width, height: streamConfig.height))

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if config.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if config.captureMicrophone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        try await stream.startCapture()
        state = .recording
        log.info("Recording started: \(streamConfig.width)x\(streamConfig.height) @ \(config.fps)fps")
    }

    private func setupWriter(config: RecordingConfiguration, url: URL, pixelSize: CGSize) throws {
        try? FileManager.default.removeItem(at: url)

        // GIF/MP4/MOV all record to a MOV/MP4 first; GIF is converted on finish.
        let fileType: AVFileType = (config.outputFormat == .mov) ? .mov : .mp4
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw RecorderError.writerSetupFailed(error.localizedDescription)
        }

        let bitrate = config.bitrate > 0
            ? config.bitrate
            : Self.recommendedBitrate(width: Int(pixelSize.width), height: Int(pixelSize.height), fps: config.fps)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: config.fps,
            AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        if config.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec.avCodec,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            throw RecorderError.writerSetupFailed("cannot add video input")
        }
        writer.add(vInput)
        self.videoInput = vInput
        self.pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(pixelSize.width),
                kCVPixelBufferHeightKey as String: Int(pixelSize.height)
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]

        if config.captureSystemAudio {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.systemAudioInput = aInput
            }
        }
        if config.captureMicrophone {
            let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mInput.expectsMediaDataInRealTime = true
            if writer.canAdd(mInput) {
                writer.add(mInput)
                self.micAudioInput = mInput
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        self.writer = writer
    }

    // MARK: - Finish

    private func finish() async {
        // Stop capture first so no new buffers arrive.
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        // Stop the cadence timer and flush the frames still due up to now, so
        // the file's duration matches the wall-clock recording length.
        cfrTimer?.cancel()
        cfrTimer = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [weak self] in
                self?.appendDueFrames()
                cont.resume()
            }
        }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()

        guard let writer, let url = outputURL, let config = configuration else {
            state = .idle
            return
        }

        await writer.finishWriting()

        if writer.status == .failed {
            handleFailure(writer.error ?? RecorderError.writerSetupFailed("unknown"))
            return
        }

        // Convert to GIF if requested.
        if config.outputFormat == .gif {
            do {
                let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
                try await GIFExporter.export(from: url, to: gifURL, fps: config.gifFPS)
                try? FileManager.default.removeItem(at: url)
                deliverFinished(gifURL)
            } catch {
                handleFailure(error)
            }
        } else {
            deliverFinished(url)
        }
    }

    private func deliverFinished(_ url: URL) {
        state = .idle
        cleanup()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.recorder(self, didFinishRecordingTo: url)
        }
    }

    private func handleFailure(_ error: Error) {
        log.error("Recorder failed: \(error.localizedDescription)")
        state = .failed(error.localizedDescription)
        cleanup()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.recorder(self, didFailWith: error)
        }
    }

    private func cleanup() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        pixelAdaptor = nil
        latestVideoFrame = nil
        cfrTimer?.cancel()
        cfrTimer = nil
        framesWritten = 0
        firstFramePTS = nil
        wallAnchor = nil
        totalPaused = 0
        pauseBegan = nil
        configuration = nil
        sessionStarted = false
    }

    // MARK: - Helpers

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let pixelWidth = mode.pixelWidth
            let pointWidth = mode.width
            if pointWidth > 0 { return CGFloat(pixelWidth) / CGFloat(pointWidth) }
        }
        return 2.0
    }

    /// Bitrate heuristic tuned for screen content (sharp text, mostly static
    /// frames): ~0.1 bits per pixel-per-second, clamped to sane bounds.
    static func recommendedBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = Double(width * height)
        let raw = pixels * Double(fps) * 0.1
        let clamped = min(max(raw, 2_000_000), 60_000_000)
        return Int(clamped)
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleFailure(error)
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Drop everything while paused.
        stateLock.lock()
        let paused = isPaused
        stateLock.unlock()

        switch type {
        case .screen:
            handleVideo(sampleBuffer, paused: paused)
        case .audio:
            if !paused { append(sampleBuffer, to: systemAudioInput) }
        default:
            // .microphone (macOS 15+)
            if #available(macOS 15.0, *), type == .microphone {
                if !paused { append(sampleBuffer, to: micAudioInput) }
            }
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, paused: Bool) {
        // Only keep complete frames.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        guard let writer else { return }

        // Always track the newest frame (even while paused, so resume starts
        // fresh); the CFR timer decides what gets written and when.
        latestVideoFrame = sampleBuffer

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstFramePTS = pts
            wallAnchor = CFAbsoluteTimeGetCurrent()
            startCFRTimer()
        }
    }

    // MARK: CFR muxer

    /// Starts the cadence timer on the sample queue: every tick appends the
    /// latest frame (repeating it when the screen is static) until the
    /// written-frame count catches up with elapsed wall-clock time.
    private func startCFRTimer() {
        let fps = max(1, Int32(configuration?.fps ?? 30))
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(),
                       repeating: .milliseconds(Int(1000 / fps)),
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.appendDueFrames() }
        cfrTimer = timer
        timer.resume()
    }

    /// Appends as many frames as wall-clock time says are due. The video PTS
    /// is synthetic (firstPTS + n × frameDuration), so output is strict CFR
    /// and stays locked to real time regardless of capture jitter or drops.
    private func appendDueFrames() {
        guard sessionStarted, let videoInput, let adaptor = pixelAdaptor,
              let config = configuration, let wallAnchor, let firstFramePTS else { return }
        stateLock.lock()
        let paused = isPaused
        stateLock.unlock()
        guard !paused else { return }

        let elapsed = CFAbsoluteTimeGetCurrent() - wallAnchor - totalPaused
        let targetCount = Int(elapsed * Double(config.fps))
        while framesWritten < targetCount {
            guard videoInput.isReadyForMoreMediaData,
                  let buffer = latestVideoFrame,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            let pts = CMTimeAdd(firstFramePTS, CMTimeMultiply(frameDuration, multiplier: Int32(framesWritten)))
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                framesWritten += 1
                lastVideoPTS = pts
            } else {
                return
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
