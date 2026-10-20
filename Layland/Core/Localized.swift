// Layland's words in the app's language, which Settings ▸ Language can change while it runs
// (AppLanguage.swift).
//
// SwiftUI looks up the literals a view shows (Text("…"), Button("…"), .help("…")) in the
// language its environment says, and every window's environment says the app's (see
// `appLanguage()`). The rest go through `L`: the menus, which no environment reaches, and every
// string made outside a view, from a legend's names to an error's message. The English is
// the key, and the compiler lists these for the String Catalog as it does SwiftUI's
// (tools/strings.py sync).
//
// `L` reads `AppLocale.shared`, which is observable: a view or a menu that called it is drawn
// again when the language changes, however deep in a model the call was.

import Foundation
import Observation

/// The language Layland's words are in, with the user's region for numbers and dates (German
/// on a French Mac writes 1 234,5). Readable from any thread: a scan's error is worded where
/// the scan runs.
public final class AppLocale: Observable, @unchecked Sendable {
    public static let shared = AppLocale()

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var value: Locale

    private init() {
        value = Self.locale(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    public var locale: Locale {
        registrar.access(self, keyPath: \.locale)
        return lock.withLock { value }
    }

    /// `code` is a translation's .lproj name ("fr", "pt-BR", "zh-Hans").
    public func switchTo(_ code: String) {
        let locale = Self.locale(for: code)
        registrar.withMutation(of: self, keyPath: \.locale) {
            lock.withLock { value = locale }
        }
    }

    /// The language `code`, in the user's region.
    public static func locale(for code: String) -> Locale {
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents = Locale.Language.Components(language: Locale.Language(identifier: code))
        return Locale(components: components)
    }
}

/// The string for `value`, in the app's language. `comment` is for the translators; the
/// catalog keeps it.
public func L(_ value: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: LocalizedStringResource(value, locale: AppLocale.shared.locale, comment: comment))
}
