import AppKit
import CoreImage

/// Annotation editor for screenshots — iShot's 截屏编辑 as a dedicated window
/// (scrolling screenshots, pin re-editing).
///
/// Uses the same toolbar and shortcuts as the in-place editor of a direct
/// screenshot: tools · colour / text-size palette · undo · pin · save · copy ·
/// cancel; Enter copies, Space saves, T pins, Esc cancels. When opened from a
/// pin, save becomes "Update Pin" (iShot's 二次标注: annotations baked back
/// into the pin).
@MainActor
final class ScreenshotEditorController {
    static let shared = ScreenshotEditorController()

    private var window: NSWindow?

    /// Presents the editor. `onUpdate` is set when editing a pin — the Save
    /// button then becomes "Update Pin" and returns the flattened image.
    func present(image: NSImage, onUpdate: ((NSImage) -> Void)? = nil) {
        if let window { window.close() }

        let editor = AnnotationEditorView(image: image)
        editor.onFinished = { [weak self] result in
            switch result {
            case .save(let img):
                if let onUpdate { onUpdate(img) }
                else { ScreenshotFileIO.save(image: img, suggestedName: ScreenshotFileIO.defaultName()) }
            case .copy(let img):
                if let onUpdate {
                    onUpdate(img)
                    ScreenshotFileIO.copyToClipboard(image: img)
                } else {
                    ScreenshotFileIO.handleScreenshotCopy(image: img)
                }
            case .pin(let img):
                PinWindowController.shared.pin(image: img)
            case .cancelled:
                break
            }
            self?.window?.close()
            self?.window = nil
        }

        let chrome = EditorChromeView(editor: editor, showsUpdate: onUpdate != nil)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: chrome.fittingSize),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L10n.tr("Edit Screenshot", "编辑截图")
        win.contentView = chrome
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = CloseRelay.shared
        CloseRelay.shared.onClose = { [weak self] in self?.window = nil }
        win.makeKeyAndOrderFront(nil)
        chrome.applyInitialZoom()
        win.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

private final class CloseRelay: NSObject, NSWindowDelegate {
    static let shared = CloseRelay()
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil }
}

// MARK: - Shape model

enum ShapeTool: String, CaseIterable {
    case rect, ellipse, arrow, line, pen, highlighter, marker, mosaic, blur, text

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .marker: return "1.circle"
        case .mosaic: return "square.grid.3x3"
        case .blur: return "drop.halffull"
        case .text: return "textformat"
        }
    }

    /// Number key that selects the tool (1…9, then 0), in toolbar order.
    var shortcutKey: String {
        let i = ShapeTool.allCases.firstIndex(of: self)! + 1
        return i == 10 ? "0" : "\(i)"
    }

    static func forShortcutKey(_ key: String) -> ShapeTool? {
        allCases.first { $0.shortcutKey == key }
    }

    var tip: String {
        let name: String
        switch self {
        case .rect: name = L10n.tr("Rectangle", "矩形")
        case .ellipse: name = L10n.tr("Ellipse", "椭圆")
        case .arrow: name = L10n.tr("Arrow", "箭头")
        case .line: name = L10n.tr("Line", "直线")
        case .pen: name = L10n.tr("Pen", "画笔")
        case .highlighter: name = L10n.tr("Highlighter", "荧光笔")
        case .marker: name = L10n.tr("Marker (stamp 1, 2, 3…)", "标号 (依次标记 1、2、3…)")
        case .mosaic: name = L10n.tr("Mosaic", "马赛克")
        case .blur: name = L10n.tr("Blur", "模糊")
        case .text: name = L10n.tr("Text", "文字")
        }
        return "\(name) (\(shortcutKey))"
    }

    /// Tools whose look depends on the stroke width.
    var usesWidth: Bool {
        switch self {
        case .rect, .ellipse, .arrow, .line, .pen, .highlighter, .marker: return true
        case .mosaic, .blur, .text: return false
        }
    }

    /// Pixel effects take their look from the screenshot, not the colour.
    var usesColor: Bool { self != .mosaic && self != .blur }

    /// Freehand tools store their path in `points`.
    var isFreehand: Bool { self == .pen || self == .highlighter }
}

struct Shape {
    var tool: ShapeTool
    var color: NSColor
    var width: CGFloat            // stroke width (points)
    var start: CGPoint
    var end: CGPoint              // marker: centre of its caption (leader-line target)
    var text: String = ""         // text shape: body; marker shape: its caption
    var fontSize: CGFloat = 18    // text: body size; marker: caption size
    var number: Int = 0           // marker only
    var id = UUID()
    var points: [CGPoint] = []    // pen / highlighter path

