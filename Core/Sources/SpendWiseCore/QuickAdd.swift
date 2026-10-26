import Foundation

// Quick add and receipts (Android util/QuickAddParser.kt, GeminiReceiptClient.kt, FollowUp.kt,
// PackHint.kt, NameSuggestions.kt): what the AI answers, read into reviewable purchases and
// snapped onto the person's own names.

/// A failure whose message is written for people (the AI's, the backend's, or the app's own).
public struct AiError: Error, Equatable, LocalizedError {
    public let message: String
    public let retryable: Bool
    public init(_ message: String, retryable: Bool = false) { self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}

public struct QuickItem: Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String
    public var quantity: Double = 1
    public var unit: String? = nil
    /** Price of one unit; nil when none was given. */
    public var unitPrice: Double? = nil
    /** unitPrice is the last price paid, filled in because none was said. */
    public var priceFromHistory: Bool = false
    /** For receipt lines: the open-list item this line is, so saving into that list ticks it off. */
    public var matchedListItem: String? = nil
    /** The price was given in another currency; converted with the review's rate. */
    public var otherCurrency: Bool = false
    /** The price looks like this many of the last price paid: maybe a pack (PackHint). */
    public var packOf: Int? = nil

    public init(id: String = UUID().uuidString, name: String, quantity: Double = 1, unit: String? = nil, unitPrice: Double? = nil,
                priceFromHistory: Bool = false, matchedListItem: String? = nil, otherCurrency: Bool = false, packOf: Int? = nil) {
        self.id = id; self.name = name; self.quantity = quantity; self.unit = unit; self.unitPrice = unitPrice
        self.priceFromHistory = priceFromHistory; self.matchedListItem = matchedListItem; self.otherCurrency = otherCurrency; self.packOf = packOf
    }

    public var total: Double? { unitPrice.map { $0 * quantity } }
}

public struct QuickPurchase: Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var listName: String
    /** An existing category's name, or a new one the model suggested. nil means Groceries. */
    public var categoryName: String?
    public var storeName: String?
    public var date: Millis
    public var items: [QuickItem]
    /** Set when the items go into an existing unfinished list instead of a new one. */
    public var existingListId: Int64? = nil
    /** Money already spent (a completed list, items ticked) rather than things still to buy. */
    public var bought: Bool = true

    public init(id: String = UUID().uuidString, listName: String, categoryName: String?, storeName: String?, date: Millis,
                items: [QuickItem], existingListId: Int64? = nil, bought: Bool = true) {
        self.id = id; self.listName = listName; self.categoryName = categoryName; self.storeName = storeName
        self.date = date; self.items = items; self.existingListId = existingListId; self.bought = bought
    }

    public var total: Double { items.reduce(0) { $0 + ($1.total ?? 0) } }

    /// Rescales the prices given in the other currency; the rest are already in the app's.
    public func scalingPrices(_ factor: Double) -> QuickPurchase {
        var p = self
        p.items = items.map { item in
            guard item.otherCurrency else { return item }
            var i = item
            i.unitPrice = item.unitPrice.map { $0 * factor }
            return i
        }
        return p
    }
}

public struct QuickAddResult: Sendable {
    public var purchases: [QuickPurchase]
    /** What the model heard in a voice note. */
    public var transcript: String?
    /** ISO code of the other currency some prices were said in, e.g. "LBP". */
    public var otherCurrency: String? = nil
}

/// An unfinished list quick add can add items to, with the names of its unticked items.
public struct OpenList: Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var toBuy: [String] = []
    public init(id: Int64, name: String, toBuy: [String] = []) { self.id = id; self.name = name; self.toBuy = toBuy }
}

/// What the AI is told about the person's data, so it reuses existing names.
public struct QuickAddContext: Sendable {
    public var categories: [String]
    public var stores: [String]
    public var knownItems: [String]
    public var currencySymbol: String
    public var openLists: [OpenList] = []
    public var now: Millis = nowMillis()
    /** The saved rate of the person's other currency: how much of it is 1 currencySymbol. */
    public var conversionRate: Double? = nil

