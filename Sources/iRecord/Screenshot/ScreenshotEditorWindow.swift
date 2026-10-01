import AppKit

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
    case rect, ellipse, arrow, line, marker, mosaic, text

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .marker: return "1.circle"
        case .mosaic: return "square.grid.3x3"
        case .text: return "textformat"
        }
    }
    var tip: String {
        switch self {
        case .rect: return L10n.tr("Rectangle", "矩形")
        case .ellipse: return L10n.tr("Ellipse", "椭圆")
        case .arrow: return L10n.tr("Arrow", "箭头")
        case .line: return L10n.tr("Line", "直线")
        case .marker: return L10n.tr("Marker (stamp 1, 2, 3…)", "标号 (依次标记 1、2、3…)")
        case .mosaic: return L10n.tr("Mosaic", "马赛克")
        case .text: return L10n.tr("Text", "文字")
        }
    }
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

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

// MARK: - Chrome (toolbar + canvas)

private final class EditorChromeView: NSView {
    let editor: AnnotationEditorView
    private let toolbar: ShotToolbarView
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
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)

        let tbSize = toolbar.fittingSize
        for v in [bar, scroll, toolbar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(bar)
        addSubview(scroll)
        bar.addSubview(toolbar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            toolbar.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            toolbar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            toolbar.widthAnchor.constraint(equalToConstant: tbSize.width),
            toolbar.heightAnchor.constraint(equalToConstant: tbSize.height),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        editor.onToolChanged = { [weak self] tool in self?.toolbar.highlightTool(tool) }
    }
    required init?(coder: NSCoder) { fatalError() }

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

    let baseImage: NSImage
    /// nil = no tool active: the view ignores mouse events (the overlay beneath
    /// keeps handling selection) until the user picks a tool on the strip.
    var currentTool: ShapeTool? = nil { didSet { onToolChanged?(currentTool); window?.invalidateCursorRects(for: self) } }
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = widths[1]
    /// Small / medium / large text sizes offered by the colour palette.
    static let textSizes: [CGFloat] = [14, 20, 30]
    var currentTextSize: CGFloat = 20 {
        didSet {
            guard let field = textField else { return }
            if let idx = captionIndex, shapes.indices.contains(idx) {
                shapes[idx].fontSize = captionFontSize(for: currentTextSize)
                field.font = .systemFont(ofSize: shapes[idx].fontSize, weight: .semibold)
            } else {
                field.font = .systemFont(ofSize: currentTextSize, weight: .medium)
            }
            fitTextField(field)
            needsDisplay = true
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
    /// Cached pixelated crops for mosaic shapes (index → image).
    private var mosaicCache: [Int: NSImage] = [:]
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    /// Index of the marker shape its caption field is editing, if any.
    private var captionIndex: Int?
    /// Move session: index of the shape being dragged and the grab offset.
    private var movingIndex: Int?
    private var moveGrabOffset: CGPoint = .zero
    /// True when the drag grabbed a marker's caption: only the caption moves
    /// (the leader line follows), the numbered badge stays put.
    private var movingCaption = false
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
            let size = (shape.text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: shape.fontSize, weight: .medium)
            ])
            let rect = CGRect(origin: shape.start, size: size).insetBy(dx: -6, dy: -6)
                .intersection(interior)
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

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextField()
        let p = clampToCrop(convert(event.locationInWindow, from: nil))
        guard let tool = currentTool else { return }
        // Press on an existing annotation moves it (topmost wins) — committed
        // text/markers/shapes can be repositioned without re-drawing.
        if let idx = shapes.indices.reversed().first(where: { hit(shape: shapes[$0], at: p) }) {
            movingIndex = idx
            movingCaption = hitCaption(of: shapes[idx], at: p)
            NSCursor.closedHand.set()
            let anchor = movingCaption ? shapes[idx].end : shapes[idx].start
            moveGrabOffset = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
            return
        }
        if tool == .text {
            beginText(at: p)
            return
        }
        if tool == .marker {
            stampMarker(at: p)
            return
        }
        draft = Shape(tool: tool, color: currentColor, width: currentWidth,
                      start: p, end: p,
                      fontSize: fontSizeForWidth(currentWidth))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let idx = movingIndex {
            NSCursor.closedHand.set()
            let p = clampToCrop(convert(event.locationInWindow, from: nil))
            if movingCaption {
                shapes[idx].end = CGPoint(x: p.x - moveGrabOffset.x, y: p.y - moveGrabOffset.y)
                needsDisplay = true
                return
            }
            let newStart = CGPoint(x: p.x - moveGrabOffset.x, y: p.y - moveGrabOffset.y)
            let dx = newStart.x - shapes[idx].start.x
            let dy = newStart.y - shapes[idx].start.y
            shapes[idx].start.x += dx
            shapes[idx].start.y += dy
            shapes[idx].end.x += dx
            shapes[idx].end.y += dy
            needsDisplay = true
            return
        }
        guard draft != nil else { return }
        draft!.end = clampToCrop(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let idx = movingIndex {
            movingIndex = nil
            movingCaption = false
            window?.invalidateCursorRects(for: self)
            NSCursor.openHand.set()
            // Mosaic pixels belong to the spot they covered — re-bake after a move.
            if shapes[idx].tool == .mosaic {
                mosaicCache[idx] = nil
                bakeMosaic(at: idx)
            }
            return
        }
        guard let d = draft else { return }
        draft = nil
        let meaningful = abs(d.end.x - d.start.x) > 3 || abs(d.end.y - d.start.y) > 3
        if meaningful {
            shapes.append(d)
            if d.tool == .mosaic { bakeMosaic(at: shapes.count - 1) }
        }
        needsDisplay = true
    }

    /// Hit area per tool: filled shapes by their rect, strokes by distance to
    /// the segment, text by its rendered bounds, markers by the badge circle
    /// (plus its caption pill).
    private func hit(shape s: Shape, at p: CGPoint) -> Bool {
        let slop: CGFloat = 6
        switch s.tool {
        case .rect, .ellipse, .mosaic:
            return s.rect.insetBy(dx: -slop, dy: -slop).contains(p)
        case .line, .arrow:
            return distanceToSegment(p, a: s.start, b: s.end) <= slop + s.width / 2
        case .text:
            let size = (s.text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: s.fontSize, weight: .medium)
            ])
            return CGRect(origin: s.start, size: size).insetBy(dx: -slop, dy: -slop).contains(p)
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

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undo()
        } else if event.keyCode == 53 {                 // Esc
            finish(.cancelled)
        } else if event.keyCode == 36 || event.keyCode == 76 {   // Enter → copy
            finish(.copy(flattenedImage()))
        } else if event.keyCode == 49 {                 // Space → save
            finish(.save(flattenedImage()))
        } else if event.charactersIgnoringModifiers?.lowercased() == "t" {
            finish(.pin(flattenedImage()))
        } else {
            super.keyDown(with: event)
        }
    }

    func undo() {
        if !shapes.isEmpty {
            let removed = shapes.removeLast()
            if removed.tool == .mosaic {
                mosaicCache = mosaicCache.filter { $0.key < shapes.count }
            }
            needsDisplay = true
        }
    }

    func finish(_ result: EditorResult) {
        if case .cancelled = result {
            let field = textField
            textField = nil
            captionIndex = nil
            field?.removeFromSuperview()
            window?.makeFirstResponder(self)
        } else {
            commitTextField()
        }
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

    private func fontSizeForWidth(_ w: CGFloat) -> CGFloat {
        w <= AnnotationEditorView.widths[0] ? 14 : (w <= AnnotationEditorView.widths[1] ? 20 : 30)
    }

    private func beginText(at p: CGPoint) {
        textAnchor = p
        let tf = makeInlineField(font: .systemFont(ofSize: currentTextSize, weight: .medium),
                                 placeholder: L10n.tr("Text", "输入文字"))
        tf.setFrameOrigin(p)
        textField = tf
        fitTextField(tf)
        addSubview(tf)
        window?.makeFirstResponder(tf)
    }

    /// Inline editor shared by text and marker captions: a hairline border in
    /// the annotation colour instead of the heavy square bezel.
    private func makeInlineField(font: NSFont, placeholder: String) -> NSTextField {
        let tf = NSTextField(frame: .zero)
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        tf.focusRingType = .none
        tf.font = font
        tf.textColor = currentColor
        tf.placeholderString = placeholder
        tf.wantsLayer = true
        tf.layer?.borderWidth = 1
        tf.layer?.borderColor = currentColor.withAlphaComponent(0.7).cgColor
        tf.layer?.cornerRadius = 3
        tf.target = self
        tf.action = #selector(textCommitted(_:))
        tf.delegate = self
        return tf
    }

    /// Sizes the inline field to its text (placeholder when empty). A caption
    /// field stays centred on its caption anchor.
    private func fitTextField(_ tf: NSTextField) {
        let font = tf.font ?? .systemFont(ofSize: currentTextSize)
        let str = (tf.stringValue.isEmpty ? (tf.placeholderString ?? "") : tf.stringValue) as NSString
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
        guard shapes.count > count, shapes.last?.tool == .marker,
              captionIndex == shapes.count - 1, let field = textField, field.stringValue.isEmpty else { return }
        textField = nil
        captionIndex = nil
        field.removeFromSuperview()
        shapes.removeLast()
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
        if let idx = captionIndex {
            // Marker caption: empty just means "no caption".
            captionIndex = nil
            if !str.isEmpty, shapes.indices.contains(idx) {
                shapes[idx].text = str
                needsDisplay = true
            }
            return
        }
        guard !str.isEmpty else { return }
        shapes.append(Shape(tool: .text, color: tf.textColor ?? currentColor,
                            width: currentWidth, start: textAnchor, end: textAnchor,
                            text: str, fontSize: tf.font?.pointSize ?? 18))
        needsDisplay = true
    }

    // MARK: Marker (numbered badge)

    private func markerRadius(for width: CGFloat) -> CGFloat { 10 + width * 1.3 }
    private func captionFontSize(for textSize: CGFloat) -> CGFloat { (textSize * 0.8).rounded() }

    private func captionAttributes(for s: Shape) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: s.fontSize, weight: .semibold), .foregroundColor: s.color]
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
        shapes.append(s)
        needsDisplay = true
        beginCaption(for: shapes.count - 1)
    }

    private func beginCaption(for index: Int) {
        captionIndex = index
        let tf = makeInlineField(font: .systemFont(ofSize: shapes[index].fontSize, weight: .semibold),
                                 placeholder: L10n.tr("Caption (optional)", "编号说明（可留空）"))
        tf.alignment = .center
        textField = tf
        fitTextField(tf)
        addSubview(tf)
        window?.makeFirstResponder(tf)
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

    // MARK: Mosaic

    /// Pixelates the base-image region covered by a mosaic shape.
    private func bakeMosaic(at index: Int) {
        let shape = shapes[index]
        let r = shape.rect.intersection(bounds)
        guard r.width >= 4, r.height >= 4 else { return }
        guard let src = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // View points (flipped) → image pixels (top-left origin already matches flipped view).
        let px = CGRect(x: r.origin.x * scale, y: r.origin.y * scale,
                        width: r.width * scale, height: r.height * scale)
        guard let crop = src.cropping(to: px) else { return }
        let block: Int = 12
        let smallW = max(1, Int(px.width) / block)
        let smallH = max(1, Int(px.height) / block)
        guard let ctx = CGContext(data: nil, width: smallW, height: smallH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let small = ctx.makeImage() else { return }
        mosaicCache[index] = NSImage(cgImage: small, size: NSSize(width: smallW, height: smallH))
        if ProcessInfo.processInfo.environment["IRECORD_DEBUG"] != nil {
            let rep = NSBitmapImageRep(cgImage: small)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/mosaic_cache_\(index).png"))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawsBaseImage { baseImage.draw(in: bounds) }
        for (i, shape) in shapes.enumerated() { draw(shape, index: i) }
        if let draft { draw(draft, index: -1) }
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
            if !s.text.isEmpty {
                let pill = captionPill(for: s)
                let bg = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
                NSColor.white.withAlphaComponent(0.85).setFill()
                bg.fill()
                s.color.withAlphaComponent(0.7).setStroke()
                bg.lineWidth = 1
                bg.stroke()
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

        case .mosaic:
            if index >= 0, let cached = mosaicCache[index],
               let cg = cached.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let ctx = NSGraphicsContext.current?.cgContext {
                // Both targets (the flipped overlay view and the flatten bitmap)
                // run y-down CTMs; CGImage drawing doesn't compensate, so
                // un-flip locally. NSImage.draw(in:from:) proved unreliable here.
                let r = s.rect.intersection(bounds)
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.translateBy(x: r.minX, y: r.minY + r.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                ctx.restoreGState()
            } else {
                // Live draft: cheap checkerboard placeholder.
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
