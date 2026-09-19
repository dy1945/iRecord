import AppKit

/// Annotation editor for screenshots — iShot's 截屏编辑 as a dedicated window.
///
/// Tools: pen · line · arrow · rectangle · ellipse · mosaic (pixel-block) ·
/// text · local highlight. 5 preset colours + custom well, 3 stroke widths,
/// ⌘Z undo. Output: Save… / Copy / Pin / Cancel — and when opened from a pin,
/// "Update Pin" (iShot's 二次标注: annotations baked back into the pin).
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
    case pen, line, arrow, rect, ellipse, mosaic, text, highlight

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .mosaic: return "square.grid.3x3"
        case .text: return "textformat"
        case .highlight: return "light.max"
        }
    }
    var tip: String {
        switch self {
        case .pen: return L10n.tr("Pen", "画笔")
        case .line: return L10n.tr("Line", "直线")
        case .arrow: return L10n.tr("Arrow", "箭头")
        case .rect: return L10n.tr("Rectangle", "矩形")
        case .ellipse: return L10n.tr("Ellipse", "椭圆")
        case .mosaic: return L10n.tr("Mosaic", "马赛克")
        case .text: return L10n.tr("Text", "文字")
        case .highlight: return L10n.tr("Highlight", "高亮")
        }
    }
}

struct Shape {
    var tool: ShapeTool
    var color: NSColor
    var width: CGFloat            // stroke width (points)
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []    // pen only
    var text: String = ""         // text only
    var fontSize: CGFloat = 18    // text only

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

// MARK: - Chrome (tool strip + canvas + bottom bar)

private final class EditorChromeView: NSView {
    let editor: AnnotationEditorView
    private let showsUpdate: Bool

    init(editor: AnnotationEditorView, showsUpdate: Bool) {
        self.editor = editor
        self.showsUpdate = showsUpdate
        super.init(frame: .zero)

        let top = ToolStrip(editor: editor)
        let bottom = BottomBar(editor: editor, showsUpdate: showsUpdate)
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)

        for v in [top, scroll, bottom] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.heightAnchor.constraint(equalToConstant: 44),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 46)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let img = editor.bounds.size
        let cap = NSScreen.main.map {
            NSSize(width: $0.visibleFrame.width - 120, height: $0.visibleFrame.height - 200)
        } ?? NSSize(width: 900, height: 640)
        return NSSize(width: min(img.width + 2, max(560, cap.width)),
                      height: min(img.height + 92, max(380, cap.height)))
    }
}

// MARK: - Tool strip

private final class ToolStrip: NSView {
    private var buttons: [ShapeTool: NSButton] = [:]

    init(editor: AnnotationEditorView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for tool in ShapeTool.allCases {
            let b = NSButton()
            b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.tip)
            b.toolTip = tool.tip
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .white
            b.target = self
            b.action = #selector(pick(_:))
            b.tag = ShapeTool.allCases.firstIndex(of: tool)!
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            buttons[tool] = b
            stack.addArrangedSubview(b)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        editor.onToolChanged = { [weak self] tool in self?.highlight(tool) }
        highlight(editor.currentTool)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ sender: NSButton) {
        let tool = ShapeTool.allCases[sender.tag]
        (superview as? EditorChromeView)?.editor.currentTool = tool
    }

    private func highlight(_ tool: ShapeTool) {
        for (t, b) in buttons {
            b.contentTintColor = (t == tool) ? .systemRed : .white
        }
    }
}

// MARK: - Bottom bar

