import AppKit
import CoreGraphics
import UserNotifications

/// Glue between the menu-bar UI, permissions, the area picker, and the recorder.
@MainActor
final class AppCoordinator: NSObject {
    static let shared = AppCoordinator()

    private let controller = RecordingController.shared

    private override init() {
        super.init()
        controller.onFinished = { [weak self] url in
            self?.handleFinished(url)
        }
    }

    /// Verify screen-recording permission, prompting / deep-linking as needed.
    func ensureScreenPermission(_ completion: @escaping (Bool) -> Void) {
        if PermissionsManager.hasScreenRecordingPermission() {
            completion(true)
            return
        }
        // Triggers the system prompt on first run.
        PermissionsManager.requestScreenRecordingPermission()
        Task {
            let ok = await PermissionsManager.verifyScreenRecordingPermission()
            if !ok {
                self.presentPermissionAlert()
            }
            completion(ok)
        }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "iRecord needs Screen Recording access to capture your screen. Enable it in System Settings, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.openScreenRecordingSettings()
        }
    }

    // MARK: Flows

    func startAreaSelection() {
        ensureScreenPermission { [weak self] granted in
            guard granted, let self else { return }
            AreaSelectionController.shared.begin(onConfirm: { globalRect, displayID in
                let sourceRect = ScreenInfo.sourceRect(forGlobalRect: globalRect, displayID: displayID)
                self.controller.startRecording(target: .area(displayID: displayID, rect: sourceRect))
            }, onCancel: {}, onWindowMode: { [weak self] in
                self?.presentWindowPickerMenu()
            })
        }
    }

    /// Pops up a list of capturable windows (used by the area picker's window
    /// button). Selecting one starts a window recording.
    func presentWindowPickerMenu() {
        Task {
            let windows = await self.fetchWindows()
            let menu = NSMenu()
            if windows.isEmpty {
                menu.addItem(withTitle: "No capturable windows", action: nil, keyEquivalent: "")
            }
            for w in windows {
                let item = NSMenuItem(title: "\(w.appName) — \(w.title)",
                                      action: #selector(self.windowMenuPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: w.id)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func windowMenuPicked(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        controller.startRecording(target: .window(windowID: CGWindowID(num.uint32Value)))
    }

    func startDisplayRecording(_ displayID: CGDirectDisplayID) {
        ensureScreenPermission { [weak self] granted in
            guard granted else { return }
            self?.controller.startRecording(target: .display(displayID: displayID))
        }
    }

    func startWindowRecording(_ windowID: CGWindowID) {
        ensureScreenPermission { [weak self] granted in
            guard granted else { return }
            self?.controller.startRecording(target: .window(windowID: windowID))
        }
    }

    /// Fetches the capturable window list (after confirming screen permission).
    func fetchWindows() async -> [WindowInfo] {
        let granted: Bool = await withCheckedContinuation { cont in
            ensureScreenPermission { cont.resume(returning: $0) }
        }
        guard granted else { return [] }
        return await ScreenInfo.windows()
    }

    /// Presents a folder picker for the save directory.
    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where iRecord saves recordings"
        panel.directoryURL = controller.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.outputDirectory = url
        }
    }

    // MARK: Finished

    private func handleFinished(_ url: URL) {
        // Open the Kap-style editor where the user picks output params and exports.
        EditorPresenter.shared.present(
            sourceURL: url,
            defaultDirectory: controller.outputDirectory,
            captureFPS: controller.captureFPS,
            onExported: { [weak self] finalURL in
                self?.controller.noteExported(finalURL)
                self?.postNotification(url: finalURL)
            })
    }

    private func postNotification(url: URL) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Recording Saved"
            content.body = url.lastPathComponent
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
