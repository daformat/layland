import SwiftUI

/// Receives `.layland` files opened from the Finder, before or after the session exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openURL: ((URL) -> Void)? {
        didSet { pending.forEach { openURL?($0) }; pending.removeAll() }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let openURL { openURL(url) } else { pending.append(url) }
        }
    }
}

/// Sets what has to be set before NSApplication starts, then runs the app.
@main
enum Main {
    static func main() {
        AppLanguage.applyLayoutDirection()
        LaylandApp.main()
    }
}

struct LaylandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var session = ScanSession()
    private let updater = Updater.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    static let mainWindowID = "main"

    var body: some Scene {
        // A single Window (not a WindowGroup) so commands can reopen or front it by id after
        // the user closed it.
        // The app's name, the same in every language: a String, so it isn't looked up.
        Window("Layland" as String, id: Self.mainWindowID) {
            ContentView()
                .environment(session)
                .appLanguage()
                .task {
                    session.openLicenseWindow = { openWindow(id: LicenseView.windowID) }
                    // `open -a Layland --args --scan ~/Downloads` starts scanning immediately;
                    // `--edit-palette` opens the palette editor.
                    if let path = Self.argument(after: "--scan"), session.phase == .idle {
                        if path.hasSuffix(".\(ScanArchive.fileExtension)") {
                            session.load(url: URL(fileURLWithPath: path))
                        } else {
                            session.scan(path: path)
                        }
                    }
                    if CommandLine.arguments.contains("--edit-palette") {
                        openWindow(id: PaletteEditorView.windowID)
                    }
                    if let text = Self.argument(after: "--search") {
                        session.searchText = text
                    }
                    // `--restore` and `--settings` are how a relaunch for a change of language
                    // (Settings ▸ Language) brings back the scan and the Settings window.
                    if let path = Self.argument(after: "--restore"), session.phase == .idle {
                        session.restore(url: URL(fileURLWithPath: path))
                    }
                    if CommandLine.arguments.contains("--settings") {
                        openSettings()
                    }
                    appDelegate.openURL = { url in
                        openWindow(id: Self.mainWindowID)
                        session.load(url: url)
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            LaylandCommands(session: session)
        }

        Window("Layland License", id: LicenseView.windowID) {
            LicenseView()
                .environment(session)
                .navigationTitle(L("Layland License"))
                .appLanguage()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Custom Palette", id: PaletteEditorView.windowID) {
            PaletteEditorView()
                .environment(session)
                .navigationTitle(L("Custom Palette"))
                .appLanguage()
        }
        .defaultSize(width: 380, height: 700)

        Settings {
            SettingsView()
                .environment(session)
                .appLanguage()
        }
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
