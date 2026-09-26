// Gumroad's license verification, as data: the request body the app sends, and what its
// answer means. Adapted from Subtitles.
//
// The endpoint is `POST https://api.gumroad.com/v2/licenses/verify`. It takes `product_id`
// and `license_key`, needs no token, and answers with the purchase record — refunded,
// charged back or disputed, the buyer's email, a `test` flag for the seller's own test
// purchases — plus a `uses` counter it increments on every call unless told
// `increment_uses_count=false`. A key it does not know, or one the seller disabled, comes
// back with `success: false` and a message.
//
// Nothing here talks to the network (LicenseVerifier does); every reading of the bytes is
// here, where a test can hand in the same bytes.

import Foundation

/// A definitive answer that a key no longer stands. Only these revoke a license: anything
/// else Gumroad says, or fails to say, leaves the record alone.
enum Revocation: String, Codable, Equatable, Sendable, CaseIterable {
    case refunded
    case chargebacked
    case disputed
    case disabled

    /// For the log: "revoked (refunded)".
    var phrase: String {
        switch self {
        case .refunded: "refunded"
        case .chargebacked: "charged back"
        case .disputed: "disputed"
        case .disabled: "disabled"
        }
    }

    /// The license window's headline.
    var headline: String { "This key was \(phrase)" }

    /// Under that headline.
    var explanation: String {
        self == .disabled
            ? "Gumroad reports the key as disabled, so it no longer unlocks Layland. Enter another to carry on."
            : "Gumroad reports the purchase as \(phrase), so the key no longer unlocks Layland. Enter another to carry on."
    }

    /// When a key just typed in turns out to have been revoked: the key on file is untouched.
    var refusal: String { "This key was \(phrase) and no longer works. Nothing has changed." }
}

enum VerifyOutcome: Equatable, Sendable {
    /// The key is good. `email` is the buyer's; `test` marks the seller's own test purchase,
    /// which counts as good.
    case valid(email: String?, test: Bool, uses: Int?)
    /// The purchase stood once and no longer does.
    case revoked(Revocation)
    /// Gumroad does not know this key for this product. Definitive at activation; ignored
    /// at re-verification of a key that was verified before.
    case invalid(message: String?)
    /// The bytes were not a verify answer at all: a proxy's error page, a half-received
    /// body. Treated exactly like no answer.
    case malformed
}

enum VerifyResponse {
    /// The form body for a verify call. `incrementUses` false is what the monthly check
    /// sends, so the dashboard's count stays a count of activations.
    static func requestBody(productID: String, key: LicenseKey, incrementUses: Bool) -> String {
        let fields = [
            ("product_id", productID),
            ("license_key", key.formatted),
            ("increment_uses_count", incrementUses ? "true" : "false"),
        ]
        return fields.map { "\($0)=\(formEncoded($1))" }.joined(separator: "&")
    }

    /// application/x-www-form-urlencoded: unreserved characters as they are, space as +,
    /// everything else percent-encoded. Gumroad's product ids end in `==`.
    static func formEncoded(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "*"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// What Gumroad's body means. The status code is not consulted: Gumroad says
    /// `success: false` in the body of every refusal.
    static func parse(_ data: Data) -> VerifyOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let success = json["success"] as? Bool else { return .malformed }
        guard success else {
            let message = json["message"] as? String
            // "This license key has been disabled." is the seller's own doing.
            if let message, message.lowercased().contains("disabled") {
                return .revoked(.disabled)
            }
            return .invalid(message: message)
        }
        guard let purchase = json["purchase"] as? [String: Any] else { return .malformed }
        if purchase["refunded"] as? Bool == true { return .revoked(.refunded) }
        if purchase["chargebacked"] as? Bool == true { return .revoked(.chargebacked) }
        // A dispute the seller won is a purchase that stands.
        if purchase["disputed"] as? Bool == true, purchase["dispute_won"] as? Bool != true {
            return .revoked(.disputed)
        }
        let email = (purchase["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .valid(email: email, test: purchase["test"] as? Bool == true, uses: json["uses"] as? Int)
    }
}
