import XCTest
@testable import SpendWiseCore

/// Sign in with Apple: the nonce and its hash, and how accounts with no name or a hidden email are shown.
final class AppleSignInTests: XCTestCase {
    func testSha256MatchesKnownVectors() {
        XCTAssertEqual(AppleNonce.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(AppleNonce.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks (56 bytes pushes the length into a second block)
        XCTAssertEqual(AppleNonce.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(AppleNonce.sha256(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testNonceIsRandomUrlSafeAndTheRequestedLength() {
        let a = AppleNonce.make(), b = AppleNonce.make()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        XCTAssertTrue(a.allSatisfy(allowed.contains))
        XCTAssertEqual(AppleNonce.make(length: 64).count, 64)
        // The hash Apple gets is 64 hex characters, and the same nonce always gives the same one
        XCTAssertEqual(AppleNonce.sha256(a).count, 64)
        XCTAssertEqual(AppleNonce.sha256(a), AppleNonce.sha256(a))
    }

    func testAppleGivesTheNameOnlySometimes() {
        XCTAssertEqual(AccountName.fullName(given: "Rima", family: "Khoury"), "Rima Khoury")
        XCTAssertEqual(AccountName.fullName(given: " Rima ", family: nil), "Rima")
        XCTAssertNil(AccountName.fullName(given: nil, family: nil))
        XCTAssertNil(AccountName.fullName(given: "", family: "  "))
    }

    func testRelayEmailsAreRecognised() {
        XCTAssertTrue(AccountName.isPrivateRelay("x7k2p9@privaterelay.appleid.com"))
        XCTAssertTrue(AccountName.isPrivateRelay(" X7K2P9@PrivateRelay.AppleID.com"))
        XCTAssertFalse(AccountName.isPrivateRelay("rima@example.com"))
        XCTAssertFalse(AccountName.isPrivateRelay("privaterelay.appleid.com@example.com"))
    }

    func testAnAccountIsNamedByItsNameElseAVisibleEmail() {
        XCTAssertEqual(AccountName.title(name: "Rima Khoury", email: "x@privaterelay.appleid.com"), .name("Rima Khoury"))
        XCTAssertEqual(AccountName.title(name: " ", email: "rima@example.com"), .email("rima@example.com"))
        XCTAssertEqual(AccountName.title(name: "", email: "x@privaterelay.appleid.com"), .hidden)
        XCTAssertEqual(AccountName.title(name: "", email: ""), .hidden)
        XCTAssertEqual(AccountName.visibleEmail("x@privaterelay.appleid.com"), nil)
        XCTAssertEqual(AccountName.visibleEmail("rima@example.com"), "rima@example.com")
        // Invites never carry a relay address
        XCTAssertEqual(AccountName.inviter(name: "", email: "x@privaterelay.appleid.com"), "")
        XCTAssertEqual(AccountName.inviter(name: "", email: "rima@example.com"), "rima@example.com")
        XCTAssertEqual(AccountName.inviter(name: "Rima", email: "rima@example.com"), "Rima")
    }
}