    public init(categories: [String], stores: [String], knownItems: [String], currencySymbol: String,
                openLists: [OpenList] = [], now: Millis = nowMillis(), conversionRate: Double? = nil) {
        self.categories = categories; self.stores = stores; self.knownItems = knownItems; self.currencySymbol = currencySymbol
        self.openLists = openLists; self.now = now; self.conversionRate = conversionRate
    }
}

/// `associateBy`: keyed by [key], the last one winning, as Kotlin's does.
func associate<T>(_ items: [T], by key: (T) -> String) -> [String: T] {
    var out: [String: T] = [:]
    for item in items { out[key(item)] = item }
    return out
}

extension JSON {
    /// A string field as Android reads one: control characters dropped, trimmed, "null" and empty as nil.
    func text(_ key: String) -> String? {
        guard let raw = self[key]?.content else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.lowercased() == "null" { return nil }
        return cleaned
    }
}

public enum QuickAddParser {

    /// True when an ISO code like "USD" is the currency the app's [symbol] stands for.
    public static func sameCurrency(_ code: String, _ symbol: String) -> Bool {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let symbolCode: String
        switch s {
        case "$", "US$", "USD": symbolCode = "USD"
        case "€", "EUR": symbolCode = "EUR"
        case "£", "GBP": symbolCode = "GBP"
        case "L.L.", "LL", "LBP", "ل.ل.", "ل.ل": symbolCode = "LBP"
        default: symbolCode = s
        }
        return code.trimmingCharacters(in: .whitespaces).uppercased() == symbolCode
    }

    /// Reads the model's JSON and snaps names onto the person's categories, stores and items.
    public static func parseResponse(_ json: String, _ context: QuickAddContext) throws -> QuickAddResult {
        guard let root = try? JSON.parse(json), root.object != nil else { throw AiError(str("ai_broken"), retryable: true) }
        let transcript = root.text("transcript")
        guard let purchases = root["purchases"]?.array else { return QuickAddResult(purchases: [], transcript: transcript) }
        let openListsByKey = associate(context.openLists) { matchKey($0.name) }
        let categoriesByKey = associate(context.categories, by: matchKey)
        let storesByKey = associate(context.stores, by: matchKey)
        let itemsByKey = associate(context.knownItems, by: matchKey)
        var otherCodes: [String] = []

        let parsed: [QuickPurchase] = purchases.compactMap { p in
            guard p.object != nil else { return nil }
            let items = (p["items"]?.array ?? []).compactMap { parseItem($0, itemsByKey, context, &otherCodes) }
            guard let first = items.first else { return nil }
            let category = p.text("category").map { categoriesByKey[matchKey($0)] ?? $0 }
            let openList = p.text("existingList").flatMap { openListsByKey[matchKey($0)] }
            return QuickPurchase(
                listName: openList?.name ?? p.text("listName") ?? first.name,
                categoryName: category.flatMap { $0.lowercased() == "groceries" ? nil : $0 },
                storeName: p.text("store").map { storesByKey[matchKey($0)] ?? $0 },
                date: resolveDate(p.text("date"), now: context.now),
                items: items,
                existingListId: openList?.id,
                bought: p["bought"]?.bool ?? true
            )
        }
        return QuickAddResult(purchases: parsed, transcript: transcript, otherCurrency: mostCommon(otherCodes))
    }

