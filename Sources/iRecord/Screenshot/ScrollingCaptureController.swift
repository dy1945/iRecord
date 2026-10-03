import AppKit
import CoreGraphics

/// iShot-style scrolling screenshot (长截图): after the user picks a region,
/// captures it ~8×/s while they scroll (wheel / trackpad / auto-scroll button),
/// stitches frames vertically, and shows a live preview beside the region.
/// The first movement decides the direction: scrolling down extends the image
/// downwards, scrolling up extends it upwards.
///
/// Stop conditions: Enter / ■ button / Esc (cancel) / no movement for 2.5 s
/// after scrolling started / max length reached. The finished long image opens
/// in the annotation editor (save / copy / pin), matching iShot's flow.
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private var globalRect: CGRect = .zero
    private var timer: Timer?
    private var stitcher: ImageStitcher?
    /// Upward candidate, kept only until the first movement picks a direction.
    private var upStitcher: ImageStitcher?
    private var lastFrame: CGImage?
    private var stillCount = 0
    private var didScroll = false
    private var hud: NSPanel?
    private var preview: NSPanel?
    private var previewView: NSImageView?
    private var statusField: NSTextField?
    private var keyMonitor: Any?
    private var keyMonitorLocal: Any?
    private var autoScroll = false
    private var session: UUID?
    private var lastPreviewUpdate = Date.distantPast

    private let maxStitchedPixels = 32_000

    func start(globalRect: CGRect) {
        stopTeardown()
        self.globalRect = globalRect
        stillCount = 0
        didScroll = false
        autoScroll = false
        lastPreviewUpdate = .distantPast
        let session = UUID()
        self.session = session

        // The selection overlay was just ordered out; give the WindowServer a
        // moment so the target app repaints (hover/focus states) before the
        // first frame — otherwise it can differ from the next one and the top
        // of the long image starts with a stale frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.session == session else { return }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard let first = grab() else {
            NSSound.beep()
            return
        }
        // Overlay scrollers are ~16 pt wide at the right edge.
        let band = Int((16 * CGFloat(first.height) / max(1, globalRect.height)).rounded())
        guard let stitcher = ImageStitcher(firstFrame: first, scrollbarBand: band) else {
            NSSound.beep()
            return
        }
        self.stitcher = stitcher
        self.upStitcher = ImageStitcher(firstFrame: first, reversed: true, scrollbarBand: band)
        self.lastFrame = first

        showHUD()
        showPreview()
        updatePreview(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Our HUD and preview float above the page (and may overlap the region
    /// when there's no room beside it), so they must never end up in a frame.
    private func grab() -> CGImage? {
        ScreenshotCapture.captureExcludingOwnWindows(globalRect: globalRect)
            ?? ScreenshotCapture.capture(globalRect: globalRect)
    }

    // MARK: - Capture loop

    private func tick() {
        guard let frame = grab() else { return }
        guard var stitcher else { return }

        var result = stitcher.append(frame)
        if let up = upStitcher {
            if let r = result, r.dy > 0 {
                upStitcher = nil                      // scrolling down
            } else if let r = up.append(frame), r.dy > 0 {
                stitcher = up                         // scrolling up
                self.stitcher = up
                upStitcher = nil
                result = r
            }
        }
        guard let match = result else {
            status(L10n.tr("Couldn't match — scroll more slowly, or back to where you were",
                           "无法衔接 — 请滚慢一点，或滚回上次的位置"), warn: true)
            return
        }
        lastFrame = frame

        if match.dx != 0 {
            abort(L10n.tr("Horizontal scrolling detected — capture aborted.",
                          "检测到横向滚动，已停止长截图。"))
            return
        }

        if match.dy == 0 {
            stillCount += 1
            if autoScroll, stillCount > 8 {
                // Auto-scroll hit the bottom of the content.
                finish()
                return
            }
            if didScroll, stillCount > 20 {   // ~2.5 s without movement
                finish()
                return
            }
        } else {
            if match.dy > 0 { didScroll = true }
            stillCount = 0
            updatePreview()
            if stitcher.stitchedHeight >= maxStitchedPixels {
                finish()
                return
            }
        }

        let arrow = stitcher.reversed ? "↑" : "↓"
        status(didScroll
               ? L10n.tr("\(arrow) Stitching… \(stitcher.stitchedHeight) px — Enter to finish",
                         "\(arrow) 拼接中… \(stitcher.stitchedHeight) px — 回车完成")
               : L10n.tr("Scroll the content up or down (wheel / trackpad)…",
                         "向上或向下滚动内容（滚轮 / 触控板）…"))
        if autoScroll { postScrollEvent() }
    }

    // MARK: - Finish / cancel

    private func finish() {
        guard timer != nil, let image = stitcher?.finalImage else { teardown(); return }
        let scale = CGFloat(lastFrame?.height ?? Int(globalRect.height)) / globalRect.height
        let nsImage = NSImage(cgImage: image, size: NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale))
        teardown()
        ScreenshotEditorController.shared.present(image: nsImage)
    }

    private func abort(_ message: String) {
        teardown()
        let alert = NSAlert()
        alert.messageText = L10n.tr("Scrolling Screenshot Failed", "滚动截图失败")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("OK", "好"))
        alert.runModal()
    }

    private func cancel() { teardown() }

    private func stopTeardown() { teardown() }

    private func teardown() {
        session = nil
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let keyMonitorLocal { NSEvent.removeMonitor(keyMonitorLocal) }
        keyMonitorLocal = nil
        hud?.close(); hud = nil
        preview?.close(); preview = nil
        previewView = nil
        statusField = nil
        stitcher = nil
        upStitcher = nil
        lastFrame = nil
        autoScroll = false
    }

    // MARK: - Auto scroll

    /// Posts a wheel event at the region centre. Requires Accessibility
    /// permission; prompt once when the user enables auto-scroll.
    private func postScrollEvent() {
        let q = ScreenshotCapture.quartzRect(from: globalRect)
        let point = CGPoint(x: q.midX, y: q.midY)
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: -48, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.post(tap: .cghidEventTap)
    }

    private func toggleAutoScroll(_ button: NSButton) {
        if !autoScroll {
            let trusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            if !trusted {
                status(L10n.tr("Grant Accessibility permission, then try Auto again",
                              "请先授予辅助功能权限，再开启自动滚动"), warn: true)
                return
            }
            autoScroll = true
            button.contentTintColor = .systemGreen
            button.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause auto-scroll")
        } else {
            autoScroll = false
            button.contentTintColor = .white
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Auto-scroll")
        }
    }

    // MARK: - HUD & preview

    private func status(_ text: String, warn: Bool = false) {
        statusField?.stringValue = text
        statusField?.textColor = warn ? .systemOrange : .white
    }

    private func showHUD() {
        let rect = globalRect
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 40))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        bar.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: L10n.tr("Scroll the content up or down (wheel / trackpad)…",
                                                         "向上或向下滚动内容（滚轮 / 触控板）…"))
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 10, width: 236, height: 20)
        statusField = label
        bar.addSubview(label)

        func hudButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(frame: .zero)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .white
            b.target = self
            b.action = action
            return b
        }
        let auto = hudButton("play.fill", L10n.tr("Auto-scroll", "自动滚动"), #selector(autoTapped(_:)))
        auto.frame = NSRect(x: 256, y: 6, width: 28, height: 28)
        let done = hudButton("checkmark", L10n.tr("Finish (Enter)", "完成 (Enter)"), #selector(doneTapped))
        done.frame = NSRect(x: 296, y: 6, width: 28, height: 28)
        let cancel = hudButton("xmark", L10n.tr("Cancel (Esc)", "取消 (Esc)"), #selector(cancelTapped))
        cancel.frame = NSRect(x: 336, y: 6, width: 28, height: 28)
        bar.addSubview(auto); bar.addSubview(done); bar.addSubview(cancel)

        panel.contentView = bar
        // Dock the HUD just below the region (inside it if no room).
        var y = rect.minY - 52
        if y < (NSScreen.screens.first?.visibleFrame.minY ?? 0) + 8 { y = rect.minY + 12 }
        panel.setFrameOrigin(NSPoint(x: rect.midX - 190, y: y))
        panel.orderFront(nil)
        hud = panel

        // Two monitors: the global one sees keys while another app is focused
        // (the normal case while scrolling — needs Accessibility permission);
        // the local one covers the no-permission case when iRecord is active.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            switch event.keyCode {
            case 53: self.cancel()          // Esc
            case 36, 76: self.finish()      // Enter
            default: break
            }
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil
            case 36, 76: self.finish(); return nil
            default: return event
            }
        }
    }

    private func showPreview() {
        let rect = globalRect
        let h = min(rect.height, 620)
        let w: CGFloat = 180
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .black.withAlphaComponent(0.8)
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignTop
        panel.contentView = iv
        previewView = iv

        // Place to the right of the region; fall back to the left.
        var x = rect.maxX + 12
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }),
           x + w > screen.visibleFrame.maxX {
            x = rect.minX - w - 12
        }
        panel.setFrameOrigin(NSPoint(x: x, y: rect.maxY - h))
        panel.orderFront(nil)
        preview = panel
    }

    /// Rebuilding the full long image is not free, so the live preview is
    /// refreshed at most ~3×/s.
    private func updatePreview(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPreviewUpdate) > 0.3,
              let img = stitcher?.currentImage else { return }
        lastPreviewUpdate = Date()
        previewView?.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    @objc private func autoTapped(_ sender: NSButton) { toggleAutoScroll(sender) }
    @objc private func doneTapped() { finish() }
    @objc private func cancelTapped() { cancel() }
}
