import Foundation

/// Sign in with Apple's nonce: a random string the app keeps, whose SHA-256 goes in Apple's
/// request; Firebase checks that Apple's token carries the hash of the string the app then sends.
public enum AppleNonce {
    static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    /// A random string of [length] characters from a URL-safe set.
    public static func make(length: Int = 32) -> String {
        var rng = SystemRandomNumberGenerator()
        return make(length: length, using: &rng)
    }

    public static func make<R: RandomNumberGenerator>(length: Int, using rng: inout R) -> String {
        precondition(length > 0)
        return String((0..<length).map { _ in charset[Int(rng.next(upperBound: UInt64(charset.count)))] })
    }

    /// What goes in Apple's request: the nonce's SHA-256, lower-case hex.
    public static func sha256(_ input: String) -> String {
        SHA256.hash(Array(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// How an account is shown when its sign-in may have no name (Apple gives it only on the very first
/// sign-in) and a private relay email (…@privaterelay.appleid.com).
public enum AccountName {
    public static let relayDomain = "privaterelay.appleid.com"

    public static func isPrivateRelay(_ email: String) -> Bool {
        email.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("@" + relayDomain)
    }

    /// The name Apple gave, "Given Family", or nil when it gave none.
    public static func fullName(given: String?, family: String?) -> String? {
        let parts = [given, family].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public enum Title: Equatable {
        case name(String)
        case email(String)
        /// No name and an email Apple hides: the app says "Apple account".
        case hidden
    }

    /// The line that names an account: its name, else its email unless Apple hides it.
    public static func title(name: String, email: String) -> Title {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return .name(n) }
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty || isPrivateRelay(e) { return .hidden }
        return .email(e)
    }

    /// The email line under it for other people (family): nil when Apple hides it or there is none.
    public static func visibleEmail(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty || isPrivateRelay(e) ? nil : e
    }

    /// What an invite says about who sent it: the name, else a visible email, else nothing.
    public static func inviter(name: String, email: String) -> String {
        switch title(name: name, email: email) {
        case .name(let n): return n
        case .email(let e): return e
        case .hidden: return ""
        }
    }
}

/// SHA-256 (FIPS 180-4) in plain Swift: Core builds on Linux, where CryptoKit isn't available.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt32($0) * 8)) } }
    }
}
