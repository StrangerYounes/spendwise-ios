import XCTest
@testable import SpendWiseCore

/// Android AnalysisDigestTest and AnalysisAiTest, ported.
final class AnalysisDigestTests: XCTestCase {
    func noon(_ month: Int, _ day: Int) -> Millis { at(2026, month, day, 12, 0) }

    func line(_ name: String, _ price: Double, _ date: Millis, _ list: Int64, qty: Double = 1, unit: String? = nil,
              store: String? = "Spinneys", category: String? = "Groceries") -> PurchaseLine {
        PurchaseLine(itemName: name, quantity: qty, unit: unit, unitPrice: price, date: date, listId: list, listName: "List \(list)",
                     storeName: store, categoryName: category)
    }

    // September 2026; the previous period is the 30 days before it
    lazy var september = AnalysisRequest(start: AnalysisRequest.startOfDay(noon(9, 1)), end: AnalysisRequest.endOfDay(noon(9, 30)), said: "September")

    lazy var lines = [
        line("Gas", 1.38, noon(8, 14), 1, qty: 22, unit: "l", store: "Costco", category: "Car"),
        line("Milk", 4.0, noon(8, 20), 2),
        line("Gas", 1.58, noon(9, 5), 3, qty: 20, unit: "liters", store: "Costco", category: "Car"),
        line("Milk", 4.5, noon(9, 10), 4),
        line("Bread", 2.0, noon(9, 10), 4, qty: 2),
        line("Gas", 1.57, noon(9, 25), 5, qty: 25, store: "Costco", category: "Car"), // no unit
    ]

    func testTotalsAndComparisonsAreComputedLocally() {
        let digest = AnalysisDigest.build(september, lines, currencySymbol: "$")
        XCTAssertEqual(digest.purchaseCount, 3)
        XCTAssertEqual(digest.itemCount, 4)
        // 31.60 + 4.50 + 4.00 + 39.25 = 79.35; before: 30.36 + 4.00 = 34.36
        XCTAssertTrue(digest.text.contains("Period: $79.35 in 3 purchases, 4 items."))
        XCTAssertTrue(digest.text.contains("Previous period: $34.36 in 2 purchases, 2 items."))
        XCTAssertTrue(digest.text.contains("Car: $70.85 | $30.36"))
        let spent = digest.facts[0]
        XCTAssertEqual(spent.value, "$79.35")
        XCTAssertEqual(spent.change, "+131% vs previous")
        XCTAssertEqual(spent.direction, 1)
    }

    func testPriceHistoryCountsUnitlessAmountsInTheUsualUnit() {
        let text = AnalysisDigest.build(september, lines, currencySymbol: "$").text
        XCTAssertTrue(text.contains("Gas (per l, +14%): 2026-08-14 $1.38 at Costco; 2026-09-05 $1.58 at Costco; 2026-09-25 $1.57 at Costco"), text)
        XCTAssertTrue(text.contains("Gas | 2 | $70.85 | 45 l"), text)
        XCTAssertTrue(text.contains("Milk (per piece, +13%)"), text)
        XCTAssertFalse(text.contains("Bread (per"), "bought once, no trend")
    }

    func testFiltersToTheRequestedCategory() {
        var r = september
        r.category = "car"
        let digest = AnalysisDigest.build(r, lines, currencySymbol: "$")
        XCTAssertEqual(digest.itemCount, 2)
        XCTAssertFalse(digest.text.contains("Milk"))
        XCTAssertTrue(digest.text.contains("Only purchases matching: car."))
    }

    func testDropsThePurchaseListWhenOverBudget() {
        let full = AnalysisDigest.build(september, lines, currencySymbol: "$")
        XCTAssertTrue(full.includesPurchaseList)
        XCTAssertTrue(full.text.contains("2026-09-10 | List 4 | Spinneys | Groceries | Bread | 2 | $2.00 | $4.00"))
        let short = AnalysisDigest.build(september, lines, currencySymbol: "$", maxChars: 500)
        XCTAssertFalse(short.includesPurchaseList)
        XCTAssertTrue(short.text.contains("was left out"))
    }

    func testEmptyPeriodSaysSoAndHasNoFacts() {
        var october = september
        october.start = AnalysisRequest.startOfDay(noon(10, 1))
        october.end = AnalysisRequest.endOfDay(noon(10, 31))
        let digest = AnalysisDigest.build(october, [], currencySymbol: "$")
        XCTAssertEqual(digest.purchaseCount, 0)
        XCTAssertTrue(digest.facts.isEmpty)
        XCTAssertTrue(digest.text.contains("There are no purchases in this period."))
    }

