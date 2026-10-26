import Foundation

// AI spending reports (Android analysis/*.kt): what was asked, the figures computed on the phone,
// and the report the AI writes about them.

public enum AnalysisFocus: String, CaseIterable, Sendable {
    case Spending, Prices, Habits

    public var label: String {
        switch self {
        case .Spending: return "spending"
        case .Prices: return "price trends"
        case .Habits: return "shopping habits"
        }
    }
}

/// What the person asked to analyze: a period, what to look at, and anything else they said.
public struct AnalysisRequest: Equatable, Sendable {
    /** Start of the first day, local time. */
    public var start: Millis
    /** End of the last day, local time. */
    public var end: Millis
    /** In the order given; every focus when the request didn't narrow it. */
    public var focus: [AnalysisFocus] = AnalysisFocus.allCases
    public var category: String? = nil
    public var store: String? = nil
    public var item: String? = nil
    /** A question beyond the period and focus, in the person's words. */
    public var question: String? = nil
    /** What was typed or heard, kept with the report. */
    public var said: String

    public init(start: Millis, end: Millis, focus: [AnalysisFocus] = AnalysisFocus.allCases, category: String? = nil,
                store: String? = nil, item: String? = nil, question: String? = nil, said: String) {
        self.start = start; self.end = end; self.focus = focus; self.category = category; self.store = store
        self.item = item; self.question = question; self.said = said
    }

    public var focusLabel: String {
        if Set(focus) == Set(AnalysisFocus.allCases) { return "Everything" }
        let joined = focus.map(\.label).joined(separator: " and ")
        return String(joined.prefix(1)).uppercased() + String(joined.dropFirst())
    }

    /** "Groceries · Spinneys", or nil when the request covers everything. */
    public var filterLabel: String? {
        let parts = [category, store, item].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Sep 1 – Sep 30, 2026" in [locale] (the year once when both ends share it).
    public static func periodLabel(_ start: Millis, _ end: Millis, locale: Locale = .current) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: Date(millis: start)) == cal.component(.year, from: Date(millis: end))
        func f(_ template: String) -> DateFormatter {
            let df = DateFormatter()
            df.locale = locale
            df.setLocalizedDateFormatFromTemplate(template)
            return df
        }
        return f(sameYear ? "MMMd" : "MMMdyyyy").string(from: Date(millis: start)) + " – " + f("MMMdyyyy").string(from: Date(millis: end))
    }

    public static func startOfDay(_ time: Millis) -> Millis { Calendar.current.startOfDay(for: Date(millis: time)).millis }

    public static func endOfDay(_ time: Millis) -> Millis {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date(millis: time)))!.millis - 1
    }

    /// The ready-made periods offered as one-tap choices.
    public static func thisMonth(_ now: Millis) -> (Millis, Millis) {
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date(millis: now)))!
        return (first.millis, endOfDay(now))
    }

    public static func lastMonth(_ now: Millis) -> (Millis, Millis) {
        let thisStart = thisMonth(now).0
        let start = Calendar.current.date(byAdding: .month, value: -1, to: Date(millis: thisStart))!
        return (start.millis, thisStart - 1)
    }

    public static func lastMonths(_ now: Millis, _ months: Int) -> (Millis, Millis) {
        let start = Calendar.current.date(byAdding: .month, value: -(months - 1), to: Date(millis: thisMonth(now).0))!
        return (start.millis, endOfDay(now))
    }
}

/// A headline number such as total spent, with its change against the previous period.
public struct ReportFact: Equatable, Sendable {
    public var label: String
    public var value: String
    public var change: String? = nil
    /** 1 when the change costs more money, -1 when it saves, 0 when neutral. */
    public var direction: Int = 0
    public init(label: String, value: String, change: String? = nil, direction: Int = 0) {
        self.label = label; self.value = value; self.change = change; self.direction = direction
    }
}

public struct ReportSection: Equatable, Sendable {
    /** spending, prices, habits, stores or other; picks the section's icon. */
    public var kind: String
    public var heading: String
    public var body: String
    public var points: [String] = []

    public init(kind: String, heading: String, body: String, points: [String] = []) {
        self.kind = kind; self.heading = heading; self.body = body; self.points = points
    }
}

