import Foundation
import SwiftUI

/// Manages in-app language override. Stores selection in AppSettings (persisted to disk).
/// Views receive the active locale via `.environment(\.locale, ...)` injected by AppDelegate.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    struct Language: Identifiable, Hashable {
        let id: String      // BCP 47 code, or "system"
        let displayName: String
        let flag: String
    }

    static let supported: [Language] = [
        Language(id: "en", displayName: "English", flag: "🇺🇸"),
        Language(id: "ko", displayName: "한국어",   flag: "🇰🇷"),
    ]

    @Published var selectedID: String = "en" {
        didSet { persist() }
    }

    var activeLocale: Locale {
        Locale(identifier: selectedID)
    }

    private init() {
        // SettingsStore is also @MainActor — safe to call here
        selectedID = Self.normalize(SettingsStore.shared.settings.appLanguage)
    }

    private func persist() {
        SettingsStore.shared.update { $0.appLanguage = self.selectedID }
    }

    var selectedLanguage: Language {
        LocalizationManager.supported.first { $0.id == selectedID }
            ?? LocalizationManager.supported[0]
    }

    func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main, locale: activeLocale)
    }

    func text(_ key: String) -> String {
        let bundle = localizedBundle ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private var localizedBundle: Bundle? {
        guard let path = Bundle.main.path(forResource: selectedID, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    private static func normalize(_ storedID: String) -> String {
        let trimmed = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
        if supported.contains(where: { $0.id == trimmed }) {
            return trimmed
        }
        return defaultLanguageID()
    }

    static func defaultLanguageID(locale: Locale = .current) -> String {
        let region = locale.region?.identifier ?? ""
        return region.uppercased() == "KR" ? "ko" : "en"
    }
}
