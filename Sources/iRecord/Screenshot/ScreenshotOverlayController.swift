import AppKit

/// The entry-point flows for still screenshots.
@MainActor
final class ScreenshotController {
    static let shared = ScreenshotController()

    private(set) var frozen: [ScreenshotCapture.FrozenDisplay] = []

    /// Region screenshot (iShot ⇧A equivalent): freeze screen → select → toolbar.
    func startRegionCapture() {
        AppDelegate.shared?.closePopover()
        AppCoordinator.shared.ensureScreenPermission { [weak self] granted in
            guard granted else { return }
            Task { await self?.beginOverlay(scrolling: false) }
        }
    }

    /// Scrolling screenshot: same selection UI, but the toolbar's primary
    /// action starts the scrolling capture engine.
    func startScrollingCapture() {
        AppDelegate.shared?.closePopover()
        AppCoordinator.shared.ensureScreenPermission { [weak self] granted in
            guard granted else { return }
            Task { await self?.beginOverlay(scrolling: true) }
        }
    }

    /// Instant full-screen capture of every display (composited), straight to
    /// the clipboard, mirroring iShot's full-screen hotkey.
    func captureFullScreen() {
        AppDelegate.shared?.closePopover()
        AppCoordinator.shared.ensureScreenPermission { granted in
            guard granted else { return }
            Task {
                do {
                    let frozen = try await ScreenshotCapture.freezeDisplays()
                    let union = frozen.reduce(CGRect.null) { $0.union($1.frame) }
                    guard let img = ScreenshotCapture.crop(globalRect: union, from: frozen) else { return }
                    ScreenshotFileIO.handleScreenshotCopy(image: NSImage(cgImage: img, size: union.size))
                    NSSound(named: "Tink")?.play()
                } catch { /* permission revoked etc. */ }
            }
        }
    }

    private func beginOverlay(scrolling: Bool) async {
        do {
            frozen = try await ScreenshotCapture.freezeDisplays()
        } catch {
            NSLog("[shot] freezeDisplays failed: %@", error.localizedDescription)
            presentCaptureError(error)
            return
        }
        NSLog("[shot] overlay begin (scrolling=%d), frozen=%d", scrolling, frozen.count)
        ScreenshotOverlayController.shared.begin(frozen: frozen, scrolling: scrolling)
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Screenshot Failed", "截图失败")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.tr("OK", "好"))
        alert.runModal()
    }
}

// MARK: - Overlay controller

