import Foundation

public enum UILanguage: String, CaseIterable, Sendable {
    case en
    case ru
    case zhHans = "zh-Hans"
    case ja
    case ko
    case de
    case fr
    case es
    case ptBR = "pt-BR"
    case uk

    public static var current: UILanguage { from(preferred: Locale.preferredLanguages) }

    /// The first of the user's preferred languages that Denny speaks.
    public static func from(preferred: [String]) -> UILanguage {
        for identifier in preferred {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("pt") { return .ptBR }
            let code = String(lower.prefix(2))
            if let match = UILanguage(rawValue: code) { return match }
        }
        return .en
    }

    public var localeIdentifier: String {
        switch self {
        case .en: return "en_US"
        case .ru: return "ru_RU"
        case .zhHans: return "zh_Hans_CN"
        case .ja: return "ja_JP"
        case .ko: return "ko_KR"
        case .de: return "de_DE"
        case .fr: return "fr_FR"
        case .es: return "es_ES"
        case .ptBR: return "pt_BR"
        case .uk: return "uk_UA"
        }
    }
}

/// Every UI string, keyed by name, one table per language (Strings/*.swift).
/// A missing translation falls back to English.
public enum Translations {
    public static func text(_ key: String, _ language: UILanguage) -> String {
        tables[language]?[key] ?? english[key] ?? key
    }

    public static func format(_ key: String, _ language: UILanguage, _ arguments: [CVarArg]) -> String {
        let template = text(key, language)
        guard !arguments.isEmpty else { return template }
        // No locale: integers must never gain grouping separators ("47 321").
        return String(format: template, arguments: arguments)
    }

    static let tables: [UILanguage: [String: String]] = [
        .en: english, .ru: russian, .zhHans: chinese, .ja: japanese, .ko: korean,
        .de: german, .fr: french, .es: spanish, .ptBR: portuguese, .uk: ukrainian
    ]
}
