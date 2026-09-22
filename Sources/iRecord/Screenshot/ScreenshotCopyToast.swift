import AppKit

/// A brief, non-interactive confirmation shown after a screenshot is copied.
@MainActor
final class ScreenshotCopyToast {
    static let shared = ScreenshotCopyToast()
    static let displayDuration: TimeInterval = 1.3

    private(set) var panel: NSPanel?
    private var dismissalTask: Task<Void, Never>?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func show(message: String? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }

        dismissalTask?.cancel()
        let content = ScreenshotCopyToastView(
            message: message ?? L10n.tr("Copied to Clipboard", "已复制到剪贴板"),
            maximumWidth: max(1, screen.visibleFrame.width - 24)
        )
        let toast: NSPanel
        if let panel {
            toast = panel
        } else {
            toast = ScreenshotCopyToastPanel(contentRect: .zero,
                                             styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
            toast.isReleasedWhenClosed = false
            toast.isOpaque = false
            toast.backgroundColor = .clear
            toast.hasShadow = true
            toast.level = .statusBar
            toast.hidesOnDeactivate = false
            toast.ignoresMouseEvents = true
            toast.isMovable = false
            toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel = toast
        }
        let size = content.frame.size
        toast.setFrame(Self.frame(for: size, in: screen.visibleFrame), display: true)
        toast.contentView = content
        // Ordering the nonactivating panel never makes iRecord or this window key.
        toast.orderFrontRegardless()

        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        panel?.orderOut(nil)
    }

    /// Screen coordinates, including displays whose origins are negative.
    static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return NSRect(x: visibleFrame.midX - width / 2,
                      y: max(visibleFrame.minY, visibleFrame.minY + visibleFrame.height * 0.32 - height / 2),
                      width: width, height: height)
    }
}

private final class ScreenshotCopyToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScreenshotCopyToastView: NSView {
    init(message: String, maximumWidth: CGFloat) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(srgbRed: 0.10, green: 0.36, blue: 0.19, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.sizeToFit()

        let width = min(maximumWidth, max(180, ceil(label.frame.width) + 60))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.90, green: 0.97, blue: 0.92, alpha: 1).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(srgbRed: 0.53, green: 0.78, blue: 0.59, alpha: 0.8).cgColor

        let icon = NSImageView(frame: NSRect(x: 15, y: 13, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(srgbRed: 0.16, green: 0.60, blue: 0.31, alpha: 1)
        addSubview(icon)

        label.frame = NSRect(x: 43, y: (46 - label.frame.height) / 2,
                             width: max(0, width - 58), height: label.frame.height)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