/// Shows the frozen-screen selection overlay used by both region and scrolling
/// screenshots. The frontmost on-screen window is pre-selected (iShot-style);
/// hovering highlights the window under the cursor, a click locks it, and a
/// drag always starts a manual region. Crosshair + magnifier while hovering;
/// once a selection is locked a floating toolbar offers the iShot action set.
@MainActor
final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    private var windows: [NSWindow] = []
    private var frozen: [ScreenshotCapture.FrozenDisplay] = []
    private var candidateWindows: [CGRect] = []

    func begin(frozen: [ScreenshotCapture.FrozenDisplay], scrolling: Bool) {
        dismiss()
        self.frozen = frozen
        candidateWindows = Self.frontToBackWindowFrames()
        for d in frozen {
            guard let screen = ScreenInfo.nsScreen(for: d.displayID) else { continue }
            let win = ShotOverlayWindow(screen: screen, frozen: d, scrolling: scrolling)
            win.overlayDelegate = self
            win.shotView.setCandidateWindows(candidateWindows)
            win.shotView.onClaimAutoSelection = { [weak self] view in
                self?.clearAutoSelections(except: view)
            }
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }
        // Pre-select the frontmost window on whichever display contains it.
        for case let win as ShotOverlayWindow in windows { win.shotView.offerFrontmostWindow() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func clearAutoSelections(except view: NSView) {
        for case let win as ShotOverlayWindow in windows where win.shotView !== view {
            win.shotView.clearAutoSelection()
        }
    }

    /// On-screen windows (front-to-back), converted to global Cocoa coordinates
    /// and excluding our own overlays and tiny utility panels. Includes normal
    /// windows (layer 0), floating panels (layer 3) and open dropdown menus
    /// (pop-up-menu level, 101) so a menu can be hover-framed like any window.
    static func frontToBackWindowFrames() -> [CGRect] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var frames: [CGRect] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 || layer == 3 || layer == 101,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let quartz = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  quartz.width >= 80, quartz.height >= 80 else { continue }
            frames.append(ScreenshotCapture.cocoaRect(from: quartz))
        }
        return frames
    }

    fileprivate func finish(globalRect: CGRect, action: ShotAction) {
        dismiss()
        guard let cg = ScreenshotCapture.crop(globalRect: globalRect, from: frozen) else { return }
        let size = NSSize(width: globalRect.width, height: globalRect.height)
        let image = NSImage(cgImage: cg, size: size)
        switch action {
        case .copy:
            ScreenshotFileIO.handleScreenshotCopy(image: image)
        case .save:
            ScreenshotFileIO.save(image: image, suggestedName: ScreenshotFileIO.defaultName())
        case .pin:
            PinWindowController.shared.pin(image: image)
        case .edit:
            ScreenshotEditorController.shared.present(image: image)
        case .scrolling:
            ScrollingCaptureController.shared.start(globalRect: globalRect)
        case .cancel:
            break
        }
    }

    fileprivate func finishEdited(image: NSImage, action: ShotAction) {
        dismiss()
        switch action {
        case .copy:
            ScreenshotFileIO.handleScreenshotCopy(image: image)
        case .save:
            ScreenshotFileIO.save(image: image, suggestedName: ScreenshotFileIO.defaultName())
        case .pin:
            PinWindowController.shared.pin(image: image)
        default:
            break
        }
    }

    fileprivate func cancel() { dismiss() }
}

enum ShotAction {
    case copy, save, edit, pin, scrolling, cancel
}

// MARK: - Window

private final class ShotOverlayWindow: NSWindow {
    weak var overlayDelegate: ScreenshotOverlayController?
    private(set) var shotView: ShotOverlayView!

