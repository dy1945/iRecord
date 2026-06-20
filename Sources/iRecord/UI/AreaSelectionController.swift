import AppKit
import CoreGraphics

/// Presents a dimmed, full-screen overlay on every display with a Kap-style
/// floating capture toolbar (crop · window · ● record · fullscreen · ⋯).
///
/// The user drags a rectangle (or uses the fullscreen button), then presses the
/// red record button. Reports the chosen region in **global Cocoa coordinates**
/// (bottom-left origin) plus the display it belongs to.
@MainActor
final class AreaSelectionController {
    static let shared = AreaSelectionController()

    private var windows: [NSWindow] = []
    private var onConfirm: ((CGRect, CGDirectDisplayID) -> Void)?
    private var onCancel: (() -> Void)?
    private var onWindowMode: (() -> Void)?

    func begin(onConfirm: @escaping (CGRect, CGDirectDisplayID) -> Void,
               onCancel: @escaping () -> Void,
               onWindowMode: @escaping () -> Void) {
        dismiss()
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onWindowMode = onWindowMode

        let mouse = NSEvent.mouseLocation
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main

        for screen in NSScreen.screens {
            let isPrimary = (screen == primaryScreen)
            let window = SelectionWindow(screen: screen, isPrimary: isPrimary)
            window.selectionDelegate = self
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    fileprivate func confirm(globalRect: CGRect) {
        guard globalRect.width >= 8, globalRect.height >= 8 else { return }
        let displayID = ScreenInfo.displayID(containing: CGPoint(x: globalRect.midX, y: globalRect.midY))
        let cb = onConfirm
        dismiss()
        cb?(globalRect, displayID)
    }

    fileprivate func cancel() {
        let cb = onCancel
        dismiss()
        cb?()
    }

    fileprivate func switchToWindowMode() {
        let cb = onWindowMode
        dismiss()
        cb?()
    }
}

// MARK: - Window

private final class SelectionWindow: NSWindow {
    weak var selectionDelegate: AreaSelectionController?
    private let selectionView: SelectionView

    init(screen: NSScreen, isPrimary: Bool) {
        selectionView = SelectionView(isPrimary: isPrimary)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.setFrame(screen.frame, display: true)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.acceptsMouseMovedEvents = true
        selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
        selectionView.window_screenFrame = screen.frame
        selectionView.onConfirmLocalRect = { [weak self] localRect in
            let global = CGRect(x: screen.frame.origin.x + localRect.origin.x,
                                y: screen.frame.origin.y + localRect.origin.y,
                                width: localRect.width, height: localRect.height)
            self?.selectionDelegate?.confirm(globalRect: global)
        }
        selectionView.onCancel = { [weak self] in self?.selectionDelegate?.cancel() }
        selectionView.onWindowMode = { [weak self] in self?.selectionDelegate?.switchToWindowMode() }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private final class SelectionView: NSView {
    var window_screenFrame: CGRect = .zero
    var onConfirmLocalRect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowMode: (() -> Void)?

    private let isPrimary: Bool
    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero
    private var hasSelection = false

    private var toolbar: CaptureToolbarView!

    init(isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()

        if toolbar == nil {
            toolbar = CaptureToolbarView(
                onCrop: { [weak self] in self?.window?.makeFirstResponder(self) },
                onWindow: { [weak self] in self?.onWindowMode?() },
                onRecord: { [weak self] in self?.confirm() },
                onFullscreen: { [weak self] in self?.selectFullScreen() },
                onMore: { [weak self] sender in self?.showMoreMenu(sender) })
            addSubview(toolbar)
        }

        // The primary screen starts with a default centred selection so the
        // toolbar is visible immediately (matching Kap).
        if isPrimary {
            let w = bounds.width * 0.6
            let h = bounds.height * 0.5
            currentRect = CGRect(x: bounds.midX - w/2, y: bounds.midY - h/2, width: w, height: h).integral
            hasSelection = true
            layoutToolbar()
        } else {
            toolbar.isHidden = true
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Clicks on the toolbar are handled by its buttons.
        if let tb = toolbar, !tb.isHidden, tb.frame.contains(p) { return }
        startPoint = p
        currentRect = CGRect(origin: p, size: .zero)
        hasSelection = true
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 { confirm(); return }
        layoutToolbar()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()              // Escape
        case 36, 76: confirm()            // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: Actions

    private func selectFullScreen() {
        currentRect = bounds
        hasSelection = true
        layoutToolbar()
        needsDisplay = true
    }

    private func confirm() {
        let rect = hasSelection ? currentRect : bounds
        guard rect.width >= 8, rect.height >= 8 else { return }
        onConfirmLocalRect?(rect.integral)
    }

    private func showMoreMenu(_ sender: NSView) {
        let menu = NSMenu()
        let c = RecordingController.shared

        func toggle(_ title: String, _ on: Bool, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        toggle("Show Cursor", c.showsCursor, #selector(toggleCursor))
        toggle("Highlight Clicks", c.highlightClicks, #selector(toggleClicks))
        toggle("System Audio", c.captureSystemAudio, #selector(toggleSystemAudio))
        toggle("Microphone", c.captureMicrophone, #selector(toggleMic))
        menu.addItem(.separator())
        let fps30 = NSMenuItem(title: "Capture 30 FPS", action: #selector(setFPS30), keyEquivalent: "")
        fps30.target = self; fps30.state = c.captureFPS == 30 ? .on : .off
        let fps60 = NSMenuItem(title: "Capture 60 FPS", action: #selector(setFPS60), keyEquivalent: "")
        fps60.target = self; fps60.state = c.captureFPS == 60 ? .on : .off
        menu.addItem(fps30); menu.addItem(fps60)
        menu.addItem(.separator())
        let cancelItem = NSMenuItem(title: "Cancel", action: #selector(cancelFromMenu), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)

        let p = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: p, in: sender)
    }

    @objc private func toggleCursor() { RecordingController.shared.showsCursor.toggle() }
    @objc private func toggleClicks() { RecordingController.shared.highlightClicks.toggle() }
    @objc private func toggleSystemAudio() { RecordingController.shared.captureSystemAudio.toggle() }
    @objc private func toggleMic() {
        let c = RecordingController.shared
        c.captureMicrophone.toggle()
        if c.captureMicrophone { Task { _ = await PermissionsManager.requestMicrophonePermission() } }
    }
    @objc private func setFPS30() { RecordingController.shared.captureFPS = 30 }
    @objc private func setFPS60() { RecordingController.shared.captureFPS = 60 }
    @objc private func cancelFromMenu() { onCancel?() }

    // MARK: Layout

    private func layoutToolbar() {
        guard hasSelection, currentRect.width >= 8, currentRect.height >= 8 else {
            toolbar.isHidden = true
            return
        }
        let size = toolbar.fittingSize
        var y = currentRect.minY - size.height - 14
        if y < 12 { y = currentRect.minY + 14 }                       // inside if no room below
        if y + size.height > bounds.height - 12 { y = currentRect.midY - size.height/2 }
        var x = currentRect.midX - size.width/2
        x = max(12, min(x, bounds.width - size.width - 12))
        toolbar.setFrameOrigin(NSPoint(x: x, y: y))
        toolbar.isHidden = false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard hasSelection, currentRect.width > 0, currentRect.height > 0 else {
            if isPrimary { drawHint() }
            return
        }

        // Punch out the selection.
        NSGraphicsContext.current?.cgContext.setBlendMode(.copy)
        NSColor.clear.setFill()
        currentRect.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

        // Border + handles.
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        NSColor.white.setStroke()
        path.stroke()
        drawHandles(for: currentRect)
        drawDimensions(for: currentRect)
    }

    private func drawHandles(for r: CGRect) {
        let pts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)
        ]
        NSColor.white.setFill()
        for p in pts {
            let d: CGFloat = 6
            NSBezierPath(ovalIn: CGRect(x: p.x - d/2, y: p.y - d/2, width: d, height: d)).fill()
        }
    }

    private func drawDimensions(for r: CGRect) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let text = "\(Int(r.width * scale)) × \(Int(r.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        let box = NSRect(x: r.midX - size.width/2 - pad, y: r.maxY + 6,
                         width: size.width + pad*2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad/2), withAttributes: attrs)
    }

    private func drawHint() {
        let text = "Drag to select an area, or use the toolbar  ·  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: bounds.midX - size.width/2, y: bounds.midY)
        let box = NSRect(x: p.x - 14, y: p.y - 10, width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: p, withAttributes: attrs)
    }
}

// MARK: - Floating toolbar

private final class CaptureToolbarView: NSView {
    private let onMore: (NSView) -> Void
    private let moreButton: NSButton

    init(onCrop: @escaping () -> Void,
         onWindow: @escaping () -> Void,
         onRecord: @escaping () -> Void,
         onFullscreen: @escaping () -> Void,
         onMore: @escaping (NSView) -> Void) {
        self.onMore = onMore

        func iconButton(_ symbol: String, _ handler: @escaping () -> Void) -> NSButton {
            let b = HandlerButton(handler: handler)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            b.imageScaling = .scaleProportionallyUpOrDown
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .white
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return b
        }

        let cropButton = iconButton("crop", onCrop)
        let windowButton = iconButton("macwindow", onWindow)
        let fullscreenButton = iconButton("viewfinder", onFullscreen)
        moreButton = iconButton("ellipsis", { })

        // Big red record button.
        let recordButton = HandlerButton(handler: onRecord)
        recordButton.isBordered = false
        recordButton.bezelStyle = .regularSquare
        recordButton.image = Self.recordImage()
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        recordButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        moreButton.target = nil
        (moreButton as? HandlerButton)?.handlerOverride = { [weak self] in
            guard let self else { return }
            self.onMore(self.moreButton)
        }

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.cornerRadius = 14

        let stack = NSStackView(views: [cropButton, windowButton, recordButton, fullscreenButton, moreButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 280, height: 56) }

    private static func recordImage() -> NSImage {
        let size = NSSize(width: 30, height: 30)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 26, height: 26)).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 28, height: 28))
        ring.lineWidth = 2
        ring.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

/// Simple block-based NSButton.
private final class HandlerButton: NSButton {
    private let handler: () -> Void
    var handlerOverride: (() -> Void)?

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { (handlerOverride ?? handler)() }
}
