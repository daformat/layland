import AppKit
import SwiftUI

/// Edits the working (Custom) palette. While it is open the main window shows `SampleTree`, so
/// every slot is visible and changes render live. Saving stores a named preset that appears in
/// View ▸ Color Palette.
struct PaletteEditorView: View {
    static let windowID = "paletteEditor"

    @Environment(ScanSession.self) private var session
    @State private var isNaming = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu("Load Preset") {
                    ForEach(PaletteScheme.allCases) { scheme in
                        Button(scheme.title) { session.loadCustomPalette(from: .builtIn(scheme)) }
                    }
                    if !session.userPalettes.isEmpty {
                        Divider()
                        ForEach(session.userPalettes) { palette in
                            Button(palette.name) { session.loadCustomPalette(from: .user(palette.id)) }
                        }
                    }
                }
                .fixedSize()
                if !session.userPalettes.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(session.userPalettes) { palette in
                            Button(palette.name, role: .destructive) { session.deleteUserPalette(palette.id) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Save New Preset…") {
                    presetName = ""
                    isNaming = true
                }
                .keyboardShortcut("s")
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0 ..< TreemapPalette.fileSlotCount, id: \.self) { slot in
                        row(slot: slot)
                        if slot == FileCategory.titles.count - 1 {
                            Divider().padding(.vertical, 6)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            Text("Changes apply live. The main window shows sample data with every category until this window is closed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .frame(minWidth: 340, minHeight: 500)
        .onAppear { session.beginPaletteEditing() }
        .onDisappear { session.endPaletteEditing() }
        .alert("Save Preset", isPresented: $isNaming) {
            TextField("Name", text: $presetName)
            Button("Save") { session.saveUserPalette(named: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current colors will be added to View ▸ Color Palette under this name.")
        }
    }

    private func row(slot: Int) -> some View {
        HStack(spacing: 10) {
            ColorPicker(selection: binding(for: slot), supportsOpacity: false) {
                EmptyView()
            }
            .labelsHidden()
            Text(TreemapPalette.slotTitles[slot])
            Spacer()
            Text(String(format: "%06X", session.customColors[slot]))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func binding(for slot: Int) -> Binding<Color> {
        Binding(
            get: {
                let value = session.customColors[slot]
                return Color(
                    .sRGB,
                    red: Double((value >> 16) & 0xFF) / 255,
                    green: Double((value >> 8) & 0xFF) / 255,
                    blue: Double(value & 0xFF) / 255
                )
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let value = UInt32(rgb.redComponent * 255 + 0.5) << 16
                    | UInt32(rgb.greenComponent * 255 + 0.5) << 8
                    | UInt32(rgb.blueComponent * 255 + 0.5)
                if session.customColors[slot] != value {
                    session.customColors[slot] = value
                    // Editing always affects the working copy, never a saved preset.
                    if session.paletteSelection != .custom { session.paletteSelection = .custom }
                }
            }
        )
    }
}
