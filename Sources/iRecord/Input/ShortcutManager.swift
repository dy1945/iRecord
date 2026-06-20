import AppKit
import Carbon.HIToolbox

/// A captured key combination: a virtual key code plus Carbon modifier flags.
/// Persisted as JSON; rendered for display with the standard ⌃⌥⇧⌘ glyphs.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var isEmpty: Bool { keyCode == 0 && carbonModifiers == 0 }

    /// Translate Cocoa modifier flags (from an `NSEvent`) to Carbon flags.
    static func carbonFlags(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if cocoa.contains(.control) { flags |= UInt32(controlKey) }
        if cocoa.contains(.option)  { flags |= UInt32(optionKey) }
        if cocoa.contains(.shift)   { flags |= UInt32(shiftKey) }
        if cocoa.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// True when at least one of ⌃⌥⌘ is held — required for a safe global hotkey
    /// (a bare key, or Shift-only, would swallow normal typing system-wide).
    var hasRequiredModifier: Bool {
        carbonModifiers & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0
    }

    var displayString: String {
        guard !isEmpty else { return "" }
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// Human-readable name for a virtual key code (US layout for the letter/number
    /// rows, plus the common special keys).
    static func keyName(for code: UInt32) -> String {
        if let name = specialKeyNames[code] { return name }
        if let name = ansiKeyNames[code] { return name }
        return "Key \(code)"
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]

    private static let ansiKeyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`"
    ]
}

/// The recorder actions that can be bound to a global hotkey.
enum ShortcutAction: String, CaseIterable, Codable {
    case toggleAreaRecording
    case recordFullScreen
    case pauseResume

    var title: String {
        switch self {
        case .toggleAreaRecording: return "Start / Stop (Area)"
        case .recordFullScreen:    return "Record Full Screen"
        case .pauseResume:         return "Pause / Resume"
        }
    }

    var symbol: String {
        switch self {
        case .toggleAreaRecording: return "crop"
        case .recordFullScreen:    return "display"
        case .pauseResume:         return "playpause"
        }
    }

    /// Stable, non-zero id used as the Carbon `EventHotKeyID`.
    var hotKeyID: UInt32 { UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// Seeded on first launch only. ⌃⌘ combos are uncommon as global hotkeys.
    var defaultCombo: KeyCombo? {
        let ctrlCmd = UInt32(controlKey) | UInt32(cmdKey)
        switch self {
        case .toggleAreaRecording: return KeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: ctrlCmd)
        case .recordFullScreen:    return nil
        case .pauseResume:         return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: ctrlCmd)
        }
    }
}

/// Registers global hotkeys via Carbon's `RegisterEventHotKey`, which works
/// app-wide without Accessibility permission. Persists bindings to UserDefaults
/// and invokes `onTrigger` on the main actor when a hotkey fires.
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    @Published private(set) var combos: [ShortcutAction: KeyCombo] = [:]

    /// Set by the app to perform the bound action.
    var onTrigger: ((ShortcutAction) -> Void)?

    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x69526563 // 'iRec'
    private let defaultsKey = "shortcuts.v1"
    private let defaults = UserDefaults.standard

    private init() {
        load()
        installHandler()
        registerAll()
    }

    func combo(for action: ShortcutAction) -> KeyCombo? { combos[action] }

    /// Assigns (or clears, when `combo` is nil/empty) the hotkey for an action and
    /// re-registers it immediately.
    func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        unregister(action)
        if let combo, !combo.isEmpty {
            combos[action] = combo
            register(action, combo)
        } else {
            combos[action] = nil
        }
        save()
    }

    // MARK: - Carbon registration

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotKey(id: hkID.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func registerAll() {
        for (action, combo) in combos { register(action, combo) }
    }

    private func register(_ action: ShortcutAction, _ combo: KeyCombo) {
        guard !combo.isEmpty else { return }
        let id = EventHotKeyID(signature: signature, id: action.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeyRefs[action] = ref }
    }

    private func unregister(_ action: ShortcutAction) {
        if let ref = hotKeyRefs[action] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[action] = nil
        }
    }

    /// Carbon dispatches hotkey events on the main run loop; hop to the main actor
    /// for isolation correctness before touching state.
    nonisolated private func handleHotKey(id: UInt32) {
        Task { @MainActor in
            guard let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
            self.onTrigger?(action)
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (raw, combo) in decoded {
                if let action = ShortcutAction(rawValue: raw) { combos[action] = combo }
            }
        } else {
            // First launch: seed defaults.
            for action in ShortcutAction.allCases {
                if let def = action.defaultCombo { combos[action] = def }
            }
            save()
        }
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

/// Drives the "press a key combo" capture flow used by the shortcuts UI. While
/// capturing, a local key-down monitor swallows the event and stores the combo.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var capturingAction: ShortcutAction?
    private var monitor: Any?

    func begin(_ action: ShortcutAction) {
        end()
        capturingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow while recording
        }
    }

    func cancel() { end() }

    private func handle(_ event: NSEvent) {
        guard let action = capturingAction else { return }
        if event.keyCode == UInt16(kVK_Escape) { end(); return }

        let cocoa = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let combo = KeyCombo(keyCode: UInt32(event.keyCode),
                             carbonModifiers: KeyCombo.carbonFlags(from: cocoa))
        guard combo.hasRequiredModifier else {
            NSSound.beep() // needs ⌃⌥⌘ to be a safe global hotkey
            return
        }
        ShortcutManager.shared.setCombo(combo, for: action)
        end()
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturingAction = nil
    }
}