    init(screen: NSScreen, frozen: ScreenshotCapture.FrozenDisplay, scrolling: Bool) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = ShotOverlayView(frozen: frozen, scrolling: scrolling)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.screenGlobalFrame = screen.frame
        view.onAction = { [weak self] rect, action in
            if action == .cancel { self?.overlayDelegate?.cancel() }
            else { self?.overlayDelegate?.finish(globalRect: rect, action: action) }
        }
        view.onEditedAction = { [weak self] image, action in
            self?.overlayDelegate?.finishEdited(image: image, action: action)
        }
        shotView = view
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private final class ShotOverlayView: NSView {
    var screenGlobalFrame: CGRect = .zero
    var onAction: ((CGRect, ShotAction) -> Void)?
    var onEditedAction: ((NSImage, ShotAction) -> Void)?
    var onClaimAutoSelection: ((ShotOverlayView) -> Void)?

    private let frozen: ScreenshotCapture.FrozenDisplay
    private let scrollingMode: Bool
    private var backgroundImage: NSImage?
    private var candidateFrames: [CGRect] = []

    private var startPoint: CGPoint?
    private var dragging = false
    private var currentRect: CGRect = .zero
    private var hasSelection = false
    /// While true the highlight follows the window under the cursor; a manual
    /// drag switches it off until the next bare click.
    private var hoverActive = true
    /// A locked selection shows the toolbar; a hover highlight does not.
    private var locked = false
    private var mouse: CGPoint = .zero
    private var toolbar: ShotToolbarView?
    /// In-place annotation (iShot 截屏编辑): the editor canvas covers the
    /// frozen screen and the toolbar swaps to the annotation strip.
    private var editMode = false
    private var editorView: AnnotationEditorView?
    private var editToolbar: EditToolbarView?

    init(frozen: ScreenshotCapture.FrozenDisplay, scrolling: Bool) {
        self.frozen = frozen
        self.scrollingMode = scrolling
        super.init(frame: .zero)
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Window auto-matching

    func setCandidateWindows(_ frames: [CGRect]) { candidateFrames = frames }

    /// Pre-selects the frontmost window when its centre lands on this display.
    /// Honours the "自动匹配最前窗口" setting.
    func offerFrontmostWindow() {
        guard RecordingController.shared.autoSelectFrontWindow else { return }
        guard let first = candidateFrames.first else { return }
        let local = CGPoint(x: first.midX - screenGlobalFrame.origin.x,
                            y: first.midY - screenGlobalFrame.origin.y)
        guard bounds.contains(local) else { return }
        adoptAutoSelection(globalRect: first, lock: true)
    }

    private func adoptAutoSelection(globalRect: CGRect, lock: Bool) {
        let local = globalRect
            .offsetBy(dx: -screenGlobalFrame.origin.x, dy: -screenGlobalFrame.origin.y)
            .intersection(bounds).integral
        guard local.width >= 8, local.height >= 8 else { return }
        guard local != currentRect || !hasSelection else { return }
        currentRect = local
        hasSelection = true
        locked = lock
        onClaimAutoSelection?(self)
        layoutToolbar()
        needsDisplay = true
    }

    /// Called on the *other* displays' views when this session's highlight
    /// moves here, so only one window highlight exists at a time.
    func clearAutoSelection() {
        guard hoverActive, hasSelection, startPoint == nil else { return }
        hasSelection = false
        locked = false
        currentRect = .zero
        toolbar?.isHidden = true
        needsDisplay = true
    }

    private func globalPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: screenGlobalFrame.origin.x + local.x,
                y: screenGlobalFrame.origin.y + local.y)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let tb = toolbar, !tb.isHidden, tb.frame.contains(p) { return }
        mouse = clampedToBounds(p)
        startPoint = p
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = clampedToBounds(convert(event.locationInWindow, from: nil))
        mouse = p
        if !dragging {
            guard abs(p.x - start.x) > 4 || abs(p.y - start.y) > 4 else { return }
            dragging = true
            hoverActive = false
            locked = false
            toolbar?.isHidden = true
        }
        hasSelection = true
        currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = clampedToBounds(convert(event.locationInWindow, from: nil))
        mouse = p
        let wasDragging = dragging
        startPoint = nil
        dragging = false
        if event.clickCount >= 2 {
            confirm(scrollingMode ? .scrolling : .copy)
            return
        }
        if !wasDragging {
            // Bare click: inside an existing selection keeps it (so a following
            // double-click copies it); otherwise lock the window under the
            // cursor (when hover-framing is on); empty space clears.
            hoverActive = true
            if hasSelection, currentRect.contains(p) {
                locked = true
            } else if RecordingController.shared.hoverFramesWindows,
                      let hit = candidateFrames.first(where: { $0.contains(globalPoint(p)) }) {
                adoptAutoSelection(globalRect: hit, lock: true)
            } else {
                hasSelection = false
                locked = false
                onClaimAutoSelection?(self)
            }
        } else {
            locked = hasSelection && currentRect.width >= 8 && currentRect.height >= 8
        }
        layoutToolbar()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = clampedToBounds(convert(event.locationInWindow, from: nil))
        // Hover window-framing can be turned off in Settings → 截图.
        if hoverActive, startPoint == nil, RecordingController.shared.hoverFramesWindows {
            let g = globalPoint(mouse)
            if let hit = candidateFrames.first(where: { $0.contains(g) }) {
                adoptAutoSelection(globalRect: hit, lock: false)
            } else if hasSelection {
                hasSelection = false
                locked = false
                toolbar?.isHidden = true
            }
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if editMode { exitEditMode() } else { onAction?(.zero, .cancel) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onAction?(.zero, .cancel)   // Esc
        case 36, 76: confirm(scrollingMode ? .scrolling : .copy)   // Enter
        case 49: confirm(.save)              // Space → save (iShot)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s" where !scrollingMode: confirm(.scrolling)   // S → 长截图
            case "t": confirm(.pin)                              // T → 贴图
            case "r": copyColorAtMouse(hex: false)               // R → copy RGB
            case "h": copyColorAtMouse(hex: true)                // H → copy HEX
            default: super.keyDown(with: event)
            }
        }
    }