    /// The most frequent value; on a tie the one seen first (Kotlin's eachCount + maxByOrNull).
    static func mostCommon(_ values: [String]) -> String? {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for v in values {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        var best: String?
        for v in order where best == nil || counts[v]! > counts[best!]! { best = v }
        return best
    }

    private static func parseItem(_ o: JSON, _ itemsByKey: [String: String], _ context: QuickAddContext, _ otherCodes: inout [String]) -> QuickItem? {
        guard o.object != nil, let rawName = o.text("name") else { return nil }
        let quantity = o["quantity"]?.double.flatMap { $0 > 0 ? $0 : nil } ?? 1
        let unitPrice = o["unitPrice"]?.double.flatMap { $0 >= 0 ? $0 : nil }
        let totalPrice = o["totalPrice"]?.double.flatMap { $0 >= 0 ? $0 : nil }
        let code = o.text("currency")?.uppercased()
        let foreign = code.flatMap { sameCurrency($0, context.currencySymbol) ? nil : $0 }
        let other = foreign != nil && (unitPrice != nil || totalPrice != nil)
        if other { otherCodes.append(foreign!) }
        return QuickItem(
            name: itemsByKey[matchKey(rawName)] ?? rawName,
            quantity: round3(quantity),
            unit: cleanUnit(o.text("unit")),
            // Derived unit prices keep full precision: $3.50 for 400 g is $0.00875 a gram
            unitPrice: unitPrice.map(round3) ?? totalPrice.map { $0 / quantity },
            otherCurrency: other
        )
    }

    /// A day other than today is stored at noon so it lands on the right day in every view.
    /// Missing, unreadable or future dates mean "now".
    public static func resolveDate(_ value: String?, now: Millis) -> Millis {
        guard let value, let parsed = parseDay(value) else { return now }
        let cal = Calendar.current
        guard let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: parsed) else { return now }
        let today = Date(millis: now)
        if cal.isDate(noon, inSameDayAs: today) || noon.millis > now { return now }
        return noon.millis
    }

