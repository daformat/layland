// The language Layland's own words are in: its menus, windows and messages. Adapted from
// Subtitles.
//
// The system's by default, and otherwise the one chosen in Settings ▸ Language, kept the way
// macOS keeps a per-app language (System Settings ▸ General ▸ Language & Region ▸
// Applications writes the same key): the app's own AppleLanguages. Bundle.main reads that at
// launch. A choice made while the app runs takes effect at once: `AppLocale` moves to it, so
// every window (through its environment, `appLanguage()`) and every menu (through `L`) is
// drawn again in it. What macOS draws for the app (Hide Layland and Quit Layland, the Edit
// and Window menus, the open and save panels, Sparkle's windows) went by the launch language
// and follows at the next launch, which Settings offers to do at once.

import AppKit
import SwiftUI

enum AppLanguage {
    /// The app's translations, as their .lproj folders name them, each under its own name for
    /// itself. Subtitles' sixteen, in its order.
    static let all: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("pt-BR", "Português (Brasil)"),
        ("de", "Deutsch"),
        ("nl", "Nederlands"),
        ("tr", "Türkçe"),
        ("ru", "Русский"),
        ("ar", "العربية"),
        ("hi", "हिन्दी"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("vi", "Tiếng Việt"),
        ("uk", "Українська"),
        ("zh-Hans", "简体中文"),
    ]

    private static let key = "AppleLanguages"

    /// The language chosen in Settings, or nil for the system's. Read from this app's own
    /// domain only: `UserDefaults.standard` would answer with the system-wide list when the
    /// app has none of its own.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first
        else { return nil }
        return Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: [first]).first
    }

    /// Choose a language for the next launch, or nil to follow the system.
    static func choose(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The language the app launched in, which is what macOS's own words for it are in.
    static let launched = Bundle.main.preferredLocalizations.first ?? "en"

    /// Choose a language, or nil to follow the system's, and switch to it now.
    static func switchTo(_ code: String?) {
        choose(code)
        AppLocale.shared.switchTo(resolving(code))
    }

    /// The language a launch with `choice` is in: itself, or for the system's (nil), what the
    /// system's list comes to among the app's translations.
    static func resolving(_ choice: String?) -> String {
        if let choice { return choice }
        let system = CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? ["en"]
        return Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: system).first ?? "en"
    }

    static func name(of code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// Whether `code` is written right to left (Arabic).
    static func isRightToLeft(_ code: String) -> Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// Right to left for a right-to-left language (Arabic), whatever the system's direction.
    /// AppKit takes the layout direction from the system rather than from the app's own
    /// language, so Arabic chosen here on an English Mac would draw its menus and windows left
    /// to right. Read once, as NSApplication starts (`Main`): the windows, their title bars
    /// and split views and SwiftUI's environment all take it from there, and a language
    /// chosen while the app runs gets its direction at the next launch.
    ///
    /// Kept in the app's own defaults, written at every launch, rather than registered as
    /// Subtitles does: AppKit reads these through CFPreferences, which never sees the
    /// registration domain, so registered values left the window left to right.
    static func applyLayoutDirection() {
        let defaults = UserDefaults.standard
        for key in ["AppleTextDirection", "NSForceRightToLeftWritingDirection"] {
            if isRightToLeft(launched) {
                defaults.set(true, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Quits and opens Layland again, passing `arguments` to the new copy. The new copy is
    /// opened only once this one has exited, and by its path with -n: `open` would otherwise
    /// front this one, or another copy of Layland that is running (an installed one, beside
    /// a development build).
    @MainActor
    static func relaunch(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 is the bundle, $1… the arguments.
        let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
            if [ $# -gt 0 ]; then exec /usr/bin/open -n "$0" --args "$@"; else exec /usr/bin/open -n "$0"; fi
            """
        process.arguments = ["-c", script, Bundle.main.bundlePath] + arguments
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

extension View {
    /// The app's language, for everything SwiftUI looks up and formats in this window. On
    /// every window's root view.
    ///
    /// Not its direction, which stays the launch language's (`applyLayoutDirection`): set here
    /// while a window is open, AppKit crashes laying it out (macOS 26), and set at launch, the
    /// window's own split view kept the sidebar's room on the left with the sidebar drawn on
    /// the right. Arabic chosen on an English launch is in Arabic at once, right to left once
    /// Layland relaunches.
    func appLanguage() -> some View {
        modifier(AppLanguageEnvironment())
    }
}

private struct AppLanguageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, AppLocale.shared.locale)
    }
}
