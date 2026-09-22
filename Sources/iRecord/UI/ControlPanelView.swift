import SwiftUI
import CoreGraphics

/// Menu-bar popover — card-based redesign per the new interaction mockups:
/// header with app icon + status pill, RECORD and SCREENSHOT sections of
/// three action cards each (bilingual title/subtitle), an OPTIONS section
/// (FPS + four toggle cards), and a bottom bar with the Save-to expansion,
/// Reveal in Finder, Settings and Quit. Primary label = system language,
/// subtitle = the other language (via `L10n`).
struct ControlPanelView: View {
    @ObservedObject var controller = RecordingController.shared
    @ObservedObject var shortcuts = ShortcutManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var displays: [DisplayInfo] = ScreenInfo.displays()
    @State private var windowPickerVisible = false
    @State private var saveToVisible = false
    @State private var windows: [WindowInfo] = []
    @State private var loadingWindows = false
    @State private var windowSearch = ""

    private var theme: PanelTheme { PanelTheme.make(dark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if controller.isRecording {
                recordingControls.padding(.top, 4)
            } else if windowPickerVisible {
                windowPicker.padding(.top, 2)
            } else if saveToVisible {
                saveToScreen.padding(.top, 2)
            } else {
                idleContent
            }

            if let err = controller.lastErrorMessage {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
            }

            bottomBar
        }
        .padding(14)
        .frame(width: 372)
        .onReceive(NotificationCenter.default.publisher(for: .iRecordShowWindowPicker)) { _ in
            guard !controller.isRecording else { return }
            openWindowPicker()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("iRecord")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundColor(theme.textPrimary)
                if let appVersion {
                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.textTertiary)
                }
            }

            Spacer(minLength: 6)

