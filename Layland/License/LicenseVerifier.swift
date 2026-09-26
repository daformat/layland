// The one request the licence ever makes: the product id and the key, to Gumroad. At
// activation with the uses counter incremented; every thirty days after with it held.
// Nothing else leaves the machine — no email, no machine name, nothing about what was scanned.

import Foundation

struct LicenseVerifier: Sendable {
    /// Gumroad's id for the product: public (it is in every buy link), so compiled in.
    static let productID = "ybsLtf7gh3y_bgEoT33-zQ=="
    static let endpoint = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    enum Result: Sendable {
        case answered(VerifyOutcome)
        case unreachable(String)
    }

    var endpoint = LicenseVerifier.endpoint

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Short: someone is looking at "Checking…", and the provisional path exists for
        // exactly the network that does not answer.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func verify(_ key: LicenseKey, incrementUses: Bool) async -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(VerifyResponse.requestBody(productID: Self.productID, key: key, incrementUses: incrementUses).utf8)
        do {
            let (data, response) = try await Self.session.data(for: request)
            let outcome = VerifyResponse.parse(data)
            if outcome == .malformed {
                // A captive portal or a proxy's error page: that is no answer.
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .unreachable("Gumroad gave an answer that couldn't be read (HTTP \(code)).")
            }
            return .answered(outcome)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
