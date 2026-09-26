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

@main
struct LaylandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var session = ScanSession()
    private let updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    static let mainWindowID = "main"

    var body: some Scene {
        // A single Window (not a WindowGroup) so commands can reopen or front it by id after
        // the user closed it.
        Window("Layland", id: Self.mainWindowID) {
            ContentView()
                .environment(session)
                .task {
                    session.openLicenseWindow = { openWindow(id: LicenseView.windowID) }
                    // `open -a Layland --args --scan ~/Downloads` starts scanning immediately;
                    // `--edit-palette` opens the palette editor.
                    if let path = Self.launchScanPath, session.phase == .idle {
                        if path.hasSuffix(".\(ScanArchive.fileExtension)") {
                            session.load(url: URL(fileURLWithPath: path))
                        } else {
                            session.scan(path: path)
                        }
                    }
                    if CommandLine.arguments.contains("--edit-palette") {
                        openWindow(id: PaletteEditorView.windowID)
                    }
                    if let index = CommandLine.arguments.firstIndex(of: "--search"), index + 1 < CommandLine.arguments.count {
                        session.searchText = CommandLine.arguments[index + 1]
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
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Custom Palette", id: PaletteEditorView.windowID) {
            PaletteEditorView()
                .environment(session)
        }
        .defaultSize(width: 380, height: 700)
    }

    private static var launchScanPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