            statusPill
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            if controller.isRecording {
                Text(timeString(controller.elapsed))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            } else {
                Text(status.text)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(0.14)))
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var status: (text: String, color: Color) {
        switch controller.state {
        case .preparing: return (L10n.tr("Preparing…", "准备中…"), Color(red: 1, green: 0.62, blue: 0.04))
        case .recording: return (L10n.tr("Recording", "录制中"), Color(red: 1, green: 0.27, blue: 0.227))
        case .paused:    return (L10n.tr("Paused", "已暂停"), Color(red: 1, green: 0.62, blue: 0.04))
        case .finishing: return (L10n.tr("Saving…", "保存中…"), Color(red: 1, green: 0.62, blue: 0.04))
        default:         return (L10n.tr("Ready", "就绪"), Color(red: 0.20, green: 0.78, blue: 0.35))
        }
    }

    // MARK: Idle content — action cards + options

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("RECORD", "录制").padding(.leading, 6)
            HStack(spacing: 10) {
                ActionCard(theme: theme, symbol: "crop",
                           title: L10n.tr("Area", "区域"),
                           shortcut: shortcuts.combo(for: .toggleAreaRecording)?.displayString) {
                    AppCoordinator.shared.startAreaSelection()
                }
                ActionCard(theme: theme, symbol: "macwindow",
                           title: L10n.tr("Window", "窗口"),
                           shortcut: shortcuts.combo(for: .recordWindow)?.displayString) {
                    openWindowPicker()
                }
                ActionCard(theme: theme, symbol: "display",
                           title: L10n.tr("Screen", "整屏"),
                           shortcut: shortcuts.combo(for: .recordFullScreen)?.displayString) {
                    AppCoordinator.shared.startDisplayRecording(displays.first?.id ?? CGMainDisplayID())
                }
            }
            .padding(.top, 8)

            sectionCaption("SCREENSHOT", "截图").padding(.leading, 6).padding(.top, 16)
            HStack(spacing: 10) {
                ActionCard(theme: theme, symbol: "camera.viewfinder",
                           title: L10n.tr("Area", "区域"),
                           shortcut: shortcuts.combo(for: .screenshotArea)?.displayString) {
                    ScreenshotController.shared.startRegionCapture()
                }
                ActionCard(theme: theme, symbol: "rectangle.expand.vertical",
                           title: L10n.tr("Scrolling", "滚动"),
                           shortcut: shortcuts.combo(for: .screenshotScrolling)?.displayString) {
                    ScreenshotController.shared.startScrollingCapture()
                }
                ActionCard(theme: theme, symbol: "pin",
                           title: L10n.tr("Pin", "贴图"),
                           shortcut: shortcuts.combo(for: .pinFromClipboard)?.displayString) {
                    PinWindowController.shared.pinFromClipboard()
                }
            }
            .padding(.top, 8)

            HStack {
                sectionCaption("OPTIONS", "参数").padding(.leading, 6)
                Spacer()
                Text(L10n.tr("Applies to next recording", "录制前生效"))
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.textTertiary)
                    .padding(.trailing, 6)
            }
            .padding(.top, 16)

            HStack {
                Text(L10n.tr("FPS", "帧率"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                FpsSegmented(theme: theme, fps: $controller.captureFPS)
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)

            HStack(spacing: 10) {
                ToggleCard(theme: theme, symbol: "cursorarrow.rays",
                           label: L10n.tr("Cursor", "光标"), isOn: $controller.showsCursor)
                ToggleCard(theme: theme, symbol: "hand.tap",
                           label: L10n.tr("Clicks", "点击"), isOn: $controller.highlightClicks)
                ToggleCard(theme: theme, symbol: "speaker.wave.2",
                           label: L10n.tr("System", "系统声"), isOn: $controller.captureSystemAudio)
                ToggleCard(theme: theme, symbol: "mic",
                           label: L10n.tr("Mic", "麦克风"), isOn: $controller.captureMicrophone) { on in
                    if on { Task { _ = await PermissionsManager.requestMicrophonePermission() } }
                }
            }
            .padding(.top, 10)
        }
    }

    private func sectionCaption(_ en: String, _ zh: String) -> some View {
        Text(L10n.tr(en, zh))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.textPrimary)
    }

    // MARK: Save-to expansion (bottom-bar sub-screen)

    private struct DirCandidate: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let url: URL
    }

    private var saveToScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                backButton(title: L10n.tr("Main Menu", "返回主菜单")) {
                    returnToMainMenu()
                }
                Spacer()
                Text(L10n.tr("Save Location", "保存位置"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)

            sectionCaption("RECORD", "录制").padding(.leading, 6)
            card {
                let dirs = dirCandidates(current: controller.outputDirectory,
                                         defaults: defaultRecordingDirs)
                ForEach(Array(dirs.enumerated()), id: \.element.id) { idx, dir in
                    if idx > 0 { separator(inset: 12) }
                    dirRow(dir, isCurrent: dir.url == controller.outputDirectory) {
                        controller.outputDirectory = dir.url
                    }
                }
                separator(inset: 12)
                actionRow(symbol: "plus",
                          title: L10n.tr("Choose Other Folder…", "选择其他文件夹…")) {
                    AppCoordinator.shared.chooseOutputDirectory()
                }
            }
            .padding(.top, 8)

            HStack {
                sectionCaption("SCREENSHOT", "截图").padding(.leading, 6)
                Spacer()
                Text(L10n.tr("Same as recording", "同录制目录"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Toggle("", isOn: $controller.screenshotUsesRecordingDir)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(red: 0.20, green: 0.78, blue: 0.35))
            }
            .padding(.top, 14)

            card {
                let dirs = dirCandidates(current: controller.screenshotDirectory,
                                         defaults: defaultScreenshotDirs)
                ForEach(Array(dirs.enumerated()), id: \.element.id) { idx, dir in
                    if idx > 0 { separator(inset: 12) }
                    dirRow(dir, isCurrent: !controller.screenshotUsesRecordingDir
                           && dir.url == controller.screenshotDirectory) {
                        controller.screenshotDirectory = dir.url
                    }
                }
                separator(inset: 12)
                actionRow(symbol: "plus",
                          title: L10n.tr("Choose Other Folder…", "选择其他文件夹…")) {
                    AppCoordinator.shared.chooseScreenshotDirectory()
                }
            }
            .padding(.top, 8)
            .opacity(controller.screenshotUsesRecordingDir ? 0.45 : 1)
            .disabled(controller.screenshotUsesRecordingDir)

            card {
                actionRow(symbol: "folder",
                          title: L10n.tr("Reveal in Finder", "在访达中打开")) {
                    NSWorkspace.shared.open(controller.outputDirectory)
                }
                separator(inset: 12)
                actionRow(symbol: "gearshape",
                          title: L10n.tr("More Settings…", "更多设置…"),
                          subtitle: L10n.tr("Naming / Format / Shortcuts", "命名 / 格式 / 快捷键")) {
                    returnToMainMenu()
                    SettingsWindowController.shared.show(tab: .save)
                }
            }
            .padding(.top, 12)

            Text(L10n.tr("Recordings and screenshots each have a folder; deeper options live in Settings.",
                         "录制与截图各有目录，可勾选同一目录；深配置走「更多设置…」"))
                .font(.system(size: 9.5))
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.top, 8)
        }
    }

    private var defaultRecordingDirs: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (L10n.tr("Movies", "影片"), home.appendingPathComponent("Movies")),
            (L10n.tr("Desktop", "桌面"), home.appendingPathComponent("Desktop"))
        ]
    }

    private var defaultScreenshotDirs: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (L10n.tr("Pictures", "图片"), home.appendingPathComponent("Pictures")),
            (L10n.tr("Desktop", "桌面"), home.appendingPathComponent("Desktop"))
        ]
    }

    /// Custom current folder first (when it is not one of the defaults),
    /// then the standard locations, de-duplicated.
    private func dirCandidates(current: URL, defaults: [(String, URL)]) -> [DirCandidate] {
        var result: [DirCandidate] = []
        let isDefault = defaults.contains { $0.1 == current }
        if !isDefault {
            result.append(DirCandidate(name: current.lastPathComponent,
                                       detail: abbreviate(current), url: current))
        }
        for (name, url) in defaults {
            result.append(DirCandidate(name: name, detail: abbreviate(url), url: url))
        }
        return result
    }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func dirRow(_ dir: DirCandidate, isCurrent: Bool,
                        action: @escaping () -> Void) -> some View {
        HoverRow(theme: theme, height: 34, action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundColor(theme.textSecondary)
                Text(dir.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                Text(dir.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func actionRow(symbol: String, title: String, subtitle: String? = nil,
                           action: @escaping () -> Void) -> some View {
        HoverRow(theme: theme, height: 34, action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Window picker (sub-screen)

    private func returnToMainMenu() {
        saveToVisible = false
        windowPickerVisible = false
        windowSearch = ""
    }

    private func openWindowPicker() {
        saveToVisible = false
        windowPickerVisible = true
        windowSearch = ""
        loadingWindows = true
        windows = []
        Task {
            let list = await AppCoordinator.shared.fetchWindows()
            await MainActor.run {
                windows = list
                loadingWindows = false
            }
        }
    }

    private var filteredWindows: [WindowInfo] {
        ScreenInfo.filterWindows(windows, query: windowSearch)
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                backButton { returnToMainMenu() }
                Spacer()
                Text(L10n.tr("Select Window", "选择窗口"))
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(theme.textSecondary)
                Spacer()
                if loadingWindows { ProgressView().controlSize(.small) } else { Color.clear.frame(width: 44, height: 1) }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(theme.textSecondary)
                TextField(L10n.tr("Search app or window title", "搜索应用名或窗口标题"), text: $windowSearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.tr("Search windows", "搜索窗口"))
                if !windowSearch.isEmpty {
                    Button { windowSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Clear search", "清空搜索"))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))

            if !loadingWindows && windows.isEmpty {
                Text(L10n.tr("No capturable windows found.", "未找到可录制的窗口。"))
                    .font(.system(size: 12)).foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 8)
            }

            if !loadingWindows && !windows.isEmpty && filteredWindows.isEmpty {
                Text(L10n.tr("No matching windows.", "没有匹配的窗口。"))
                    .font(.system(size: 12)).foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 8)
            }

            ScrollView {
                card {
                    ForEach(Array(filteredWindows.enumerated()), id: \.element.id) { idx, win in
                        if idx > 0 { separator(inset: 14) }
                        HoverRow(theme: theme, height: 50, action: {
                            windowPickerVisible = false
                            AppCoordinator.shared.startWindowRecording(win.id)
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "macwindow").foregroundColor(theme.textSecondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(win.title).font(.system(size: 13)).foregroundColor(theme.textPrimary).lineLimit(1)
                                    Text(win.appName).font(.system(size: 11)).foregroundColor(theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    // MARK: Recording controls (active state, per mockup 状态A)

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            card {
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    Text(timeString(controller.elapsed))
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                    Text(L10n.tr("recorded", "已录制"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textTertiary)
                    Spacer()
                    Text(Self.formatSize(controller.recordingFileSize))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack(spacing: 10) {
                    Button { controller.stopRecording() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(L10n.tr("Stop & Save", "停止并保存"))
                                .font(.system(size: 13.5, weight: .semibold))
                            if let s = shortcuts.combo(for: .toggleAreaRecording)?.displayString {
                                Text(s)
                                    .font(.system(size: 10, design: .monospaced))
                                    .opacity(0.85)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0.875, green: 0.227, blue: 0.173))
                        )
                    }
                    .buttonStyle(.plain)

                    squareControl(symbol: controller.isPaused ? "play.fill" : "pause.fill",
                                  tip: controller.isPaused ? L10n.tr("Resume", "继续") : L10n.tr("Pause", "暂停")) {
                        controller.togglePause()
                    }
                    .disabled({ if case .preparing = controller.state { return true } else { return false } }())

                    squareControl(symbol: "xmark", tip: L10n.tr("Discard recording", "放弃录制")) {
                        confirmDiscard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Text(sessionChips)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.top, 11)
                    .padding(.bottom, 14)
            }

            HStack(spacing: 10) {
                ActionCard(theme: theme, symbol: "camera.viewfinder",
                           title: L10n.tr("Area", "区域"),
                           shortcut: nil) {}
                ActionCard(theme: theme, symbol: "rectangle.expand.vertical",
                           title: L10n.tr("Scrolling", "滚动"),
                           shortcut: nil) {}
                ActionCard(theme: theme, symbol: "pin",
                           title: L10n.tr("Pin", "贴图"),
                           shortcut: nil) {}
            }
            .disabled(true)
            .opacity(0.35)
            .padding(.top, 12)

            Text(L10n.tr("Other actions and options are greyed out while recording; they return after stop.",
                         "录制期间其余入口与参数置灰，停止后恢复"))
                .font(.system(size: 9.5))
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.top, 8)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private func squareControl(symbol: String, tip: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.textPrimary)
                .frame(width: 44, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.btnBg)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.btnBorder, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var sessionChips: String {
        var parts: [String] = []
        if let info = controller.sessionInfo {
            let size: String
            if let s = info.size {
                size = " \(Int(s.width))×\(Int(s.height))"
            } else {
                size = ""
            }
            switch info.mode {
            case .area:    parts.append(L10n.tr("Area", "区域") + size)
            case .window:  parts.append(L10n.tr("Window", "窗口") + size)
            case .display: parts.append(L10n.tr("Display", "整屏") + size)
            }
        }
        parts.append("\(controller.captureFPS) fps")
        func onOff(_ v: Bool) -> String { L10n.tr(v ? "On" : "Off", v ? "开" : "关") }
        parts.append("\(L10n.tr("Cursor", "光标")) \(onOff(controller.showsCursor))")
        parts.append("\(L10n.tr("Clicks", "点击")) \(onOff(controller.chipsHighlightClicks))")
        parts.append("\(L10n.tr("System", "系统声")) \(onOff(controller.captureSystemAudio))")
        if controller.captureMicrophone {
            parts.append("\(L10n.tr("Mic", "麦克风")) \(onOff(true))")
        }
        return parts.joined(separator: "  ")
    }

    private static func formatSize(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private func confirmDiscard() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Discard this recording?", "要放弃这段录制吗？")
        alert.informativeText = L10n.tr("The captured video will be deleted.", "已录制的内容将被删除。")
        alert.addButton(withTitle: L10n.tr("Discard", "放弃录制"))
        alert.addButton(withTitle: L10n.tr("Keep Recording", "继续录制"))
        if alert.runModal() == .alertFirstButtonReturn {
            controller.cancelRecording()
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if saveToVisible {
                        returnToMainMenu()
                    } else {
                        returnToMainMenu()
                        saveToVisible = true
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                    if saveToVisible {
                        Text(controller.outputDirectory.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                        Text(L10n.tr("Save to", "保存位置"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.textSecondary)
                    } else {
                        Text(L10n.tr("Save to", "保存位置"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Image(systemName: saveToVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.textTertiary)
                }
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.btnBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.btnBorder, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)

            Spacer()

            barIcon("folder", tip: L10n.tr("Reveal in Finder", "在访达中打开")) {
                NSWorkspace.shared.open(controller.outputDirectory)
            }
            barIcon("gearshape", tip: L10n.tr("Settings", "设置")) {
                returnToMainMenu()
                SettingsWindowController.shared.show()
            }
            barIcon("power", tip: L10n.tr("Quit", "退出")) {
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 12)
    }

    private func barIcon(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.btnBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.btnBorder, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: Shared building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 11).fill(theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func separator(inset: CGFloat) -> some View {
        Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, inset)
    }

    private func backButton(title: String = L10n.tr("Back", "返回"),
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13))
            }
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Reusable views

/// A white action card: monochrome icon + title. The bound hotkey (or
/// "not set") only appears as a bottom overlay while hovering.
private struct ActionCard: View {
    let theme: PanelTheme
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(theme.textPrimary)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBgStrong)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            )
            .overlay(RoundedRectangle(cornerRadius: 10).fill(hover ? theme.rowHover : Color.clear))
            .overlay(alignment: .bottom) {
                if hover {
                    Text(shortcut ?? L10n.tr("Not set", "未设置"))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(shortcut == nil ? theme.textTertiary.opacity(0.75) : theme.textSecondary)
                        .lineLimit(1)
                        .padding(.bottom, 3)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.12), value: hover)
    }
}

/// An option toggle card: on = green-tinted fill + green border/text per
/// design, off = neutral gray fill with a constant light border.
private struct ToggleCard: View {
    let theme: PanelTheme
    let symbol: String
    let label: String
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil
    @State private var hover = false

    var body: some View {
        Button {
            isOn.toggle()
            onChange?(isOn)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isOn ? theme.toggleOnFg : theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? theme.toggleOnBg : theme.toggleOffBg)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isOn ? theme.toggleOnBorder : theme.toggleOffBorder,
                                      lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

/// A tappable row with a hover highlight.
private struct HoverRow<Content: View>: View {
    let theme: PanelTheme
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover ? theme.rowHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The sliding 30/60 FPS segmented control, compact edition.
private struct FpsSegmented: View {
    let theme: PanelTheme
    @Binding var fps: Int

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7).fill(theme.track)
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.pill)
                .frame(width: 48, height: 20)
                .shadow(color: .black.opacity(0.14), radius: 1, x: 0, y: 1)
                .offset(x: fps == 60 ? 54 : 2)
                .animation(.easeInOut(duration: 0.2), value: fps)
            HStack(spacing: 0) {
                segment(30)
                segment(60)
            }
        }
        .frame(width: 104, height: 24)
    }

    private func segment(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(fps == value ? theme.textPrimary : theme.textSecondary)
            .frame(width: 52, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { fps = value }
    }
}

// MARK: - Theme

/// Light/dark palette mirroring the design's `theme` dictionaries.
struct PanelTheme {
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let cardBg: Color
    let cardBgStrong: Color
    let cardBorder: Color
    let separator: Color
    let chevron: Color
    let rowHover: Color
    let track: Color
    let pill: Color
    let btnBg: Color
    let btnBorder: Color
    let badgeBg: Color
    let toggleOnBg: Color
    let toggleOnFg: Color
    let toggleOnBorder: Color
    let toggleOffBg: Color
    let toggleOffBorder: Color

    static func make(dark: Bool) -> PanelTheme {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
            Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
        }
        if dark {
            return PanelTheme(
                textPrimary: c(255, 255, 255, 0.92),
                textSecondary: c(235, 235, 245, 0.55),
                textTertiary: c(235, 235, 245, 0.40),
                cardBg: c(255, 255, 255, 0.06),
                cardBgStrong: c(255, 255, 255, 0.09),
                cardBorder: c(255, 255, 255, 0.08),
                separator: c(255, 255, 255, 0.16),
                chevron: c(235, 235, 245, 0.30),
                rowHover: c(255, 255, 255, 0.06),
                track: c(120, 120, 128, 0.34),
                pill: c(120, 120, 128, 0.62),
                btnBg: c(255, 255, 255, 0.10),
                btnBorder: c(255, 255, 255, 0.14),
                badgeBg: c(255, 255, 255, 0.10),
                toggleOnBg: c(51, 199, 89, 0.22),
                toggleOnFg: c(120, 225, 155, 1.0),
                toggleOnBorder: c(120, 225, 155, 0.55),
                toggleOffBg: c(255, 255, 255, 0.07),
                toggleOffBorder: c(255, 255, 255, 0.10))
        } else {
            return PanelTheme(
                textPrimary: c(29, 29, 31, 1.0),
                textSecondary: c(0, 0, 0, 0.50),
                textTertiary: c(0, 0, 0, 0.36),
                cardBg: c(255, 255, 255, 0.60),
                cardBgStrong: c(255, 255, 255, 0.92),
                cardBorder: c(0, 0, 0, 0.05),
                separator: c(0, 0, 0, 0.14),
                chevron: c(0, 0, 0, 0.25),
                rowHover: c(0, 0, 0, 0.045),
                track: c(120, 120, 128, 0.14),
                pill: c(255, 255, 255, 1.0),
                btnBg: c(255, 255, 255, 0.90),
                btnBorder: c(0, 0, 0, 0.13),
                badgeBg: c(0, 0, 0, 0.06),
                toggleOnBg: c(234, 249, 238, 1.0),
                toggleOnFg: c(51, 199, 89, 1.0),
                toggleOnBorder: c(51, 199, 89, 1.0),
                toggleOffBg: c(245, 245, 247, 1.0),
                toggleOffBorder: c(231, 231, 232, 1.0))
        }
    }
}
