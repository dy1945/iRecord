import AppKit
import Vision

/// Runs on a worker queue; the input is always the original frozen selection.
enum ScreenshotOCR {
    private static let queue = DispatchQueue(label: "com.irecord.ocr", qos: .userInitiated)

    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    let supported = try request.supportedRecognitionLanguages()
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    let lines = (request.results ?? []).sorted {
                        if $0.boundingBox.midY == $1.boundingBox.midY {
                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        return $0.boundingBox.midY > $1.boundingBox.midY
                    }.compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class OCRResultController: NSObject, NSWindowDelegate {
    static let shared = OCRResultController()
    private var window: NSWindow?
    private let textView = OCRTextView()
    private let status = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let retryButton = NSButton()
    private var onClose: (() -> Void)?

    func showLoading(onClose: @escaping () -> Void) {
        window?.close()
        self.onClose = onClose
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = L10n.tr("OCR — Extract Text", "OCR — 提取文字")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.minSize = NSSize(width: 360, height: 260)
        let content = NSView()
        win.contentView = content
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.string = ""
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(L10n.tr("Recognized text", "识别文字"))
        scroll.documentView = textView
        textView.undoManager?.removeAllActions()
        status.toolTip = nil
        status.stringValue = L10n.tr("Recognizing…", "正在识别…")
        status.lineBreakMode = .byTruncatingTail
        copyButton.title = L10n.tr("Copy All", "复制全部")
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.isEnabled = false
        retryButton.title = L10n.tr("Select Again", "重新框选")
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(selectAgain)
        retryButton.isHidden = false
        for view in [scroll, status, copyButton, retryButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            retryButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            retryButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor)
        ])
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showResult(_ text: String) {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.string = text
        textView.isEditable = !empty
        copyButton.isEnabled = !empty
        retryButton.isHidden = !empty
        status.stringValue = empty ? L10n.tr("No text recognized", "未识别到文字")
            : L10n.tr("You can edit the text before copying.", "可编辑文字后复制。")
        if !empty {
            window?.level = .normal
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
        }
    }

    func showError(_ error: Error) {
        status.stringValue = L10n.tr("Recognition failed. Please select again.", "识别失败，请重新框选。")
        status.toolTip = error.localizedDescription
        retryButton.isHidden = false
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        status.stringValue = L10n.tr("Copied", "已复制")
    }

    @objc private func selectAgain() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
        window = nil
    }
}

/// The menu-bar app has no Edit menu to route standard editing shortcuts.
private final class OCRTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "v": paste(nil)
        case "x": cut(nil)
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
