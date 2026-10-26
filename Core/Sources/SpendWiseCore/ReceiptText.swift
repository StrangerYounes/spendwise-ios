import Foundation

/// A line read from a receipt photo by the phone itself.
public struct ScannedItem: Hashable, Sendable {
    public var name: String
    public var quantity: Double = 1
    public var unit: String? = nil
    public var unitPrice: Double? = nil
    public var totalPrice: Double? = nil
}

/// Reads items from a receipt's text rows (Android util/ReceiptParser.kt): the fallback when the
/// AI can't be used. Android groups ML Kit's lines into rows; iOS does the same with Vision's.
public enum ReceiptText {

    /// One text box found in the photo: its text and where it is (top-left origin, any unit).
    public struct Box: Sendable {
        public var text: String
        public var top: Double, left: Double, height: Double
        public init(text: String, top: Double, left: Double, height: Double) { self.text = text; self.top = top; self.left = left; self.height = height }
    }

    /// Lines on the same level (within half a row's height) become one row, read left to right.
    public static func rows(_ boxes: [Box]) -> [String] {
        var rows: [[Box]] = []
        for box in boxes.sorted(by: { $0.top < $1.top }) {
            let center = box.top + box.height / 2
            if let i = rows.firstIndex(where: { row in
                let rowCenter = row.map { $0.top + $0.height / 2 }.reduce(0, +) / Double(row.count)
                let rowHeight = row.map(\.height).reduce(0, +) / Double(row.count)
                return abs(center - rowCenter) < rowHeight * 0.5
            }) {
                rows[i].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.map { $0.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
    }

    public static func parseRows(_ rows: [String]) -> [ScannedItem] {
        let itemRows = extractItemSection(rows)
        var items: [ScannedItem] = []
        var i = 0
        while i < itemRows.count {
            let current = itemRows[i]
            // A name on one line, its quantity and prices on the next
            if i + 1 < itemRows.count, isQuantityLine(itemRows[i + 1]), let scanned = parseQuantityLine(current, itemRows[i + 1]) {
                items.append(scanned)
                i += 2
                continue
            }
            if let scanned = parseSingleLineItem(current) { items.append(scanned) }
            i += 1
        }
        return items
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    static func extractItemSection(_ rows: [String]) -> [String] {
        var start = 0
        var stop = rows.count
        for (index, row) in rows.enumerated() {
            let lower = row.lowercased()
            if lower.contains("description") || lower.contains("amount") || lower.contains("item name") { start = index + 1 }
            if lower.hasPrefix("total") || lower.contains("cash") || lower.contains("rounding") || lower.contains("number of items") {
                stop = index
                break
            }
        }
        if start >= stop { return rows.filter { !isMetadata($0) } }
        return rows[start..<stop].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isMetadata($0) }
    }

    static let quantityLine = regex(#"^(\d+[.,\s]?\d*)\s*(pc|kg|pck\d+|g|l|ml|unit)?.*"#)
    static let quantityPrefix = regex(#"^(\d+[.,\s]?\d*)\s*(pc|kg|pck\d+|g|l|ml|unit)?\s*[@a©]?"#)

    static func isQuantityLine(_ row: String) -> Bool {
        // Kotlin's matches() needs the whole row; ".*" doesn't cross line breaks there either
        guard let m = firstMatch(quantityLine, row) else { return false }
        return m.range.location == 0 && m.range.length == (row as NSString).length
    }

    static func parseQuantityLine(_ nameRow: String, _ qtyRow: String) -> ScannedItem? {
        guard let m = firstMatch(quantityPrefix, qtyRow) else { return nil }
        let quantity = parseNumber(group(m, 1, qtyRow)) ?? 1
        let unitText = group(m, 2, qtyRow)
        let unit = unitText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : unitText
        let numbers = extractNumbers(qtyRow)
        // Skip the quantity if it's the first number
        let prices = (!numbers.isEmpty && abs(numbers[0] - quantity) < 0.01) ? Array(numbers.dropFirst()) : numbers
        guard !prices.isEmpty else { return nil }
        return ScannedItem(name: nameRow, quantity: quantity, unit: unit, unitPrice: prices[0], totalPrice: prices.count >= 2 ? prices[1] : prices[0])
    }

    static let unitAtEnd = regex(#"\s+(pc|kg|pck\d+|g|l|ml)\s*$"#)
    static let priceLike = regex(#"[\d,.\s]+[\.,]\d{2}|[\d,.\s]{5,}"#)

    static func parseSingleLineItem(_ row: String) -> ScannedItem? {
        let numbers = extractNumbers(row)
        guard let lastPrice = numbers.last else { return nil }
        // VAT markers at the end (0, 1, *)
        let effective = (lastPrice < 5 && numbers.count >= 2) ? numbers[numbers.count - 2] : lastPrice
        if effective < 100 { return nil } // too small to be an item's price on these receipts
        guard let m = firstMatch(priceLike, row), let r = Range(m.range, in: row) else { return nil }
        let first = String(row[r])
        guard let at = row.range(of: first) else { return nil }
        let namePart = String(row[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
        var name = namePart
        var unit: String?
        if let um = firstMatch(unitAtEnd, namePart), let ur = Range(um.range, in: namePart) {
            name = String(namePart[..<ur.lowerBound]).trimmingCharacters(in: .whitespaces)
            unit = group(um, 1, namePart)
        }
        guard name.count > 2, !isMetadata(name) else { return nil }
        return ScannedItem(name: name, unit: unit, unitPrice: effective, totalPrice: effective)
    }

    static let shortNumber = regex(#"^\d{1,3}$"#)
    static let thousands = regex(#"^\d{3}([\.,]\d{2})?$"#)

    static func whole(_ re: NSRegularExpression, _ s: String) -> Bool {
        guard let m = firstMatch(re, s) else { return false }
        return m.range.length == (s as NSString).length
    }

    static func extractNumbers(_ text: String) -> [Double] {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var numbers: [Double] = []
        var i = 0
        while i < parts.count {
            var current = parts[i]
            // "120 000,00": a group of thousands split by a space
            if i + 1 < parts.count, whole(shortNumber, current), whole(thousands, parts[i + 1]) {
                current += parts[i + 1]
                i += 1
            }
            if let n = parseNumber(current) { numbers.append(n) }
            i += 1
        }
        return numbers
    }

    static func parseNumber(_ text: String) -> Double? {
        let cleaned = String(text.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") })
        if cleaned.isEmpty { return nil }
        let lastDot = cleaned.lastIndex(of: ".").map { cleaned.distance(from: cleaned.startIndex, to: $0) } ?? -1
        let lastComma = cleaned.lastIndex(of: ",").map { cleaned.distance(from: cleaned.startIndex, to: $0) } ?? -1
        let lastSep = max(lastDot, lastComma)
        if lastSep != -1 && cleaned.count - lastSep <= 3 {
            let integerPart = String(cleaned.prefix(lastSep)).filter { $0 != "." && $0 != "," }
            let decimalPart = String(cleaned.dropFirst(lastSep + 1))
            return Double("\(integerPart).\(decimalPart)")
        }
        return Double(cleaned.filter { $0 != "." && $0 != "," })
    }

    static func isMetadata(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["total", "cash", "rounding", "exchange", "vat", "phone", "slip", "staff", "date", "trans", "subtotal", "items",
                "points", "account", "member", "facebook", "webpage", "net.amt"].contains { lower.contains($0) }
    }
}