    func testMentionsTheConversionRate() {
        XCTAssertTrue(AnalysisDigest.build(september, lines, currencySymbol: "$", conversionRate: 89_500).text.contains("89,500 per $"))
    }

    func testNoComparisonWhenRecordsStartAfterThePreviousPeriodBegins() {
        // Records start Aug 14, but the previous period would start Aug 2
        let digest = AnalysisDigest.build(september, lines, currencySymbol: "$", firstRecord: noon(8, 14))
        XCTAssertFalse(digest.text.contains("Previous period"))
        XCTAssertTrue(digest.text.contains("Records start on 2026-08-14"))
        XCTAssertTrue(digest.text.contains("Car: $70.85\n"))
        XCTAssertNil(digest.facts[0].change)
        XCTAssertNil(digest.facts[1].change)
    }

    func testComparisonKeptWhenRecordsCoverThePreviousPeriod() {
        let digest = AnalysisDigest.build(september, lines, currencySymbol: "$", firstRecord: noon(7, 1))
        XCTAssertTrue(digest.text.contains("Previous period: $34.36"))
        XCTAssertEqual(digest.currencyExample, "$4.50")
    }

    // New on iOS: the exact opening of the text, so the AI gets what Android sends

    func testContextSectionReadsAsOnAndroid() {
        let text = AnalysisDigest.build(september, lines, currencySymbol: "$").text
        XCTAssertTrue(text.hasPrefix("""
            CONTEXT
            Prices are in $.
            Period: 2026-09-01 to 2026-09-30 (30 days).
            Previous period of the same length, for comparison: 2026-08-02 to 2026-08-31.
            A purchase is one shop visit or occasion; it can contain several items.

            TOTALS
            """), text)
        XCTAssertTrue(text.contains("BY MONTH (period)\n2026-09: $79.35 in 3 purchases\n"))
        XCTAssertTrue(text.contains("BY STORE: period | previous period (no store: not recorded)\nCostco: $70.85 | $30.36\nSpinneys: $8.50 | $4.00\n"))
        XCTAssertTrue(text.contains("Top category") == false, "facts aren't in the text")
    }

    func testFactsNameTheTopCategoryAndBiggestPurchase() {
        let facts = AnalysisDigest.build(september, lines, currencySymbol: "$").facts
        XCTAssertEqual(facts.map(\.label), ["Spent", "Purchases", "Top category", "Biggest purchase"])
        XCTAssertEqual(facts[1].value, "3")
        XCTAssertEqual(facts[1].change, "2 before")
        XCTAssertEqual(facts[2].value, "Car")
        XCTAssertEqual(facts[2].change, "89% of spending")
        XCTAssertEqual(facts[3].value, "$39.25")
        XCTAssertEqual(facts[3].change, "List 5")
    }
}

final class AnalysisAiTests: XCTestCase {
    // Sunday 2026-10-18 15:30 local time
    let now = at(2026, 10, 18, 15, 30)
    func day(_ month: Int, _ d: Int) -> Millis { at(2026, month, d) }
    lazy var context = AnalysisRequestContext(categories: ["Groceries", "Car"], stores: ["Spinneys", "Costco"], knownItems: ["Gas", "Milk"],
                                              firstRecord: day(7, 1), now: now)

    func testPeriodAndFocusResolveToLocalDays() throws {
        let json = """
            {"transcript": "how did gas prices move since september", "startDate": "2026-09-01", "endDate": null,
             "focus": ["prices"], "category": null, "store": null, "item": "gas", "question": null}
            """
        let r = try AnalysisRequestParser.parseResponse(json, description: nil, context: context)
        XCTAssertEqual(r.start, day(9, 1))
        XCTAssertEqual(r.end, AnalysisRequest.endOfDay(now))
        XCTAssertEqual(r.focus, [.Prices])
        XCTAssertEqual(r.item, "Gas")
        XCTAssertEqual(r.said, "how did gas prices move since september")
    }

