// Whether this copy is unlocked, and why. Adapted from Subtitles, minus its trial clock:
// Layland's free tier never expires, it just shows less (see `ScanSession.isLocked`).
//
// Honour system by construction: anyone with `defaults write` can forge a record, and that
// is not worth defending against for an app this size. The checks keep an honest person
// honest — a reinstall that would lose the key, a clock set wrong — and no more.

import Foundation

enum Entitlement: Equatable, Sendable {
    /// No key: the free tier.
    case free
    /// A key Gumroad confirmed. `email` is the buyer's, when Gumroad gave one.
    case licensed(email: String?)
    /// A well-formed key entered while Gumroad was unreachable, good until `until` and
    /// checked again as soon as the network is back.
    case provisional(until: Date)
    /// The key stood once and Gumroad has since said it does not.
    case revoked(Revocation)

    var isUnlocked: Bool {
        switch self {
        case .licensed, .provisional: true
        case .free, .revoked: false
        }
    }

    /// The app menu item that opens the license window.
    var menuTitle: String { isUnlocked ? "Layland License…" : "Unlock Layland…" }
}

struct LicenseRecord: Codable, Equatable, Sendable {
    /// The latest moment this record was evaluated at; it never moves back.
    var lastSeen: Date?
    /// The key on file, verified or provisional.
    var key: LicenseKey?
    /// The buyer's email from the last good verification, for display.
    var email: String?
    /// When Gumroad last confirmed `key`. Nil while the key is provisional.
    var verifiedAt: Date?
    /// When `key` was accepted without an answer from Gumroad.
    var provisionalSince: Date?
    /// Gumroad's definitive answer that `key` no longer stands.
    var revocation: Revocation?

    static let provisionalLength: TimeInterval = 72 * 3600
    static let reverifyInterval: TimeInterval = 30 * 86400
    /// How far the clock may step back before it counts as set back.
    static let clockTolerance: TimeInterval = 3600

    func entitlement(now: Date) -> Entitlement {
        guard key != nil else { return .free }
        if let revocation { return .revoked(revocation) }
        if verifiedAt != nil { return .licensed(email: email) }
        if let since = provisionalSince {
            let until = since.addingTimeInterval(Self.provisionalLength)
            if now >= since, now < until, !clockWentBackwards(now: now) {
                return .provisional(until: until)
            }
        }
        // Past 72 h with no answer: the key stays on file to be checked.
        return .free
    }

    func clockWentBackwards(now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now < lastSeen.addingTimeInterval(-Self.clockTolerance)
    }

    /// A provisional key is always due; a verified one every thirty days.
    func reverifyDue(now: Date) -> Bool {
        guard key != nil, revocation == nil else { return false }
        guard let verifiedAt else { return provisionalSince != nil }
        return now.timeIntervalSince(verifiedAt) >= Self.reverifyInterval
    }

    mutating func observe(now: Date) {
        if let lastSeen, lastSeen >= now { return }
        lastSeen = now
    }

    /// Gumroad's answer to a key the user just entered. Only a good answer replaces the key
    /// on file, so a licensed user mistyping a second key loses nothing.
    mutating func activate(_ key: LicenseKey, outcome: VerifyOutcome, now: Date) {
        guard case let .valid(email, _, _) = outcome else { return }
        self.key = key
        self.email = email
        verifiedAt = now
        provisionalSince = nil
        revocation = nil
        observe(now: now)
    }

    /// A well-formed key entered while Gumroad could not be reached: accepted for 72 hours,
    /// unless a verified key is already on file. Returns whether the key was taken.
    @discardableResult
    mutating func acceptProvisionally(_ key: LicenseKey, now: Date) -> Bool {
        if self.key != nil, verifiedAt != nil, revocation == nil { return false }
        self.key = key
        email = nil
        verifiedAt = nil
        provisionalSince = now
        revocation = nil
        observe(now: now)
        return true
    }

    /// The monthly check, or the first answer for a provisional key.
    mutating func reverify(outcome: VerifyOutcome, now: Date) {
        guard key != nil else { return }
        switch outcome {
        case let .valid(email, _, _):
            self.email = email
            verifiedAt = now
            provisionalSince = nil
            revocation = nil
        case let .revoked(why):
            revocation = why
        case .invalid:
            if verifiedAt == nil { removeKey() }
        case .malformed:
            break
        }
        observe(now: now)
    }

    mutating func removeKey() {
        key = nil
        email = nil
        verifiedAt = nil
        provisionalSince = nil
        revocation = nil
    }

    /// The record the defaults held, completed from the Keychain's copy of the key, which
    /// outlives a reinstall. A key found only there comes back provisional.
    static func restore(defaults: LicenseRecord?, keychainKey: LicenseKey?, now: Date) -> LicenseRecord {
        var record = defaults ?? LicenseRecord()
        if record.key == nil, let keychainKey {
            record.key = keychainKey
            record.provisionalSince = now
            record.verifiedAt = nil
            record.revocation = nil
        }
        return record
    }
}
