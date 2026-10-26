import Foundation

/// A JSON value with keys kept in order. Reading is lenient the way kotlinx.serialization's
/// `jsonPrimitive.doubleOrNull` is (a number written as a string still reads as a number), and
/// writing keeps the order things were put in, so text sent to the AI or saved in a backup reads
/// the same as the Android app's.
public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    /// A number exactly as written ("40", "1.0"), so integers stay integers.
    case integer(Int64)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default:
            if let x = a.numberValue, let y = b.numberValue, a.isNumber, b.isNumber { return x == y }
            return false
        }
    }

    var isNumber: Bool {
        switch self { case .number, .integer: return true; default: return false }
    }

    var numberValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    // MARK: Reading

    public subscript(_ key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }

    public var object: [(String, JSON)]? { if case .object(let o) = self { return o } else { return nil } }

    /// kotlinx's `contentOrNull`: a primitive's text (numbers and booleans as written), nil for null.
    public var content: String? {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .number(let d): return JSON.format(d)
        default: return nil
        }
    }

    /// kotlinx's `doubleOrNull`: a number, or a string that reads as one.
    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return d == d.rounded() ? Int64(d) : nil
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    /// kotlinx's `booleanOrNull`: true/false, also as strings.
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true" ? true : s.lowercased() == "false" ? false : nil
        default: return nil
        }
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    // MARK: Parsing

    public struct ParseError: Error {}

    public static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipSpace()
        let value = try p.value()
        p.skipSpace()
        guard p.atEnd else { throw ParseError() }
        return value
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { i >= bytes.count }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ s: String) throws {
            for b in s.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw ParseError() }
                i += 1
            }
        }

        mutating func value() throws -> JSON {
            guard i < bytes.count else { throw ParseError() }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pairs: [(String, JSON)] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    pairs.append((key, try value()))
                    skipSpace()
                    guard i < bytes.count else { throw ParseError() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                    throw ParseError()
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [JSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard i < bytes.count else { throw ParseError() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw ParseError()
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func number() throws -> JSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let text = String(bytes: bytes[start..<i], encoding: .utf8) else { throw ParseError() }
            if !text.contains(where: { ".eE".contains($0) }), let n = Int64(text) { return .integer(n) }
            guard let d = Double(text) else { throw ParseError() }
            return .number(d)
        }

        mutating func string() throws -> String {
            try expect("\"")
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw ParseError() }
                let b = bytes[i]
                i += 1
                if b == UInt8(ascii: "\"") { break }
                if b != UInt8(ascii: "\\") { out.append(b); continue }
                guard i < bytes.count else { throw ParseError() }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .utf8), let v = UInt32(s, radix: 16) else { throw ParseError() }
            i += 4
            return v
        }
    }

    // MARK: Writing

    /// Compact text, as kotlinx's `toString()` writes it ("1.0" for whole doubles, no spaces).
    public var text: String {
        var out = ""
        write(into: &out, pretty: false, indent: "")
        return out
    }

    /// Pretty text, as kotlinx's `prettyPrint = true` writes it (4 spaces).
    public var prettyText: String {
        var out = ""
        write(into: &out, pretty: true, indent: "")
        return out
    }

    /// kotlinx writes doubles the way Kotlin's Double.toString does: "40.0", "0.0088", "1.0E7", "1.0E-4".
    public static func format(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let a = abs(d)
        // The shortest digits that read back as this double, and where the point goes
        let s = "\(a)"
        var mantissa = s
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(s[..<e])
            exponent = Int(s[s.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        var point = (mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count) + exponent
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst(); point -= 1 }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        let zeros = { (n: Int) in String(repeating: "0", count: max(0, n)) }
        let body: String
        if a >= 1e-3 && a < 1e7 {
            if point <= 0 {
                body = "0." + zeros(-point) + digits
            } else if point >= digits.count {
                body = digits + zeros(point - digits.count) + ".0"
            } else {
                body = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
            }
        } else {
            let first = String(digits.prefix(1))
            let rest = digits.count > 1 ? String(digits.dropFirst()) : "0"
            body = first + "." + rest + "E" + String(point - 1)
        }
        return (d < 0 ? "-" : "") + body
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    private func write(into out: inout String, pretty: Bool, indent: String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .integer(let i): out += String(i)
        case .number(let d): out += JSON.format(d)
        case .string(let s): out += JSON.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            let inner = indent + "    "
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                if pretty { out += "\n" + inner }
                item.write(into: &out, pretty: pretty, indent: inner)
            }
            if pretty { out += "\n" + indent }
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            let inner = indent + "    "
            out += "{"
            for (n, (key, value)) in pairs.enumerated() {
                if n > 0 { out += "," }
                if pretty { out += "\n" + inner }
                out += JSON.quote(key) + (pretty ? ": " : ":")
                value.write(into: &out, pretty: pretty, indent: inner)
            }
            if pretty { out += "\n" + indent }
            out += "}"
        }
    }

    // MARK: Building

    public static func str(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }
    public static func num(_ d: Double?) -> JSON { d.map(JSON.number) ?? .null }
    public static func int(_ i: Int64?) -> JSON { i.map(JSON.integer) ?? .null }
}