/// What a saved report shows: the facts are computed on the phone, the rest is the AI's reading.
public struct ReportContent: Equatable, Sendable {
    public var summary: String
    public var facts: [ReportFact] = []
    public var sections: [ReportSection] = []
    public var tips: [String] = []
    /** How much data the report was based on, e.g. "42 purchases, 180 items". */
    public var basedOn: String? = nil

    public init(summary: String, facts: [ReportFact] = [], sections: [ReportSection] = [], tips: [String] = [], basedOn: String? = nil) {
        self.summary = summary; self.facts = facts; self.sections = sections; self.tips = tips; self.basedOn = basedOn
    }

    /// As kotlinx writes it (every field, compact).
    public var json: String {
        JSON.object([
            ("summary", .string(summary)),
            ("facts", .array(facts.map { f in .object([
                ("label", .string(f.label)), ("value", .string(f.value)), ("change", .str(f.change)), ("direction", .integer(Int64(f.direction))),
            ]) })),
            ("sections", .array(sections.map { s in .object([
                ("kind", .string(s.kind)), ("heading", .string(s.heading)), ("body", .string(s.body)), ("points", .array(s.points.map(JSON.string))),
            ]) })),
            ("tips", .array(tips.map(JSON.string))),
            ("basedOn", .str(basedOn)),
        ]).text
    }

    /// Old reports are read leniently: only the summary is required.
    public static func from(json: String) -> ReportContent? {
        guard let root = try? JSON.parse(json), let summary = root["summary"]?.content else { return nil }
        return ReportContent(
            summary: summary,
            facts: (root["facts"]?.array ?? []).compactMap { f in
                guard let label = f["label"]?.content, let value = f["value"]?.content else { return nil }
                return ReportFact(label: label, value: value, change: f["change"].flatMap { $0.isNull ? nil : $0.content },
                                  direction: Int(f["direction"]?.int64 ?? 0))
            },
            sections: (root["sections"]?.array ?? []).compactMap { s in
                guard let kind = s["kind"]?.content, let heading = s["heading"]?.content, let body = s["body"]?.content else { return nil }
                return ReportSection(kind: kind, heading: heading, body: body, points: (s["points"]?.array ?? []).compactMap(\.content))
            },
            tips: (root["tips"]?.array ?? []).compactMap(\.content),
            basedOn: root["basedOn"].flatMap { $0.isNull ? nil : $0.content }
        )
    }
}

/// The words people read in a report's headline facts and "based on" line (the data for the AI
/// stays in English). English by default; the app passes its language's.
public struct DigestWords: Sendable {
    public var spent = "Spent"
    public var purchases = "Purchases"
    public var topCategory = "Top category"
    public var biggestPurchase = "Biggest purchase"
    public var vsPrevious: @Sendable (String) -> String = { "\($0) vs previous" }
    public var before: @Sendable (Int) -> String = { "\($0) before" }
    public var ofSpending: @Sendable (Int) -> String = { "\($0)% of spending" }
    public var category: @Sendable (String) -> String = { $0 }
    public var basedOn: @Sendable (Int, Int) -> String = { p, i in "\(p) \(p == 1 ? "purchase" : "purchases"), \(i) \(i == 1 ? "item" : "items")" }

    public init() {}

    /// In the app's language, from its strings (CoreText).
    public static func localized() -> DigestWords {
        var w = DigestWords()
        w.spent = str("fact_spent")
        w.purchases = str("fact_purchases")
        w.topCategory = str("fact_top_category")
        w.biggestPurchase = str("fact_biggest_purchase")
        w.vsPrevious = { str("fact_vs_previous", $0) }
        w.before = { str("fact_before", $0) }
        w.ofSpending = { str("fact_of_spending", $0) }
        w.category = { $0 == "Groceries" ? str("groceries") : $0 }
        w.basedOn = { p, i in str("based_on", plural("purchases_n", p), plural("items_count", i)) }
        return w
    }
}

/// The data sent to the AI for one analysis, as compact text, plus the headline facts. Every number
/// is computed here, so the AI explains figures instead of making them up.
public struct AnalysisDigest: Sendable {
    public var text: String
    public var facts: [ReportFact]
    public var purchaseCount: Int
    public var itemCount: Int
    public var includesPurchaseList: Bool
    public var currencySymbol: String = "$"
    public var words = DigestWords()

