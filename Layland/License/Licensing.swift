// The licence as the app sees it: holds the record, keeps it saved, asks Gumroad when a key
// needs asking about, and answers the one question the rest of the app has — is this copy
// unlocked? What the free tier shows is decided in `ScanSession.isLocked`.

import AppKit
import Observation
import os

@MainActor
@Observable
final class Licensing {
    /// Where buyers go, and where they find a key they already bought.
    /// TODO: point these at the Layland product on Gumroad (or redirects on the site).
    static let buyURL = URL(string: "https://gumroad.com/l/layland")!
    static let libraryURL = URL(string: "https://app.gumroad.com/library")!

    private(set) var record: LicenseRecord
    /// Bumped by the clock, so views reading `entitlement` notice a provisional key lapsing.
    private var tick = 0

    @ObservationIgnored private let store = LicenseStore()
    @ObservationIgnored private let verifier = LicenseVerifier()
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var timer: Timer?
    private static let log = Logger(subsystem: "com.matjouhet.Layland", category: "license")

    init() {
        let now = Date()
        record = store.load(now: now)
        record.observe(now: now)
        store.save(record)
        Self.log.info("license: \(String(describing: self.record.entitlement(now: now)))")
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // Not at the instant of launch: that races the network coming up, and the interval
        // is a month.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.reverifyIfDue()
        }
    }

    var entitlement: Entitlement {
        _ = tick
        return record.entitlement(now: Date())
    }

    var isUnlocked: Bool { entitlement.isUnlocked }

    private func evaluate() {
        record.observe(now: Date())
        store.save(record)
        tick += 1
        Task { await reverifyIfDue() }
    }

    // MARK: Activation

    enum ActivationResult: Equatable {
        case notAKey
        case licensed
        /// Gumroad could not be reached; the key is good for 72 hours.
        case provisional
        case revoked(Revocation)
        case invalid(String?)
        /// Gumroad could not be reached and a verified key is already on file.
        case unreachable(String)
    }

    func activate(_ text: String) async -> ActivationResult {
        guard let key = LicenseKey(parsing: text) else { return .notAKey }
        let now = Date()
        switch await verifier.verify(key, incrementUses: true) {
        case let .answered(outcome):
            record.activate(key, outcome: outcome, now: now)
            store.save(record)
            switch outcome {
            case .valid: return .licensed
            case let .revoked(why): return .revoked(why)
            case let .invalid(message): return .invalid(message)
            case .malformed: return .invalid(nil)
            }
        case let .unreachable(message):
            guard record.acceptProvisionally(key, now: now) else { return .unreachable(message) }
            store.save(record)
            return .provisional
        }
    }

    func removeKey() {
        record.removeKey()
        store.save(record)
    }

    // MARK: Re-verification

    /// A verified key every thirty days, a provisional one at every tick until Gumroad
    /// answers. No answer changes nothing.
    func reverifyIfDue(force: Bool = false) async {
        guard !checking, let key = record.key, force || record.reverifyDue(now: Date()) else { return }
        checking = true
        defer { checking = false }
        switch await verifier.verify(key, incrementUses: false) {
        case let .answered(outcome):
            record.reverify(outcome: outcome, now: Date())
            store.save(record)
            Self.log.info("license checked: \(String(describing: self.record.entitlement(now: Date())))")
        case let .unreachable(message):
            Self.log.info("license check postponed: \(message)")
        }
    }
}