    /// "yyyy-MM-dd" in local time, strictly (no rolling over 2026-02-30).
    static func parseDay(_ s: String) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        let cal = Calendar.current
        guard let date = cal.date(from: c), cal.component(.day, from: date) == d, cal.component(.month, from: date) == m else { return nil }
        return date
    }

    /// Compares names by their letters and digits only (the model sometimes garbles emoji it copies).
    public static func matchKey(_ name: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
                kept.append(scalar)
            default:
                if scalar.properties.isWhitespace { kept.append(" ") }
            }
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static let unitAliases: [String: String] = {
        let table: [(String, [String])] = [
            ("l", ["l", "lt", "ltr", "liter", "liters", "litre", "litres", "لتر", "ليتر", "ليترات", "litr"]),
            ("ml", ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "مل"]),
            ("kg", ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms", "كيلو", "كغ", "kilogramme"]),
            ("g", ["g", "gr", "gram", "grams", "gramme", "grammes", "غرام"]),
            ("pack", ["pack", "packs", "package", "packet", "packets"]),
        ]
        var out: [String: String] = [:]
        for (canonical, aliases) in table { for a in aliases { out[a] = canonical } }
        return out
    }()

    private static let pieceUnits: Set<String> = ["pc", "pcs", "piece", "pieces", "x", "each", "ea", "unit", "units", "قطعة", "حبة"]

    private static func trimDots(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// A unit worth keeping, normalised; nil for "pc" and the like, since counting is the default.
    public static func cleanUnit(_ unit: String?) -> String? {
        guard let unit else { return nil }
        let trimmed = trimDots(unit)
        if trimmed.isEmpty { return nil }
        return pieceUnits.contains(trimmed.lowercased()) ? nil : normalizeUnit(trimmed)
    }

    /// "Litre", "liters" and "لتر" all become "l", so a unit price chart doesn't split them.
    public static func normalizeUnit(_ unit: String) -> String {
        unitAliases[trimDots(unit).lowercased()] ?? unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func round3(_ v: Double) -> Double { Double(javaRound(v * 1000)) / 1000 }
}

// MARK: - Receipts

/// A receipt read into a reviewable purchase, with prices still in the receipt's currency.
public struct ReceiptScan: Sendable {
    public var purchase: QuickPurchase
    /** ISO code such as "LBP" or "USD", when the model could tell. */
    public var currency: String?
    /** What the model heard in the person's voice note. */
    public var transcript: String? = nil

    public init(purchase: QuickPurchase, currency: String?, transcript: String? = nil) {
        self.purchase = purchase; self.currency = currency; self.transcript = transcript
    }
}

public enum ReceiptReader {
    /** What the backend takes for one receipt (firebase/functions/src/request.ts). */
    public static let maxPhotos = 3

    public static func parseResponse(_ json: String, _ context: QuickAddContext) throws -> ReceiptScan {
        guard let root = try? JSON.parse(json), root.object != nil else { throw AiError(str("ai_broken"), retryable: true) }
        let listItems = associate(context.openLists.flatMap(\.toBuy), by: QuickAddParser.matchKey)
        let knownItems = associate(context.knownItems, by: QuickAddParser.matchKey)
        let items: [QuickItem] = (root["items"]?.array ?? []).compactMap { o in
            guard o.object != nil, let name = o.text("name") else { return nil }
            let quantity = o["quantity"]?.double.flatMap { $0 > 0 ? $0 : nil } ?? 1
            let unitPrice = o["unitPrice"]?.double.flatMap { $0 >= 0 ? $0 : nil }
            let totalPrice = o["totalPrice"]?.double.flatMap { $0 >= 0 ? $0 : nil }
            return QuickItem(
                // The model copies a known item's name when the line is that product; snap its spelling
                name: knownItems[QuickAddParser.matchKey(name)] ?? name,
                quantity: QuickAddParser.round3(quantity),
                unit: QuickAddParser.cleanUnit(o.text("unit")),
                // The line total is what was paid, so derive from it at full precision
                unitPrice: totalPrice.map { $0 / quantity } ?? unitPrice,
                matchedListItem: o.text("listItem").flatMap { listItems[QuickAddParser.matchKey($0)] }
            )
        }
        let openList = root.text("existingList").flatMap { wanted in
            context.openLists.first { QuickAddParser.matchKey($0.name) == QuickAddParser.matchKey(wanted) }
        }
        let category = root.text("category").map { c in
            context.categories.first { QuickAddParser.matchKey($0) == QuickAddParser.matchKey(c) } ?? c
        }
        let purchase = QuickPurchase(
            listName: openList?.name ?? root.text("listName") ?? str("receipt_list_name"),
            categoryName: category.flatMap { $0.lowercased() == "groceries" ? nil : $0 },
            storeName: root.text("store").map { st in
                context.stores.first { QuickAddParser.matchKey($0) == QuickAddParser.matchKey(st) } ?? st
            },
            date: QuickAddParser.resolveDate(root.text("date"), now: context.now),
            items: items,
            existingListId: openList?.id
        )
        return ReceiptScan(purchase: purchase, currency: root.text("currency")?.uppercased(), transcript: root.text("transcript"))
    }
}

// MARK: - Follow-ups

/// The review as it is now, with the person's edits, in the shape the AI answered in, so a
/// follow-up ("use English names", "the eggs were 2") can send it back to be changed.
public enum FollowUp {
    static func day(_ time: Millis) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(millis: time))
    }

    static func round2(_ v: Double) -> Double { Double(javaRound(v * 100)) / 100 }
    // A price per gram can be $0.00875
    static func round4(_ v: Double) -> Double { Double(javaRound(v * 10_000)) / 10_000 }

    /// A quick add's purchases; prices said in the other currency go back as they were said.
    public static func quickAdd(_ purchases: [QuickPurchase], otherCurrency: String?, rate: Double?) -> String {
        JSON.object([
            ("purchases", .array(purchases.map { p in
                .object([
                    ("bought", .bool(p.bought)),
                    ("listName", .string(p.listName)),
                    ("existingList", p.existingListId != nil ? .string(p.listName) : .null),
                    ("category", .string(p.categoryName ?? "Groceries")),
                    ("store", .str(p.storeName)),
                    ("date", .string(day(p.date))),
                    ("items", .array(p.items.map { item in
                        let other = item.otherCurrency && otherCurrency != nil
                        let factor = other ? (rate ?? 1) : 1
                        return .object([
                            ("name", .string(item.name)),
                            ("quantity", .number(item.quantity)),
                            ("unit", .str(item.unit)),
                            ("unitPrice", .num(item.unitPrice.map { round4($0 * factor) })),
                            ("totalPrice", .num(item.total.map { round2($0 * factor) })),
                            ("currency", other ? .str(otherCurrency) : .null),
                        ])
                    })),
                ])
            })),
        ]).text
    }

    /// A receipt's purchase, with its prices as printed (in [currency] at [rate] when converted).
    public static func receipt(_ purchase: QuickPurchase, currency: String?, rate: Double?) -> String {
        JSON.object([
            ("store", .str(purchase.storeName)),
            ("date", .string(day(purchase.date))),
            ("currency", .str(currency)),
            ("listName", .string(purchase.listName)),
            ("category", .string(purchase.categoryName ?? "Groceries")),
            ("existingList", purchase.existingListId != nil ? .string(purchase.listName) : .null),
            ("items", .array(purchase.items.map { item in
                let factor = item.otherCurrency ? (rate ?? 1) : 1
                return .object([
                    ("name", .string(item.name)),
                    ("listItem", .str(item.matchedListItem)),
                    ("quantity", .number(item.quantity)),
                    ("unit", .str(item.unit)),
                    ("unitPrice", .num(item.unitPrice.map { round4($0 * factor) })),
                    ("totalPrice", .num(item.total.map { round2($0 * factor) })),
                ])
            })),
        ]).text
    }
}