    /// Samples the frozen pixel under the cursor and copies it to the clipboard.
    private func copyColorAtMouse(hex: Bool) {
        let scale = frozen.scale
        let px = Int((mouse.x * scale).rounded())
        let py = Int(((bounds.height - mouse.y) * scale).rounded())
        guard let data = frozen.image.dataProvider?.data,
              let base = CFDataGetBytePtr(data),
              px >= 0, px < frozen.image.width, py >= 0, py < frozen.image.height else { return }
        let off = py * frozen.image.bytesPerRow + px * 4
        let b = base[off], g = base[off + 1], r = base[off + 2]
        let str = hex ? String(format: "#%02X%02X%02X", r, g, b)
                      : String(format: "rgb(%d, %d, %d)", r, g, b)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        NSSound(named: "Tink")?.play()
    }

    private func clampedToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(bounds.width, p.x)), y: max(0, min(bounds.height, p.y)))
    }

    private func confirm(_ action: ShotAction) {
        let rect = (hasSelection && currentRect.width >= 8 && currentRect.height >= 8)
            ? currentRect.integral : bounds
        let global = CGRect(x: screenGlobalFrame.origin.x + rect.origin.x,
                            y: screenGlobalFrame.origin.y + rect.origin.y,
                            width: rect.width, height: rect.height)
        onAction?(global, action)
    }

    // MARK: Toolbar

    private func layoutToolbar() {
        guard locked, hasSelection, currentRect.width >= 8, currentRect.height >= 8 else {
            toolbar?.isHidden = true
            return
        }
        if toolbar == nil {
            let tb = ShotToolbarView(scrollingMode: scrollingMode) { [weak self] action in
                guard let self else { return }
                if action == .edit { self.enterEditMode() } else { self.confirm(action) }
            }
            addSubview(tb)
            toolbar = tb
        }
        let size = toolbar!.fittingSize
        var y = currentRect.minY - size.height - 12
        if y < 12 { y = currentRect.minY + 12 }
        var x = currentRect.maxX - size.width
        x = max(12, min(x, bounds.width - size.width - 12))
        toolbar!.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        toolbar!.isHidden = false
    }

    // MARK: In-place annotation (edit mode)

    private func enterEditMode() {
        guard !editMode, hasSelection, currentRect.width >= 8, currentRect.height >= 8 else { return }
        editMode = true

        let image = backgroundImage ?? NSImage(cgImage: frozen.image, size: bounds.size)
        let editor = AnnotationEditorView(image: image)
        editor.drawsBaseImage = false
        editor.frame = bounds
        // The editor view is flipped (top-left origin); convert the selection.
        editor.cropRect = CGRect(x: currentRect.minX, y: bounds.height - currentRect.maxY,
                                 width: currentRect.width, height: currentRect.height)
        editor.onFinished = { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                self.exitEditMode()
            case .copy(let img):
                self.onEditedAction?(img, .copy)
            case .save(let img):
                self.onEditedAction?(img, .save)
            case .pin(let img):
                self.onEditedAction?(img, .pin)
            }
        }
        if let toolbar {
            addSubview(editor, positioned: .below, relativeTo: toolbar)
        } else {
            addSubview(editor)
        }
        editorView = editor

        toolbar?.isHidden = true
        let strip = EditToolbarView(editor: editor)
        addSubview(strip)
        editToolbar = strip
        let size = strip.fittingSize
        var y = currentRect.minY - size.height - 12
        if y < 12 { y = currentRect.minY + 12 }
        var x = currentRect.maxX - size.width
        x = max(12, min(x, bounds.width - size.width - 12))
        strip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func exitEditMode() {
        guard editMode else { return }
        editMode = false
        editorView?.removeFromSuperview()
        editorView = nil
        editToolbar?.removeFromSuperview()
        editToolbar = nil
        window?.makeFirstResponder(self)
        layoutToolbar()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Frozen screen background.
        if backgroundImage == nil {
            backgroundImage = NSImage(cgImage: frozen.image, size: bounds.size)
        }
        backgroundImage?.draw(in: bounds)

        let dim = NSColor.black.withAlphaComponent(0.35)
        if hasSelection, currentRect.width > 0, currentRect.height > 0 {
            dim.setFill()
            bounds.fill()
            // Reveal the selection.
            NSGraphicsContext.current?.cgContext.setBlendMode(.copy)
            NSColor.clear.setFill()
            currentRect.fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: currentRect)
            border.lineWidth = 1.5
            border.stroke()
            drawDimensions(for: currentRect)
        } else {
            dim.setFill()
            bounds.fill()
            drawHint()
        }

        if !editMode, !hasSelection || startPoint == nil || (toolbar?.isHidden ?? true) {
            drawGuideLines(at: mouse)
            drawMagnifier(at: mouse)
        }
    }

    /// Full-screen crosshair guide lines through the cursor (iShot 辅助十字线).
    private func drawGuideLines(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: NSPoint(x: 0, y: p.y))
        path.line(to: NSPoint(x: bounds.width, y: p.y))
        path.move(to: NSPoint(x: p.x, y: 0))
        path.line(to: NSPoint(x: p.x, y: bounds.height))
        path.stroke()
    }

    private func drawDimensions(for r: CGRect) {
        let text = "\(Int(r.width * frozen.scale)) × \(Int(r.height * frozen.scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var y = r.maxY + 6
        if y + size.height + pad > bounds.height - 4 { y = r.maxY - size.height - pad - 6 }
        let box = NSRect(x: r.minX, y: y, width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    /// iShot-style magnifier: 15×15 source pixels around the cursor, zoomed,
    /// with the pixel colour in hex underneath.
    private func drawMagnifier(at p: CGPoint) {
        let scale = frozen.scale
        let srcRadius = 7                       // source pixels each side
        let cell: CGFloat = 10                  // zoomed cell size in points
        let grid = CGFloat(srcRadius * 2 + 1)
        let boxW = grid * cell
        let boxH = grid * cell + 26

        var x = p.x + 18
        var y = p.y + 18
        if x + boxW > bounds.width - 8 { x = p.x - boxW - 18 }
        if y + boxH > bounds.height - 8 { y = p.y - boxH - 18 }

        let px = Int((p.x * scale).rounded())
        let pyTopOrigin = Int(((bounds.height - p.y) * scale).rounded())   // image pixels, top-left origin

        let box = NSRect(x: x, y: y, width: boxW, height: boxH)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()

        var picked: (r: Int, g: Int, b: Int) = (0, 0, 0)
        if let data = frozen.image.dataProvider?.data,
           let base = CFDataGetBytePtr(data) {
            let bpl = frozen.image.bytesPerRow
            let imgW = frozen.image.width
            let imgH = frozen.image.height
            for gy in -srcRadius...srcRadius {
                for gx in -srcRadius...srcRadius {
                    let sx = px + gx
                    let sy = pyTopOrigin + gy
                    guard sx >= 0, sx < imgW, sy >= 0, sy < imgH else { continue }
                    let off = sy * bpl + sx * 4
                    let b = base[off], g = base[off + 1], r = base[off + 2]
                    if gx == 0 && gy == 0 { picked = (Int(r), Int(g), Int(b)) }
                    let cellRect = NSRect(x: x + CGFloat(gx + srcRadius) * cell,
                                          y: y + 26 + CGFloat(srcRadius - gy) * cell,
                                          width: cell, height: cell)
                    NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
                    cellRect.fill()
                }
            }
        }
        // Centre crosshair on the magnified grid.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let centre = NSRect(x: x + CGFloat(srcRadius) * cell, y: y + 26 + CGFloat(srcRadius) * cell,
                            width: cell, height: cell)
        NSBezierPath(rect: centre).stroke()

        let hex = String(format: "#%02X%02X%02X", picked.r, picked.g, picked.b)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let label = "\(hex)  \(px),\(pyTopOrigin)"
        (label as NSString).draw(at: NSPoint(x: x + 8, y: y + 7), withAttributes: attrs)
    }

    private func drawHint() {
        let text = scrollingMode
            ? "Click a window or drag the scrolling area · Enter starts · Esc cancels"
            : "Click a window or drag an area · double-click copies · Esc cancels"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY)
        let box = NSRect(x: p.x - 14, y: p.y - 10, width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: p, withAttributes: attrs)
    }
}