    var rect: CGRect {
        if tool.isFreehand, let first = points.first {
            var r = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

// MARK: - Chrome (toolbar + canvas)

private final class EditorChromeView: NSView {
    let editor: AnnotationEditorView
    private let toolbar: ShotToolbarView
    private let scroll = NSScrollView()
    private static let barHeight: CGFloat = 60

    init(editor: AnnotationEditorView, showsUpdate: Bool) {
        self.editor = editor
        toolbar = ShotToolbarView(
            editor: editor, scrollingMode: false, captureActions: false,
            saveTip: showsUpdate ? L10n.tr("Update Pin (Space)", "更新贴图 (空格)") : nil
        ) { [weak editor] action in
            guard let editor else { return }
            switch action {
            case .copy: editor.finish(.copy(editor.flattenedImage()))
            case .save: editor.finish(.save(editor.flattenedImage()))
            case .pin: editor.finish(.pin(editor.flattenedImage()))
            case .cancel: editor.finish(.cancelled)
            default: break
            }
        }
        super.init(frame: .zero)

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)
        // Long screenshots are far taller than the window: pinch or use the
        // zoom buttons to see the whole image. Annotations keep working at any
        // zoom (the clip view scales the canvas, coordinates stay the same).
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 4

        func zoomButton(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ])
            b.toolTip = tip
            return b
        }
        let zoomStack = NSStackView(views: [
            zoomButton(L10n.tr("Fit", "适应窗口"), L10n.tr("Fit the whole image (⌘0)", "显示完整图片 (⌘0)"), #selector(zoomToFit)),
            zoomButton("100%", L10n.tr("Actual size (⌘1)", "实际大小 (⌘1)"), #selector(zoomToActual))
        ])
        zoomStack.spacing = 10

        let tbSize = toolbar.fittingSize
        for v in [bar, scroll, toolbar, zoomStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(bar)
        addSubview(scroll)
        bar.addSubview(toolbar)
        bar.addSubview(zoomStack)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            toolbar.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            toolbar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            toolbar.widthAnchor.constraint(equalToConstant: tbSize.width),
            toolbar.heightAnchor.constraint(equalToConstant: tbSize.height),

            zoomStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            zoomStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            zoomStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.leadingAnchor, constant: -10),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        editor.onToolChanged = { [weak self] tool in self?.toolbar.highlightTool(tool) }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func zoomToFit() {
        scroll.magnify(toFit: editor.bounds)
    }

    @objc func zoomToActual() {
        scroll.magnification = 1
    }

    /// Wider-than-window images open scaled to the window width; long
    /// screenshots stay readable and scroll vertically.
    func applyInitialZoom() {
        layoutSubtreeIfNeeded()
        let visibleW = scroll.contentSize.width
        if editor.bounds.width > visibleW, visibleW > 0 {
            scroll.magnification = max(scroll.minMagnification, visibleW / editor.bounds.width)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "0": zoomToFit(); return true
        case "1": zoomToActual(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override var fittingSize: NSSize {
        let img = editor.bounds.size
        let cap = NSScreen.main.map {
            NSSize(width: $0.visibleFrame.width - 120, height: $0.visibleFrame.height - 200)
        } ?? NSSize(width: 900, height: 640)
        let minW = toolbar.fittingSize.width + 32
        return NSSize(width: max(minW, min(img.width + 2, max(560, cap.width))),
                      height: min(img.height + Self.barHeight + 2, max(380, cap.height)))
    }
}

// MARK: - Editor canvas

enum EditorResult {
    case save(NSImage), copy(NSImage), pin(NSImage), cancelled
}

final class AnnotationEditorView: NSView, NSTextFieldDelegate {
    static let widths: [CGFloat] = [2.5, 4.5, 8]
    /// Small / medium / large text sizes offered by the colour palette.
    static let textSizes: [CGFloat] = [14, 20, 30]

    let baseImage: NSImage
    /// nil = no tool active: the view ignores mouse events (the overlay beneath
    /// keeps handling selection) until the user picks a tool on the strip.
    var currentTool: ShapeTool? = nil {
        didSet {
            if currentTool == nil { selectedID = nil }
            onToolChanged?(currentTool)
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Colour / width / text size apply to new annotations and, when one is
    /// selected, restyle it (one undo step per change).
    var currentColor: NSColor = .systemRed {
        didSet {
            restyleField()
            applyToSelection { s in
                guard s.tool.usesColor, s.color != currentColor else { return false }
                s.color = currentColor
                return true
            }
        }
    }
    var currentWidth: CGFloat = widths[1] {
        didSet {
            applyToSelection { s in
                guard s.tool.usesWidth, s.width != currentWidth else { return false }
                s.width = currentWidth
                return true
            }
        }
    }
    var currentTextSize: CGFloat = 20 {
        didSet {
            if let field = textField {
                if let idx = captionIndex, shapes.indices.contains(idx) {
                    shapes[idx].fontSize = captionFontSize(for: currentTextSize)
                    field.font = .systemFont(ofSize: shapes[idx].fontSize, weight: .semibold)
                } else {
                    field.font = .systemFont(ofSize: currentTextSize, weight: .medium)
                }
                fitTextField(field)
                needsDisplay = true
                if captionIndex != nil { return }
            }
            applyToSelection { s in
                switch s.tool {
                case .text where s.fontSize != currentTextSize:
                    s.fontSize = currentTextSize
                case .marker where s.fontSize != captionFontSize(for: currentTextSize):
                    s.fontSize = captionFontSize(for: currentTextSize)
                default:
                    return false
                }
                return true
            }
        }
    }
    var onToolChanged: ((ShapeTool?) -> Void)?
    var onFinished: ((EditorResult) -> Void)?
    /// In-place mode (screenshot overlay): the frozen screen beneath supplies
    /// the background, so the editor only draws shapes.
    var drawsBaseImage = true
    /// When set (view coords, top-left origin), `flattenedImage()` renders just
    /// this region — the overlay uses it to export the selection only.
    var cropRect: CGRect? { didSet { window?.invalidateCursorRects(for: self) } }

    private(set) var shapes: [Shape] = [] { didSet { if movingIndex == nil { window?.invalidateCursorRects(for: self) } } }
    private var draft: Shape?
    /// Baked mosaic / blur pixels per shape, valid for the rect they were baked for.
    private var effectCache: [UUID: (rect: CGRect, image: CGImage)] = [:]
    private lazy var baseCGImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    private static let ciContext = CIContext(options: nil)

    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    /// Index of the marker shape its caption field is editing, if any.
    private var captionIndex: Int?
    /// The caption belongs to a marker stamped just now: stamp + caption are
    /// one undo step.
    private var captionIsNew = false
    /// Index of the committed text being edited again (hidden while editing).
    private var editingTextIndex: Int?

    /// Move session: index of the shape being dragged and the grab offset.
    private var movingIndex: Int?
    private var moveGrabOffset: CGPoint = .zero
    private var moveRecorded = false
    /// True when the drag grabbed a marker's caption: only the caption moves
    /// (the leader line follows), the numbered badge stays put.
    private var movingCaption = false

    /// Selected annotation (click it with any tool): Delete removes it, arrow
    /// keys nudge it, colour / width / size changes restyle it.
    private var selectedID: UUID? { didSet { if oldValue != selectedID { needsDisplay = true } } }
    private var selectedIndex: Int? { selectedID.flatMap { id in shapes.firstIndex { $0.id == id } } }

    /// Snapshots of `shapes` before each change; redo holds undone states.
    private var undoStack: [[Shape]] = []
    private var redoStack: [[Shape]] = []
    /// Consecutive arrow-key nudges of one shape coalesce into one undo step.
    private var lastNudgedID: UUID?

    /// True while `flattenedImage()` renders into the bitmap context: its CTM
    /// is y-flipped, so NSImage/NSString drawing (which self-compensate for
    /// flipped views) must be un-flipped locally or they come out mirrored.
    private var flattening = false
    private let scale: CGFloat

    init(image: NSImage) {
        self.baseImage = image
        let pxW = image.representations.first?.pixelsWide ?? Int(image.size.width * 2)
        self.scale = image.size.width > 0 ? CGFloat(pxW) / image.size.width : 2
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        guard currentTool != nil else { return }
        // The transparent overlay canvas spans the display, but only owns the
        // crop interior. Leave the backdrop and resize cursors to its parent.
        let interior = (cropRect?.insetBy(dx: ShotSelectionGeometry.hitSlop,
                                         dy: ShotSelectionGeometry.hitSlop) ?? bounds).intersection(bounds)
        if !interior.isEmpty { addCursorRect(interior, cursor: .crosshair) }
        for shape in shapes where shape.tool == .text {
            let rect = selectionBounds(of: shape).insetBy(dx: -6, dy: -6).intersection(interior)
            if !rect.isEmpty { addCursorRect(rect, cursor: .openHand) }
        }
    }

    /// Annotation tools only own the interior of the selected screenshot.
    /// Outside the crop and along its resize border, events fall through to
    /// the selection overlay so the user can reframe and still reach its UI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // An active text field must not make the full-screen canvas consume
        // clicks on the outside backdrop or the crop's resize border.
        if textField != nil, let target = super.hitTest(point), target !== self { return target }
        guard currentTool != nil else { return nil }
        if let cropRect {
            let annotationInterior = cropRect.insetBy(dx: ShotSelectionGeometry.hitSlop,
                                                      dy: ShotSelectionGeometry.hitSlop)
            // NSView passes hitTest points in the superview's coordinates.
            // This editor is flipped, so compare in its own coordinates.
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            guard !annotationInterior.isEmpty, annotationInterior.contains(localPoint) else { return nil }
        }
        return super.hitTest(point)
    }

    /// Keeps annotations inside the export region (the screenshot selection):
    /// strokes landing outside would be invisible in the output anyway.
    private func clampToCrop(_ p: CGPoint) -> CGPoint {
        guard let crop = cropRect else { return p }
        let insetBy = currentTool == .marker ? markerRadius(for: currentWidth) : 1
        let inset = crop.insetBy(dx: insetBy, dy: insetBy)
        guard inset.width > 0, inset.height > 0 else { return p }
        return CGPoint(x: max(inset.minX, min(inset.maxX, p.x)),
                       y: max(inset.minY, min(inset.maxY, p.y)))
    }

    /// True when a double-click at `p` (view coords) would re-open a committed
    /// text or marker caption — the overlay must not treat it as "finish".
    func isEditableAnnotation(at p: CGPoint) -> Bool {
        guard currentTool != nil else { return false }
        return shapes.contains { s in
            (s.tool == .text && hit(shape: s, at: p)) || hitCaption(of: s, at: p)
        }
    }

    // MARK: History

    private func recordUndo(nudging id: UUID? = nil) {
        if let id, id == lastNudgedID { return }
        lastNudgedID = id
        undoStack.append(shapes)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        commitTextField()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(shapes)
        restore(previous)
    }

    func redo() {
        commitTextField()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(shapes)
        restore(next)
    }

    private func restore(_ state: [Shape]) {
        lastNudgedID = nil
        shapes = state
        if selectedIndex == nil { selectedID = nil }
        needsDisplay = true
    }

    /// Restyles the selected annotation; `change` returns false for no-ops.
    private func applyToSelection(_ change: (inout Shape) -> Bool) {
        guard let i = selectedIndex, i != editingTextIndex || textField == nil else { return }
        var copy = shapes[i]
        guard change(&copy) else { return }
        recordUndo()
        shapes[i] = copy
        needsDisplay = true
    }

    private func deleteSelection() -> Bool {
        guard textField == nil, let i = selectedIndex else { return false }
        recordUndo()
        let removed = shapes.remove(at: i)
        if removed.tool == .marker { renumberMarkers() }
        selectedID = nil
        needsDisplay = true
        return true
    }

    /// Keeps marker numbers consecutive (1, 2, 3…) after one is deleted.
    private func renumberMarkers() {
        let order = shapes.indices.filter { shapes[$0].tool == .marker }
            .sorted { shapes[$0].number < shapes[$1].number }
        for (n, i) in order.enumerated() where shapes[i].number != n + 1 {
            shapes[i].number = n + 1
        }
    }

    private func nudgeSelection(_ event: NSEvent) -> Bool {
        guard textField == nil, let i = selectedIndex else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch event.keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = step          // flipped view: down is +y
        case 126: dy = -step
        default: return false
        }
        recordUndo(nudging: shapes[i].id)
        shapes[i].offset(dx: dx, dy: dy)
        needsDisplay = true
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextField()
        let p = clampToCrop(convert(event.locationInWindow, from: nil))
        guard let tool = currentTool else { return }
        lastNudgedID = nil
        // Press on an existing annotation selects and moves it (topmost wins);
        // a double-click on text or a caption opens it for editing again.
        if let idx = shapes.indices.reversed().first(where: { hit(shape: shapes[$0], at: p) }) {
            selectedID = shapes[idx].id
            if event.clickCount >= 2 {
                if shapes[idx].tool == .text {
                    beginEditingText(at: idx)
                    return
                }
                if hitCaption(of: shapes[idx], at: p) {
                    beginCaption(for: idx, isNew: false)
                    return
                }
            }
            movingIndex = idx
            moveRecorded = false
            movingCaption = hitCaption(of: shapes[idx], at: p)
            NSCursor.closedHand.set()
            let anchor = movingCaption ? shapes[idx].end : shapes[idx].start
            moveGrabOffset = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
            return
        }
        selectedID = nil
        if tool == .text {
            beginText(at: p)
            return
        }
        if tool == .marker {
            stampMarker(at: p)
            return
        }
        draft = Shape(tool: tool, color: currentColor, width: currentWidth,
                      start: p, end: p, fontSize: currentTextSize,
                      points: tool.isFreehand ? [p] : [])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToCrop(convert(event.locationInWindow, from: nil))
        if let idx = movingIndex {
            NSCursor.closedHand.set()
            if !moveRecorded {
                recordUndo()
                moveRecorded = true
            }
            if movingCaption {
                shapes[idx].end = CGPoint(x: p.x - moveGrabOffset.x, y: p.y - moveGrabOffset.y)
                needsDisplay = true
                return
            }
            let dx = p.x - moveGrabOffset.x - shapes[idx].start.x
            let dy = p.y - moveGrabOffset.y - shapes[idx].start.y
            shapes[idx].offset(dx: dx, dy: dy)
            needsDisplay = true
            return
        }
        guard draft != nil else { return }
        draft!.end = p
        if draft!.tool.isFreehand, let last = draft!.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
            draft!.points.append(p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if movingIndex != nil {
            movingIndex = nil
            movingCaption = false
            window?.invalidateCursorRects(for: self)
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        guard let d = draft else { return }
        draft = nil
        let r = d.rect
        let meaningful = d.tool.isFreehand
            ? (d.points.count >= 2 && (r.width > 3 || r.height > 3))
            : (abs(d.end.x - d.start.x) > 3 || abs(d.end.y - d.start.y) > 3)
        if meaningful {
            recordUndo()
            shapes.append(d)
        }
        needsDisplay = true
    }

    /// Hit area per tool: filled shapes by their rect, strokes by distance to
    /// the path, text by its rendered bounds, markers by the badge circle
    /// (plus its caption pill).
    private func hit(shape s: Shape, at p: CGPoint) -> Bool {
        let slop: CGFloat = 6
        switch s.tool {
        case .rect, .ellipse, .mosaic, .blur:
            return s.rect.insetBy(dx: -slop, dy: -slop).contains(p)
        case .line, .arrow:
            return distanceToSegment(p, a: s.start, b: s.end) <= slop + s.width / 2
        case .pen, .highlighter:
            let half = strokeWidth(of: s) / 2
            guard s.rect.insetBy(dx: -(slop + half), dy: -(slop + half)).contains(p) else { return false }
            if s.points.count == 1 { return hypot(p.x - s.points[0].x, p.y - s.points[0].y) <= slop + half }
            for i in 1..<s.points.count
            where distanceToSegment(p, a: s.points[i - 1], b: s.points[i]) <= slop + half {
                return true
            }
            return false
        case .text:
            return selectionBounds(of: s).insetBy(dx: -slop, dy: -slop).contains(p)
        case .marker:
            let r = markerRadius(for: s.width)
            if hypot(p.x - s.start.x, p.y - s.start.y) <= r + slop { return true }
            return hitCaption(of: s, at: p)
        }
    }

    private func hitCaption(of s: Shape, at p: CGPoint) -> Bool {
        guard s.tool == .marker, !s.text.isEmpty else { return false }
        return captionPill(for: s).insetBy(dx: -4, dy: -4).contains(p)
    }

    /// Visible extent of an annotation, for the selection outline and hits.
    private func selectionBounds(of s: Shape) -> CGRect {
        switch s.tool {
        case .text:
            let size = (s.text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: s.fontSize, weight: .medium)
            ])
            return CGRect(origin: s.start, size: size)
        case .marker:
            let r = markerRadius(for: s.width)
            let badge = CGRect(x: s.start.x - r, y: s.start.y - r, width: 2 * r, height: 2 * r)
            return s.text.isEmpty ? badge : badge.union(captionPill(for: s))
        case .line, .arrow:
            let pad = s.width / 2 + (s.tool == .arrow ? 10 + s.width * 1.6 : 0)
            return s.rect.insetBy(dx: -pad, dy: -pad)
        case .pen, .highlighter:
            let half = strokeWidth(of: s) / 2
            return s.rect.insetBy(dx: -half, dy: -half)
        case .rect, .ellipse:
            return s.rect.insetBy(dx: -s.width / 2, dy: -s.width / 2)
        case .mosaic, .blur:
            return s.rect
        }
    }

    private func strokeWidth(of s: Shape) -> CGFloat {
        s.tool == .highlighter ? s.width * 3 + 8 : s.width
    }

    /// NSString drawing mirrors its glyphs under the flatten bitmap's flipped
    /// CTM (it self-compensates for flipped *views* only) — re-flip locally
    /// around the anchor so exported text stays upright.
    private func drawString(_ str: NSString, at origin: CGPoint,
                            attrs: [NSAttributedString.Key: Any]) {
        if flattening, let ctx = NSGraphicsContext.current?.cgContext {
            // NSString anchors at the baseline (y-up); after the local un-flip
            // that leaves the glyphs one line above the on-screen position —
            // shift down by the line height to match the flipped view exactly.
            let h = str.size(withAttributes: attrs).height
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: 1, y: -1)
            str.draw(at: NSPoint(x: 0, y: -h), withAttributes: attrs)
            ctx.restoreGState()
        } else {
            str.draw(at: origin, withAttributes: attrs)
        }
    }

    /// Draws the base image upright in the flatten bitmap. NSImage.draw
    /// self-compensates for flipped *views* only — under the flatten context's
    /// hand-flipped CTM it mirrors, so go through the CGImage with a local
    /// un-flip instead.
    private func drawImageUpright(_ image: NSImage, in rect: NSRect) {
        if flattening, let ctx = NSGraphicsContext.current?.cgContext,
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        } else {
            image.draw(in: rect)
        }
    }

    private func distanceToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        if len2 < 0.001 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
        return hypot(p.x - (a.x + t * ab.x), p.y - (a.y + t * ab.y))
    }

    // MARK: Keyboard

    /// Number keys pick tools (1…9, 0 in toolbar order); pressing the active
    /// tool's key again puts the tool down. Used by the overlay as well.
    @discardableResult
    func selectTool(for event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers,
              let tool = ShapeTool.forShortcutKey(key) else { return false }
        commitTextField()
        currentTool = (currentTool == tool) ? nil : tool
        if currentTool != nil { window?.makeFirstResponder(self) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods.contains(.command), key == "z" {
            if mods.contains(.shift) { redo() } else { undo() }
            return
        }
        if selectTool(for: event) { return }
        switch event.keyCode {
        case 51, 117:                                   // Delete / Forward Delete
            if deleteSelection() { return }
        case 123, 124, 125, 126:                        // arrows: nudge selection
            if nudgeSelection(event) { return }
        case 53:                                        // Esc
            finish(.cancelled)
            return
        case 36, 76:                                    // Enter → copy
            finish(.copy(flattenedImage()))
            return
        case 49:                                        // Space → save
            finish(.save(flattenedImage()))
            return
        default:
            break
        }
        if key == "t", mods.isDisjoint(with: [.command, .control, .option]) {
            finish(.pin(flattenedImage()))
            return
        }
        super.keyDown(with: event)
    }

    func finish(_ result: EditorResult) {
        if case .cancelled = result {
            let field = textField
            textField = nil
            captionIndex = nil
            captionIsNew = false
            editingTextIndex = nil
            field?.removeFromSuperview()
            window?.makeFirstResponder(self)
        } else {
            commitTextField()
        }
        selectedID = nil
        onFinished?(result)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(.cancelled)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish(.cancelled)
        return true
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        textAnchor = p
        editingTextIndex = nil
        let tf = makeInlineField(font: .systemFont(ofSize: currentTextSize, weight: .medium),
                                 placeholder: L10n.tr("Text", "输入文字"), filled: false, color: currentColor)
        tf.setFrameOrigin(p)
        textField = tf
        fitTextField(tf)
        addSubview(tf)
        window?.makeFirstResponder(tf)
    }

    /// Re-opens a committed text in place; the shape hides while it's edited.
    private func beginEditingText(at index: Int) {
        let s = shapes[index]
        textAnchor = s.start
        editingTextIndex = index
        let tf = makeInlineField(font: .systemFont(ofSize: s.fontSize, weight: .medium),
                                 placeholder: L10n.tr("Text", "输入文字"), filled: false, color: s.color)
        tf.stringValue = s.text
        tf.setFrameOrigin(s.start)
        textField = tf
        fitTextField(tf)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        needsDisplay = true
    }

    /// Inline editor shared by text and marker captions.
    /// `filled`: marker caption — previews the final tag (annotation-colour
    /// fill, contrasting text). Otherwise free text — transparent, so what you
    /// type looks like the committed text. Both share the same 1 px outline.
    private func makeInlineField(font: NSFont, placeholder: String, filled: Bool, color: NSColor) -> NSTextField {
        let tf = InlineTextField(frame: .zero)
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = font
        tf.isFilled = filled
        style(tf, color: color, placeholder: placeholder)
        tf.target = self
        tf.action = #selector(textCommitted(_:))
        tf.delegate = self
        return tf
    }

    private func style(_ tf: InlineTextField, color: NSColor, placeholder: String? = nil) {
        let textColor = tf.isFilled ? AnnotationEditorView.contrastingText(on: color) : color
        tf.fillColor = tf.isFilled ? color.withAlphaComponent(0.92) : .clear
        tf.outlineColor = color.withAlphaComponent(0.85)
        tf.textColor = textColor
        let text = placeholder ?? tf.placeholderAttributedString?.string ?? ""
        tf.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: tf.font ?? NSFont.systemFont(ofSize: currentTextSize),
            .foregroundColor: textColor.withAlphaComponent(0.55)
        ])
        tf.needsDisplay = true
    }

    /// Colour picked while a field is open: recolour the field (and a marker
    /// stamped just now, whose caption is being typed).
    private func restyleField() {
        guard let tf = textField as? InlineTextField else { return }
        if let idx = captionIndex {
            guard captionIsNew, shapes.indices.contains(idx) else { return }
            shapes[idx].color = currentColor
        }
        style(tf, color: currentColor)
        needsDisplay = true
    }

    /// Sizes the inline field to its text (placeholder when empty). A caption
    /// field stays centred on its caption anchor.
    private func fitTextField(_ tf: NSTextField) {
        let font = tf.font ?? .systemFont(ofSize: currentTextSize)
        let str = (tf.stringValue.isEmpty ? (tf.placeholderAttributedString?.string ?? "") : tf.stringValue) as NSString
        let textW = str.size(withAttributes: [.font: font]).width
        let size = NSSize(width: max(60, ceil(textW) + 14), height: ceil(font.ascender - font.descender + font.leading) + 6)
        if let idx = captionIndex, shapes.indices.contains(idx) {
            let c = shapes[idx].end
            tf.frame = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2,
                              width: size.width, height: size.height)
        } else {
            tf.setFrameSize(size)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf === textField else { return }
        fitTextField(tf)
        if captionIndex != nil { needsDisplay = true }
    }

    @objc private func textCommitted(_ sender: NSTextField) { commitTextField() }

    /// A marker tool stamps on the first click. When that press turns out to
    /// be the first half of a completion double-click, omit its empty marker.
    func discardEmptyMarker(addedAfter count: Int) {
        guard shapes.count > count, shapes.last?.tool == .marker, captionIsNew,
              captionIndex == shapes.count - 1, let field = textField, field.stringValue.isEmpty else { return }
        textField = nil
        captionIndex = nil
        captionIsNew = false
        field.removeFromSuperview()
        shapes.removeLast()
        _ = undoStack.popLast()          // the stamp's own undo step
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func commitTextField() {
        guard let tf = textField else { return }
        textField = nil
        let str = tf.stringValue
        tf.removeFromSuperview()
        // The committed field held first responder — hand it to the editor so
        // Esc / Enter / ⌘Z keep working instead of falling into the void.
        window?.makeFirstResponder(self)
        needsDisplay = true
        if let idx = captionIndex {
            // Marker caption: empty just means "no caption".
            captionIndex = nil
            let isNew = captionIsNew
            captionIsNew = false
            guard shapes.indices.contains(idx), shapes[idx].text != str else { return }
            if !isNew { recordUndo() }
            shapes[idx].text = str
            return
        }
        if let idx = editingTextIndex {
            editingTextIndex = nil
            guard shapes.indices.contains(idx) else { return }
            let size = tf.font?.pointSize ?? shapes[idx].fontSize
            let color = tf.textColor ?? shapes[idx].color
            if str.isEmpty {
                recordUndo()
                shapes.remove(at: idx)
                selectedID = nil
            } else if str != shapes[idx].text || size != shapes[idx].fontSize || color != shapes[idx].color {
                recordUndo()
                shapes[idx].text = str
                shapes[idx].fontSize = size
                shapes[idx].color = color
            }
            return
        }
        guard !str.isEmpty else { return }
        recordUndo()
        shapes.append(Shape(tool: .text, color: tf.textColor ?? currentColor,
                            width: currentWidth, start: textAnchor, end: textAnchor,
                            text: str, fontSize: tf.font?.pointSize ?? 18))
    }

    // MARK: Marker (numbered badge)

    private func markerRadius(for width: CGFloat) -> CGFloat { 10 + width * 1.3 }
    private func captionFontSize(for textSize: CGFloat) -> CGFloat { (textSize * 0.8).rounded() }

    private func captionAttributes(for s: Shape) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: s.fontSize, weight: .semibold),
         .foregroundColor: AnnotationEditorView.contrastingText(on: s.color)]
    }

