import Foundation

// Money and numbers as the Android app shows and reads them (ui/components/Common.kt). Formatting
// rounds the way Java's String.format does (half up on the double's exact value), so the same
// amount reads the same on both phones.

/// Java's `"%.Nf".format(Locale.US, d)`: the exact binary value rounded half up.
public func javaFixed(_ d: Double, _ decimals: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    // Every digit of the exact value (a double has at most ~1075 of them; 60 after the point is plenty here)
    let exact = String(format: "%.60f", abs(d))
    let parts = exact.split(separator: ".", maxSplits: 1)
    var intDigits = Array(String(parts[0]))
    var frac = Array(parts.count > 1 ? String(parts[1]) : "")
    let roundUp = frac.count > decimals && frac[decimals] >= "5"
    frac = Array(frac.prefix(decimals))
    while frac.count < decimals { frac.append("0") }
    if roundUp {
        var digits = intDigits + frac
        var k = digits.count - 1
        while k >= 0 {
            if digits[k] == "9" { digits[k] = "0"; k -= 1 } else { digits[k] = Character(String(digits[k].wholeNumberValue! + 1)); break }
        }
        if k < 0 { digits.insert("1", at: 0) }
        intDigits = Array(digits.prefix(digits.count - decimals))
        frac = Array(digits.suffix(decimals))
    }
    let negative = d < 0 && (intDigits + frac).contains { $0 != "0" }
    let body = String(intDigits) + (decimals > 0 ? "." + String(frac) : "")
    return (negative ? "-" : "") + body
}

/// Thousands separated by commas: "1,234,567.50".
public func grouped(_ fixed: String) -> String {
    let negative = fixed.hasPrefix("-")
    let unsigned = negative ? String(fixed.dropFirst()) : fixed
    let parts = unsigned.split(separator: ".", maxSplits: 1)
    let digits = Array(String(parts[0]))
    var out = ""
    for (i, c) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(c)
    }
    if parts.count > 1 { out += "." + String(parts[1]) }
    return (negative ? "-" : "") + out
}

/// "$1,234.50".
public func formatMoney(_ symbol: String, _ amount: Double, decimals: Int = 2) -> String {
    symbol + grouped(javaFixed(amount, decimals))
}

/// Like formatMoney, but keeps a third decimal when there is one (fuel is priced like 1.149).
public func formatUnitPrice(_ symbol: String, _ amount: Double) -> String {
    let hasThirdDecimal = abs(amount * 100 - (amount * 100).rounded(.toNearestOrEven)) > 1e-6
    return formatMoney(symbol, amount, decimals: hasThirdDecimal ? 3 : 2)
}

private func trimZeros(_ s: String) -> String {
    var t = s
    while t.hasSuffix("0") { t.removeLast() }
    if t.hasSuffix(".") { t.removeLast() }
    return t
}

/// "1", "1.5", "0.25" instead of "1.0" / "1.50".
public func formatQuantity(_ quantity: Double) -> String {
    if quantity.truncatingRemainder(dividingBy: 1) == 0, abs(quantity) < 9.2e18 { return String(Int64(quantity)) }
    return trimZeros(javaFixed(quantity, 2))
}

/// A price for an edit field: blank for nil, no trailing ".0".
public func formatPriceInput(_ price: Double?) -> String {
    guard let price else { return "" }
    if price.truncatingRemainder(dividingBy: 1) == 0, abs(price) < 9.2e18 { return String(Int64(price)) }
    return trimZeros(javaFixed(price, 2))
}

/// Western digits for the Arabic-Indic (٠-٩) and Persian (۰-۹) ones.
func westernDigits(_ c: Character) -> Character {
    guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return c }
    switch scalar.value {
    case 0x0660...0x0669: return Character(String(scalar.value - 0x0660))
    case 0x06F0...0x06F9: return Character(String(scalar.value - 0x06F0))
    default: return c
    }
}