// MARK: - Toolbar

/// Floating frosted-glass action bar: grouped filled icons with separators,
/// hover feedback and a drop shadow — replacing the old flat gray strip.
private final class ShotToolbarView: NSView {
    private let contentSize: NSSize
    override var fittingSize: NSSize { contentSize }

    init(scrollingMode: Bool, onAction: @escaping (ShotAction) -> Void) {
        func iconButton(_ symbol: String, _ tip: String, tinted tint: NSColor = .labelColor,
                        _ handler: @escaping () -> Void) -> NSButton {
            let b = OverlayHandlerButton(handler: handler)
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(config)
            b.toolTip = tip
            b.imageScaling = .scaleNone
            b.isBordered = false
            b.contentTintColor = tint
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 36),
                b.heightAnchor.constraint(equalToConstant: 36)
            ])
            return b
        }
        func separator() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: 1),
                v.heightAnchor.constraint(equalToConstant: 20)
            ])
            return v
        }

        let primary: [NSView]
        if scrollingMode {
            primary = [iconButton("play.fill", L10n.tr("Start scrolling capture (Enter)", "开始滚动截图 (Enter)")) { onAction(.scrolling) }]
        } else {
            primary = [
                iconButton("rectangle.expand.vertical", L10n.tr("Scrolling screenshot (S)", "滚动截图 (S)")) { onAction(.scrolling) },
                iconButton("pin.fill", L10n.tr("Pin to screen (T)", "贴到屏幕 (T)")) { onAction(.pin) },
                iconButton("pencil.tip.crop.circle", L10n.tr("Annotate", "标注")) { onAction(.edit) }
            ]
        }
        let share = [
            iconButton("doc.on.doc.fill", L10n.tr("Copy to clipboard (Enter)", "复制到剪贴板 (Enter)")) { onAction(.copy) },
            iconButton("tray.and.arrow.down.fill", L10n.tr("Save… (Space)", "保存… (空格)")) { onAction(.save) }
        ]
        let cancel = iconButton("xmark", L10n.tr("Cancel (Esc)", "取消 (Esc)"), tinted: .systemRed) { onAction(.cancel) }

        let sep1 = separator(), sep2 = separator()
        let stack = NSStackView(views: primary + [sep1] + share + [sep2] + [cancel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        if let lastPrimary = primary.last { stack.setCustomSpacing(10, after: lastPrimary) }
        stack.setCustomSpacing(10, after: sep1)
        if let lastShare = share.last { stack.setCustomSpacing(10, after: lastShare) }
        stack.setCustomSpacing(10, after: sep2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentSize = stack.fittingSize

        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        let border = ToolbarBorderView()
        border.layer?.cornerRadius = 14
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Draws the toolbar's hairline border without swallowing clicks.
private final class ToolbarBorderView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class OverlayHandlerButton: NSButton {
    private let handler: () -> Void
    private var hoverArea: NSTrackingArea?

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 9
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    @objc private func fire() { handler() }
}

// MARK: - Edit toolbar (in-place annotation strip)

/// Annotation strip shown in edit mode: tool picker, colour swatches, stroke
/// widths, undo, and Copy / Save / Exit. Same frosted chrome as the action bar.
private final class EditToolbarView: NSView {
    private let contentSize: NSSize
    override var fittingSize: NSSize { contentSize }
    private var toolButtons: [ShapeTool: NSButton] = [:]
    private var widthButtons: [NSButton] = []
    private weak var editor: AnnotationEditorView?

    init(editor: AnnotationEditorView) {
        func iconButton(_ symbol: String, _ tip: String, tinted tint: NSColor = .labelColor,
                        _ handler: @escaping () -> Void) -> NSButton {
            let b = OverlayHandlerButton(handler: handler)
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(config)
            b.toolTip = tip
            b.imageScaling = .scaleNone
            b.isBordered = false
            b.contentTintColor = tint
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 32),
                b.heightAnchor.constraint(equalToConstant: 36)
            ])
            return b
        }
        func separator() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: 1),
                v.heightAnchor.constraint(equalToConstant: 20)
            ])
            return v
        }

        // Tool picker.
        var toolBtns: [ShapeTool: NSButton] = [:]
        var views: [NSView] = ShapeTool.allCases.map { tool in
            let b = iconButton(tool.symbol, tool.tip) { [weak editor] in editor?.currentTool = tool }
            toolBtns[tool] = b
            return b
        }

        views.append(separator())

        // Colour swatches.
        for color in [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue] {
            let b = EditSwatchButton(color: color) { [weak editor] in editor?.currentColor = color }
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 20),
                b.heightAnchor.constraint(equalToConstant: 20)
            ])
            views.append(b)
        }

        views.append(separator())

        // Stroke widths.
        var widthBtns: [NSButton] = []
        for (i, w) in AnnotationEditorView.widths.enumerated() {
            let b = iconButton(["smallcircle.fill", "circle.fill", "largecircle.fill"][i],
                               ["Thin stroke", "Medium stroke", "Thick stroke"][i]) { [weak editor] in
                editor?.currentWidth = w
            }
            b.tag = i
            widthBtns.append(b)
            views.append(b)
        }

        views.append(separator())

        views.append(iconButton("arrow.uturn.left", L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")) { [weak editor] in editor?.undo() })

        views.append(separator())

        views.append(iconButton("doc.on.doc.fill", L10n.tr("Copy (Enter)", "复制 (Enter)"), tinted: .systemGreen) { [weak editor] in
            guard let editor else { return }
            editor.finish(.copy(editor.flattenedImage()))
        })
        views.append(iconButton("tray.and.arrow.down.fill", L10n.tr("Save…", "保存…")) { [weak editor] in
            guard let editor else { return }
            editor.finish(.save(editor.flattenedImage()))
        })
        views.append(iconButton("xmark", L10n.tr("Back to selection (Esc)", "返回框选 (Esc)"), tinted: .systemRed) { [weak editor] in
            editor?.finish(.cancelled)
        })

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentSize = stack.fittingSize
        self.editor = editor
        self.toolButtons = toolBtns
        self.widthButtons = widthBtns

        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        let border = ToolbarBorderView()
        border.layer?.cornerRadius = 14
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        editor.onToolChanged = { [weak self] tool in self?.highlightTool(tool) }
        highlightTool(editor.currentTool)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func highlightTool(_ tool: ShapeTool) {
        for (t, b) in toolButtons {
            b.contentTintColor = (t == tool) ? .systemRed : .labelColor
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Round colour swatch for the edit strip.
private final class EditSwatchButton: NSButton {
    private let handler: () -> Void

    init(color: NSColor, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
