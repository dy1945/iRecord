import AppKit
import AVFoundation
import ControlProtocol
import Darwin

/// Commands share the GUI recorder, but CLI-owned recordings retain their raw
/// source until a successful export. No accessibility automation is involved.
@MainActor
final class AutomationController {
    static let shared = AutomationController()
    private let recorder = RecordingController.shared
    private var sessionID: String?
    private var source: URL?
    private var busy = false
    private var ownsCapture = false
    func releaseCapture() { ownsCapture = false }
    private var lastExport: ControlReply?
    private var lockFD: Int32 = -1
    private var listener: Int32 = -1

    func startServer() {
        do {
            try ControlSocket.prepareDirectory()
            lockFD = Darwin.open(ControlSocket.directory + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw ControlSocket.failure() }
            unlink(ControlSocket.path)
            guard ControlSocket.address({ bind(listener, $0, $1) }) == 0 else { throw ControlSocket.failure() }
            chmod(ControlSocket.path, 0o600)
            guard listen(listener, 8) == 0 else { throw ControlSocket.failure() }
            let fd = listener
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { if errno == EINTR { continue }; break }
                    guard ControlSocket.sameUser(client) else { close(client); continue }
                    ControlSocket.configure(client)
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let request = try ControlSocket.receive(ControlRequest.self, from: client)
                            Task { @MainActor in
                                let reply = await self.handle(request)
                                DispatchQueue.global(qos: .utility).async {
                                    try? ControlSocket.send(reply, to: client); close(client)
                                }
                            }
                        } catch { close(client) }
                    }
                }
            }
        } catch { NSLog("iRecord CLI unavailable: %@", error.localizedDescription) }
    }

    func acceptFinished(_ url: URL) -> Bool {
        guard ownsCapture else { return false }
        source = url
        ownsCapture = false
        return true
    }

    private var stateName: String {
        if busy && source != nil { return "exporting" }
        switch recorder.state {
        case .idle: return source == nil ? "idle" : "captured"
        case .preparing: return "preparing"
        case .recording: return "recording"
        case .paused: return "paused"
        case .finishing: return "finishing"
        case .failed: return "failed"
        }
    }
    private func status() -> ControlReply {
        var values = ["state": stateName, "app_path": Bundle.main.bundlePath,
                      "pid": String(getpid()), "protocol_version": "1",
                      "owner": ownsCapture ? "cli" : (recorder.isRecording ? "gui" : "none"),
                      "screen_permission": CGPreflightScreenCaptureAccess() ? "granted" : "required",
                      "elapsed_seconds": String(recorder.elapsed)]
        if let id = sessionID { values["session_id"] = id }
        if let source { values["source_path"] = source.path }
        if let lastExport { values["output"] = lastExport.values["output"] }
        if let error = recorder.lastErrorMessage { values["last_error"] = error }
        return ControlReply(values: values)
    }
    private func waitUntil(_ condition: () -> Bool, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }

    func handle(_ request: ControlRequest) async -> ControlReply {
        if request.command == "status" { return status() }
        if request.command == "permission request" {
            let granted = CGRequestScreenCaptureAccess()
            return granted
                ? ControlReply(values: ["screen_permission": "granted"])
                : ControlReply("permission_required", "Enable iRecord in System Settings > Privacy & Security > Screen & System Audio Recording, then restart iRecord.")
        }
        if request.command == "windows list" {
            guard CGPreflightScreenCaptureAccess() else { return permissionError() }
            let windows = ScreenInfo.filterWindows(await ScreenInfo.windows(), query: request.options["search"] ?? "")
            return ControlReply(windows: windows.map {
                ["id": String($0.id), "app": $0.appName, "title": $0.title,
                 "x": String(Int($0.frame.origin.x)), "y": String(Int($0.frame.origin.y)),
                 "width": String(Int($0.frame.width)), "height": String(Int($0.frame.height))]
            })
        }
        if request.command == "windows preview" {
            guard CGPreflightScreenCaptureAccess() else { return permissionError() }
            guard let rawID = request.options["window-id"], let id = UInt32(rawID),
                  let output = request.options["output"], output.hasPrefix("/"),
                  URL(fileURLWithPath: output).pathExtension.lowercased() == "png" else {
                return ControlReply("invalid_arguments", "Provide --window-id and an absolute .png --output path.")
            }
            guard let window = await ScreenInfo.windows().first(where: { $0.id == id }) else {
                return ControlReply("window_not_found", "Refresh windows list and choose an on-screen window.")
            }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                       [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return ControlReply("preview_failed", "Could not capture this window preview.")
            }
            let destination = URL(fileURLWithPath: output)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return ControlReply(values: ["output": output, "window_id": rawID,
                                               "app": window.appName, "title": window.title,
                                               "width": String(image.width), "height": String(image.height)])
            } catch {
                return ControlReply("output_exists", "Preview output must not already exist: \(error.localizedDescription)")
            }
        }
        guard !busy else { return ControlReply("busy", "Another command is in progress.", values: status().values) }
        if request.command == "recording start" {
            guard !recorder.isRecording, source == nil else {
                return ControlReply("already_recording", "An active or unexported recording already exists.", values: status().values)
            }
            guard CGPreflightScreenCaptureAccess() else { return permissionError() }
            guard let rawID = request.options["window-id"], let id = UInt32(rawID) else {
                return ControlReply("invalid_arguments", "--window-id must be an unsigned window ID.")
            }
            busy = true; defer { busy = false }
            guard await ScreenInfo.windows().contains(where: { $0.id == id }) else {
                return ControlReply("window_not_found", "Refresh windows list and choose an on-screen window.")
            }
            guard !recorder.isRecording else { return ControlReply("already_recording", "A recording started in the App.") }
            if recorder.captureMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                return ControlReply("permission_required", "Enable microphone access in iRecord or turn microphone recording off.")
            }
            sessionID = UUID().uuidString; lastExport = nil; ownsCapture = true
            recorder.startRecording(target: .window(windowID: id), automation: true)
            let ready = await waitUntil({ self.recorder.state == .recording || self.recorder.lastErrorMessage != nil })
            if ready && recorder.state == .recording { return status() }
            return ControlReply(ready ? "capture_failed" : "capture_timeout", recorder.lastErrorMessage ?? "Check status before retrying; capture may still be preparing.", values: status().values)
        }
        guard ["recording stop", "recording pause", "recording resume"].contains(request.command) else {
            return ControlReply("unknown_command", "Unknown command.")
        }
        guard let id = sessionID, request.options["session-id"] == id else {
            return ControlReply("session_mismatch", "Use the session_id returned by recording start.", values: status().values)
        }
        if request.command != "recording stop" {
            let pausing = request.command == "recording pause"
            guard ownsCapture, recorder.state == .recording || recorder.state == .paused else { return ControlReply("not_recording", "No active CLI recording.") }
            busy = true; defer { busy = false }
            if recorder.isPaused != pausing { recorder.togglePause() }
            let done = await waitUntil({ self.recorder.isPaused == pausing }, seconds: 5)
            return done ? status() : ControlReply("state_timeout", "Check status before retrying.")
        }
        let explicitOutput = request.options["output"]
        if let explicitOutput,
           (!explicitOutput.hasPrefix("/") || !["mp4", "mov", "gif"].contains(URL(fileURLWithPath: explicitOutput).pathExtension.lowercased())) {
            return ControlReply("invalid_arguments", "--output must be an absolute .mp4, .mov or .gif path.")
        }
        if let lastExport {
            return explicitOutput == nil || lastExport.values["output"] == explicitOutput
                ? lastExport
                : ControlReply("already_exported", "Session already exported.", values: lastExport.values)
        }
        let format = explicitOutput
            .flatMap { OutputFormat(rawValue: URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            ?? recorder.outputFormat
        let cropInsets: RecordingExportPolicy.CropInsets?
        if let raw = request.options["crop-insets"] {
            guard let parsed = RecordingExportPolicy.CropInsets.parse(raw) else {
                return ControlReply("invalid_arguments", "--crop-insets must be four non-negative source-pixel values: top,right,bottom,left.")
            }
            cropInsets = parsed
        } else {
            cropInsets = nil
        }
        if cropInsets != nil && format == .gif {
            return ControlReply("invalid_arguments", "--crop-insets currently supports MP4 and MOV output.")
        }
        let destination = explicitOutput.map { URL(fileURLWithPath: $0) }
            ?? uniqueDestination(directory: recorder.outputDirectory, format: format)
        let output = destination.path
        let maxEdge: CGFloat
        if let raw = request.options["max-edge"] {
            guard let value = Double(raw), value == 0 || (value >= 320 && value <= 8192) else {
                return ControlReply("invalid_arguments", "--max-edge must be 0 or a number from 320 through 8192.")
            }
            maxEdge = CGFloat(value)
        } else {
            maxEdge = 1920
        }
        let overwrite = request.options["overwrite"] == "true"
        if FileManager.default.fileExists(atPath: output) && !overwrite { return ControlReply("output_exists", "Use another filename or --overwrite.") }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            return ControlReply("invalid_output", "Output directory must exist and be writable.")
        }
        busy = true; defer { busy = false }
        if source == nil {
            guard ownsCapture, recorder.state == .recording || recorder.state == .paused || recorder.state == .finishing else {
                return ControlReply("not_recording", "No captured source is available.", values: status().values)
            }
            if recorder.state != .finishing { recorder.stopRecording() }
            guard await waitUntil({ self.source != nil || self.recorder.lastErrorMessage != nil }, seconds: 60), source != nil else {
                return ControlReply("capture_failed", recorder.lastErrorMessage ?? "Finalizing timed out; check status before retrying.", values: status().values)
            }
        }
        guard let source else { return ControlReply("capture_failed", "Missing source.") }
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportEngine.ExportError.noVideoTrack }
            let naturalSize = try await track.load(.naturalSize)
            let preferred = try await track.load(.preferredTransform)
            let oriented = naturalSize.applying(preferred)
            let sourceSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            let cropRect: CGRect?
            if let cropInsets {
                guard let rect = RecordingExportPolicy.cropRect(sourceSize, insets: cropInsets) else {
                    return ControlReply("invalid_arguments", "--crop-insets leaves no usable video area.")
                }
                cropRect = rect
            } else {
                cropRect = nil
            }
            let size = RecordingExportPolicy.fittedSize(cropRect?.size ?? sourceSize, maxEdge: maxEdge)
            let duration = try await asset.load(.duration).seconds
            let exported = try await ExportEngine.export(source: source,
                options: ExportOptions(renderSize: size, fps: recorder.fps,
                                       format: format, codec: recorder.codec,
                                       sourceCropRect: cropRect))
            defer { try? FileManager.default.removeItem(at: exported) }
            // Stage on the destination volume. link() provides exclusive creation;
            // rename() atomically replaces an existing file only with --overwrite.
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".irecord-\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: exported, to: stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            let result = overwrite ? rename(stage.path, destination.path) : link(stage.path, destination.path)
            guard result == 0 else { throw ControlSocket.failure() }
            recorder.noteExported(destination)
            let reply = ControlReply(values: ["state": "completed", "session_id": id, "output": output,
                                               "duration_seconds": String(duration), "width": String(Int(size.width)), "height": String(Int(size.height))])
            self.source = nil; lastExport = reply
            try? FileManager.default.removeItem(at: source)
            return reply
        } catch { return ControlReply("export_failed", error.localizedDescription, values: status().values) }
    }
    private func permissionError() -> ControlReply {
        ControlReply("permission_required", "Enable iRecord in System Settings > Privacy & Security > Screen Recording, then restart iRecord if macOS requests it.")
    }

    private func uniqueDestination(directory: URL, format: OutputFormat) -> URL {
        let base = RecordingController.recordingBaseName()
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(format.fileExtension)
            suffix += 1
        }
        return candidate
    }
}
