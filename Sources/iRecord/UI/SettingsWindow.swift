import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import Combine

/// Standalone settings window, per the 设置窗口 mockups: a standard titled
/// window with five icon tabs (通用 / 录制 / 截图 / 保存 / 快捷键). Opened from
/// the panel's gear button (last tab) or the Save-to screen's 更多设置… (.save).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let model = SettingsModel()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 556),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.tr("Settings", "设置")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))

        // Keep the title bar in sync with UI-language switches.
        RecordingController.shared.$uiRefresh
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.window?.title = L10n.tr("Settings", "设置") }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Shows the window, optionally jumping straight to a tab.
    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, screenshot, save, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return L10n.tr("General", "通用")
        case .recording:  return L10n.tr("Recording", "录制")
        case .screenshot: return L10n.tr("Screenshot", "截图")
        case .save:       return L10n.tr("Save", "保存")
        case .shortcuts:  return L10n.tr("Shortcuts", "快捷键")
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "sun.max"
        case .recording:  return "record.circle"
        case .screenshot: return "crop"
        case .save:       return "folder"
        case .shortcuts:  return "keyboard"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

// MARK: - Root view

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var controller = RecordingController.shared
    @ObservedObject private var manager = ShortcutManager.shared
    @StateObject private var recorder = ShortcutRecorder()
    @Environment(\.colorScheme) private var colorScheme
    /// Frozen at first render so the screenshot-name preview doesn't reshuffle
    /// its random suffix on every state change.
    @State private var shotPreviewBase = ScreenshotFileIO.autoSaveName()

    private var theme: PanelTheme { PanelTheme.make(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.tab {
                    case .general:    generalTab
                    case .recording:  recordingTab
                    case .screenshot: screenshotTab
                    case .save:       saveTab
                    case .shortcuts:  shortcutsTab
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: 556)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = model.tab == tab
                Button { model.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15))
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(selected ? Color.accentColor : theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? theme.cardBgStrong : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: 通用 General

    /// Language as a segmented toggle: "System" is localized; the two language
    /// options name themselves (中文 / English), so switching only swaps the
    /// first label's text and never reshuffles or reorders anything.
    private var langSelection: Binding<Int> {
        Binding(
            get: {
                switch UserDefaults.standard.string(forKey: L10n.overrideKey) {
                case "zh": return 1
                case "en": return 2
                default: return 0
                }
            },
            set: { idx in
                switch idx {
                case 1: UserDefaults.standard.set("zh", forKey: L10n.overrideKey)
                case 2: UserDefaults.standard.set("en", forKey: L10n.overrideKey)
                default: UserDefaults.standard.removeObject(forKey: L10n.overrideKey)
                }
                controller.uiRefresh.toggle()
            })
    }

    private var cliInstalled: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/irecord").path
        let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/irecord").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == expected
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("textformat", "LANGUAGE", "语言", tint: .accentColor)
            card {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textSecondary)
                        .frame(width: 18)
                    Text(L10n.tr("Language", "语言"))
                        .font(.system(size: 12.5))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    Segmented(theme: theme,
                              options: [(0, L10n.tr("System", "跟随系统")), (1, "中文"), (2, "English")],
                              selection: langSelection)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }

            sectionHeader("power", "STARTUP", "启动", tint: .accentColor)
            card {
                switchRow("sparkles", L10n.tr("Launch at Login", "开机自动启动"),
                          binding: Binding(
                            get: { SMAppService.mainApp.status == .enabled },
                            set: { on in
                                do {
                                    if on { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    NSLog("[settings] launch-at-login failed: %@", error.localizedDescription)
                                }
                                controller.uiRefresh.toggle()
                            }))
            }

            sectionHeader("terminal", "COMMAND LINE", "命令行工具", tint: .accentColor)
            card {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .foregroundColor(theme.textSecondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("irecord").font(.system(size: 12.5))
                        Text(cliInstalled ? L10n.tr("Installed · ~/.local/bin/irecord", "已安装 · ~/.local/bin/irecord") : L10n.tr("Let agents and scripts control recording", "让 Agent 和脚本直接控制录屏"))
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                    }
                    Spacer()
                    Button(cliInstalled ? L10n.tr("Reinstall", "重新安装") : L10n.tr("Install", "安装")) {
                        AppCoordinator.shared.installCommandLineTool()
                    }
                    if cliInstalled {
                        Button(L10n.tr("Uninstall", "卸载")) { AppCoordinator.shared.installCommandLineTool(uninstall: true) }
                    }
                }
                .padding(14)
            }
            footnote(L10n.tr("No administrator password needed. After installation, open a new terminal and run irecord --help.",
                            "无需管理员密码。安装后打开新终端，输入 irecord --help。"))

            footnote(L10n.tr("Applies immediately — no restart needed; \"System\" follows the system language.",
                             "语言切换立即生效，无需重启。"))
        }
    }

    // MARK: 录制 Recording

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("gauge", "CAPTURE", "采集", tint: theme.toggleOnFg)
            card {
                HStack(spacing: 10) {
                    Text(L10n.tr("Frame Rate", "帧率"))
                        .font(.system(size: 12.5)).foregroundColor(theme.textPrimary)
                    Spacer()
                    Segmented(theme: theme,
                              options: [(30, "30"), (60, "60")],
                              selection: $controller.captureFPS)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }

            sectionHeader("switch.2", "OPTIONS", "选项", tint: .accentColor)
            card {
                switchRow("cursorarrow.rays", L10n.tr("Show Cursor", "光标"),
                          binding: $controller.showsCursor)
                separator
                switchRow("hand.tap", L10n.tr("Highlight Clicks", "点击"),
                          binding: $controller.highlightClicks)
                separator
                switchRow("speaker.wave.2", L10n.tr("System Audio", "系统声"),
                          binding: $controller.captureSystemAudio)
                separator
                switchRow("mic", L10n.tr("Microphone", "麦克风"),
                          binding: Binding(
                            get: { controller.captureMicrophone },
                            set: { on in
                                if on { Task { _ = await PermissionsManager.requestMicrophonePermission() } }
                                controller.captureMicrophone = on
                            }))
            }

            footnote(L10n.tr("These options apply to the next recording.",
                             "以上参数在下一次录制生效。"))
        }
    }

    // MARK: 截图 Screenshot

    private var screenshotTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("macwindow", "WINDOW MATCHING", "窗口匹配", tint: .accentColor)
            card {
                switchRow("macwindow", L10n.tr("Match Front Window", "自动匹配最前窗口"),
                          L10n.tr("Pre-select the frontmost window", "框选开始时自动选中当前最前的窗口"),
                          binding: $controller.autoSelectFrontWindow)
                separator
                switchRow("cursorarrow.square", L10n.tr("Frame on Hover", "悬停框定窗口"),
                          L10n.tr("Frame the window under the cursor", "鼠标移到窗口上时自动框定整个窗口"),
                          binding: $controller.hoverFramesWindows)
            }

            footnote(L10n.tr("With both off, the shot overlay starts with a plain crosshair and manual drag only.",
                             "两者都关闭时，截屏进入纯手动框选（十字线+拖拽）。"))
        }
    }

    // MARK: 保存 Save

    private var saveTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("record.circle", "RECORDINGS", "录制文件", tint: theme.toggleOnFg)
            card {
                labeledRow(L10n.tr("Save To", "保存位置")) {
                    pathField(controller.outputDirectory)
                    changeButton { AppCoordinator.shared.chooseOutputDirectory() }
                }
                separator
                labeledRow(L10n.tr("Naming", "文件命名")) {
                    textFieldLike(L10n.tr("Recording (Date) (Time)", "录屏 （日期） （时间）"))
                    Text(RecordingController.recordingBaseName() + "." + controller.outputFormat.fileExtension)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                separator
                labeledRow(L10n.tr("Format", "格式")) {
                    Segmented(theme: theme,
                              options: OutputFormat.allCases.map { ($0, $0.displayName) },
                              selection: $controller.outputFormat)
                    Spacer(minLength: 0)
                }
            }

            sectionHeader("camera", "SCREENSHOTS", "截图文件", tint: .accentColor) {
                Text(L10n.tr("Same as Recording", "与录制同一目录"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Toggle("", isOn: $controller.screenshotUsesRecordingDir)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(red: 0.20, green: 0.78, blue: 0.35))
            }
            card {
                switchRow("externaldrive", L10n.tr("Save a Copy Locally", "保存到本地"),
                          L10n.tr("Off = clipboard only", "关闭后截图仅复制到剪贴板"),
                          binding: $controller.screenshotAlsoSaves)
                separator
                labeledRow(L10n.tr("Save To", "保存位置")) {
                    pathField(controller.effectiveScreenshotDirectory)
                    changeButton { AppCoordinator.shared.chooseScreenshotDirectory() }
                        .disabled(controller.screenshotUsesRecordingDir || !controller.screenshotAlsoSaves)
                }
                .opacity(controller.screenshotAlsoSaves ? 1 : 0.45)
                separator
                labeledRow(L10n.tr("Naming", "文件命名")) {
                    textFieldLike(L10n.tr("iRecord_screeenshots_(Date)_(Random)",
                                          "iRecord_screeenshots_（日期）_（随机数）"))
                    Text(shotPreviewBase + "." + controller.screenshotImageFormat.fileExtension)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                .opacity(controller.screenshotAlsoSaves ? 1 : 0.45)
                separator
                labeledRow(L10n.tr("Format", "格式")) {
                    Segmented(theme: theme,
                              options: ScreenshotFormat.allCases.map { ($0, $0.displayName) },
                              selection: $controller.screenshotImageFormat)
                        .opacity(controller.screenshotAlsoSaves ? 1 : 0.45)
                        .disabled(!controller.screenshotAlsoSaves)
                    Spacer(minLength: 0)
                    Text(L10n.tr("Copy to Clipboard", "同时复制到剪贴板"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    Toggle("", isOn: $controller.shotCopyToClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Color(red: 0.20, green: 0.78, blue: 0.35))
                }
            }

            footnote(L10n.tr("The panel's \"Save to\" bar only switches folders; everything else lives here.",
                             "菜单栏面板底部的「保存位置」只切换目录，其余配置在这里改。"))
        }
    }

    private func labeledRow<Content: View>(_ label: String,
                                           @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(theme.textPrimary)
                .frame(width: 56, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
    }

    private func pathField(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10.5))
                .foregroundColor(theme.textTertiary)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11.5))
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.toggleOffBg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.cardBorder, lineWidth: 0.5))
    }

    private func textFieldLike(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.toggleOffBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.cardBorder, lineWidth: 0.5))
    }

    private func changeButton(_ action: @escaping () -> Void) -> some View {
        Button(L10n.tr("Change…", "更改…"), action: action)
            .controlSize(.small)
    }

    // MARK: 快捷键 Shortcuts

    private var areaShotConflict: Bool {
        manager.combo(for: .screenshotArea)
            == KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(cmdKey))
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("record.circle", "RECORD", "录制", tint: theme.toggleOnFg)
            card {
                ShortcutRow(theme: theme, action: .toggleAreaRecording,
                            manager: manager, recorder: recorder)
                separator
                ShortcutRow(theme: theme, action: .recordWindow,
                            manager: manager, recorder: recorder)
                separator
                ShortcutRow(theme: theme, action: .recordFullScreen,
                            manager: manager, recorder: recorder)
                separator
                stopAndSaveRow
            }

            sectionHeader("camera.viewfinder", "SCREENSHOT", "截图", tint: .accentColor)
            card {
                ShortcutRow(theme: theme, action: .screenshotArea,
                            manager: manager, recorder: recorder, conflict: areaShotConflict,
                            hint: areaShotConflict
                                ? L10n.tr("Conflicts with Finder's Get Info (⌘E); ⌥⌘E is suggested.",
                                          "与「访达·显示简介」冲突，建议改为 ⌥⌘E")
                                : nil)
                separator
                ShortcutRow(theme: theme, action: .screenshotScrolling,
                            manager: manager, recorder: recorder)
                separator
                ShortcutRow(theme: theme, action: .pinFromClipboard,
                            manager: manager, recorder: recorder)
            }

            sectionHeader("command", "OTHER", "其他", tint: theme.textSecondary)
            card {
                ShortcutRow(theme: theme, action: .pauseResume,
                            manager: manager, recorder: recorder)
                separator
                ShortcutRow(theme: theme, action: .screenshotFullScreen,
                            manager: manager, recorder: recorder)
                separator
                ShortcutRow(theme: theme, action: .togglePins,
                            manager: manager, recorder: recorder)
            }

            Text(recorder.capturingAction != nil
                 ? L10n.tr("Type a combination with ⌘, ⌥ or ⌃ · Esc to cancel",
                           "按下包含 ⌘、⌥ 或 ⌃ 的组合键 · Esc 取消")
                 : L10n.tr("Shortcuts work system-wide while iRecord is running.",
                           "iRecord 运行期间快捷键全局生效。"))
                .font(.system(size: 10.5))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .onDisappear { recorder.cancel() }
    }

    /// Read-only row: mirrors the area-recording binding (same hotkey stops the
    /// current recording).
    private var stopAndSaveRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Stop & Save", "停止并保存"))
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.textPrimary)
                Text(L10n.tr("Same as \"Start / Stop (Area)\": stops while recording, starts when idle.",
                             "与「开始/停止（区域）」相同：录制中按下即停止，未录制时开始。"))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
            }
            Spacer()
            Text(manager.combo(for: .toggleAreaRecording)?.displayString
                 ?? L10n.tr("Not set", "未设置"))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .frame(minWidth: 76)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.badgeBg))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    // MARK: Shared building blocks

    private func sectionHeader<Trailing: View>(_ symbol: String, _ en: String, _ zh: String,
                                               tint: Color,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(L10n.tr(en, zh))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 6)
    }

    private func sectionHeader(_ symbol: String, _ en: String, _ zh: String,
                               tint: Color) -> some View {
        sectionHeader(symbol, en, zh, tint: tint) { EmptyView() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 11).fill(theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var separator: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 14)
    }

    private func switchRow(_ symbol: String, _ title: String, _ subtitle: String? = nil,
                           binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(theme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }

    private func footnote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 9.5))
            Text(text)
                .font(.system(size: 9.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.textTertiary)
        .padding(.horizontal, 6)
    }
}

