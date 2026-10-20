import SwiftUI

/// The menus' titles go through `L`: a menu has no environment to take the app's language from,
/// and calling it is what redraws them when the language changes.
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
            CheckForUpdatesButton()
            Button(session.licensing.entitlement.menuTitle) {
                session.requestUnlock(nil)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("New Scan")) { inMainWindow { $0.reset() } }
                .keyboardShortcut("n")
            Button(L("Scan Folder…")) { inMainWindow { $0.chooseFolder() } }
                .keyboardShortcut("o")
            Button(L("Scan Home Folder")) { inMainWindow { $0.scanHomeFolder() } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(L("Scan Startup Disk")) { inMainWindow { $0.scanStartupDisk() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button(L("Rescan")) { inMainWindow { $0.rescan() } }
                .keyboardShortcut("r")
                .disabled(session.rootPath == nil || session.isScanning)
            Button(L("Stop Scan")) { session.cancelScan() }
                .keyboardShortcut(".")
                .disabled(!session.isScanning)
            Divider()
            Button(L("Open Scan…")) { inMainWindow { $0.openScan() } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(L("Save Scan…")) { session.saveScan() }
                .keyboardShortcut("s")
                .disabled(session.result == nil || session.isScanning)
        }

        CommandMenu(L("Item")) {
            Button(L("Quick Look")) { session.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(session.selection == nil || session.isEditingPalette)
            Button(L("Reveal in Finder")) {
                if let node = session.selection { session.revealInFinder(node) }
            }
            .keyboardShortcut(.return)
            .disabled(!session.canRevealSelection)
            // ⌘⌫ here, like Finder; plain ⌫ is handled by the treemap itself so the search field
            // keeps it.
            Button(L("Move to Trash")) {
                if let node = session.selection { session.requestTrash(node) }
            }
            .keyboardShortcut(.delete)
            .disabled(!session.canTrashSelection)
            Divider()
            Button(L("Select Enclosing Folder")) { session.selectEnclosingFolder() }
                .keyboardShortcut("[")
                .disabled(session.selection == nil)
            Button(L("Select Largest Item Inside")) { session.selectLargestChild() }
                .keyboardShortcut("]")
                .disabled(session.selection == nil)
            Divider()
            Button(L("Next Search Result")) { session.selectNextMatch() }
                .keyboardShortcut("g")
                .disabled(session.searchMatches?.isEmpty ?? true)
        }

        CommandGroup(after: .toolbar) {
            Button(L("Zoom In")) { session.zoomIntoSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(session.selection == nil)
            Button(L("Zoom Out")) { session.zoomOut() }
                .keyboardShortcut(.upArrow)
                .disabled(!session.canZoomOut)
            Divider()
            Picker(L("Color By"), selection: $session.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker(L("Group By"), selection: $session.groupMode) {
                ForEach(GroupMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle(L("Show Legend"), isOn: $session.showsLegend.animation())
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle(L("Show Free Space"), isOn: $session.showsVolume)
            Picker(L("Size"), selection: $session.sizeMode) {
                ForEach(SizeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker(L("Color Palette"), selection: $session.paletteSelection) {
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
                Text(L("Custom")).tag(PaletteSelection.custom)
            }
            Button(L("Edit Custom Palette…")) { openWindow(id: PaletteEditorView.windowID) }
            Picker(L("Cushion Strength"), selection: $session.cushionStrength) {
                ForEach(CushionStrength.allCases) { strength in
                    Text(strength.title).tag(strength)
                }
            }
            Picker(L("Cell Margin"), selection: $session.cellMargin) {
                Text(L("None")).tag(0)
                Text(L("1 pixel")).tag(1)
                Text(L("2 pixels")).tag(2)
            }
        }
    }
}