    func testNoPeriodMeansTheLast30DaysAndNoFocusMeansEverything() throws {
        let r = try AnalysisRequestParser.parseResponse(#"{"focus": []}"#, description: "analyze my spending", context: context)
        XCTAssertEqual(r.start, day(9, 19))
        XCTAssertEqual(Set(r.focus), Set(AnalysisFocus.allCases))
        XCTAssertEqual(r.said, "analyze my spending")
        XCTAssertEqual(r.focusLabel, "Everything")
    }

    func testFutureEndIsCappedAndReversedPeriodCollapses() throws {
        let capped = try AnalysisRequestParser.parseResponse(#"{"startDate": "2026-10-01", "endDate": "2026-12-31", "focus": ["spending"]}"#, description: "x", context: context)
        XCTAssertEqual(capped.end, AnalysisRequest.endOfDay(now))
        let reversed = try AnalysisRequestParser.parseResponse(#"{"startDate": "2026-10-10", "endDate": "2026-10-05", "focus": []}"#, description: "x", context: context)
        XCTAssertEqual(reversed.start, day(10, 5))
        XCTAssertLessThanOrEqual(reversed.start, reversed.end)
    }

    func testReportKeepsLocalFactsAndDropsBadSections() throws {
        let digest = AnalysisDigest(text: "data", facts: [ReportFact(label: "Spent", value: "$10.00")], purchaseCount: 2, itemCount: 3, includesPurchaseList: true)
        let json = """
            {"title": "September spending", "summary": " You spent less. ",
             "sections": [
               {"kind": "PRICES", "heading": "Gas got pricier", "body": "Up 14%.", "points": ["Aug $1.38", " "]},
               {"kind": "weird", "heading": "Other", "body": "x"},
               {"kind": "spending", "body": "no heading"}
             ],
             "tips": ["Buy milk at Costco"]}
            """
        let report = try SpendingAnalyst.parseResponse(json, digest: digest)
        XCTAssertEqual(report.title, "September spending")
        XCTAssertEqual(report.content.summary, "You spent less.")
        XCTAssertEqual(report.content.sections.map(\.kind), ["prices", "other"])
        XCTAssertEqual(report.content.sections[0].points, ["Aug $1.38"])
        XCTAssertEqual(report.content.facts, digest.facts)
        XCTAssertEqual(report.content.basedOn, "2 purchases, 3 items")
        XCTAssertEqual(ReportContent.from(json: report.content.json), report.content)
    }

    // New on iOS

    func testMissingSummaryIsAnEmptyReport() {
        let digest = AnalysisDigest(text: "", facts: [], purchaseCount: 0, itemCount: 0, includesPurchaseList: false)
        XCTAssertThrowsError(try SpendingAnalyst.parseResponse(#"{"title": "x"}"#, digest: digest)) {
            XCTAssertEqual(($0 as? AiError)?.message, "The report came back empty. Try again.")
        }
        XCTAssertEqual(try SpendingAnalyst.parseResponse(#"{"summary": "ok"}"#, digest: digest).title, "Spending report")
    }

    func testPresetPeriods() {
        let (start, end) = AnalysisRequest.thisMonth(now)
        XCTAssertEqual(start, at(2026, 10, 1))
        XCTAssertEqual(end, at(2026, 10, 19) - 1)
        let (ls, le) = AnalysisRequest.lastMonth(now)
        XCTAssertEqual(ls, at(2026, 9, 1))
        XCTAssertEqual(le, at(2026, 10, 1) - 1)
        XCTAssertEqual(AnalysisRequest.lastMonths(now, 3).0, at(2026, 8, 1))
    }

    func testFocusLabelsAndFilter() {
        var r = AnalysisRequest(start: 0, end: 1, focus: [.Prices, .Habits], store: "Spinneys", item: "Milk", said: "x")
        XCTAssertEqual(r.focusLabel, "Price trends and shopping habits")
        XCTAssertEqual(r.filterLabel, "Spinneys · Milk")
        r.store = nil; r.item = nil
        XCTAssertNil(r.filterLabel)
    }

    func testOldReportsWithoutNewFieldsStillRead() {
        let c = ReportContent.from(json: #"{"summary":"Fine"}"#)
        XCTAssertEqual(c?.summary, "Fine")
        XCTAssertEqual(c?.facts, [])
        XCTAssertNil(c?.basedOn)
    }

    func testReportPayloadCarriesTheDigest() throws {
        let digest = AnalysisDigest(text: "DATA", facts: [], purchaseCount: 1, itemCount: 1, includesPurchaseList: true)
        let r = AnalysisRequest(start: 0, end: 1, focus: [.Spending], question: "why?", said: "September")
        let p = SpendingAnalyst.payload(r, digest, periodLabel: "Sep 1 – Sep 30, 2026", language: "Arabic")
        XCTAssertEqual(p["report"]?["data"]?.content, "DATA")
        XCTAssertEqual(p["report"]?["focus"], .array([.string("spending")]))
        XCTAssertEqual(p["report"]?["language"]?.content, "Arabic")
        XCTAssertEqual(p["report"]?["currencyExample"]?.content, "$4.50")
    }
}
