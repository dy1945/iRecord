import AppKit
import QuartzCore

/// Draws an animated ripple at every mouse click while recording, so taps are
/// visible in the captured video. The overlay windows sit above all content but
/// are click-through (`ignoresMouseEvents`), and because we capture the whole
/// display the ripples are composited into the recording naturally.
///
/// Clicks are observed with a global `NSEvent` monitor (mouse-down monitoring
/// does not require Accessibility permission).
@MainActor
final class ClickHighlighter {
    static let shared = ClickHighlighter()

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var monitor: Any?
    private var isActive = false

    private init() {}

    func start() {
        guard !isActive else { return }
        isActive = true

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let window = makeOverlay(for: screen)
            window.orderFrontRegardless()
            windows[id] = window
        }

        // Global monitor: clicks anywhere on screen.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // event.locationInWindow is in global screen coords for global monitors.
            let global = NSEvent.mouseLocation
            Task { @MainActor in
                self?.ripple(at: global)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - Overlay window

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        return window
    }

    private func ripple(at globalPoint: CGPoint) {
        // Find the screen / overlay containing the click.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalPoint) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let window = windows[CGDirectDisplayID(number.uint32Value)],
              let host = window.contentView?.layer else { return }

        // Convert to window/view-local (view origin == screen origin).
        let local = CGPoint(x: globalPoint.x - screen.frame.origin.x,
                            y: globalPoint.y - screen.frame.origin.y)

        let diameter: CGFloat = 44
        let circle = CAShapeLayer()
        let rect = CGRect(x: local.x - diameter/2, y: local.y - diameter/2, width: diameter, height: diameter)
        circle.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)), transform: nil)
        circle.frame = rect
        circle.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        circle.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        circle.lineWidth = 2
        host.addSublayer(circle)

        // Expand + fade, then remove.
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            circle.removeFromSuperlayer()
        }
        circle.opacity = 0
        circle.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}
