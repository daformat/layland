import Sparkle
import SwiftUI

/// In-app updates through Sparkle: a daily check of the appcast (once the user has agreed,
/// which Sparkle asks on the second launch), EdDSA and Developer ID checks on what it
/// downloads, the swap in place and the relaunch. Sparkle's standard windows suit a regular
/// windowed app like this one.
///
/// `LAYLAND_FEED=http://localhost:8000/appcast.xml` points a build at a local appcast for
/// testing, rather than editing the plist (which is how a dev feed would ship).
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private(set) var controller: SPUStandardUpdaterController!

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["LAYLAND_FEED"]
    }
}

/// App menu ▸ Check for Updates…, enabled while Sparkle can start a check.
struct CheckForUpdatesButton: View {
    @State private var model = CanCheckModel(updater: Updater.shared.updater)

    var body: some View {
        Button("Check for Updates…") { Updater.shared.updater.checkForUpdates() }
            .disabled(!model.canCheck)
    }

    @MainActor
    @Observable
    final class CanCheckModel {
        var canCheck = false
        @ObservationIgnored private var observation: NSKeyValueObservation?

        init(updater: SPUUpdater) {
            canCheck = updater.canCheckForUpdates
            observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            }
        }
    }
}