    /// White or near-black, whichever reads on `fill`. White is preferred
    /// while it keeps ≥ 3:1 contrast (bold caption text), so red and blue tags
    /// get white text like the number badges; orange, yellow and green get
    /// dark text, where white would drop to ~2:1.
    static func contrastingText(on fill: NSColor) -> NSColor {
        guard let c = fill.usingColorSpace(.sRGB) else { return .white }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        let whiteContrast = 1.05 / (lum + 0.05)
        return whiteContrast >= 3 ? .white : NSColor(white: 0.11, alpha: 1)
    }

    /// Rounded pill behind a marker caption, centred on `end`.
    private func captionPill(for s: Shape) -> CGRect {
        let size = (s.text as NSString).size(withAttributes: captionAttributes(for: s))
        let w = size.width + 12, h = size.height + 4
        return CGRect(x: s.end.x - w / 2, y: s.end.y - h / 2, width: w, height: h)
    }

    /// Default caption spot: up and to the right of the badge, mirrored when
    /// that would leave the crop, so there's room for a visible leader line.
    private func defaultCaptionCenter(for p: CGPoint, radius r: CGFloat) -> CGPoint {
        let area = cropRect ?? bounds
        var dx = r + 46, dy = -(r + 22)
        if p.x + dx + 50 > area.maxX { dx = -dx }
        if p.y + dy - 14 < area.minY { dy = -dy }
        return CGPoint(x: p.x + dx, y: p.y + dy)
    }