    public init(text: String, facts: [ReportFact], purchaseCount: Int, itemCount: Int, includesPurchaseList: Bool,
                currencySymbol: String = "$", words: DigestWords = DigestWords()) {
        self.text = text; self.facts = facts; self.purchaseCount = purchaseCount; self.itemCount = itemCount
        self.includesPurchaseList = includesPurchaseList; self.currencySymbol = currencySymbol; self.words = words
    }

    /// How amounts look in the data, e.g. "$4.50".
    public var currencyExample: String { formatMoney(currencySymbol, 4.5) }

    /// "12 purchases, 30 items", in the app's language.
    public var basedOn: String { words.basedOn(purchaseCount, itemCount) }

    /** About 15,000 tokens; a few cents at most per report. */
    public static let maxChars = 60_000
    static let maxItems = 80
    static let maxPriceSeries = 40
    static let maxPoints = 12
    static let day: Millis = 86_400_000
    static let priceHistory: Millis = 365 * day

    /// How far back build needs lines: the previous period and a year of prices.
    public static func historyStart(_ r: AnalysisRequest) -> Millis { min(previousStart(r), r.end - priceHistory) }

    static func previousStart(_ r: AnalysisRequest) -> Millis { r.start - (r.end + 1 - r.start) }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// Kotlin's groupBy: groups in the order their keys first appear.
    static func groups(_ lines: [PurchaseLine], _ key: (PurchaseLine) -> String) -> [(String, [PurchaseLine])] {
        var order: [String] = []
        var map: [String: [PurchaseLine]] = [:]
        for l in lines {
            let k = key(l)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(l)
        }
        return order.map { ($0, map[$0]!) }
    }

    static func sum(_ lines: [PurchaseLine]) -> Double { lines.reduce(0) { $0 + $1.total } }