private final class BottomBar: NSView {
    private let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue]

    init(editor: AnnotationEditorView, showsUpdate: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        // Colour swatches.
        for (i, color) in presetColors.enumerated() {
            let b = SwatchButton(color: color) { editor.currentColor = color }
            b.tag = i
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            stack.addArrangedSubview(b)
        }
        let well = NSColorWell()
        well.color = editor.currentColor
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 26).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(well)
        self.colorWell = well

        stack.addArrangedSubview(separator())

        // Stroke widths.
        for (i, _) in AnnotationEditorView.widths.enumerated() {
            let b = NSButton(title: ["S", "M", "L"][i], target: self, action: #selector(widthPicked(_:)))
            b.tag = i
            b.isBordered = false
            b.contentTintColor = .white
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(separator())

        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.left", accessibilityDescription: "Undo")!,
                            target: self, action: #selector(undo))
        undo.toolTip = L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")
        undo.isBordered = false
        undo.contentTintColor = .white
        stack.addArrangedSubview(undo)

        stack.addArrangedSubview(NSView()) // spacer
        (stack.arrangedSubviews.last!).setContentHuggingPriority(.defaultLow, for: .horizontal)

        func actionButton(_ title: String, _ symbol: String, _ sel: Selector, prominent: Bool = false) -> NSButton {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                             target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            if prominent { b.bezelColor = .systemRed }
            return b
        }
        stack.addArrangedSubview(actionButton(L10n.tr("Cancel", "取消"), "xmark", #selector(cancel)))
        stack.addArrangedSubview(actionButton(L10n.tr("Pin", "贴图"), "pin", #selector(pin)))
        stack.addArrangedSubview(actionButton(L10n.tr("Copy", "复制"), "doc.on.doc", #selector(copyShot)))
        stack.addArrangedSubview(actionButton(showsUpdate ? L10n.tr("Update Pin", "更新贴图") : L10n.tr("Save…", "保存…"),
                                              showsUpdate ? "checkmark" : "square.and.arrow.down",
                                              #selector(save), prominent: true))

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        self.editor = editor
    }
    required init?(coder: NSCoder) { fatalError() }

    private weak var editor: AnnotationEditorView?
    private weak var colorWell: NSColorWell?

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return v
    }

    @objc private func colorChanged(_ sender: NSColorWell) { editor?.currentColor = sender.color }
    @objc private func widthPicked(_ sender: NSButton) {
        editor?.currentWidth = AnnotationEditorView.widths[sender.tag]
    }
    @objc private func undo() { editor?.undo() }
    @objc private func cancel() { editor?.finish(.cancelled) }
    @objc private func pin() { editor?.finish(.pin(editor!.flattenedImage())) }
    @objc private func copyShot() { editor?.finish(.copy(editor!.flattenedImage())) }
    @objc private func save() { editor?.finish(.save(editor!.flattenedImage())) }
}

private final class SwatchButton: NSButton {
    init(color: NSColor, handler: @escaping () -> Void) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        target = self
        action = #selector(fire)
        self.handler = handler
    }
    required init?(coder: NSCoder) { fatalError() }
    private var handler: (() -> Void)?
    @objc private func fire() { handler?() }
}

// MARK: - Editor canvas

enum EditorResult {
    case save(NSImage), copy(NSImage), pin(NSImage), cancelled
}

final class AnnotationEditorView: NSView {
    static let widths: [CGFloat] = [2.5, 4.5, 8]

    let baseImage: NSImage
    var currentTool: ShapeTool = .rect { didSet { onToolChanged?(currentTool) } }
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = widths[1]
    var onToolChanged: ((ShapeTool) -> Void)?
    var onFinished: ((EditorResult) -> Void)?
    /// In-place mode (screenshot overlay): the frozen screen beneath supplies
    /// the background, so the editor only draws shapes.
    var drawsBaseImage = true
    /// When set (view coords, top-left origin), `flattenedImage()` renders just
    /// this region — the overlay uses it to export the selection only.
    var cropRect: CGRect?

    private(set) var shapes: [Shape] = []
    private var draft: Shape?
    /// Cached pixelated crops for mosaic shapes (index → image).
    private var mosaicCache: [Int: NSImage] = [:]
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
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
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextField()
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .text {
            beginText(at: p)
            return
        }
        draft = Shape(tool: currentTool, color: currentColor, width: currentWidth,
                      start: p, end: p,
                      points: currentTool == .pen ? [p] : [],
                      fontSize: fontSizeForWidth(currentWidth))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draft != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if draft!.tool == .pen {
            draft!.points.append(p)
        } else {
            draft!.end = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = draft else { return }
        draft = nil
        let meaningful = d.tool == .pen ? d.points.count > 2 : (abs(d.end.x - d.start.x) > 3 || abs(d.end.y - d.start.y) > 3)
        if meaningful {
            shapes.append(d)
            if d.tool == .mosaic { bakeMosaic(at: shapes.count - 1) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undo()
        } else if event.keyCode == 53 {                 // Esc
            if textField != nil { commitTextField() } else { finish(.cancelled) }
        } else if event.keyCode == 36 || event.keyCode == 76 {   // Enter → copy
            finish(.copy(flattenedImage()))
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
        commitTextField()
        onFinished?(result)
    }

    // MARK: Text

    private func fontSizeForWidth(_ w: CGFloat) -> CGFloat {
        w <= AnnotationEditorView.widths[0] ? 14 : (w <= AnnotationEditorView.widths[1] ? 20 : 30)
    }

    private func beginText(at p: CGPoint) {
        textAnchor = p
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y, width: 220, height: fontSizeForWidth(currentWidth) + 10))
        tf.isBezeled = true
        tf.bezelStyle = .squareBezel
        tf.font = .systemFont(ofSize: fontSizeForWidth(currentWidth), weight: .medium)
        tf.textColor = currentColor
        tf.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        tf.placeholderString = L10n.tr("Text", "输入文字")
        tf.target = self
        tf.action = #selector(textCommitted(_:))
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
    }

    @objc private func textCommitted(_ sender: NSTextField) { commitTextField() }

    private func commitTextField() {
        guard let tf = textField else { return }
        textField = nil
        let str = tf.stringValue
        tf.removeFromSuperview()
        guard !str.isEmpty else { return }
        shapes.append(Shape(tool: .text, color: tf.textColor ?? currentColor,
                            width: currentWidth, start: textAnchor, end: textAnchor,
                            text: str, fontSize: tf.font?.pointSize ?? 18))
        needsDisplay = true
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
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawsBaseImage { baseImage.draw(in: bounds) }
        for (i, shape) in shapes.enumerated() { draw(shape, index: i) }
        if let draft { draw(draft, index: -1) }
    }

    private func draw(_ s: Shape, index: Int) {
        switch s.tool {
        case .pen:
            s.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if let first = s.points.first {
                path.move(to: first)
                for p in s.points.dropFirst() { path.line(to: p) }
            }
            path.stroke()

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

        case .mosaic:
            if index >= 0, let cached = mosaicCache[index] {
                NSGraphicsContext.current?.imageInterpolation = .none
                cached.draw(in: s.rect.intersection(bounds),
                            from: NSRect(origin: .zero, size: cached.size),
                            operation: .sourceOver, fraction: 1)
                NSGraphicsContext.current?.imageInterpolation = .default
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
            (s.text as NSString).draw(at: s.start, withAttributes: attrs)

        case .highlight:
            // Dim everything except the highlighted rect.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                let path = CGMutablePath()
                path.addRect(bounds)
                path.addRect(s.rect)
                ctx.addPath(path)
                ctx.clip(using: .evenOdd)
                NSColor.black.withAlphaComponent(0.45).setFill()
                bounds.fill()
                ctx.restoreGState()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(rect: s.rect)
                border.lineWidth = 1
                border.stroke()
            }
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
    /// context gets the same transform for identical output. When `cropRect`
    /// is set, only that region (view coords) is exported.
    func flattenedImage() -> NSImage {
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
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: scale, y: -scale)   // flipped view coords, at pixel scale
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        baseImage.draw(in: NSRect(origin: .zero, size: baseImage.size))
        for (i, shape) in shapes.enumerated() { draw(shape, index: i) }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: pointSize)
        img.addRepresentation(rep)
        return img
    }
}
