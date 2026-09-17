import SwiftUI

struct LaylandCommands: Commands {
    @Bindable var session: ScanSession
    @Environment(\.openWindow) private var openWindow

    /// Reopens (or fronts) the main window — the user may have closed it — then acts.
    private func inMainWindow(_ action: (ScanSession) -> Void) {
        openWindow(id: LaylandApp.mainWindowID)
        action(session)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(session.licensing.entitlement.menuTitle) {
                session.requestUnlock(nil)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Scan") { inMainWindow { $0.reset() } }
                .keyboardShortcut("n")
            Button("Scan Folder…") { inMainWindow { $0.chooseFolder() } }
                .keyboardShortcut("o")
            Button("Scan Home Folder") { inMainWindow { $0.scanHomeFolder() } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Scan Startup Disk") { inMainWindow { $0.scanStartupDisk() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Rescan") { inMainWindow { $0.rescan() } }
                .keyboardShortcut("r")
                .disabled(session.rootPath == nil || session.isScanning)
            Button("Stop Scan") { session.cancelScan() }
                .keyboardShortcut(".")
                .disabled(!session.isScanning)
            Divider()
            Button("Open Scan…") { inMainWindow { $0.openScan() } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Save Scan…") { session.saveScan() }
                .keyboardShortcut("s")
                .disabled(session.result == nil || session.isScanning)
        }

        CommandMenu("Item") {
            Button("Quick Look") { session.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(session.selection == nil || session.isEditingPalette)
            Button("Reveal in Finder") {
                if let node = session.selection { session.revealInFinder(node) }
            }
            .keyboardShortcut(.return)
            .disabled(!session.canRevealSelection)
            // ⌘⌫ here, like Finder; plain ⌫ is handled by the treemap itself so the search field
            // keeps it.
            Button("Move to Trash") {
                if let node = session.selection { session.requestTrash(node) }
            }
            .keyboardShortcut(.delete)
            .disabled(!session.canTrashSelection)
            Divider()
            Button("Select Enclosing Folder") { session.selectEnclosingFolder() }
                .keyboardShortcut("[")
                .disabled(session.selection == nil)
            Button("Select Largest Item Inside") { session.selectLargestChild() }
                .keyboardShortcut("]")
                .disabled(session.selection == nil)
            Divider()
            Button("Next Search Result") { session.selectNextMatch() }
                .keyboardShortcut("g")
                .disabled(session.searchMatches?.isEmpty ?? true)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { session.zoomIntoSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(session.selection == nil)
            Button("Zoom Out") { session.zoomOut() }
                .keyboardShortcut(.upArrow)
                .disabled(!session.canZoomOut)
            Divider()
            Picker("Color By", selection: $session.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Show Legend", isOn: $session.showsLegend.animation())
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Show Free Space", isOn: $session.showsVolume)
            Picker("Size", selection: $session.sizeMode) {
                ForEach(SizeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Color Palette", selection: $session.paletteSelection) {
                ForEach(PaletteScheme.allCases) { scheme in
                    Text(scheme.title).tag(PaletteSelection.builtIn(scheme))
                }
                if !session.userPalettes.isEmpty {
                    Divider()
                    ForEach(session.userPalettes) { palette in
                        Text(palette.name).tag(PaletteSelection.user(palette.id))
                    }
                }
                Divider()
                Text("Custom").tag(PaletteSelection.custom)
            }
            Button("Edit Custom Palette…") { openWindow(id: PaletteEditorView.windowID) }
            Picker("Cushion Strength", selection: $session.cushionStrength) {
                ForEach(CushionStrength.allCases) { strength in
                    Text(strength.title).tag(strength)
                }
            }
            Picker("Cell Margin", selection: $session.cellMargin) {
                Text("None").tag(0)
                Text("1 pixel").tag(1)
                Text("2 pixels").tag(2)
            }
        }
    }
}