    /// Kotlin's sortedByDescending: stable.
    static func sortedDescending<T>(_ items: [T], _ key: (T) -> Double) -> [T] {
        items.enumerated().sorted { a, b in
            let x = key(a.element), y = key(b.element)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// [lines] must cover historyStart to the request's end. [conversionRate] is the saved rate of
    /// the person's other currency. [firstRecord] is the oldest list's date: a previous period that
    /// starts before it is incomplete and isn't compared with.
    public static func build(_ request: AnalysisRequest, _ lines: [PurchaseLine], currencySymbol: String, conversionRate: Double? = nil,
                             firstRecord: Millis? = nil, maxChars: Int = maxChars, words: DigestWords = DigestWords()) -> AnalysisDigest {
        let filtered = lines.filter { matches(request, $0) }
        let period = filtered.filter { $0.date >= request.start && $0.date <= request.end }
        let prevStart = previousStart(request)
        let comparable = firstRecord == nil || AnalysisRequest.startOfDay(firstRecord!) <= prevStart
        let previous = comparable ? filtered.filter { $0.date >= prevStart && $0.date < request.start } : []
        let money = { (v: Double) in formatMoney(currencySymbol, v) }
        let dayF = formatter("yyyy-MM-dd")
        let monthF = formatter("yyyy-MM")
        func day(_ t: Millis) -> String { dayF.string(from: Date(millis: t)) }

        var sections: [String] = []
        var context = "CONTEXT\nPrices are in \(currencySymbol).\n"
        if let rate = conversionRate {
            context += "The person also pays in a local currency; such prices were converted at \(grouped(javaFixed(rate, 0))) per \(currencySymbol) when entered.\n"
        }
        let days = (request.end + 1 - request.start) / Self.day
        context += "Period: \(day(request.start)) to \(day(request.end)) (\(days) days).\n"
        if comparable {
            context += "Previous period of the same length, for comparison: \(day(prevStart)) to \(day(request.start - 1)).\n"
        } else {
            context += "Records start on \(day(firstRecord!)), so there is no complete previous period: don't compare with earlier spending.\n"
        }
        if let filter = request.filterLabel { context += "Only purchases matching: \(filter).\n" }
        context += "A purchase is one shop visit or occasion; it can contain several items.\n"
        sections.append(context)

        var totals = "TOTALS\nPeriod: \(money(sum(period))) in \(purchases(period)) purchases, \(period.count) items.\n"
        if comparable { totals += "Previous period: \(money(sum(previous))) in \(purchases(previous)) purchases, \(previous.count) items.\n" }
        sections.append(totals)

        if !period.isEmpty {
            let months = groups(period) { monthF.string(from: Date(millis: $0.date)) }.sorted { $0.0 < $1.0 }
            sections.append(table("BY MONTH (period)", months.map { "\($0.0): \(money(sum($0.1))) in \(purchases($0.1)) purchases" }))
            let vs = comparable ? " | previous period" : ""
            sections.append(table("BY CATEGORY: period\(vs)", compare(period, previous, comparable, { $0.categoryName ?? "Groceries" }, money)))
            sections.append(table("BY STORE: period\(vs) (no store: not recorded)", compare(period, previous, comparable, { $0.storeName ?? "no store" }, money)))

            let items = sortedDescending(groups(period, \.itemName)) { sum($0.1) }
            var rows = items.prefix(maxItems).map { (name, l) -> String in
                let series = priceSeries(l)
                let amount = series.unit.map { "\(formatQuantity(series.points.reduce(0) { $0 + $1.quantity })) \($0)" }
                    ?? "\(formatQuantity(l.reduce(0) { $0 + $1.quantity })) pieces"
                return "\(name) | \(l.count) | \(money(sum(l))) | \(amount)"
            }
            if items.count > maxItems { rows.append("(\(items.count - maxItems) more items not listed)") }
            sections.append(table("ITEMS IN PERIOD by spend: name | times bought | spent | amount bought", rows))

            // Price trends use the last year up to the period's end, so a short period still shows where prices came from
            let history = filtered.filter { $0.date >= request.end - priceHistory && $0.date <= request.end }
            let inPeriod = Set(period.map(\.itemName))
            let trends = sortedDescending(
                groups(history, \.itemName).filter { inPeriod.contains($0.0) }.compactMap { (name, l) -> (String, PriceSeries)? in
                    let s = priceSeries(l)
                    return s.points.count >= 2 ? (name, s) : nil
                }) { abs($0.1.change) }.prefix(maxPriceSeries)
            if !trends.isEmpty {
                sections.append(table(
                    "PRICE HISTORY, last 12 months, items bought in the period at least twice; per unit, oldest first, with change first to last",
                    trends.map { (name, s) in
                        let points = s.points.suffix(maxPoints).map { p in
                            "\(day(p.date)) \(formatUnitPrice(currencySymbol, p.unitPrice))\(p.store.map { " at \($0)" } ?? "")"
                        }.joined(separator: "; ")
                        return "\(name) (per \(s.unit ?? "piece"), \(percent(s.change))): \(points)"
                    }))
            }
        }

        var text = sections.joined(separator: "\n")
        let purchaseList: String? = period.isEmpty ? nil : table(
            "PURCHASES IN PERIOD, oldest first: date | list | store | category | item | quantity | unit price | total",
            period.map { l in
                [day(l.date), l.listName, l.storeName ?? "-", l.categoryName ?? "Groceries", l.itemName,
                 formatQuantity(l.quantity) + (l.unit.map { " \($0)" } ?? ""), formatUnitPrice(currencySymbol, l.unitPrice), money(l.total)]
                    .joined(separator: " | ")
            })
        // Kotlin counts UTF-16 units
        let includesList = purchaseList != nil && text.utf16.count + purchaseList!.utf16.count <= maxChars
        if let list = purchaseList {
            text += "\n" + (includesList ? list : "The full purchase list (\(period.count) items) was left out to keep this short; use the summaries above.")
        } else {
            text += "\nThere are no purchases in this period."
        }

        return AnalysisDigest(text: text, facts: facts(period, previous, money, words), purchaseCount: purchases(period),
                              itemCount: period.count, includesPurchaseList: includesList, currencySymbol: currencySymbol, words: words)
    }

    static func matches(_ r: AnalysisRequest, _ line: PurchaseLine) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let b else { return true }
            guard let a else { return false }
            return QuickAddParser.matchKey(a) == QuickAddParser.matchKey(b)
        }
        return same(line.categoryName ?? "Groceries", r.category) && same(line.storeName, r.store) && same(line.itemName, r.item)
    }

    static func purchases(_ lines: [PurchaseLine]) -> Int { Set(lines.map(\.listId)).count }

    static func table(_ title: String, _ rows: [String]) -> String { title + "\n" + rows.map { $0 + "\n" }.joined() }