// MARK: - Pack hints

/// A bundle on a receipt ("tuna, special offer") often reads as one item at three times the price.
/// When a price is close to a whole multiple of what was last paid for one, ask whether it was a pack.
public enum PackHint {
    static let maxPack = 12
    static func margin(_ count: Int) -> Double { 0.3 + 0.05 * Double(count) }

    /// How many [lastUnitPrice]s [unitPrice] looks like, or nil when it doesn't look like a pack.
    public static func guess(_ unitPrice: Double, _ lastUnitPrice: Double) -> Int? {
        guard unitPrice > 0, lastUnitPrice > 0 else { return nil }
        let ratio = unitPrice / lastUnitPrice
        let count = Int(javaRound(ratio))
        guard count >= 2, count <= maxPack else { return nil }
        return abs(ratio - Double(count)) < margin(count) ? count : nil
    }
}

// MARK: - Name suggestions

/// Ranks existing item names against what is typed, so "Chicken eggs" finds "Eggs hawa chicken".
public enum NameSuggestions {
    /// [names]: each name with how often it was bought (the tie-breaker), in their usual order.
    public static func rank(_ query: String, _ names: [(String, Int)], limit: Int = 6) -> [String] {
        let q = QuickAddParser.matchKey(query)
        if q.isEmpty { return [] }
        let queryWords = q.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var scored: [(name: String, score: Double, count: Int, index: Int)] = []
        for (index, (name, count)) in names.enumerated() {
            let n = QuickAddParser.matchKey(name)
            if n.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery { continue }
            let nameWords = n.split(separator: " ").map(String.init)
            let score: Double
            if n == q { score = 4 } else if n.hasPrefix(q) { score = 3 } else if n.contains(q) { score = 2 } else {
                // Words match on a shared start, so "tomato" meets "tomatoes"
                let matched = queryWords.filter { w in
                    nameWords.contains { $0.hasPrefix(String(w.prefix(4))) && w.hasPrefix(String($0.prefix(4))) }
                }.count
                if matched == 0 { continue }
                score = Double(matched) / Double(queryWords.count)
            }
            scored.append((name, score, count, index))
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.count != b.count { return a.count > b.count }
            return a.index < b.index
        }.prefix(limit).map(\.name)
    }
}

// MARK: - The AI's features and allowances

/// Each AI request names its feature, so the backend can allow, limit and price it on its own.
public enum AiFeature: String, CaseIterable, Sendable {
    case quickAdd, receipt, analysisRequest, analysisReport

    public var id: String { rawValue }

    /// Seconds to wait, covering the backend's one retry.
    public var timeout: Double {
        switch self {
        case .quickAdd: return 80
        case .receipt: return 110
        case .analysisRequest: return 80
        case .analysisReport: return 260
        }
    }
}

