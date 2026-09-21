import AppKit

/// Selection cursor: a familiar pointer plus a compact blue add badge. The
/// arrow makes the hotspot and drag direction clearer than a bare crosshair.
enum ShotSelectionCursor {
    static let cursor: NSCursor = {
        let size = NSSize(width: 30, height: 34)
        let image = NSImage(size: size, flipped: false) { _ in
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 3, y: 31))
            arrow.line(to: NSPoint(x: 3, y: 8))
            arrow.line(to: NSPoint(x: 9, y: 13))
            arrow.line(to: NSPoint(x: 13, y: 4))
            arrow.line(to: NSPoint(x: 17, y: 6))
            arrow.line(to: NSPoint(x: 13, y: 15))
            arrow.line(to: NSPoint(x: 21, y: 15))
            arrow.close()
            NSColor.black.withAlphaComponent(0.9).setStroke()
            arrow.lineWidth = 3
            arrow.lineJoinStyle = .round
            arrow.stroke()
            NSColor.white.setFill()
            arrow.fill()

            let badge = NSRect(x: 15, y: 16, width: 14, height: 14)
            NSColor.black.withAlphaComponent(0.88).setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let plus = NSBezierPath()
            plus.lineWidth = 2
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: badge.midX - 3.5, y: badge.midY))
            plus.line(to: NSPoint(x: badge.midX + 3.5, y: badge.midY))
            plus.move(to: NSPoint(x: badge.midX, y: badge.midY - 3.5))
            plus.line(to: NSPoint(x: badge.midX, y: badge.midY + 3.5))
            plus.stroke()
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 3))
    }()

    private static func diagonal(_ symbol: String) -> NSCursor {
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return .crosshair
        }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }

    static let resizeNorthWestSouthEast = diagonal("arrow.up.left.and.arrow.down.right")
    static let resizeNorthEastSouthWest = diagonal("arrow.up.right.and.arrow.down.left")
}

enum ShotSelectionHandle: CaseIterable, Equatable {
    case northWest, north, northEast, east, southEast, south, southWest, west
}

enum ShotSelectionHit: Equatable {
    case none
    case move
    case resize(ShotSelectionHandle)
}

/// Pure selection geometry shared by mouse handling and the headless self-test.
enum ShotSelectionGeometry {
    static let hitSlop: CGFloat = 7
    static let minimumSize: CGFloat = 8

    static func handlePoint(_ handle: ShotSelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .northWest: return CGPoint(x: rect.minX, y: rect.maxY)
        case .north: return CGPoint(x: rect.midX, y: rect.maxY)
        case .northEast: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .east: return CGPoint(x: rect.maxX, y: rect.midY)
        case .southEast: return CGPoint(x: rect.maxX, y: rect.minY)
        case .south: return CGPoint(x: rect.midX, y: rect.minY)
        case .southWest: return CGPoint(x: rect.minX, y: rect.minY)
        case .west: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    static func hitTest(_ point: CGPoint, in rect: CGRect) -> ShotSelectionHit {
        guard rect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) else { return .none }
        let corners: [ShotSelectionHandle] = [.northWest, .northEast, .southEast, .southWest]
        for handle in corners {
            let p = handlePoint(handle, in: rect)
            if abs(point.x - p.x) <= hitSlop, abs(point.y - p.y) <= hitSlop {
                return .resize(handle)
            }
        }
        if point.x >= rect.minX - hitSlop, point.x <= rect.maxX + hitSlop {
            if abs(point.y - rect.maxY) <= hitSlop { return .resize(.north) }
            if abs(point.y - rect.minY) <= hitSlop { return .resize(.south) }
        }
        if point.y >= rect.minY - hitSlop, point.y <= rect.maxY + hitSlop {
            if abs(point.x - rect.maxX) <= hitSlop { return .resize(.east) }
            if abs(point.x - rect.minX) <= hitSlop { return .resize(.west) }
        }
        return rect.contains(point) ? .move : .none
    }