// MARK: - Shortcut row with record / clear

private struct ShortcutRow: View {
    let theme: PanelTheme
    let action: ShortcutAction
    @ObservedObject var manager: ShortcutManager
    @ObservedObject var recorder: ShortcutRecorder
    var conflict: Bool = false
    /// Optional second line under the title (e.g. conflict warning), keeps the
    /// hint attached to its row instead of breaking the card's row rhythm.
    var hint: String? = nil

    private var isCapturing: Bool { recorder.capturingAction == action }
    private var combo: KeyCombo? { manager.combo(for: action) }
    private var hasCombo: Bool { combo?.isEmpty == false }
    private static let conflictRed = Color(red: 0.84, green: 0.23, blue: 0.17)

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundColor(conflict ? Self.conflictRed : theme.textTertiary)
                }
            }
            Spacer()
            pill
            Button { manager.setCombo(nil, for: action) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasCombo && !isCapturing)
            .opacity(!hasCombo && !isCapturing ? 0.3 : 1)
            .help(L10n.tr("Clear shortcut", "清除快捷键"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    private var pill: some View {
        Button { isCapturing ? recorder.cancel() : recorder.begin(action) } label: {
            Group {
                if isCapturing {
                    Text(L10n.tr("Type shortcut…", "按下快捷键…"))
                        .foregroundColor(.accentColor)
                } else if let combo, !combo.isEmpty {
                    Text(combo.displayString)
                        .foregroundColor(conflict ? Self.conflictRed : theme.textPrimary)
                } else {
                    Text(L10n.tr("Click to Record", "点击录入"))
                        .foregroundColor(theme.textTertiary)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .frame(minWidth: 76)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCapturing ? Color.clear
                          : (conflict && hasCombo ? Self.conflictRed.opacity(0.10) : theme.badgeBg))
                    .opacity(isCapturing || (!hasCombo) ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isCapturing ? Color.accentColor
                            : (conflict && hasCombo ? Self.conflictRed.opacity(0.55) : theme.btnBorder),
                        style: StrokeStyle(lineWidth: 0.5,
                                           dash: (isCapturing || !hasCombo) ? [4, 3] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasCombo ? L10n.tr("Click to re-record", "点击重新录入")
                       : L10n.tr("Click to record a shortcut", "点击录入快捷键"))
    }
}

// MARK: - Segmented control

private struct Segmented<T: Hashable>: View {
    let theme: PanelTheme
    let options: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = selection == opt.value
                Text(opt.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? theme.textPrimary : theme.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? theme.pill : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.track))
    }
}
