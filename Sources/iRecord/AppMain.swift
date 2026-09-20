import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    /// Posted when the "record window" hotkey fires: the panel opens its window
    /// picker sub-screen.
    static let iRecordShowWindowPicker = Notification.Name("iRecordShowWindowPicker")
}

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

        if CommandLine.arguments.contains("--windowflowtest") {
            SelfTest.runWindowFlow()
        }

        if CommandLine.arguments.contains("--ocrtest") || CommandLine.arguments.contains("--ocrtest-ui") {
            SelfTest.runOCR(showWindow: CommandLine.arguments.contains("--ocrtest-ui"))
        }

        // Headless stitch-engine check: `iRecord --stitchtest`
        if CommandLine.arguments.contains("--stitchtest") {
            SelfTest.runStitch()
        }

        // Headless still-screenshot check: `iRecord --shottest`
        if CommandLine.arguments.contains("--shottest") {
            SelfTest.runShot()
        }

        if CommandLine.arguments.contains("--cursortest") {
            SelfTest.runShotCursor()
        }

        // Headless annotation-toolbar check: `iRecord --toolbartest`
        // Renders the merged screenshot toolbar plus a canvas with stamped
        // markers / an arrow / a rect in a small floating window, then prints
        // its window number so CI can `screencapture -l <n>` it.
        if CommandLine.arguments.contains("--toolbartest") {
            SelfTest.runToolbar()
        }

        // Headless settings-window check: `iRecord --settingstest [tab]`
        // Opens the settings window (optionally on a tab) and prints its window
        // number so CI can `screencapture -l <n>` it without synthetic input.
        if let idx = CommandLine.arguments.firstIndex(of: "--settingstest") {
            let tabName = idx + 1 < CommandLine.arguments.count ? CommandLine.arguments[idx + 1] : nil
            let tab = tabName.flatMap { SettingsTab(rawValue: $0) }
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    SettingsWindowController.shared.show(tab: tab)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if let win = SettingsWindowController.shared.window {
                        print("[settingstest] windowNumber=\(win.windowNumber) frame=\(win.frame)")
                        fflush(stdout)
                    }
                }
            }
            app.run()
            exit(0)
        }

        // Headless panel check: `iRecord --paneltest` — opens the popover so CI
        // can grab it via `screencapture -l` without synthetic input.
        if CommandLine.arguments.contains("--paneltest") {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    AppDelegate.shared?.openPopover()
                }
            }
            app.run()
            exit(0)
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

    /// Lets feature controllers close the panel before capturing the screen.
    private(set) static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        setupStatusItem()
        setupPopover()
        observeState()
        // Touch the coordinator so its onFinished hook is wired up.
        _ = AppCoordinator.shared
        AutomationController.shared.startServer()
        setupGlobalShortcuts()
    }

    /// Closes the status-item popover immediately (no animation) so it does
    /// not end up inside the frozen screenshot frame.
    func closePopover() {
        if popover.isShown { popover.close() }
    }

    /// Opens the status-item popover (no-op when already shown).
    func openPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
            case .recordWindow:
                if controller.isRecording {
                    controller.stopRecording()
                } else {
                    // Open the panel and switch it to the window-picker sub-screen.
                    self.openPopover()
                    NotificationCenter.default.post(name: .iRecordShowWindowPicker, object: nil)
                }
            case .pauseResume:
                if controller.isRecording { controller.togglePause() }
            case .screenshotArea:
                ScreenshotController.shared.startRegionCapture()
            case .screenshotScrolling:
                ScreenshotController.shared.startScrollingCapture()
            case .screenshotFullScreen:
                ScreenshotController.shared.captureFullScreen()
            case .pinFromClipboard:
                PinWindowController.shared.pinFromClipboard()
            case .togglePins:
                PinWindowController.shared.togglePinsHidden()
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
