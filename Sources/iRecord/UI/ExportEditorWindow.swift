import AppKit
import AVKit
import AVFoundation
import CoreMedia

/// Kap-style post-recording editor: preview the clip, trim it, choose the output
/// size / scale / FPS / format / destination, then Convert. Output parameters are
/// chosen *here*, after recording — not before.
@MainActor
final class ExportEditorWindowController: NSWindowController {
    private let sourceURL: URL
    private let defaultDirectory: URL
    private let captureFPS: Int
    private var onExported: ((URL) -> Void)?

    private let player: AVPlayer
    private let playerView = AVPlayerView()

    private var nativeSize = CGSize(width: 1280, height: 720)
    private var trimStart: CMTime?
    private var trimEnd: CMTime?
    private var didExportOrSave = false

    // Controls
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let scalePopup = NSPopUpButton()
    private let fpsField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let destinationPopup = NSPopUpButton()
    private let convertButton = NSButton()
    private let muteButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    // Rotating circular progress shown over the preview during conversion.
    private let circularProgress = CircularProgressView()

    // Format table: title → (container, codec)
    private let formats: [(title: String, format: OutputFormat, codec: VideoCodec)] = [
        ("MP4 (H264)", .mp4, .h264),
        ("MP4 (HEVC)", .mp4, .hevc),
        ("MOV (HEVC)", .mov, .hevc),
        ("GIF", .gif, .h264)
    ]

