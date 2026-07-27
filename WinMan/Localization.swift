import Foundation

// Lightweight bilingual support: the UI ships Chinese and English strings side
// by side in code and picks by the user's preferred system language. Avoids
// .lproj resources so the swiftc-based test/typecheck pipeline stays intact.
enum L10n {
    static let isChinese: Bool =
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
}

/// Returns the Chinese string on zh-* systems and the English string elsewhere.
func tr(_ zh: String, _ en: String) -> String {
    L10n.isChinese ? zh : en
}
