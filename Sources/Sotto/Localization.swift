import Foundation

/// Localization helper. Wraps NSLocalizedString with a short syntax.
/// Usage: String(localized: "SETTINGS_WINDOW_TITLE")
///
/// To add a new language:
/// 1. Create Sources/Sotto/Localizable.strings (xx)
/// 2. Copy all keys from Localizable.strings (English)
/// 3. Translate values to xx
/// 4. Xcode will automatically detect and include it in the build
enum Localization {
    /// Return the localized string for the given key, falling back to English if not found.
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: Bundle.main, comment: "")
    }
}

// MARK: SwiftUI convenience

extension String {
    /// Localize using key lookup. Example: Text(localized: "SETTINGS_WINDOW_TITLE")
    init(localized key: String) {
        self = Localization.string(key)
    }
}
