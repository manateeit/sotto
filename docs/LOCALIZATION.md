# Localization Guide — Sotto

**Status**: Infrastructure in place. English strings catalogued. Ready for translation.

## For Users / Translators

To contribute a translation for a new language:

1. **Clone the repo** and navigate to `Sources/Sotto/`
2. **Create a new `.strings` file**:
   - File name format: `Localizable.strings (xx)` where `xx` is the ISO 639-1 language code
   - Example: `Localizable.strings (de)` for German, `Localizable.strings (es)` for Spanish
3. **Copy all keys** from `Localizable.strings` (the English source)
4. **Translate the values**:
   ```
   "SETTINGS_WINDOW_TITLE" = "Settings";
   "GENERAL_SHORTCUT_LABEL" = "Dictation shortcut";
   ...
   ```
5. **Test your translation**:
   - Build: `swift build`
   - Change your Mac's system language (System Settings › General › Language & Region)
   - Run Sotto: `open .build/debug/Sotto.app`
   - Verify all UI strings appear in the translated language
6. **Submit a PR** with your translation

## For Developers

### Adding a new string to the UI

1. **Add the key to `Localizable.strings`**:
   ```
   "NEW_FEATURE_LABEL" = "New Feature";
   "NEW_FEATURE_HELP" = "This is what the feature does.";
   ```

2. **Use the string in SwiftUI**:
   ```swift
   Text(localized: "NEW_FEATURE_LABEL")
   Button("New Feature", action: { ... })
       .accessibilityHint(String(localized: "NEW_FEATURE_HELP"))
   ```

3. **Or in AppKit**:
   ```swift
   NSMenuItem(title: NSLocalizedString("NEW_FEATURE_LABEL", comment: ""), ...)
   ```

### The localization helper

- **File**: `Sources/Sotto/Localization.swift`
- **Usage**: `String(localized: "KEY")` in SwiftUI, or `Localization.string("KEY")` in Foundation code
- Handles fallback to English if translation missing

### Which strings to localize

**Priority 1** (must localize for each language):
- Settings window (General, Vocabulary, History tabs)
- Onboarding/permissions guide
- HUD status messages
- Menu items

**Priority 2** (should localize):
- Error messages
- Confirmation prompts
- Status bar text

**Priority 3** (optional):
- Accessibility hints (can remain English for developers)
- In-app documentation
- Prompts (example values are often English-specific)

## Supported Languages (MVP)

**English**: ✅ Complete (Localizable.strings)

**Other languages**: 🔜 Waiting for contributor translations.

Common candidates:
- German (de)
- Spanish (es)
- French (fr)
- Italian (it)
- Japanese (ja)
- Mandarin (zh-Hans)

## Technical Notes

- **Format**: macOS `.strings` files (UTF-8, one key=value per line)
- **Tool support**: Xcode, BartyCrouch, SwiftGen all work with this format
- **Fallback**: If a translation key is missing, the English version is used automatically
- **Pluralization**: Not yet supported; if needed, add plural keys (e.g., `RETENTION_DAYS_SINGULAR`, `RETENTION_DAYS_PLURAL`)
- **Parameters**: Use `%d`, `%s`, `%@` for placeholders (example: `"RETENTION_DAYS" = "%d days"`)

## Future: Improving Localization

- **AI-first translation**: Use Claude API to auto-translate all strings (L effort, helps bootstrap new languages)
- **Crowdsourcing**: Weblate or similar platform for community translations
- **RTL support**: Arabic, Hebrew (requires layout changes — separate ticket)
- **Locale-specific formatting**: Dates, numbers, currency (if Sotto gains these features)

## Testing

After adding a new language file:
1. Build: `swift build`
2. Change system language (System Settings › General › Language & Region)
3. Reboot or log out/in
4. Run the app and verify all strings are translated
5. Check that **untranslated keys fall back to English** (test by leaving one key out)

If strings don't update after language change, try:
- Delete `~/Library/Preferences/com.chrismckenna.sotto.plist` (resets cached strings)
- Rebuild: `rm -rf .build && swift build`
