import SwiftUI

/// Unlocking Layland: what a license adds, where to buy one, and the key field. Once unlocked, who it's
/// licensed to and a way to remove the key.
struct LicenseView: View {
    static let windowID = "license"

    @Environment(ScanSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case checking
        case message(String, isError: Bool)
    }

    private var licensing: Licensing { session.licensing }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.title2.weight(.semibold))
                    Text(subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if licensing.isUnlocked {
                licensedBody
            } else {
                unlockBody
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: licensing.isUnlocked) { _, _ in status = .idle }
    }

    private var headline: String {
        switch licensing.entitlement {
        case .licensed, .provisional: "Layland is unlocked"
        case let .revoked(why): why.headline
        case .free: "Unlock Layland"
        }
    }

    private var subheadline: String {
        switch licensing.entitlement {
        case let .licensed(email): email.map { "Licensed to \($0). Thank you!" } ?? "Licensed. Thank you!"
        case let .provisional(until):
            "Gumroad couldn't be reached, so the key works until \(until.formatted(date: .abbreviated, time: .shortened)) and will be checked when you're online."
        case let .revoked(why): why.explanation
        case .free: session.unlockReason ?? "See everything, however deep it's buried."
        }
    }

    // MARK: Free

    private var unlockBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                feature("eye", "Names and paths of every file and folder, at every depth")
                feature("trash", "Reveal in Finder, Quick Look and Move to Trash anywhere on the map")
                feature("magnifyingglass", "Search file names across the whole scan")
                feature("square.and.arrow.down", "Save scans and reopen them later")
            }
            Text("The free version shows the whole map and every size, and names the folders in the first \(ScanSession.freeDepth) levels of the scanned folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(Licensing.buyURL)
            } label: {
                Text("Buy Layland…")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Already bought it? Enter your license key:")
                    .font(.callout)
                HStack {
                    TextField("XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(activate)
                        .disabled(status == .checking)
                    Button("Activate", action: activate)
                        .disabled(LicenseKey(parsing: keyText) == nil || status == .checking)
                }
                HStack {
                    statusLine
                    Spacer()
                    Button("Where's my key?") { NSWorkspace.shared.open(Licensing.libraryURL) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with Gumroad…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case let .message(text, isError):
            Text(text)
                .font(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activate() {
        guard status != .checking else { return }
        guard LicenseKey(parsing: keyText) != nil else {
            status = .message("That doesn't look like a license key. It has 32 letters and digits, in four groups.", isError: true)
            return
        }
        status = .checking
        Task {
            switch await licensing.activate(keyText) {
            case .licensed, .provisional:
                keyText = ""
                status = .idle
            case .notAKey:
                status = .message("That doesn't look like a license key.", isError: true)
            case let .revoked(why):
                status = .message(why.refusal, isError: true)
            case let .invalid(message):
                status = .message(message ?? "Gumroad doesn't recognize this key.", isError: true)
            case let .unreachable(message):
                status = .message("Gumroad couldn't be reached: \(message)", isError: true)
            }
        }
    }

    // MARK: Licensed

    private var licensedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let key = licensing.record.key {
                LabeledContent("License key") {
                    Text(key.formatted)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Remove Key") { licensing.removeKey() }
                if case .provisional = licensing.entitlement {
                    Button("Check Now") { Task { await licensing.reverifyIfDue(force: true) } }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
