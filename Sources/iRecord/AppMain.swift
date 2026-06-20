import AppKit
import SwiftUI
import Combine

/// App entry point. iRecord is a menu-bar (accessory) app: no Dock icon, a
/// status item that toggles a SwiftUI popover, and a red indicator while recording.
@main
struct iRecordMain {
    @MainActor
    static func main() {
        // Headless pipeline verification: `iRecord --selftest [seconds] [fps] [codec]`
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest") {
            let rest = Array(CommandLine.arguments[(idx + 1)...])
            SelfTest.run(arguments: rest)
        }

        // Headless export-pipeline check: `iRecord --exporttest [mp4|hevc|mov|gif]`
        if let idx = CommandLine.arguments.firstIndex(of: "--exporttest") {
            let rest = Array(CommandLine.arguments[(idx + 1)...])
            SelfTest.runExport(arguments: rest)
        }

        // Headless window-enumeration check: `iRecord --listwindows`
        if CommandLine.arguments.contains("--listwindows") {
            Task {
                let windows = await ScreenInfo.windows()
                print("[listwindows] found \(windows.count) capturable windows")
                for w in windows.prefix(15) {
                    print("  • \(w.appName) — \(w.title)  [id \(w.id)]")
                }
                exit(windows.isEmpty ? 1 : 0)
            }
            CFRunLoopRun()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        observeState()
        // Touch the coordinator so its onFinished hook is wired up.
        _ = AppCoordinator.shared
        setupGlobalShortcuts()
    }

    /// Registers global hotkeys and routes them to the recorder.
    private func setupGlobalShortcuts() {
        ShortcutManager.shared.onTrigger = { action in
            let controller = RecordingController.shared
            switch action {
            case .toggleAreaRecording:
                if controller.isRecording {
                    controller.stopRecording()
                } else {
                    AppCoordinator.shared.startAreaSelection()
                }
            case .recordFullScreen:
                if controller.isRecording {
                    controller.stopRecording()
                } else {
                    AppCoordinator.shared.startDisplayRecording(CGMainDisplayID())
                }
            case .pauseResume:
                if controller.isRecording { controller.togglePause() }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "iRecord")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: ControlPanelView())
        // Let the popover size itself to the SwiftUI content so it fits the
        // redesigned panel and its variable-height sub-screens.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    private func observeState() {
        // Reflect recording state in the menu-bar icon (red while recording).
        RecordingController.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.applyStatusIcon(for: state)
            }
            .store(in: &cancellables)

        // Live timer in the menu bar while recording, for clear status.
        RecordingController.shared.$elapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] elapsed in
                guard let button = self?.statusItem.button else { return }
                if RecordingController.shared.isRecording {
                    let total = Int(elapsed)
                    button.title = String(format: " %02d:%02d", total / 60, total % 60)
                } else {
                    button.title = ""
                }
            }
            .store(in: &cancellables)
    }

    /// Builds a coloured SF Symbol so the recording state is unmistakably red.
    private func applyStatusIcon(for state: RecorderState) {
        guard let button = statusItem.button else { return }

        func coloredSymbol(_ name: String, _ color: NSColor) -> NSImage? {
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "iRecord")
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(hierarchicalColor: color))
            let colored = img?.withSymbolConfiguration(config)
            colored?.isTemplate = false   // keep the colour (don't auto-tint to menu-bar colour)
            return colored
        }

        switch state {
        case .recording, .preparing, .finishing:
            button.image = coloredSymbol("record.circle.fill", .systemRed)
        case .paused:
            button.image = coloredSymbol("pause.circle.fill", .systemOrange)
        default:
            let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "iRecord")
            img?.isTemplate = true        // adapts to light/dark menu bar when idle
            button.image = img
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