    static func moved(_ rect: CGRect, delta: CGPoint, within bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: rect.origin.x + delta.x, y: rect.origin.y + delta.y)
        origin.x = max(bounds.minX, min(bounds.maxX - rect.width, origin.x))
        origin.y = max(bounds.minY, min(bounds.maxY - rect.height, origin.y))
        return CGRect(origin: origin, size: rect.size)
    }

    static func resized(_ rect: CGRect, handle: ShotSelectionHandle,
                        delta: CGPoint, within bounds: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .northWest, .west, .southWest:
            minX = max(bounds.minX, min(rect.maxX - minimumSize, rect.minX + delta.x))
        case .northEast, .east, .southEast:
            maxX = min(bounds.maxX, max(rect.minX + minimumSize, rect.maxX + delta.x))
        default: break
        }
        switch handle {
        case .northWest, .north, .northEast:
            maxY = min(bounds.maxY, max(rect.minY + minimumSize, rect.maxY + delta.y))
        case .southWest, .south, .southEast:
            minY = max(bounds.minY, min(rect.maxY - minimumSize, rect.minY + delta.y))
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

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
/// drag always starts a manual region. Crosshair guides while hovering;
/// once a selection is locked a floating toolbar offers the iShot action set.
@MainActor
final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    private var windows: [NSWindow] = []
    private var frozen: [ScreenshotCapture.FrozenDisplay] = []
    private var candidateWindows: [CGRect] = []
    private var ocrTask: Task<Void, Never>?

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
        ocrTask?.cancel()
        ocrTask = nil
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
        if action == .ocr {
            recognizeText(globalRect: globalRect)
            return
        }
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
        case .ocr, .cancel:
            break
        }
    }

    private func recognizeText(globalRect: CGRect) {
        guard ocrTask == nil,
              let image = ScreenshotCapture.crop(globalRect: globalRect, from: frozen) else { return }
        OCRResultController.shared.showLoading { [weak self] in
            self?.ocrTask?.cancel()
            self?.ocrTask = nil
            for case let window as ShotOverlayWindow in self?.windows ?? [] {
                window.shotView.prepareForReselection()
            }
            self?.windows.first(where: { $0.screen?.frame.intersects(globalRect) == true })?.makeKeyAndOrderFront(nil)
        }
        ocrTask = Task { [weak self] in
            do {
                let text = try await ScreenshotOCR.recognize(image)
                guard !Task.isCancelled, let self else { return }
                self.ocrTask = nil
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.dismiss()
                }
                OCRResultController.shared.showResult(text)
            } catch {
                guard !Task.isCancelled else { return }
                self?.ocrTask = nil
                OCRResultController.shared.showError(error)
            }
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
    case copy, save, edit, pin, scrolling, ocr, cancel
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
    private var dragHit: ShotSelectionHit = .none
    private var dragStartRect: CGRect = .zero
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
    /// frozen screen as soon as the selection locks; the merged toolbar below
    /// the selection offers tools, a colour picker and the finish actions.
    private var editorView: AnnotationEditorView?

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
        ShotSelectionCursor.cursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ShotSelectionCursor.cursor)
        guard locked, hasSelection else { return }
        let inner = currentRect.insetBy(dx: ShotSelectionGeometry.hitSlop,
                                        dy: ShotSelectionGeometry.hitSlop)
        if !inner.isEmpty { addCursorRect(inner, cursor: .openHand) }
        let slop = ShotSelectionGeometry.hitSlop
        addCursorRect(CGRect(x: currentRect.minX + slop, y: currentRect.maxY - slop,
                             width: max(0, currentRect.width - slop * 2), height: slop * 2),
                      cursor: .resizeUpDown)
        addCursorRect(CGRect(x: currentRect.minX + slop, y: currentRect.minY - slop,
                             width: max(0, currentRect.width - slop * 2), height: slop * 2),
                      cursor: .resizeUpDown)
        addCursorRect(CGRect(x: currentRect.maxX - slop, y: currentRect.minY + slop,
                             width: slop * 2, height: max(0, currentRect.height - slop * 2)),
                      cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: currentRect.minX - slop, y: currentRect.minY + slop,
                             width: slop * 2, height: max(0, currentRect.height - slop * 2)),
                      cursor: .resizeLeftRight)
        for handle in ShotSelectionHandle.allCases {
            let p = ShotSelectionGeometry.handlePoint(handle, in: currentRect)
            let hitRect = CGRect(x: p.x - ShotSelectionGeometry.hitSlop,
                                 y: p.y - ShotSelectionGeometry.hitSlop,
                                 width: ShotSelectionGeometry.hitSlop * 2,
                                 height: ShotSelectionGeometry.hitSlop * 2)
            addCursorRect(hitRect, cursor: cursor(for: .resize(handle)))
        }
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
        guard hoverActive, hasSelection, startPoint == nil, editorView == nil else { return }
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
        startPoint = mouse
        dragHit = (locked && hasSelection)
            ? ShotSelectionGeometry.hitTest(mouse, in: currentRect)
            : .none
        dragStartRect = currentRect
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
            if dragHit == .none {
                discardEditor()      // a fresh region means fresh annotations
            }
            toolbar?.isHidden = true
        }
        hasSelection = true
        let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
        switch dragHit {
        case .move:
            currentRect = ShotSelectionGeometry.moved(dragStartRect, delta: delta, within: bounds)
            NSCursor.closedHand.set()
        case .resize(let handle):
            currentRect = ShotSelectionGeometry.resized(dragStartRect, handle: handle,
                                                        delta: delta, within: bounds)
            cursor(for: dragHit).set()
        case .none:
            currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                 width: abs(p.x - start.x), height: abs(p.y - start.y))
        }
        if let editorView { updateEditorCrop(for: editorView) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = clampedToBounds(convert(event.locationInWindow, from: nil))
        mouse = p
        let wasDragging = dragging
        let completedHit = dragHit
        startPoint = nil
        dragging = false
        dragHit = .none
        if event.clickCount >= 2 {
            confirm(scrollingMode ? .scrolling : .copy)
            return
        }
        if !wasDragging {
            // Bare click: inside an existing selection keeps it (so a following
            // double-click copies it); otherwise lock the window under the
            // cursor (when hover-framing is on); empty space clears.
            if completedHit != .none || (hasSelection && currentRect.contains(p)) {
                hoverActive = false
                locked = true
            } else if RecordingController.shared.hoverFramesWindows,
                      let hit = candidateFrames.first(where: { $0.contains(globalPoint(p)) }) {
                discardEditor()
                adoptAutoSelection(globalRect: hit, lock: true)
            } else {
                hasSelection = false
                locked = false
                discardEditor()
                onClaimAutoSelection?(self)
            }
        } else {
            locked = hasSelection && currentRect.width >= 8 && currentRect.height >= 8
        }
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = clampedToBounds(convert(event.locationInWindow, from: nil))
        if locked, hasSelection {
            cursor(for: ShotSelectionGeometry.hitTest(mouse, in: currentRect)).set()
        }
        // Hover window-framing can be turned off in Settings → 截图. Once the
        // annotation editor is attached the region stays put (iShot-style).
        if editorView == nil, !locked, hoverActive, startPoint == nil,
           RecordingController.shared.hoverFramesWindows {
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

    private func cursor(for hit: ShotSelectionHit) -> NSCursor {
        switch hit {
        case .move: return .openHand
        case .resize(.north), .resize(.south): return .resizeUpDown
        case .resize(.east), .resize(.west): return .resizeLeftRight
        case .resize(.northWest), .resize(.southEast): return ShotSelectionCursor.resizeNorthWestSouthEast
        case .resize(.northEast), .resize(.southWest): return ShotSelectionCursor.resizeNorthEastSouthWest
        case .none: return ShotSelectionCursor.cursor
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if editorView?.currentTool != nil { editorView?.currentTool = nil }
        else { onAction?(.zero, .cancel) }
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
        // Annotated shots export through the editor so drawings are baked in.
        if action != .scrolling, action != .ocr, let editor = editorView, !editor.shapes.isEmpty {
            onEditedAction?(editor.flattenedImage(), action)
            return
        }
        let rect = (hasSelection && currentRect.width >= 8 && currentRect.height >= 8)
            ? currentRect.integral : bounds
        let global = CGRect(x: screenGlobalFrame.origin.x + rect.origin.x,
                            y: screenGlobalFrame.origin.y + rect.origin.y,
                            width: rect.width, height: rect.height)
        onAction?(global, action)
    }

    // MARK: Toolbar

    private func layoutToolbar() {
        // Never show the bar mid-drag: while the mouse is down shaping a new
        // region the canvas belongs to the selection gesture alone.
        guard locked, hasSelection, !dragging, startPoint == nil,
              currentRect.width >= 8, currentRect.height >= 8 else {
            toolbar?.isHidden = true
            return
        }
        if !scrollingMode { ensureEditor() }
        if toolbar == nil {
            let tb = ShotToolbarView(editor: editorView, scrollingMode: scrollingMode) { [weak self] action in
                self?.confirm(action)
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

    // MARK: In-place annotation editor

    /// Attaches the annotation canvas (transparent, covering the frozen
    /// screen) and points its export crop at the current selection.
    private func ensureEditor() {
        if let editor = editorView {
            updateEditorCrop(for: editor)
            return
        }
        let image = backgroundImage ?? NSImage(cgImage: frozen.image, size: bounds.size)
        let editor = AnnotationEditorView(image: image)
        editor.drawsBaseImage = false
        editor.frame = bounds
        updateEditorCrop(for: editor)
        editor.onFinished = { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                self.onAction?(.zero, .cancel)
            case .copy(let img):
                self.onEditedAction?(img, .copy)
            case .save(let img):
                self.onEditedAction?(img, .save)
            case .pin(let img):
                self.onEditedAction?(img, .pin)
            }
        }
        editor.onToolChanged = { [weak self] tool in
            guard let self else { return }
            self.toolbar?.highlightTool(tool)
            // Tool deselected (Esc / clicking the active tool) → keys return to
            // the overlay so Enter / Space / colour-copy shortcuts work again.
            if tool == nil { self.window?.makeFirstResponder(self) }
        }
        addSubview(editor)
        editorView = editor
        // The editor keeps first responder while attached: Esc deselects the
        // active tool (or cancels), unhandled keys (R/H/S…) bubble up the
        // responder chain to the overlay. Losing responder entirely was why
        // Esc went dead after committing a text/caption field.
        window?.makeFirstResponder(editor)
    }

    /// The editor view is flipped (top-left origin); convert the selection.
    private func updateEditorCrop(for editor: AnnotationEditorView) {
        editor.cropRect = CGRect(x: currentRect.minX, y: bounds.height - currentRect.maxY,
                                 width: currentRect.width, height: currentRect.height)
    }

    func prepareForReselection() {
        editorView?.currentTool = nil
        window?.makeFirstResponder(self)
    }

    private func discardEditor() {
        editorView?.removeFromSuperview()
        editorView = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
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
            // Dim only the outside. Clearing the selection would punch a
            // transparent hole through the frozen image into the live desktop.
            let mask = NSBezierPath(rect: bounds)
            mask.append(NSBezierPath(rect: currentRect))
            mask.windingRule = .evenOdd
            dim.setFill()
            mask.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: currentRect)
            border.lineWidth = 1.5
            border.stroke()
            if locked { drawSelectionHandles(for: currentRect) }
            drawDimensions(for: currentRect)
        } else {
            dim.setFill()
            bounds.fill()
            drawHint()
        }

        if !hasSelection || startPoint == nil || (toolbar?.isHidden ?? true) {
            drawGuideLines(at: mouse)
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

    private func drawSelectionHandles(for rect: CGRect) {
        for handle in ShotSelectionHandle.allCases {
            let point = ShotSelectionGeometry.handlePoint(handle, in: rect)
            let knob = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            NSColor.systemBlue.setFill()
            NSColor.white.setStroke()
            let path = NSBezierPath(roundedRect: knob, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }

    private func drawHint() {
        let text = scrollingMode
            ? L10n.tr("Click a window or drag the scrolling area · Enter starts · Esc cancels",
                      "点击窗口或拖拽框选滚动区域 · 回车开始 · Esc 取消")
            : L10n.tr("Click a window or drag an area · double-click copies · Esc cancels",
                      "点击窗口或拖拽框选 · 双击复制 · Esc 取消")
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

/// Floating frosted-glass bar shown once a selection locks: annotation tools,
/// a compact colour picker up front (iShot-style — no separate "annotate"
/// step), then undo, mode actions and the finish buttons. Scrolling mode
/// keeps a minimal variant since annotations don't apply to a live capture.
final class ShotToolbarView: NSView {
    private let contentSize: NSSize
    override var fittingSize: NSSize { contentSize }
    private var toolButtons: [ShapeTool: NSButton] = [:]

    init(editor: AnnotationEditorView?, scrollingMode: Bool, onAction: @escaping (ShotAction) -> Void) {
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
                b.widthAnchor.constraint(equalToConstant: 34),
                b.heightAnchor.constraint(equalToConstant: 38)
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
                v.heightAnchor.constraint(equalToConstant: 22)
            ])
            return v
        }

        var views: [NSView] = []
        if scrollingMode || editor == nil {
            views = [
                iconButton("play.fill", L10n.tr("Start scrolling capture (Enter)", "开始滚动截图 (Enter)")) { onAction(.scrolling) },
                separator(),
                iconButton("doc.on.doc.fill", L10n.tr("Copy to clipboard (Enter)", "复制到剪贴板 (Enter)")) { onAction(.copy) },
                iconButton("tray.and.arrow.down.fill", L10n.tr("Save… (Space)", "保存… (空格)")) { onAction(.save) },
                separator(),
                iconButton("xmark", L10n.tr("Cancel (Esc)", "取消 (Esc)"), tinted: .systemRed) { onAction(.cancel) }
            ]
        } else if let editor {
            // Annotation tools — clicking the active tool deselects it and
            // returns the overlay to region-selection behaviour.
            var toolBtns: [ShapeTool: NSButton] = [:]
            for tool in ShapeTool.allCases {
                let b = iconButton(tool.symbol, tool.tip) { [weak editor] in
                    guard let editor else { return }
                    editor.currentTool = (editor.currentTool == tool) ? nil : tool
                    if editor.currentTool != nil { editor.window?.makeFirstResponder(editor) }
                }
                toolBtns[tool] = b
                views.append(b)
            }
            toolButtons = toolBtns

            views.append(separator())

            views.append(ShotColorButton(editor: editor))

            views.append(separator())
            views.append(iconButton("arrow.uturn.left", L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")) { [weak editor] in editor?.undo() })

            views.append(separator())
            views.append(iconButton("rectangle.expand.vertical", L10n.tr("Scrolling screenshot (S)", "滚动截图 (S)")) { onAction(.scrolling) })
            views.append(iconButton("pin.fill", L10n.tr("Pin to screen (T)", "贴到屏幕 (T)")) { onAction(.pin) })
            let ocr = OverlayHandlerButton { onAction(.ocr) }
            ocr.title = "OCR"
            ocr.font = .systemFont(ofSize: 12, weight: .semibold)
            ocr.isBordered = false
            ocr.toolTip = L10n.tr("Extract text from the original selection", "识别选区原始文字")
            ocr.setAccessibilityLabel("OCR")
            ocr.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                ocr.widthAnchor.constraint(equalToConstant: 42),
                ocr.heightAnchor.constraint(equalToConstant: 38)
            ])
            views.append(ocr)

            views.append(separator())
            views.append(iconButton("tray.and.arrow.down.fill", L10n.tr("Save… (Space)", "保存… (空格)")) { onAction(.save) })
            views.append(iconButton("checkmark", L10n.tr("Copy to clipboard (Enter)", "复制到剪贴板 (Enter)"), tinted: .systemGreen) { onAction(.copy) })

            views.append(separator())
            views.append(iconButton("xmark", L10n.tr("Cancel (Esc)", "取消 (Esc)"), tinted: .systemRed) { onAction(.cancel) })
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
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

    /// Tints the active tool's button red; nil clears the highlight.
    func highlightTool(_ tool: ShapeTool?) {
        for (t, b) in toolButtons {
            b.contentTintColor = (t == tool) ? .systemRed : .labelColor
        }
    }

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

/// A single current-colour button with a transient palette below the toolbar.
private final class ShotColorButton: NSButton {
    private weak var editor: AnnotationEditorView?
    private let palette = NSPopover()
    private var sizePicker: NSSegmentedControl!

    init(editor: AnnotationEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        title = ""
        isBordered = false
        image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: L10n.tr("Annotation colour", "标注颜色"))?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .regular))
        contentTintColor = editor.currentColor
        toolTip = L10n.tr("Choose annotation colour", "选择标注颜色")
        setAccessibilityLabel(toolTip)
        target = self
        action = #selector(togglePalette)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 38)
        ])

        let colours: [(NSColor, String)] = [
            (.systemRed, L10n.tr("Red", "红色")),
            (.systemOrange, L10n.tr("Orange", "橙色")),
            (.systemYellow, L10n.tr("Yellow", "黄色")),
            (.systemGreen, L10n.tr("Green", "绿色")),
            (.systemBlue, L10n.tr("Blue", "蓝色"))
        ]
        let swatches = colours.map { colour, name in
            let button = EditSwatchButton(color: colour) { [weak self] in
                guard let self else { return }
                self.editor?.currentColor = colour
                self.contentTintColor = colour
                self.palette.performClose(nil)
                if let editor = self.editor, editor.currentTool != nil {
                    editor.window?.makeFirstResponder(editor)
                }
            }
            button.toolTip = name
            button.setAccessibilityLabel(name)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20)
            ])
            return button
        }
        let colourRow = NSStackView(views: swatches)
        colourRow.orientation = .horizontal
        colourRow.spacing = 12
        sizePicker = NSSegmentedControl(labels: [L10n.tr("Small", "小"), L10n.tr("Large", "大")],
                                       trackingMode: .selectOne, target: self, action: #selector(changeTextSize))
        sizePicker.selectedSegment = editor.currentTextSize >= 30 ? 1 : 0
        sizePicker.setAccessibilityLabel(L10n.tr("Text size", "文字大小"))
        sizePicker.setToolTip("20 pt", forSegment: 0)
        sizePicker.setToolTip("30 pt", forSegment: 1)
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: L10n.tr("Text", "文字")), sizePicker])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 12
        let stack = NSStackView(views: [colourRow, sizeRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 176, height: 84)
        let controller = NSViewController()
        controller.view = stack
        palette.contentViewController = controller
        palette.contentSize = stack.frame.size
        palette.behavior = .transient
        palette.animates = false
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changeTextSize() {
        editor?.currentTextSize = sizePicker.selectedSegment == 1 ? 30 : 20
        palette.performClose(nil)
    }

    @objc private func togglePalette() {
        sizePicker.selectedSegment = (editor?.currentTextSize ?? 20) >= 30 ? 1 : 0
        if palette.isShown {
            palette.performClose(nil)
        } else {
            palette.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { palette.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
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
