// Where the licence record lives. Adapted from Subtitles.
//
// The whole record is JSON in the defaults (readable with `defaults read`); the key is also
// a generic-password item in the login Keychain, which outlives a reinstall.
// `LicenseRecord.restore` is the merge.
//
// Keychain access is per signing identity, and ad-hoc builds change identity with every
// build, so they use a separate service string and never prompt for the release build's item.

import Foundation
import os
import Security

@MainActor
final class LicenseStore {
    let service: String
    static let recordKey = "license.record"
    static let keyAccount = "key"

    private static let log = Logger(subsystem: "com.matjouhet.Layland", category: "license")
    private let defaults: UserDefaults
    /// What the Keychain held at the last read, so a save only writes what changed.
    private var keychainKey: LicenseKey?

    init(defaults: UserDefaults = .standard, service: String? = nil) {
        self.defaults = defaults
        self.service = service ?? (Self.isAdHocSigned ? "com.matjouhet.layland.license.dev" : "com.matjouhet.layland.license")
    }

    func load(now: Date) -> LicenseRecord {
        var stored: LicenseRecord?
        if let json = defaults.string(forKey: Self.recordKey) {
            stored = try? Self.decoder.decode(LicenseRecord.self, from: Data(json.utf8))
        }
        keychainKey = read(Self.keyAccount).flatMap { LicenseKey(parsing: $0) }
        return LicenseRecord.restore(defaults: stored, keychainKey: keychainKey, now: now)
    }

    func save(_ record: LicenseRecord) {
        if let data = try? Self.encoder.encode(record), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.recordKey)
        }
        if record.key != keychainKey {
            write(Self.keyAccount, record.key?.formatted)
            keychainKey = record.key
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Keychain

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { Self.log.error("read \(account): \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Nil removes the item.
    private func write(_ account: String, _ value: String?) {
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { Self.log.error("delete \(account): \(status)") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query(account)
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = "Layland license"
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status != errSecSuccess { Self.log.error("write \(account): \(status)") }
    }

    /// True when the running code carries no team identifier (ad-hoc or unsigned).
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }
}