/// Accepts "3,50" as well as "3.50" (many keyboards only offer a comma) and the digits an Arabic or
/// Persian keyboard types ("٣٫٥٠", "۱۲").
public func parseDecimal(_ input: String) -> Double? {
    let mapped = input.trimmingCharacters(in: .whitespacesAndNewlines).map { c -> Character in
        switch c {
        case "٫", ",", "،": return "."
        default: return westernDigits(c)
        }
    }.filter { $0 != "٬" }
    let text = String(mapped)
    guard !text.isEmpty, text.allSatisfy({ "+-0123456789.eE".contains($0) }) else { return nil }
    return Double(text)
}

private let operators: Set<Character> = ["+", "-", "*", "/", "×", "÷", "−"]

/// Whether a price box holds a sum ("89500/3", "2×1.5") rather than a plain number.
public func isSum(_ input: String) -> Bool {
    input.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().contains { operators.contains($0) }
}

/// A price as typed, sums included: "89500/3", "2×1.5+0.25", "(3+4)÷2". Numbers read as
/// parseDecimal reads them; nil while the sum is unfinished or divides by zero.
public func parseAmount(_ input: String) -> Double? {
    if !isSum(input) { return parseDecimal(input) }
    enum Token: Equatable { case number(Double), op(Character) }
    var tokens: [Token] = []
    let text = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
    var i = 0
    while i < text.count {
        let c = text[i]
        if c.isWhitespace { i += 1; continue }
        switch c {
        case "+", "-", "−": tokens.append(.op(c == "−" ? "-" : c)); i += 1
        case "*", "×": tokens.append(.op("*")); i += 1
        case "/", "÷": tokens.append(.op("/")); i += 1
        case "(", ")": tokens.append(.op(c)); i += 1
        default:
            let start = i
            while i < text.count, westernDigits(text[i]).isNumber && westernDigits(text[i]).isASCII || ".,٫،٬".contains(text[i]) { i += 1 }
            if i == start { return nil }
            guard let n = parseDecimal(String(text[start..<i])) else { return nil }
            tokens.append(.number(n))
        }
    }
    var pos = 0
    func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }
    func factor() -> Double? {
        switch peek() {
        case .number(let n)?: pos += 1; return n
        case .op("-")?: pos += 1; return factor().map { -$0 }
        case .op("+")?: pos += 1; return factor()
        case .op("(")?:
            pos += 1
            guard let v = sum() else { return nil }
            guard peek() == .op(")") else { return nil }
            pos += 1
            return v
        default: return nil
        }
    }
    func product() -> Double? {
        guard var v = factor() else { return nil }
        while peek() == .op("*") || peek() == .op("/") {
            let op = peek()
            pos += 1
            guard let r = factor() else { return nil }
            if op == .op("*") { v *= r } else { if r == 0 { return nil }; v /= r }
        }
        return v
    }
    func sum() -> Double? {
        var v = product()
        while v != nil, peek() == .op("+") || peek() == .op("-") {
            let op = peek()
            pos += 1
            guard let r = product() else { return nil }
            v = op == .op("+") ? v! + r : v! - r
        }
        return v
    }
    guard let result = sum(), pos == tokens.count, result.isFinite else { return nil }
    return result
}

/// A conversion rate as typed: rates are whole numbers like "89,500", so commas are thousands
/// separators here, not decimal commas. A point keeps a fraction.
public func parseRate(_ input: String) -> Double? {
    parseDecimal(String(input.filter { $0 != "," && $0 != "٬" && !$0.isWhitespace }))
}

/// "89,500" for a rate, "1.5" for a small one.
public func formatRate(_ rate: Double) -> String {
    rate >= 100 ? grouped(javaFixed(rate, 0)) : formatQuantity(rate)
}

/// Java's Math.round(x): half up (towards positive infinity).
public func javaRound(_ x: Double) -> Int64 { Int64((x + 0.5).rounded(.down)) }