    static func compare(_ period: [PurchaseLine], _ previous: [PurchaseLine], _ comparable: Bool,
                        _ key: (PurchaseLine) -> String, _ money: (Double) -> String) -> [String] {
        let now = groups(period, key).map { ($0.0, sum($0.1)) }
        let before = groups(previous, key).map { ($0.0, sum($0.1)) }
        let nowMap = Dictionary(uniqueKeysWithValues: now)
        let beforeMap = Dictionary(uniqueKeysWithValues: before)
        var keys = now.map(\.0)
        for (k, _) in before where nowMap[k] == nil { keys.append(k) }
        return sortedDescending(keys) { nowMap[$0] ?? 0 }.map { k in
            "\(k): \(money(nowMap[k] ?? 0))" + (comparable ? " | \(money(beforeMap[k] ?? 0))" : "")
        }
    }

    static func facts(_ period: [PurchaseLine], _ previous: [PurchaseLine], _ money: (Double) -> String, _ words: DigestWords) -> [ReportFact] {
        if period.isEmpty { return [] }
        let spent = sum(period)
        let spentBefore = sum(previous)
        let ch = change(spent, spentBefore)
        var out = [
            ReportFact(label: words.spent, value: money(spent), change: ch.map { words.vsPrevious(percent($0)) },
                       direction: ch.map { $0 > 0.005 ? 1 : $0 < -0.005 ? -1 : 0 } ?? 0),
            ReportFact(label: words.purchases, value: String(purchases(period)), change: previous.isEmpty ? nil : words.before(purchases(previous))),
        ]
        if let (name, l) = maxGroup(groups(period) { $0.categoryName ?? "Groceries" }) {
            out.append(ReportFact(label: words.topCategory, value: words.category(name), change: words.ofSpending(Int(javaRound(sum(l) / spent * 100)))))
        }
        if let (_, l) = maxGroup(groups(period) { String($0.listId) }) {
            out.append(ReportFact(label: words.biggestPurchase, value: money(sum(l)), change: l[0].listName))
        }
        return out
    }

    /// Kotlin's maxByOrNull: the first group with the largest total.
    static func maxGroup(_ g: [(String, [PurchaseLine])]) -> (String, [PurchaseLine])? {
        var best: (String, [PurchaseLine])?
        for entry in g where best == nil || sum(entry.1) > sum(best!.1) { best = entry }
        return best
    }

    static func change(_ now: Double, _ before: Double) -> Double? { before > 0 ? (now - before) / before : nil }

    static func percent(_ fraction: Double) -> String { (fraction >= 0 ? "+" : "−") + "\(javaRound(abs(fraction) * 100))%" }

    struct PricePoint { let date: Millis; let unitPrice: Double; let quantity: Double; let store: String? }

    struct PriceSeries {
        let unit: String?
        let points: [PricePoint]
        var change: Double {
            guard let first = points.first?.unitPrice, let last = points.last?.unitPrice else { return 0 }
            return first > 0 ? (last - first) / first : 0
        }
    }

    /// The comparable unit prices of one item, as on its insights screen: the unit used most, with
    /// unit-less amounts other than 1 counted in it ("25.4 × 1.57" is still litres).
    static func priceSeries(_ lines: [PurchaseLine]) -> PriceSeries {
        let units = lines.map { l -> String? in
            guard let u = l.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else { return nil }
            return QuickAddParser.normalizeUnit(u)
        }
        let common = QuickAddParser.mostCommon(units.compactMap { $0 })
        let points = zip(lines, units).filter { line, unit in
            line.unitPrice > 0 && (common == nil || unit == common || (unit == nil && line.quantity != 1))
        }.map { line, _ in PricePoint(date: line.date, unitPrice: line.unitPrice, quantity: line.quantity, store: line.storeName) }
        return PriceSeries(unit: common, points: points)
    }
}

/// What the request parser needs to know about the person's data.
public struct AnalysisRequestContext: Sendable {
    public var categories: [String]
    public var stores: [String]
    public var knownItems: [String]
    /** Date of the oldest list, or nil when there is none. */
    public var firstRecord: Millis?
    public var now: Millis = nowMillis()
    public init(categories: [String], stores: [String], knownItems: [String], firstRecord: Millis?, now: Millis = nowMillis()) {
        self.categories = categories; self.stores = stores; self.knownItems = knownItems; self.firstRecord = firstRecord; self.now = now
    }
}

