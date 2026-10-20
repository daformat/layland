import SwiftUI

/// Layland ▸ Settings… (⌘,). One tab for now, laid out like Subtitles' Settings so more can join it.
struct SettingsView: View {
    var body: some View {
        Group {
            if #available(macOS 15, *) {
                TabView {
                    Tab {
                        LanguageSettings()
                    } label: {
                        languageLabel
                    }
                }
            } else {
                // macOS 14 has no Tab; tabItem draws the same toolbar tab.
                TabView {
                    LanguageSettings()
                        .tabItem { languageLabel }
                }
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var languageLabel: some View {
        Label {
            Text("Language", comment: "Settings tab: the language of the app's own menus and windows")
        } icon: {
            Image(systemName: "globe")
        }
    }
}

/// Settings ▸ Language: the system's language, or one of the translations. Switched at once,
/// this window included; what macOS draws for the app follows at the next launch (see
/// `AppLanguage`), which it offers to do now.
struct LanguageSettings: View {
    @Environment(ScanSession.self) private var session
    /// nil for the system's.
    @State private var choice: String? = AppLanguage.chosen
    @State private var isRelaunching = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $choice) {
                    Text("System Language", comment: "Language picker: follow the language macOS is set to")
                        .tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.all, id: \.code) { language in
                        Text(verbatim: language.name).tag(Optional(language.code))
                    }
                } label: {
                    Text("Language")
                }
            } footer: {
                Text("The language of Layland's menus and windows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if AppLanguage.resolving(choice) != AppLanguage.launched {
                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A few menu items that macOS provides, like Quit Layland and the Edit menu, change language the next time Layland opens.")
                            if AppLanguage.isRightToLeft(AppLanguage.resolving(choice)) != AppLanguage.isRightToLeft(AppLanguage.launched) {
                                Text("So does the direction windows are laid out in.", comment: "Settings ▸ Language, after the sentence about menu items changing language at the next launch: right to left for Arabic, left to right for the others")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Relaunch Now") {
                            isRelaunching = true
                            session.relaunch()
                        }
                        .disabled(isRelaunching)
                        .help("Quit and reopen Layland, with the current scan")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: choice) { _, code in AppLanguage.switchTo(code) }
    }
}
