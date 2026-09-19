import AppKit
import ImageIO

/// iShot-style "贴图": pins an image as an always-on-top floating window.
///
/// The window is a normal on-screen window, so it appears inside later
/// screenshots — which is exactly iShot's "二次截屏" (pin a reference shot,
/// then screenshot again with it visible).
///
/// Interactions: drag to move · scroll to zoom · right-click menu
/// (Copy / Save / Close) · double-click or ⌘W to close.
@MainActor
final class PinWindowController {
    static let shared = PinWindowController()
    private(set) var pins: [PinWindow] = []

    /// Pins an image near the top-right of the main screen (iShot behaviour),
    /// cascading when several pins exist.
    func pin(image: NSImage) {
        let win = PinWindow(image: image)
        win.onClose = { [weak self, weak win] in
            guard let win else { return }
            self?.pins.removeAll { $0 === win }
        }
        if let screen = NSScreen.main {
            let cascade = CGFloat(pins.count % 6) * 24
            let size = win.frame.size
            let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 40 - cascade,
                                 y: screen.visibleFrame.maxY - size.height - 40 - cascade)
            win.setFrameOrigin(origin)
        }
        win.makeKeyAndOrderFront(nil)
        pins.append(win)
    }

    /// Pins whatever image is currently on the clipboard, if any.
    @discardableResult
    func pinFromClipboard() -> Bool {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self],
                                                         options: nil)?.first as? NSImage,
              img.size.width > 0 else { return false }
        pin(image: img)
        return true
    }

    /// iShot's ⌥H: temporarily hide / restore all pinned images.
    func togglePinsHidden() {
        let anyVisible = pins.contains { $0.isVisible }
        for pin in pins {
            if anyVisible { pin.orderOut(nil) } else { pin.makeKeyAndOrderFront(nil) }
        }
    }
}

// MARK: - Window

final class PinWindow: NSWindow {
    var onClose: (() -> Void)?

    private let pinImage: NSImage
    private let imageView: PinImageView
    private var zoom: CGFloat = 1

    init(image: NSImage) {
        self.pinImage = image
        imageView = PinImageView(image: image)
        // Open at a sensible size: point size of the image, capped to ~60% of
        // the screen so a full-screen pin doesn't bury the desktop.
        var size = image.size
        if let screen = NSScreen.main {
            let cap = NSSize(width: screen.visibleFrame.width * 0.6,
                             height: screen.visibleFrame.height * 0.6)
            let factor = min(1, cap.width / size.width, cap.height / size.height)
            size = NSSize(width: (size.width * factor).rounded(),
                          height: (size.height * factor).rounded())
        }
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView
        imageView.onCloseRequest = { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 二次标注: replace the pinned image after re-annotation.
    func updateImage(_ image: NSImage) {
        imageView.image = image
        let ratio = image.size.height / max(1, image.size.width)
        var frame = frame
        frame.size.height = frame.width * ratio
        setFrame(frame, display: true)
        imageView.needsDisplay = true
    }

    override func close() {
        onClose?()
        super.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
        } else if event.keyCode == 53 {          // Esc
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return }
        zoom = max(0.1, min(5, zoom * (delta > 0 ? 1.08 : 1 / 1.08)))
        let base = pinImage.size
        let newSize = NSSize(width: (base.width * zoom).rounded(),
                             height: (base.height * zoom).rounded())
        var frame = frame
        // Zoom around the window centre.
        frame.origin.x += (frame.width - newSize.width) / 2
        frame.origin.y += (frame.height - newSize.height) / 2
        frame.size = newSize
        setFrame(frame, display: true, animate: false)
    }
}

// MARK: - View

private final class PinImageView: NSView {
    var onCloseRequest: (() -> Void)?
    var image: NSImage { didSet { needsDisplay = true } }
    private var hovering = false
    private var opacitySlider: NSSlider?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        // Thin border so a white screenshot doesn't vanish into the desktop.
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        if hovering {
            // iShot-style close badge, top-left.
            let d: CGFloat = 18
            let badge = NSRect(x: bounds.minX + 6, y: bounds.maxY - 6 - d, width: d, height: d)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let cross = NSBezierPath()
            let inset: CGFloat = 5
            cross.move(to: NSPoint(x: badge.minX + inset, y: badge.minY + inset))
            cross.line(to: NSPoint(x: badge.maxX - inset, y: badge.maxY - inset))
            cross.move(to: NSPoint(x: badge.maxX - inset, y: badge.minY + inset))
            cross.line(to: NSPoint(x: badge.minX + inset, y: badge.maxY - inset))
            cross.lineWidth = 1.8
            cross.stroke()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        showOpacitySlider(true)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        showOpacitySlider(false)
        needsDisplay = true
    }

