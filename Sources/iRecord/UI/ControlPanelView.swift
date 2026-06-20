import SwiftUI
import CoreGraphics

/// Menu-bar popover, redesigned to the "iRecord Menu" spec: grouped translucent
/// cards (CAPTURE / RECORDING / OUTPUT), colored icon badges, a sliding FPS
/// segmented control, iOS-style toggles, a live status indicator, and a footer.
/// Light/dark palettes mirror the design; the NSPopover supplies the floating
/// chrome (arrow + material), so the cards float on top of it.
struct ControlPanelView: View {
    @ObservedObject var controller = RecordingController.shared
    @ObservedObject var shortcuts = ShortcutManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var displays: [DisplayInfo] = ScreenInfo.displays()
    @State private var windowPickerVisible = false
    @State private var shortcutsVisible = false
    @State private var windows: [WindowInfo] = []
    @State private var loadingWindows = false

    private var theme: PanelTheme { PanelTheme.make(dark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if controller.isRecording {
                recordingControls.padding(.top, 4)
            } else if shortcutsVisible {
                ShortcutsScreen(theme: theme, onBack: { shortcutsVisible = false }).padding(.top, 2)
            } else if windowPickerVisible {
                windowPicker.padding(.top, 2)
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

            footer
        }
        .padding(13)
        .frame(width: 344)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Color(red: 1, green: 0.27, blue: 0.227), lineWidth: 1.7)
                    .frame(width: 15.5, height: 15.5)
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.227))
                    .frame(width: 7.3, height: 7.3)
            }
            .frame(width: 19, height: 19)

            Text("iRecord")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.1)
                .foregroundColor(theme.textPrimary)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: status.color.opacity(0.5), radius: 0.5)
                    .overlay(
                        Circle().stroke(status.color.opacity(0.16), lineWidth: 3).frame(width: 7, height: 7)
                    )
                if controller.isRecording {
                    Text(timeString(controller.elapsed))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                } else {
                    Text(status.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, controller.isRecording || shortcutsVisible || windowPickerVisible ? 10 : 12)
    }

    private var status: (text: String, color: Color) {
        switch controller.state {
        case .preparing: return ("Preparing…", Color(red: 1, green: 0.62, blue: 0.04))
        case .recording: return ("Recording", Color(red: 1, green: 0.27, blue: 0.227))
        case .paused:    return ("Paused", Color(red: 1, green: 0.62, blue: 0.04))
        case .finishing: return ("Saving…", Color(red: 1, green: 0.62, blue: 0.04))
        default:         return ("Ready", Color(red: 0.20, green: 0.78, blue: 0.35))
        }
    }

    // MARK: Idle content (the design's three sections)

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("CAPTURE")
            captureCard
            sectionLabel("RECORDING").padding(.top, 16)
            recordingCard
            Text("Size, format and output FPS are set after recording.")
                .font(.system(size: 11.5))
                .foregroundColor(theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 7)
            sectionLabel("OUTPUT").padding(.top, 15)
            outputCard
            sectionLabel("SHORTCUTS").padding(.top, 15)
            shortcutsEntryCard
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.55)
            .foregroundColor(theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
    }

    // MARK: CAPTURE card

    private var captureCard: some View {
        card {
            captureRow(color: Color(red: 0.04, green: 0.52, blue: 1.0), symbol: "crop",
                       title: "Select Area…",
                       shortcut: shortcuts.combo(for: .toggleAreaRecording)?.displayString) {
                AppCoordinator.shared.startAreaSelection()
            }
            separator(inset: 52)
            captureRow(color: Color(red: 0.37, green: 0.36, blue: 0.90), symbol: "macwindow",
                       title: "Select Window…", shortcut: nil) {
                openWindowPicker()
            }
            ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                separator(inset: 52)
                captureRow(color: Color(red: 0.19, green: 0.69, blue: 0.78), symbol: "display",
                           title: display.name,
                           shortcut: index == 0 ? shortcuts.combo(for: .recordFullScreen)?.displayString : nil) {
                    AppCoordinator.shared.startDisplayRecording(display.id)
                }
            }
        }
    }

    private func captureRow(color: Color, symbol: String, title: String,
                            shortcut: String?, action: @escaping () -> Void) -> some View {
        HoverRow(theme: theme, height: 46, action: action) {
            HStack(spacing: 12) {
                IconBadge(color: color, symbol: symbol)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(theme.textPrimary)
                Spacer(minLength: 6)
                if let shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(theme.badgeBg))
                }
                chevron
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: RECORDING card

    private var recordingCard: some View {
        card {
            HStack {
                Text("Capture FPS").font(.system(size: 15)).foregroundColor(theme.textPrimary)
                Spacer()
                FpsSegmented(theme: theme, fps: $controller.captureFPS)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            separator(inset: 14)
            toggleRow("Show cursor", isOn: $controller.showsCursor)
            separator(inset: 14)
            toggleRow("Highlight clicks", isOn: $controller.highlightClicks)
            separator(inset: 14)
            toggleRow("System audio", isOn: $controller.captureSystemAudio)
            separator(inset: 14)
            toggleRow("Microphone", isOn: $controller.captureMicrophone) { on in
                if on { Task { _ = await PermissionsManager.requestMicrophonePermission() } }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>,
                           onChange: ((Bool) -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(theme.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(red: 0.20, green: 0.78, blue: 0.35))
                .onChange(of: isOn.wrappedValue) { value in onChange?(value) }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: OUTPUT card

    private var outputCard: some View {
        card {
            HStack(spacing: 8) {
                Text("Save to").font(.system(size: 14)).foregroundColor(theme.textSecondary)
                Text(controller.outputDirectory.lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(controller.outputDirectory.path)
                Button {
                    AppCoordinator.shared.chooseOutputDirectory()
                } label: {
                    Text("Change…")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 13).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.btnBg)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.btnBorder, lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
    }

    // MARK: Keyboard shortcuts entry

    private var shortcutsEntryCard: some View {
        card {
            HoverRow(theme: theme, height: 46, action: { shortcutsVisible = true }) {
                HStack(spacing: 12) {
                    IconBadge(color: Color(red: 0.56, green: 0.56, blue: 0.58), symbol: "keyboard")
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 15))
                        .foregroundColor(theme.textPrimary)
                    Spacer(minLength: 6)
                    chevron
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: Window picker (sub-screen)

    private func openWindowPicker() {
        windowPickerVisible = true
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

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                backButton { windowPickerVisible = false }
                Spacer()
                Text("Select Window").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.textSecondary)
                Spacer()
                if loadingWindows { ProgressView().controlSize(.small) } else { Color.clear.frame(width: 44, height: 1) }
            }

            if !loadingWindows && windows.isEmpty {
                Text("No capturable windows found.")
                    .font(.system(size: 12)).foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 8)
            }

            ScrollView {
                card {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { idx, win in
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

    // MARK: Recording controls (active state)

    private var recordingControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { controller.stopRecording() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 1, green: 0.27, blue: 0.227)).controlSize(.large)

                Button { controller.togglePause() } label: {
                    Label(controller.isPaused ? "Resume" : "Pause",
                          systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled({ if case .preparing = controller.state { return true } else { return false } }())
            }
            Text(status.text).font(.system(size: 12)).foregroundColor(theme.textSecondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                if let url = controller.lastOutputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").font(.system(size: 14, weight: .medium))
                    Text("Reveal Last").font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(controller.lastOutputURL == nil ? theme.textTertiary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(controller.lastOutputURL == nil)

            Spacer()

            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.system(size: 14, weight: .medium)).foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 2)
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

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.chevron)
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("Back").font(.system(size: 13))
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

/// A colored rounded-square badge with a white SF Symbol, matching the design's
/// 28×28 icon tiles.
private struct IconBadge: View {
    let color: Color
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(color))
            .shadow(color: color.opacity(0.4), radius: 1.5, x: 0, y: 1)
    }
}

/// A tappable row with a hover highlight, used for capture/window/shortcut rows.
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

/// The sliding 30/60 FPS segmented control from the design.
private struct FpsSegmented: View {
    let theme: PanelTheme
    @Binding var fps: Int

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(theme.track)
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.pill)
                .frame(width: 63, height: 24)
                .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
                .offset(x: fps == 60 ? 69 : 2)
                .animation(.easeInOut(duration: 0.22), value: fps)
            HStack(spacing: 0) {
                segment(30)
                segment(60)
            }
        }
        .frame(width: 134, height: 28)
    }

    private func segment(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 13.5, weight: .medium))
            .foregroundColor(fps == value ? theme.textPrimary : theme.textSecondary)
            .frame(width: 65, height: 28)
            .contentShape(Rectangle())
            .onTapGesture { fps = value }
    }
}

// MARK: - Shortcuts editor (sub-screen)

private struct ShortcutsScreen: View {
    let theme: PanelTheme
    let onBack: () -> Void
    @ObservedObject private var manager = ShortcutManager.shared
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: { recorder.cancel(); onBack() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back").font(.system(size: 13))
                    }.foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Global Shortcuts").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.textSecondary)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }

            VStack(spacing: 0) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { idx, action in
                    if idx > 0 { Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 14) }
                    row(for: action)
                }
            }
            .background(RoundedRectangle(cornerRadius: 11).fill(theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            Text(recorder.capturingAction != nil
                 ? "Type a combination with ⌘, ⌥ or ⌃ · Esc to cancel"
                 : "Shortcuts work system-wide while iRecord is running.")
                .font(.system(size: 11.5))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onDisappear { recorder.cancel() }
    }

    @ViewBuilder
    private func row(for action: ShortcutAction) -> some View {
        let isCapturing = recorder.capturingAction == action
        let combo = manager.combo(for: action)

        HStack(spacing: 10) {
            Image(systemName: action.symbol).frame(width: 20).foregroundColor(theme.textSecondary)
            Text(action.title).font(.system(size: 14)).foregroundColor(theme.textPrimary)
            Spacer()

            if isCapturing {
                Text("Type shortcut…")
                    .font(.system(size: 11.5)).foregroundColor(.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 0.5))
            } else if let combo, !combo.isEmpty {
                Text(combo.displayString)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.badgeBg))
            } else {
                Text("Not set").font(.system(size: 11.5)).foregroundColor(theme.textTertiary)
            }

            Button(action: { isCapturing ? recorder.cancel() : recorder.begin(action) }) {
                Image(systemName: isCapturing ? "xmark.circle.fill" : "pencil").foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(isCapturing ? "Cancel" : "Record shortcut")

            Button(action: { manager.setCombo(nil, for: action) }) {
                Image(systemName: "trash").foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(combo == nil)
            .help("Clear shortcut")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

// MARK: - Theme

/// Light/dark palette mirroring the design's `theme` dictionaries.
struct PanelTheme {
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let cardBg: Color
    let cardBorder: Color
    let separator: Color
    let chevron: Color
    let rowHover: Color
    let track: Color
    let pill: Color
    let btnBg: Color
    let btnBorder: Color
    let badgeBg: Color

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
                cardBorder: c(255, 255, 255, 0.08),
                separator: c(255, 255, 255, 0.09),
                chevron: c(235, 235, 245, 0.30),
                rowHover: c(255, 255, 255, 0.06),
                track: c(120, 120, 128, 0.34),
                pill: c(120, 120, 128, 0.62),
                btnBg: c(255, 255, 255, 0.10),
                btnBorder: c(255, 255, 255, 0.14),
                badgeBg: c(255, 255, 255, 0.10))
        } else {
            return PanelTheme(
                textPrimary: c(29, 29, 31, 1.0),
                textSecondary: c(0, 0, 0, 0.50),
                textTertiary: c(0, 0, 0, 0.36),
                cardBg: c(255, 255, 255, 0.60),
                cardBorder: c(0, 0, 0, 0.05),
                separator: c(0, 0, 0, 0.08),
                chevron: c(0, 0, 0, 0.25),
                rowHover: c(0, 0, 0, 0.045),
                track: c(120, 120, 128, 0.14),
                pill: c(255, 255, 255, 1.0),
                btnBg: c(255, 255, 255, 0.90),
                btnBorder: c(0, 0, 0, 0.13),
                badgeBg: c(0, 0, 0, 0.06))
        }
    }
}
