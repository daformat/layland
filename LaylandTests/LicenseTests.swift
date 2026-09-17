import Foundation
import Testing
@testable import Layland

struct LicenseKeyTests {
    @Test("keys are read however they were pasted")
    func parsing() {
        let canonical = "4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0"
        #expect(LicenseKey(parsing: canonical)?.formatted == canonical)
        #expect(LicenseKey(parsing: " 4b1c2d3e-5f607182-93a4b5c6-d7e8f9a0\n")?.formatted == canonical)
        #expect(LicenseKey(parsing: "4B1C2D3E5F60718293A4B5C6D7E8F9A0")?.formatted == canonical)
        #expect(LicenseKey(parsing: "4B1C2D3E-5F607182-93A4B5C6") == nil)
        #expect(LicenseKey(parsing: "4B1C2D3E-5F607182-93A4B5C6-D7E8F9AZ") == nil)
    }
}

struct VerifyResponseTests {
    private func parse(_ json: String) -> VerifyOutcome { VerifyResponse.parse(Data(json.utf8)) }

    @Test("Gumroad's answers mean what they say")
    func outcomes() {
        #expect(parse(#"{"success":true,"uses":2,"purchase":{"email":"a@b.c","refunded":false}}"#) == .valid(email: "a@b.c", test: false, uses: 2))
        #expect(parse(#"{"success":true,"purchase":{"refunded":true}}"#) == .revoked(.refunded))
        #expect(parse(#"{"success":true,"purchase":{"chargebacked":true}}"#) == .revoked(.chargebacked))
        #expect(parse(#"{"success":true,"purchase":{"disputed":true,"dispute_won":true}}"#) == .valid(email: nil, test: false, uses: nil))
        #expect(parse(#"{"success":true,"purchase":{"disputed":true}}"#) == .revoked(.disputed))
        #expect(parse(#"{"success":false,"message":"This license key has been disabled."}"#) == .revoked(.disabled))
        #expect(parse(#"{"success":false,"message":"That license does not exist for the provided product."}"#) == .invalid(message: "That license does not exist for the provided product."))
        #expect(parse("<html>captive portal</html>") == .malformed)
    }

    @Test("product ids are form-encoded")
    func body() {
        let key = LicenseKey(parsing: "4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0")!
        #expect(VerifyResponse.requestBody(productID: "ab+c==", key: key, incrementUses: false)
            == "product_id=ab%2Bc%3D%3D&license_key=4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0&increment_uses_count=false")
    }
}

struct LicenseRecordTests {
    let key = LicenseKey(parsing: "4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("no key is the free tier; a good answer unlocks")
    func activation() {
        var record = LicenseRecord()
        #expect(record.entitlement(now: now) == .free)
        record.activate(key, outcome: .invalid(message: nil), now: now)
        #expect(record.entitlement(now: now) == .free)
        record.activate(key, outcome: .valid(email: "a@b.c", test: false, uses: 1), now: now)
        #expect(record.entitlement(now: now) == .licensed(email: "a@b.c"))
        #expect(record.entitlement(now: now).isUnlocked)
    }

    @Test("an offline activation lasts 72 hours, then waits for an answer")
    func provisional() {
        var record = LicenseRecord()
        let accepted = record.acceptProvisionally(key, now: now)
        #expect(accepted)
        #expect(record.entitlement(now: now.addingTimeInterval(3600)).isUnlocked)
        #expect(record.entitlement(now: now.addingTimeInterval(73 * 3600)) == .free)
        #expect(record.reverifyDue(now: now))
        record.reverify(outcome: .invalid(message: nil), now: now)
        #expect(record.key == nil)
    }

    @Test("a verified key survives an offline mistype and loses to a refund")
    func revocation() {
        var record = LicenseRecord()
        record.activate(key, outcome: .valid(email: nil, test: false, uses: 1), now: now)
        let replaced = record.acceptProvisionally(LicenseKey(parsing: "00000000-00000000-00000000-00000000")!, now: now)
        #expect(!replaced)
        #expect(record.key == key)
        #expect(!record.reverifyDue(now: now.addingTimeInterval(86400)))
        #expect(record.reverifyDue(now: now.addingTimeInterval(31 * 86400)))
        record.reverify(outcome: .invalid(message: nil), now: now)
        #expect(record.entitlement(now: now).isUnlocked) // not one of the definitive answers
        record.reverify(outcome: .revoked(.refunded), now: now)
        #expect(record.entitlement(now: now) == .revoked(.refunded))
        #expect(!record.entitlement(now: now).isUnlocked)
    }

    @Test("a key only in the Keychain comes back provisional")
    func restore() {
        let record = LicenseRecord.restore(defaults: nil, keychainKey: key, now: now)
        #expect(record.entitlement(now: now) == .provisional(until: now.addingTimeInterval(LicenseRecord.provisionalLength)))
    }
}

struct DepthTests {
    @Test("depth counts the levels below the root")
    func depth() {
        let tree = SampleTree.shared
        #expect(tree.depth(FileTree.rootIndex) == 0)
        for node in stride(from: Int32(1), to: Int32(tree.nodes.count), by: 97) {
            #expect(tree.depth(node) == tree.ancestors(of: node).count - 1)
        }
    }
}