    /// Stamps the next numbered badge at `p` and opens a small field beside it
    /// for an optional caption (iShot 标号: click → 1, 2, 3…).
    private func stampMarker(at p: CGPoint) {
        let next = (shapes.lazy.filter { $0.tool == .marker }.map { $0.number }.max() ?? 0) + 1
        let center = defaultCaptionCenter(for: p, radius: markerRadius(for: currentWidth))
        var s = Shape(tool: .marker, color: currentColor, width: currentWidth,
                      start: p, end: center, fontSize: captionFontSize(for: currentTextSize))
        s.number = next
        recordUndo()
        shapes.append(s)
        needsDisplay = true
        beginCaption(for: shapes.count - 1, isNew: true)
    }

    private func beginCaption(for index: Int, isNew: Bool) {
        captionIndex = index
        captionIsNew = isNew
        let s = shapes[index]
        let tf = makeInlineField(font: .systemFont(ofSize: s.fontSize, weight: .semibold),
                                 placeholder: L10n.tr("Caption (optional)", "编号说明（可留空）"),
                                 filled: true, color: s.color)
        tf.alignment = .center
        tf.stringValue = s.text
        textField = tf
        fitTextField(tf)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        needsDisplay = true
    }

    /// Thin leader from the badge to its caption: leaves the badge radially and
    /// eases into the side of the caption pill that faces the badge, so the
    /// path reads as one smooth stroke wherever the caption is dragged.
    private func leaderPath(from c: CGPoint, radius r: CGFloat, to pill: CGRect) -> NSBezierPath? {
        guard !pill.insetBy(dx: -r, dy: -r).contains(c) else { return nil }

        let end: CGPoint
        let endTangent: CGPoint                  // direction the curve arrives in
        if c.x < pill.minX - 4 {
            end = CGPoint(x: pill.minX, y: pill.midY); endTangent = CGPoint(x: 1, y: 0)
        } else if c.x > pill.maxX + 4 {
            end = CGPoint(x: pill.maxX, y: pill.midY); endTangent = CGPoint(x: -1, y: 0)
        } else if c.y < pill.minY {
            end = CGPoint(x: pill.midX, y: pill.minY); endTangent = CGPoint(x: 0, y: 1)
        } else {
            end = CGPoint(x: pill.midX, y: pill.maxY); endTangent = CGPoint(x: 0, y: -1)
        }
        let vx = end.x - c.x, vy = end.y - c.y
        let len = hypot(vx, vy)
        guard len > r + 4 else { return nil }
        let ux = vx / len, uy = vy / len
        let start = CGPoint(x: c.x + ux * r, y: c.y + uy * r)
        let d = len - r
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end,
                   controlPoint1: CGPoint(x: start.x + ux * d * 0.35, y: start.y + uy * d * 0.35),
                   controlPoint2: CGPoint(x: end.x - endTangent.x * d * 0.45, y: end.y - endTangent.y * d * 0.45))
        return path
    }

    // MARK: Mosaic / blur

    /// Baked pixels for a mosaic or blur shape, re-baked whenever the shape
    /// covers a different spot (move, undo).
    private func effectImage(for s: Shape) -> CGImage? {
        let r = s.rect.intersection(bounds)
        if let cached = effectCache[s.id], cached.rect == r { return cached.image }
        guard let image = bakeEffect(s.tool, in: r) else { return nil }
        effectCache[s.id] = (r, image)
        return image
    }

    private func bakeEffect(_ tool: ShapeTool, in r: CGRect) -> CGImage? {
        guard r.width >= 4, r.height >= 4, let src = baseCGImage else { return nil }
        // View points (flipped) → image pixels (top-left origin already matches flipped view).
        let px = CGRect(x: r.origin.x * scale, y: r.origin.y * scale,
                        width: r.width * scale, height: r.height * scale)
        guard let crop = src.cropping(to: px) else { return nil }
        if tool == .blur {
            let input = CIImage(cgImage: crop)
            let output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(10 * scale))
                .cropped(to: input.extent)
            return Self.ciContext.createCGImage(output, from: input.extent)
        }
        let block: Int = 12
        let smallW = max(1, Int(px.width) / block)
        let smallH = max(1, Int(px.height) / block)
        guard let ctx = CGContext(data: nil, width: smallW, height: smallH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        return ctx.makeImage()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawsBaseImage { baseImage.draw(in: bounds) }
        for (i, shape) in shapes.enumerated() where i != editingTextIndex || textField == nil {
            draw(shape, index: i)
        }
        if let draft { draw(draft, index: -1) }
        if !flattening, let i = selectedIndex, i != editingTextIndex || textField == nil {
            drawSelectionOutline(around: selectionBounds(of: shapes[i]))
        }
    }

    /// Dashed outline around the selected annotation (screen only, never exported).
    private func drawSelectionOutline(around rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemBlue.setStroke()
        path.stroke()
    }

    private func draw(_ s: Shape, index: Int) {
        switch s.tool {
        case .line, .arrow:
            s.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.move(to: s.start)
            path.line(to: s.end)
            path.stroke()
            if s.tool == .arrow { drawArrowhead(from: s.start, to: s.end, color: s.color, width: s.width) }

        case .pen, .highlighter:
            guard let first = s.points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = strokeWidth(of: s)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if s.points.count == 1 {
                path.line(to: first)
            } else {
                for p in s.points.dropFirst() { path.line(to: p) }
            }
            // One stroke for the whole path, so overlapping highlighter
            // segments don't stack up darker.
            (s.tool == .highlighter ? s.color.withAlphaComponent(0.35) : s.color).setStroke()
            path.stroke()

        case .rect:
            s.color.setStroke()
            let path = NSBezierPath(rect: s.rect)
            path.lineWidth = s.width
            path.stroke()

        case .ellipse:
            s.color.setStroke()
            let path = NSBezierPath(ovalIn: s.rect)
            path.lineWidth = s.width
            path.stroke()

        case .marker:
            let r = markerRadius(for: s.width)
            let center = s.start
            // While its caption field is open the leader runs to the field.
            var target: CGRect?
            if index >= 0, index == captionIndex, let tf = textField {
                target = tf.frame
            } else if !s.text.isEmpty {
                target = captionPill(for: s)
            }
            if let target, let leader = leaderPath(from: center, radius: r, to: target) {
                s.color.withAlphaComponent(0.85).setStroke()
                leader.lineWidth = 1.2
                leader.lineCapStyle = .round
                leader.stroke()
            }
            if !s.text.isEmpty, !(index >= 0 && index == captionIndex && textField != nil) {
                let pill = captionPill(for: s)
                // Tag in the annotation colour, like the number badge: no
                // bright white block on the screenshot.
                s.color.withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                let size = (s.text as NSString).size(withAttributes: captionAttributes(for: s))
                drawString(s.text as NSString,
                           at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
                           attrs: captionAttributes(for: s))
            }
            let rect = NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            s.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            let num = "\(s.number)" as NSString
            let nattrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.05, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let nsize = num.size(withAttributes: nattrs)
            drawString(num, at: NSPoint(x: center.x - nsize.width / 2, y: center.y - nsize.height / 2),
                       attrs: nattrs)

        case .mosaic, .blur:
            if index >= 0, let cg = effectImage(for: s),
               let ctx = NSGraphicsContext.current?.cgContext {
                // Both targets (the flipped overlay view and the flatten bitmap)
                // run y-down CTMs; CGImage drawing doesn't compensate, so
                // un-flip locally. NSImage.draw(in:from:) proved unreliable here.
                let r = s.rect.intersection(bounds)
                ctx.saveGState()
                ctx.interpolationQuality = s.tool == .mosaic ? .none : .default
                ctx.translateBy(x: r.minX, y: r.minY + r.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                ctx.restoreGState()
            } else {
                // Live draft: cheap placeholder until the mouse is released.
                NSColor.gray.withAlphaComponent(0.6).setFill()
                s.rect.fill()
            }

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: s.fontSize, weight: .medium),
                .foregroundColor: s.color
            ]
            drawString(s.text as NSString, at: s.start, attrs: attrs)
        }
    }

    private func drawArrowhead(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let len: CGFloat = 10 + width * 1.6
        let spread: CGFloat = .pi / 7
        color.setStroke()
        let head = NSBezierPath()
        head.lineWidth = width
        head.lineCapStyle = .round
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - len * cos(angle - spread), y: end.y - len * sin(angle - spread)))
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - len * cos(angle + spread), y: end.y - len * sin(angle + spread)))
        head.stroke()
    }

    // MARK: Flatten

    /// Renders base image + annotations into a single NSImage at native pixels.
    /// The view draws in flipped (top-left-origin) coordinates, so the bitmap
    /// context gets the matching transform; image/text drawing self-compensates
    /// for flipped *views* only, so those paths un-flip locally (`flattening`).
    /// When `cropRect` is set, only that region (view coords) is exported.
    func flattenedImage() -> NSImage {
        commitTextField()
        let crop = cropRect ?? NSRect(origin: .zero, size: baseImage.size)
        let pointSize = crop.size
        let pxW = Int((pointSize.width * scale).rounded())
        let pxH = Int((pointSize.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return baseImage
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        // View points (y-down) → bitmap pixels (y-up): translate by the pixel
        // height (not points — that bug mirrored and shifted the output).
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        flattening = true
        drawImageUpright(baseImage, in: NSRect(origin: .zero, size: baseImage.size))
        for (i, shape) in shapes.enumerated() { draw(shape, index: i) }
        flattening = false
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: pointSize)
        img.addRepresentation(rep)
        return img
    }
}

/// Inline annotation input: draws its own 1 px rounded outline (and optional
/// fill) so free-text and caption fields look identical, independent of the
/// bezel/layer styling AppKit applies to text fields.
private final class InlineTextField: NSTextField {
    var isFilled = false
    var fillColor: NSColor = .clear
    var outlineColor: NSColor = .clear

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        fillColor.setFill()
        path.fill()
        outlineColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }
}
