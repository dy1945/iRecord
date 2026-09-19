import Foundation

/// Tiny runtime localization: the app ships English and Simplified Chinese,
/// picked from the system's preferred-language list (a SwiftPM-built binary has
/// no .lproj bundles, so NSLocalizedString is unavailable). The user can
/// override the choice in Settings; the override applies immediately.
enum L10n {
    /// UserDefaults key for the language override: "zh" / "en" / absent = system.
    static let overrideKey = "langOverride"

    static var isChinese: Bool {
        if let lang = UserDefaults.standard.string(forKey: overrideKey) {
            return lang == "zh"
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    /// Returns the Chinese string when the system prefers Chinese, else English.
    static func tr(_ en: String, _ zh: String) -> String { isChinese ? zh : en }
}