    /// iShot shows an opacity slider at the top centre of a hovered pin.
    private func showOpacitySlider(_ show: Bool) {
        if show {
            guard opacitySlider == nil, bounds.width > 120 else { return }
            let s = NSSlider(value: Double(window?.alphaValue ?? 1), minValue: 0.2, maxValue: 1,
                             target: self, action: #selector(opacityChanged(_:)))
            s.controlSize = .small
            s.frame = NSRect(x: bounds.midX - 50, y: bounds.maxY - 16, width: 100, height: 14)
            s.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
            addSubview(s)
            opacitySlider = s
        } else {
            opacitySlider?.removeFromSuperview()
            opacitySlider = nil
        }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        window?.alphaValue = CGFloat(sender.doubleValue)
    }

    override func mouseDown(with event: NSEvent) {
        if hovering {
            let p = convert(event.locationInWindow, from: nil)
            let badge = NSRect(x: bounds.minX + 6, y: bounds.maxY - 6 - 18, width: 18, height: 18)
            if badge.contains(p) { onCloseRequest?(); return }
        }
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 { onCloseRequest?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let annotate = NSMenuItem(title: L10n.tr("Annotate…", "标注…"), action: #selector(annotate), keyEquivalent: "")
        annotate.target = self
        let copy = NSMenuItem(title: L10n.tr("Copy Image", "复制图片"), action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        let save = NSMenuItem(title: L10n.tr("Save Image…", "保存图片…"), action: #selector(saveImage), keyEquivalent: "")
        save.target = self
        let close = NSMenuItem(title: L10n.tr("Close", "关闭"), action: #selector(closeItem), keyEquivalent: "")
        close.target = self
        menu.items = [annotate, copy, save, .separator(), close]
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// 二次标注: annotate the pinned image and bake the result back into the pin.
    @objc private func annotate() {
        guard let win = window as? PinWindow else { return }
        ScreenshotEditorController.shared.present(image: image) { newImage in
            win.updateImage(newImage)
        }
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func saveImage() {
        ScreenshotFileIO.save(image: image, suggestedName: ScreenshotFileIO.defaultName(prefix: "Pinned"))
    }

    @objc private func closeItem() { onCloseRequest?() }
}

/// Shared file helpers
@MainActor
enum ScreenshotFileIO {
    static func defaultName(prefix: String = "Screenshot") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: Date()))"
    }

    /// Presents a save panel and writes the image as PNG.
    static func save(image: NSImage, suggestedName: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        panel.directoryURL = RecordingController.shared.effectiveScreenshotDirectory
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    static func copyToClipboard(image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Screenshot output entry point: copies to the clipboard and/or writes the
    /// image to the effective screenshot directory, per the user's save settings.
    static func handleScreenshotCopy(image: NSImage) {
        let controller = RecordingController.shared
        if controller.shotCopyToClipboard {
            copyToClipboard(image: image)
        }
        if controller.screenshotAlsoSaves {
            saveQuietly(image: image)
        }
    }

    /// `iRecord_screeenshots_<yyyyMMdd_HHmmss>_<random hex>` (prefix per spec).
    nonisolated static func autoSaveName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let rand = String(format: "%04x", Int.random(in: 0...0xFFFF))
        return "iRecord_screeenshots_\(f.string(from: Date()))_\(rand)"
    }

    /// Encodes the image in the given format (JPEG at quality 0.9).
    static func encode(image: NSImage, format: ScreenshotFormat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.destinationUTI as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if format == .jpg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Writes the image in the configured format into the effective screenshot
    /// directory, no save panel. The directory is created if missing.
    @discardableResult
    static func saveQuietly(image: NSImage) -> URL? {
        let format = RecordingController.shared.screenshotImageFormat
        guard let data = encode(image: image, format: format) else { return nil }
        let dir = RecordingController.shared.effectiveScreenshotDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent(autoSaveName() + "." + format.fileExtension)
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("[shot] auto-save failed: %@", error.localizedDescription)
            return nil
        }
    }
}
