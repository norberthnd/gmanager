import Crypto
import Foundation
import Testing
@testable import GhostKit

@Suite struct AdminAPIKeyTests {
    @Test func parsesIdAndHexSecret() throws {
        let key = try AdminAPIKey(" 6489f0a1b2c3:0a1bff \n")
        #expect(key.id == "6489f0a1b2c3")
        #expect(key.secret == [0x0a, 0x1b, 0xff])
    }

    @Test(arguments: ["", "abc", "abc:", ":abcd", "id:xyz0", "id:abc", "a:b:c"])
    func rejectsMalformedKeys(_ raw: String) {
        #expect(throws: GhostError.invalidAPIKey) { try AdminAPIKey(raw) }
    }
}

@Suite struct TokenSignerTests {
    let key = try! AdminAPIKey("abc123:00112233445566778899aabbccddeeff")

    @Test func producesVerifiableHS256Token() throws {
        let token = TokenSigner.sign(key: key, issuedAt: 1_700_000_000, expiresAt: 1_700_000_300)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try JSONSerialization.jsonObject(with: base64URLDecode(parts[0])) as? [String: String]
        #expect(header == ["alg": "HS256", "kid": "abc123", "typ": "JWT"])

        let payload = try JSONSerialization.jsonObject(with: base64URLDecode(parts[1])) as? [String: Any]
        #expect(payload?["iat"] as? Int == 1_700_000_000)
        #expect(payload?["exp"] as? Int == 1_700_000_300)
        #expect(payload?["aud"] as? String == "/admin/")

        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            base64URLDecode(parts[2]),
            authenticating: Data("\(parts[0]).\(parts[1])".utf8),
            using: SymmetricKey(data: key.secret)
        )
        #expect(valid)
    }

    @Test func reusesTokenUntilNearExpiry() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let signer = TokenSigner(key: key, now: { clock.now })
        let first = signer.token()
        clock.now += 200
        #expect(signer.token() == first)
        clock.now += 50 // 250s elapsed: under the 60s refresh margin
        #expect(signer.token() != first)
    }

    private func base64URLDecode(_ text: String) -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) { base64 += "=" }
        return Data(base64Encoded: base64)!
    }
}

final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