    init(sourceURL: URL, defaultDirectory: URL, captureFPS: Int, onExported: ((URL) -> Void)?) {
        self.sourceURL = sourceURL
        self.defaultDirectory = defaultDirectory
        self.captureFPS = captureFPS
        self.onExported = onExported
        self.player = AVPlayer(url: sourceURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = sourceURL.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        Task { await loadAssetInfo() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        player.play()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // No AirPlay this phase: disabling external playback removes the AirPlay
        // routing button from the inline transport controls.
        player.allowsExternalPlayback = false

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        // Rotating progress ring, centered over the preview, hidden until convert.
        circularProgress.translatesAutoresizingMaskIntoConstraints = false
        circularProgress.isHidden = true
        content.addSubview(circularProgress)

        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        // Left group: mute + trim + size + scale + fps
        let trimButton = NSButton(title: " Trim", target: self, action: #selector(beginTrim))
        trimButton.bezelStyle = .rounded
        trimButton.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim")
        trimButton.imagePosition = .imageLeading

        // Mute toggle: the recording may carry system/mic audio; let the user play
        // it back with sound or silenced. Default is sound on.
        muteButton.bezelStyle = .rounded
        muteButton.setButtonType(.toggle)
        muteButton.imagePosition = .imageOnly
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        updateMuteButton()

        configureNumberField(widthField, width: 58)
        configureNumberField(heightField, width: 58)
        configureNumberField(fpsField, width: 42)

        scalePopup.addItems(withTitles: ["100%", "75%", "50%", "25%"])
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)

        formatPopup.addItems(withTitles: formats.map { $0.title })
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        destinationPopup.addItems(withTitles: ["Save to File…", "Copy to Clipboard"])

        let leftStack = NSStackView(views: [
            muteButton,
            trimButton,
            NSTextField(labelWithString: "Size"),
            widthField,
            NSTextField(labelWithString: "×"),
            heightField,
            scalePopup,
            NSTextField(labelWithString: "FPS"),
            fpsField
        ])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        convertButton.title = "Convert"
        convertButton.bezelStyle = .rounded
        convertButton.keyEquivalent = "\r"
        convertButton.target = self
        convertButton.action = #selector(convert)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let rightStack = NSStackView(views: [
            statusLabel,
            formatPopup,
            destinationPopup,
            convertButton
        ])
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(leftStack)
        bar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),

            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            circularProgress.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            circularProgress.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            circularProgress.widthAnchor.constraint(equalToConstant: 88),
            circularProgress.heightAnchor.constraint(equalToConstant: 88)
        ])
    }

    private func configureNumberField(_ field: NSTextField, width: CGFloat) {
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        field.formatter = fmt
    }

    // MARK: - Asset info

    private func loadAssetInfo() async {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }
        let oriented = natural.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? Float(captureFPS)

        await MainActor.run {
            self.nativeSize = size
            self.widthField.integerValue = Int(size.width)
            self.heightField.integerValue = Int(size.height)
            self.fpsField.integerValue = Int(nominalFPS.rounded()) > 0 ? Int(nominalFPS.rounded()) : self.captureFPS
        }
    }

    // MARK: - Actions

    @objc private func scaleChanged() {
        let pct: CGFloat
        switch scalePopup.indexOfSelectedItem {
        case 1: pct = 0.75
        case 2: pct = 0.5
        case 3: pct = 0.25
        default: pct = 1.0
        }
        widthField.integerValue = Int((nativeSize.width * pct).rounded())
        heightField.integerValue = Int((nativeSize.height * pct).rounded())
    }

    @objc private func formatChanged() {
        // GIF tends to want a lower default fps; nudge the field if it is high.
        if formats[formatPopup.indexOfSelectedItem].format == .gif, fpsField.integerValue > 20 {
            fpsField.integerValue = 15
        }
    }

    @objc private func toggleMute() {
        player.isMuted = (muteButton.state == .on)
        updateMuteButton()
    }

    private func updateMuteButton() {
        let muted = player.isMuted
        muteButton.state = muted ? .on : .off
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: muted ? "Unmute" : "Mute")
        muteButton.toolTip = muted ? "Sound off — click to enable" : "Sound on — click to mute"
    }

    @objc private func beginTrim() {
        guard playerView.canBeginTrimming else {
            NSSound.beep()
            return
        }
        playerView.beginTrimming { [weak self] result in
            guard let self, result == .okButton, let item = self.player.currentItem else { return }
            // The native trimmer records the front/back axis in these item
            // properties; this range becomes the final generated video length.
            let start = item.reversePlaybackEndTime
            let end = item.forwardPlaybackEndTime
            self.trimStart = CMTIME_IS_NUMERIC(start) ? start : nil
            self.trimEnd = CMTIME_IS_NUMERIC(end) ? end : nil
            self.updateTrimStatus()
        }
    }

    /// Reflect the selected front/back trim window as the resulting clip length.
    private func updateTrimStatus() {
        guard let s = trimStart, let e = trimEnd, e > s else {
            statusLabel.stringValue = ""
            return
        }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(e, s))
        guard seconds.isFinite, seconds > 0 else { statusLabel.stringValue = ""; return }
        statusLabel.stringValue = String(format: "Length %.1fs", seconds)
    }

    @objc private func convert() {
        let width = max(2, widthField.integerValue)
        let height = max(2, heightField.integerValue)
        let fps = max(1, fpsField.integerValue)
        let entry = formats[formatPopup.indexOfSelectedItem]
        let saveToFile = destinationPopup.indexOfSelectedItem == 0

        var range: CMTimeRange?
        if let s = trimStart, let e = trimEnd, e > s {
            range = CMTimeRange(start: s, duration: CMTimeSubtract(e, s))
        }

        let options = ExportOptions(
            timeRange: range,
            renderSize: CGSize(width: width, height: height),
            fps: fps,
            format: entry.format,
            codec: entry.codec)

        setBusy(true, message: "Converting…")
        // GIF has no fractional progress; spin without a percentage there.
        circularProgress.setIndeterminate(entry.format == .gif)
        player.pause()

        Task {
            do {
                let temp = try await ExportEngine.export(source: sourceURL, options: options) { fraction in
                    Task { @MainActor in self.circularProgress.progress = fraction }
                }
                await MainActor.run {
                    self.setBusy(false, message: "")
                    if saveToFile {
                        self.saveToFile(temp, ext: entry.format.fileExtension)
                    } else {
                        self.copyToClipboard(temp)
                    }
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false, message: "")
                    self.showError(error)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        convertButton.isEnabled = !busy
        formatPopup.isEnabled = !busy
        destinationPopup.isEnabled = !busy
        statusLabel.stringValue = message
        if busy {
            circularProgress.progress = 0
            circularProgress.isHidden = false
            circularProgress.startSpinning()
        } else {
            circularProgress.stopSpinning()
            circularProgress.isHidden = true
        }
    }

    // MARK: - Destinations

    private func saveToFile(_ temp: URL, ext: String) {
        let panel = NSSavePanel()
        panel.directoryURL = defaultDirectory
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "iRecord Recording \(df.string(from: Date())).\(ext)"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let dest = panel.url {
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: temp, to: dest)
                    self.didExportOrSave = true
                    self.onExported?(dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    self.close()
                } catch {
                    self.showError(error)
                }
            } else {
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }

    private func copyToClipboard(_ temp: URL) {
        // Keep a stable copy so the pasteboard URL stays valid after this window closes.
        let stable = defaultDirectory.appendingPathComponent(temp.lastPathComponent)
        try? FileManager.default.removeItem(at: stable)
        let finalURL = (try? FileManager.default.copyItem(at: temp, to: stable)) != nil ? stable : temp

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([finalURL as NSURL])
        if let data = try? Data(contentsOf: finalURL) {
            // Also offer the raw data (helps apps that paste image/video bytes).
            let type = NSPasteboard.PasteboardType(rawValue: finalURL.pathExtension == "gif" ? "com.compuserve.gif" : "public.movie")
            pb.setData(data, forType: type)
        }
        didExportOrSave = true
        statusLabel.stringValue = "Copied to clipboard"
        onExported?(finalURL)
        // Brief confirmation, then close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.close()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

// MARK: - NSWindowDelegate

extension ExportEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        player.pause()
        // Clean up the recording intermediate if the user closed without exporting.
        if !didExportOrSave {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        EditorPresenter.shared.didClose(self)
    }
}

/// Retains editor windows for their lifetime (NSWindowController would otherwise
/// be deallocated immediately).
@MainActor
final class EditorPresenter {
    static let shared = EditorPresenter()
    private var controllers: [ExportEditorWindowController] = []

    func present(sourceURL: URL, defaultDirectory: URL, captureFPS: Int, onExported: ((URL) -> Void)?) {
        let controller = ExportEditorWindowController(
            sourceURL: sourceURL,
            defaultDirectory: defaultDirectory,
            captureFPS: captureFPS,
            onExported: onExported)
        controllers.append(controller)
        controller.present()
    }

    func didClose(_ controller: ExportEditorWindowController) {
        controllers.removeAll { $0 === controller }
    }
}

// MARK: - Circular progress

/// A rotating progress ring used while a clip is being generated. A faint full
/// track sits under a continuously spinning arc; when a determinate fraction is
/// available it also draws a filled progress arc plus a centered percentage.
@MainActor
final class CircularProgressView: NSView {
    private let backdrop = CAShapeLayer()
    private let track = CAShapeLayer()
    private let spinner = CAShapeLayer()   // rotating indeterminate arc
    private let fill = CAShapeLayer()      // determinate progress arc
    private let percentLabel = NSTextField(labelWithString: "")
    private var indeterminate = true
    private let lineWidth: CGFloat = 6

    /// 0...1 fraction. Setting it switches the view to determinate display.
    var progress: Double = 0 {
        didSet {
            let p = max(0, min(1, progress))
            fill.strokeEnd = CGFloat(p)
            fill.isHidden = indeterminate
            percentLabel.isHidden = indeterminate
            percentLabel.stringValue = "\(Int((p * 100).rounded()))%"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let host = layer else { return }

        backdrop.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        backdrop.strokeColor = nil
        host.addSublayer(backdrop)

        for shape in [track, fill, spinner] {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            host.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.strokeColor = NSColor.controlAccentColor.cgColor
        fill.strokeStart = 0
        fill.strokeEnd = 0
        fill.isHidden = true
        spinner.strokeColor = NSColor.white.cgColor
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.25   // quarter-circle that rotates

        percentLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        percentLabel.textColor = .white
        percentLabel.alignment = .center
        percentLabel.isHidden = true
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        NSLayoutConstraint.activate([
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        let b = bounds
        backdrop.frame = b
        backdrop.path = CGPath(roundedRect: b, cornerWidth: 16, cornerHeight: 16, transform: nil)

        let inset = lineWidth + 8
        let ring = b.insetBy(dx: inset, dy: inset)
        let radius = min(ring.width, ring.height) / 2
        let center = CGPoint(x: b.midX, y: b.midY)
        let circle = CGMutablePath()
        circle.addArc(center: center, radius: radius,
                      startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)

        for shape in [track, fill, spinner] {
            shape.frame = b
            shape.path = circle
            // Rotate around the view center.
            shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            shape.position = center
            shape.bounds = b
        }
    }

    func setIndeterminate(_ value: Bool) {
        indeterminate = value
        fill.isHidden = value
        percentLabel.isHidden = value
    }

    func startSpinning() {
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi   // clockwise on screen
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        spinner.add(rotation, forKey: "spin")
    }

    func stopSpinning() {
        spinner.removeAnimation(forKey: "spin")
    }
}