/// How much of a feature this account used this period, as the backend counted it [asOf].
public struct Allowance: Equatable, Sendable {
    public var used: Int
    /** nil: not in this plan. */
    public var limit: Int?
    public var weekly: Bool
    public var asOf: Millis = nowMillis()

    public init(used: Int, limit: Int?, weekly: Bool, asOf: Millis = nowMillis()) {
        self.used = used; self.limit = limit; self.weekly = weekly; self.asOf = asOf
    }

    public var left: Int? { limit.map { max(0, $0 - used) } }

    /// Still this period (the phone's day, or the week from Monday)? After midnight the count is old news.
    public func isCurrent(now: Millis = nowMillis()) -> Bool {
        func start(_ t: Millis) -> Date {
            let cal = Calendar(identifier: .gregorian)
            var day = cal.startOfDay(for: Date(millis: t))
            if weekly {
                let back = (cal.component(.weekday, from: day) + 5) % 7
                day = cal.date(byAdding: .day, value: -back, to: day)!
            }
            return day
        }
        return start(asOf) == start(now)
    }

    /// From the backend's answer: {used, limit, per: "day"|"week"}.
    public static func from(_ value: Any?) -> Allowance? {
        guard let m = value as? [String: Any] else { return nil }
        let used = (m["used"] as? NSNumber)?.intValue ?? (m["used"] as? Int) ?? 0
        let limit = (m["limit"] as? NSNumber)?.intValue ?? (m["limit"] as? Int)
        return Allowance(used: used, limit: limit, weekly: (m["per"] as? String) == "week")
    }
}

/// The parts of an AI request that don't depend on Firebase: the person's names fitted into the
/// backend's caps, and the day stamps. AiGateway.kt's `names`, `today` and `day`.
public enum AiPayload {
    public static let maxName = 120
    public static let namesBudget = 28_000

    static func formatted(_ time: Millis, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = format
        return f.string(from: Date(millis: time))
    }

    /// "Sunday, 2026-10-18": the phone's own day, which "yesterday" and "this month" are relative to.
    public static func today(_ now: Millis) -> String { formatted(now, "EEEE, yyyy-MM-dd") }

    public static func day(_ time: Millis) -> String { formatted(time, "yyyy-MM-dd") }

    /// The person's names within the backend's caps: each at most maxName characters, and
    /// namesBudget characters in all, filled in order: categories, stores, known items, open lists.
    public static func names(_ context: QuickAddContext, maxKnownItems: Int = 200, maxListItems: Int = 150, firstRecord: Millis? = nil) -> JSON {
        var left = namesBudget
        func fit(_ names: [String], _ max: Int) -> [JSON] {
            var out: [JSON] = []
            for raw in names {
                if out.count >= max { break }
                let name = String(raw.prefix(maxName))
                // Kotlin counts UTF-16 units
                let length = name.utf16.count
                if length + 2 > left { break }
                left -= length + 2
                out.append(.string(name))
            }
            return out
        }
        let categories = fit(context.categories, 400)
        let stores = fit(context.stores, 400)
        let knownItems = fit(context.knownItems, maxKnownItems)
        var openLists: [JSON] = []
        for list in context.openLists.prefix(50) {
            let name = String(list.name.prefix(maxName))
            if name.utf16.count > left { break }
            left -= name.utf16.count
            openLists.append(.object([("name", .string(name)), ("toBuy", .array(fit(list.toBuy, maxListItems)))]))
        }
        return .object([
            ("categories", .array(categories)),
            ("stores", .array(stores)),
            ("knownItems", .array(knownItems)),
            ("openLists", .array(openLists)),
            ("currencySymbol", .string(context.currencySymbol)),
            ("conversionRate", .num(context.conversionRate)),
            ("today", .string(today(context.now))),
            ("firstRecord", .str(firstRecord.map(day))),
        ])
    }
}

public extension JSON {
    /// The value as Foundation objects, for Firebase callables (nil becomes NSNull).
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .integer(let i): return i
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.foundation }
            return out
        }
    }
}
