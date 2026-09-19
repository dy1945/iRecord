import AppKit
import CoreGraphics

/// iShot-style scrolling screenshot (长截图): after the user picks a region,
/// captures it ~6×/s while they scroll (wheel / trackpad / auto-scroll button),
/// stitches frames vertically, and shows a live preview beside the region.
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

    private let maxStitchedPixels = 32_000

    func start(globalRect: CGRect) {
        stopTeardown()
        self.globalRect = globalRect
        stillCount = 0
        didScroll = false
        autoScroll = false

        guard let first = ScreenshotCapture.capture(globalRect: globalRect),
              let stitcher = ImageStitcher(firstFrame: first) else {
            NSSound.beep()
            return
        }
        self.stitcher = stitcher
        self.lastFrame = first

        showHUD()
        showPreview()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Capture loop

    private func tick() {
        guard let frame = ScreenshotCapture.capture(globalRect: globalRect) else { return }
        guard let stitcher else { return }

        guard let match = stitcher.append(frame) else {
            status("Couldn't match — scroll more slowly", warn: true)
            return
        }
        lastFrame = frame

        if match.dx != 0 {
            abort("Horizontal scrolling detected — capture aborted.")
            return
        }

        if match.dy == 0 {
            stillCount += 1
            if autoScroll, stillCount > 6 {
                // Auto-scroll hit the bottom of the content.
                finish()
                return
            }
            if didScroll, stillCount > 15 {   // ~2.5 s without movement
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

        status(didScroll
               ? "Stitching… \(stitcher.stitchedHeight) px — Enter to finish"
               : "Scroll the content (wheel / trackpad)…")
        if autoScroll { postScrollEvent() }
    }

    // MARK: - Finish / cancel

    private func finish() {
        guard let image = stitcher?.currentImage else { teardown(); return }
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
                status("Grant Accessibility permission, then try Auto again", warn: true)
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

        let label = NSTextField(labelWithString: L10n.tr("Scroll the content (wheel / trackpad)…",
                                                         "滚动内容（滚轮 / 触控板）…"))
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

    private func updatePreview() {
        guard let img = stitcher?.currentImage else { return }
        previewView?.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    @objc private func autoTapped(_ sender: NSButton) { toggleAutoScroll(sender) }
    @objc private func doneTapped() { finish() }
    @objc private func cancelTapped() { cancel() }
}
