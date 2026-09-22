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
        alert.messageText = L10n.tr("Screen Recording Permission Needed", "需要屏幕录制权限")
        alert.informativeText = L10n.tr(
            "iRecord needs Screen Recording access to capture your screen. Enable it in System Settings, then try again.",
            "iRecord 需要屏幕录制权限才能采集画面。请在系统设置中开启后重试。")
        alert.addButton(withTitle: L10n.tr("Open System Settings", "打开系统设置"))
        alert.addButton(withTitle: L10n.tr("Cancel", "取消"))
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

    /// The area picker's window button uses the same searchable window picker
    /// as the menu-bar panel and the window-recording shortcut.
    func presentWindowPickerMenu() {
        AppDelegate.shared?.showWindowPicker()
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
        panel.prompt = L10n.tr("Choose", "选择")
        panel.message = L10n.tr("Choose where iRecord saves recordings", "选择 iRecord 保存录制的位置")
        panel.directoryURL = controller.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.outputDirectory = url
        }
    }

    func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Choose", "选择")
        panel.message = L10n.tr("Choose where iRecord saves screenshots", "选择 iRecord 保存截图的位置")
        panel.directoryURL = controller.screenshotDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.screenshotDirectory = url
        }
    }

    /// Install the bundled tool for this user; no administrator privileges.
    func installCommandLineTool(uninstall: Bool = false) {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/irecord")
        Task {
            let result: (Bool, String) = await Task.detached {
                let process = Process()
                process.executableURL = executable
                process.arguments = [uninstall ? "uninstall" : "install"]
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
                } catch { return (false, error.localizedDescription) }
            }.value
            let alert = NSAlert()
            controller.uiRefresh.toggle()
            alert.messageText = result.0 ? (uninstall ? "命令行工具已卸载" : "命令行工具已安装") : "命令行工具操作失败"
            alert.informativeText = uninstall && result.0 ? "App 和已有录屏保持不变。" : result.0
                ? "打开新的终端即可使用 irecord。\n\n快速检查：irecord status --json\n卸载命令：irecord uninstall\n\n安装在 ~/.local/bin，无需管理员权限。"
                : result.1
            alert.runModal()
        }
    }

    // MARK: Finished

    private func handleFinished(_ url: URL) {
        if AutomationController.shared.acceptFinished(url) { return }
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
            content.title = L10n.tr("Recording Saved", "录制已保存")
            content.body = url.lastPathComponent
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