/// Turns "analyze my spending since September" into an AnalysisRequest (a cheap, fast call).
public enum AnalysisRequestParser {
    static let defaultDays: Millis = 30 * 86_400_000

    public static func payload(text: String?, audioBase64: String?, context: AnalysisRequestContext) -> JSON {
        let names = QuickAddContext(categories: context.categories, stores: context.stores, knownItems: context.knownItems,
                                    currencySymbol: "", now: context.now)
        return .object([
            ("text", .str(text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)),
            ("audio", .str(audioBase64)),
            ("context", AiPayload.names(names, firstRecord: context.firstRecord)),
        ])
    }

    /// Resolves the model's answer into exact local times; no period means the last 30 days.
    public static func parseResponse(_ json: String, description: String?, context: AnalysisRequestContext) throws -> AnalysisRequest {
        guard let root = try? JSON.parse(json), root.object != nil else { throw AiError(str("ai_broken"), retryable: true) }
        func string(_ key: String) -> String? { root[key]?.content?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        func date(_ key: String) -> Millis? { string(key).flatMap(QuickAddParser.parseDay)?.millis }

        let today = AnalysisRequest.endOfDay(context.now)
        let end = date("endDate").map { min(AnalysisRequest.endOfDay($0), today) } ?? today
        let start = min(date("startDate").map(AnalysisRequest.startOfDay) ?? AnalysisRequest.startOfDay(end - defaultDays + 1),
                        AnalysisRequest.startOfDay(end))
        var focus: [AnalysisFocus] = []
        for f in root["focus"]?.array ?? [] {
            if let match = AnalysisFocus.allCases.first(where: { $0.rawValue.lowercased() == f.content?.lowercased() }), !focus.contains(match) {
                focus.append(match)
            }
        }
        if focus.isEmpty { focus = AnalysisFocus.allCases }
        func snap(_ value: String?, _ names: [String]) -> String? {
            value.map { v in names.first { QuickAddParser.matchKey($0) == QuickAddParser.matchKey(v) } ?? v }
        }
        return AnalysisRequest(
            start: start, end: end, focus: focus,
            category: snap(string("category"), context.categories),
            store: snap(string("store"), context.stores),
            item: snap(string("item"), context.knownItems),
            question: string("question"),
            said: string("transcript") ?? description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// A finished report: the title plus what is stored as the report's content.
public struct WrittenReport: Equatable, Sendable {
    public var title: String
    public var content: ReportContent
}

/// Writes a spending report from a digest (on the backend's stronger model).
public enum SpendingAnalyst {
    public static let sectionKinds = ["spending", "prices", "habits", "stores", "other"]

    public static func payload(_ request: AnalysisRequest, _ digest: AnalysisDigest, periodLabel: String, language: String) -> JSON {
        .object([("report", .object([
            ("said", .string(request.said)),
            ("periodLabel", .string(periodLabel)),
            ("focus", .array(request.focus.map { .string($0.label) })),
            ("question", .str(request.question)),
            ("currencyExample", .string(digest.currencyExample)),
            ("language", .string(language)),
            ("data", .string(digest.text)),
        ]))])
    }

    public static func parseResponse(_ json: String, digest: AnalysisDigest) throws -> WrittenReport {
        guard let root = try? JSON.parse(json), root.object != nil else { throw AiError(str("ai_broken"), retryable: true) }
        func text(_ o: JSON, _ key: String) -> String? { o[key]?.content?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        func lines(_ o: JSON, _ key: String) -> [String] {
            (o[key]?.array ?? []).compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        }
        guard let summary = text(root, "summary") else { throw AiError(str("report_empty"), retryable: true) }
        let sections: [ReportSection] = (root["sections"]?.array ?? []).compactMap { s in
            guard let heading = text(s, "heading") else { return nil }
            let kind = text(s, "kind")?.lowercased()
            return ReportSection(kind: kind.flatMap { sectionKinds.contains($0) ? $0 : nil } ?? "other", heading: heading,
                                 body: text(s, "body") ?? "", points: lines(s, "points"))
        }
        return WrittenReport(
            title: text(root, "title") ?? str("spending_report"),
            content: ReportContent(summary: summary, facts: digest.facts, sections: sections, tips: lines(root, "tips"), basedOn: digest.basedOn))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
