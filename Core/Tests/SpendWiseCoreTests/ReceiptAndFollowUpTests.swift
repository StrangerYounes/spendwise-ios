import XCTest
@testable import SpendWiseCore

/// Android ReceiptScanTest, FollowUpTest, PackHintTest, NameSuggestionsTest, AllowanceTest and
/// ReceiptParserTest, ported.
final class ReceiptScanTests: XCTestCase {
    let now = at(2026, 10, 13, 15, 30)
    lazy var context = QuickAddContext(categories: ["Groceries", "Car 🚗"], stores: ["Spinneys"], knownItems: [], currencySymbol: "$",
                                       openLists: [OpenList(id: 4, name: "Weekly", toBuy: ["Labneh", "Butter"])], now: now)

    func testReadsStoreDateCurrencyAndMatchesListItems() throws {
        let json = """
            {"store": "spinneys", "date": "2026-10-11", "currency": "lbp", "listName": "Groceries at Spinneys",
             "category": "groceries", "existingList": "weekly",
             "items": [
               {"name": "لبنة ليبان ليه 450 غ", "listItem": "labneh", "quantity": 1, "unit": null, "unitPrice": 270000, "totalPrice": 270000},
               {"name": "فول مدمس 800 غ", "listItem": null, "quantity": 2, "unit": null, "unitPrice": 80100, "totalPrice": 160200}
             ]}
            """
        let scan = try ReceiptReader.parseResponse(json, context)
        XCTAssertEqual(scan.currency, "LBP")
        let p = scan.purchase
        XCTAssertEqual(p.storeName, "Spinneys")
        XCTAssertNil(p.categoryName)
        XCTAssertEqual(p.existingListId, 4)
        XCTAssertEqual(p.listName, "Weekly")
        XCTAssertEqual(Calendar.current.component(.day, from: Date(millis: p.date)), 11)
        XCTAssertEqual(p.items[0].matchedListItem, "Labneh")
        XCTAssertNil(p.items[1].matchedListItem)
        XCTAssertClose(p.items[1].unitPrice, 80100)
        XCTAssertClose(p.items[1].total, 160200)
    }

    func testNoListOrDateMeansANewListToday() throws {
        let json = """
            {"store": null, "date": null, "currency": null, "listName": "Hardware", "category": "Home", "existingList": null,
             "items": [{"name": "Screws", "quantity": 1, "totalPrice": 2.5}]}
            """
        let p = try ReceiptReader.parseResponse(json, context).purchase
        XCTAssertNil(p.existingListId)
        XCTAssertEqual(p.listName, "Hardware")
        XCTAssertEqual(p.categoryName, "Home")
        XCTAssertEqual(p.date, now)
    }

    func testPieceUnitsAreDropped() {
        XCTAssertNil(QuickAddParser.cleanUnit("pc"))
        XCTAssertNil(QuickAddParser.cleanUnit("قطعة"))
        XCTAssertNil(QuickAddParser.cleanUnit(" "))
        XCTAssertEqual(QuickAddParser.cleanUnit("Kilo"), "kg")
    }

    func testNoListNameMeansReceipt() throws {
        let p = try ReceiptReader.parseResponse(#"{"items": [{"name": "Milk", "totalPrice": 1}]}"#, context).purchase
        XCTAssertEqual(p.listName, "Receipt")
    }
}

final class FollowUpTests: XCTestCase {
    let now = at(2026, 10, 25, 15, 30)
    lazy var context = QuickAddContext(categories: ["Groceries"], stores: ["Spinneys"], knownItems: ["Almarai Milk 1l", "Labneh"],
                                       currencySymbol: "$", openLists: [OpenList(id: 4, name: "Weekly", toBuy: ["Butter"])], now: now)

    func testReceiptGoesBackAsPrintedAndReadsBackTheSame() throws {
        // Converted at 89,500: the AI gets the lira prices it read, and its list
        let purchase = QuickPurchase(listName: "Weekly", categoryName: nil, storeName: "Spinneys", date: now, items: [
            QuickItem(name: "Almarai Milk 1l", quantity: 2, unitPrice: 1, otherCurrency: true),
            QuickItem(name: "Butter", quantity: 1, unitPrice: 3, matchedListItem: "Butter", otherCurrency: true),
        ], existingListId: 4)
        let json = FollowUp.receipt(purchase, currency: "LBP", rate: 89_500)
        let root = try JSON.parse(json)
        XCTAssertEqual(root["currency"]?.content, "LBP")
        XCTAssertEqual(root["existingList"]?.content, "Weekly")
        XCTAssertEqual(root["category"]?.content, "Groceries")
        XCTAssertEqual(root["date"]?.content, "2026-10-25")
        let milk = try XCTUnwrap(root["items"]?.array?[0])
        XCTAssertClose(milk["unitPrice"]?.double, 89_500, 0.001)
        XCTAssertClose(milk["totalPrice"]?.double, 179_000, 0.001)

        // What comes back in that shape lands as it was
        let scan = try ReceiptReader.parseResponse(json, context)
        XCTAssertEqual(scan.purchase.existingListId, 4)
        XCTAssertEqual(scan.purchase.storeName, "Spinneys")
        XCTAssertEqual(scan.purchase.items.map(\.name), ["Almarai Milk 1l", "Butter"])
        XCTAssertEqual(scan.purchase.items[1].matchedListItem, "Butter")
        XCTAssertClose(scan.purchase.items[0].unitPrice, 89_500, 0.001)
    }

    func testQuickAddKeepsWhatWasSaidInTheOtherCurrency() throws {
        let purchases = [QuickPurchase(listName: "Bakery", categoryName: "Food", storeName: nil, date: now, items: [
            QuickItem(name: "Bread", quantity: 2, unitPrice: 1, otherCurrency: true),
            QuickItem(name: "Gas", quantity: 40, unit: "l", unitPrice: 0.00875),
        ], bought: true)]
        let json = FollowUp.quickAdd(purchases, otherCurrency: "LBP", rate: 80_000)
        let items = try XCTUnwrap(JSON.parse(json)["purchases"]?.array?[0]["items"]?.array)
        XCTAssertEqual(items[0]["currency"]?.content, "LBP")
        XCTAssertClose(items[0]["unitPrice"]?.double, 80_000, 0.001)
        XCTAssertEqual(items[1]["currency"], .null)
        XCTAssertClose(items[1]["unitPrice"]?.double, 0.0088, 0.00001)

        let result = try QuickAddParser.parseResponse(json, context)
        XCTAssertEqual(result.otherCurrency, "LBP")
        XCTAssertTrue(result.purchases[0].items[0].otherCurrency)
        XCTAssertFalse(result.purchases[0].items[1].otherCurrency)
        XCTAssertEqual(result.purchases[0].categoryName, "Food")
    }

    func testReceiptNamesSnapToTheItemLibrary() throws {
        let json = #"{"listName": "x", "items": [{"name": "almarai milk 1L", "quantity": 1, "totalPrice": 1.5}, {"name": "حليب", "quantity": 1, "totalPrice": 1}]}"#
        XCTAssertEqual(try ReceiptReader.parseResponse(json, context).purchase.items.map(\.name), ["Almarai Milk 1l", "حليب"])
    }

    func testReceiptCarriesWhatWasHeard() throws {
        let json = #"{"transcript": "سمّي الأغراض بالإنكليزي", "listName": "x", "items": [{"name": "Milk", "quantity": 1, "totalPrice": 1}]}"#
        XCTAssertEqual(try ReceiptReader.parseResponse(json, context).transcript, "سمّي الأغراض بالإنكليزي")
    }

    func testFollowUpTextIsWhatKotlinWrites() {
        // Same keys, order and number spelling as kotlinx's buildJsonObject().toString()
        let p = QuickPurchase(listName: "Gas", categoryName: nil, storeName: nil, date: at(2026, 10, 25, 12), items: [
            QuickItem(name: "Gas", quantity: 1, unitPrice: 40),
        ], bought: true)
        XCTAssertEqual(FollowUp.quickAdd([p], otherCurrency: nil, rate: nil),
                       #"{"purchases":[{"bought":true,"listName":"Gas","existingList":null,"category":"Groceries","store":null,"date":"2026-10-25","items":[{"name":"Gas","quantity":1.0,"unit":null,"unitPrice":40.0,"totalPrice":40.0,"currency":null}]}]}"#)
    }
}

final class PackHintTests: XCTestCase {
    func testABundleLooksLikeAWholeNumberOfItems() {
        // Three cans of tuna on offer for 4.00, one is usually 1.50
        XCTAssertEqual(PackHint.guess(4.0, 1.5), 3)
        XCTAssertEqual(PackHint.guess(5.9, 1.0), 6)
        XCTAssertEqual(PackHint.guess(2.1, 1.0), 2)
    }

    func testOrdinaryPricesAreLeftAlone() {
        XCTAssertNil(PackHint.guess(1.6, 1.5)) // a bit dearer
        XCTAssertNil(PackHint.guess(1.0, 1.5)) // cheaper
        XCTAssertNil(PackHint.guess(2.5, 1.0)) // halfway between 2 and 3
        XCTAssertNil(PackHint.guess(30.0, 1.0)) // more than a pack
        XCTAssertNil(PackHint.guess(3.0, 0.0))
    }
}

final class NameSuggestionsTests: XCTestCase {
    let names: [(String, Int)] = [("Eggs hawa chicken", 4), ("Tomatoes 🍅", 9), ("Tomato paste", 1), ("Milk powder klio", 2), ("Laban (libanlait)", 3)]

    func testSharedWordsMatchInAnyOrder() {
        XCTAssertEqual(NameSuggestions.rank("Chicken eggs", names).first, "Eggs hawa chicken")
    }

    func testPluralsAndEmojiStillMatch() {
        XCTAssertEqual(NameSuggestions.rank("tomato", names), ["Tomatoes 🍅", "Tomato paste"])
    }

    func testTheTypedNameItselfAndUnrelatedNamesAreLeftOut() {
        XCTAssertEqual(NameSuggestions.rank("tomatoes", names).first, "Tomatoes 🍅")
        XCTAssertFalse(NameSuggestions.rank("Tomatoes 🍅", names).contains("Tomatoes 🍅"))
        XCTAssertTrue(NameSuggestions.rank("Gas", names).isEmpty)
    }
}

final class AllowanceTests: XCTestCase {
    func testADayCountIsOldNewsAfterMidnight() {
        let a = Allowance(used: 10, limit: 10, weekly: false, asOf: at(2026, 10, 21, 23))
        XCTAssertTrue(a.isCurrent(now: at(2026, 10, 21, 23) + 50 * 60_000))
        XCTAssertFalse(a.isCurrent(now: at(2026, 10, 22, 0) + 60_000))
    }

    func testAWeekCountLastsUntilMonday() {
        // Wednesday 21 Oct 2026; the week started Monday the 19th
        let a = Allowance(used: 3, limit: 3, weekly: true, asOf: at(2026, 10, 21, 9))
        XCTAssertTrue(a.isCurrent(now: at(2026, 10, 19, 0) + 1))
        XCTAssertTrue(a.isCurrent(now: at(2026, 10, 25, 23)))
        XCTAssertFalse(a.isCurrent(now: at(2026, 10, 26, 0) + 1))
        // Asked on a Sunday: still the week from Monday the 19th
        XCTAssertTrue(Allowance(used: 1, limit: 3, weekly: true, asOf: at(2026, 10, 25, 20)).isCurrent(now: at(2026, 10, 20, 8)))
    }

    func testLeftNeverGoesBelowZeroAndIsNilOutsideThePlan() {
        XCTAssertEqual(Allowance(used: 12, limit: 10, weekly: false).left, 0)
        XCTAssertNil(Allowance(used: 0, limit: nil, weekly: false).left)
        let parsed = Allowance.from(["used": NSNumber(value: 2), "limit": NSNumber(value: 10), "per": "week"])
        XCTAssertEqual(parsed?.used, 2)
        XCTAssertEqual(parsed?.limit, 10)
        XCTAssertEqual(parsed?.weekly, true)
    }
}

final class ReceiptTextTests: XCTestCase {
    func testParseReceiptText() {
        let text = """
            mushroom extra
            0.29 kg @ 680,000.00 197,200.00 0
            Tomato Extra
            2.325 kg @ 105,000.00 244,125.00 0
            Green Sweet Pepper
            0.51 kg @ 75,000.00 38,250.00 0
            Sweet Pepper Colored
            0.66 kg @ 350,000.00 231,000.00 0
            Liban Lait laban ful pc 358,701.00 0
            Rindo tamarind 1.25m
            2 pc @ 86,303.10 172,606.20 *
            cidfoods garlic dip pc 96,193.00 *
            Al Wadi fava beans 8
            2 pc @ 132,153.00 264,306.00 *
            Rim sparkling water
            1 pck6 @ 588,845.00 588,845.00 *
            """
        let items = ReceiptText.parseRows(text.components(separatedBy: "\n"))
        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(items[0].name, "mushroom extra")
        XCTAssertEqual(items[0].quantity, 0.29, accuracy: 0.001)
        XCTAssertClose(items[0].totalPrice, 197200, 0.001)
        XCTAssertEqual(items[4].name, "Liban Lait laban ful")
        XCTAssertClose(items[4].totalPrice, 358701, 0.001)
        XCTAssertEqual(items[8].name, "Rim sparkling water")
        XCTAssertEqual(items[8].quantity, 1, accuracy: 0.001)
        XCTAssertClose(items[8].totalPrice, 588845, 0.001)
    }

    func testParseNoisyReceiptText() {
        let text = """
            Onion Red
            0,85 kg a 120 000,00 102 000,00 0
            Cucumber Local
            1.42 kg © 95.000,00 134.900,00 *
            Milk 1L Full Fat 150.000,00 0
            Bread Large Bundle 85 000,00
            Cheese Halloumi 250g 210,500.00 *
            TOTAL AMOUNT 682.400,00
            """
        let items = ReceiptText.parseRows(text.components(separatedBy: "\n"))
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].name, "Onion Red")
        XCTAssertEqual(items[0].quantity, 0.85, accuracy: 0.001)
        XCTAssertClose(items[0].totalPrice, 102000, 0.001)
        XCTAssertEqual(items[1].name, "Cucumber Local")
        XCTAssertClose(items[1].totalPrice, 134900, 0.001)
        XCTAssertEqual(items[2].name, "Milk 1L Full Fat")
        XCTAssertClose(items[2].totalPrice, 150000, 0.001)
        XCTAssertEqual(items[3].name, "Bread Large Bundle")
        XCTAssertClose(items[3].totalPrice, 85000, 0.001)
        XCTAssertEqual(items[4].name, "Cheese Halloumi 250g")
        XCTAssertClose(items[4].totalPrice, 210500, 0.001)
    }

    func testParseSecondReceiptText() {
        let text = """
            Favia Group s.a.r.l
            Description Amount
            Amarin arabic brown
            3 pc @ 102,486.00 307,458.00 0
            Domo Corn Flour Glut pc 69,223.00 0
            X-tra Ketchup Hot 34 pc 75,516.00 *
            Tomato Extra
            1.78 kg @ 90,000.00 160,200.00 0
            Bonux Standard 1.5K off2 308,357.00 *
            Total L.L. 1,436,890.00
            """
        let items = ReceiptText.parseRows(text.components(separatedBy: "\n"))
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].name, "Amarin arabic brown")
        XCTAssertClose(items[0].totalPrice, 307458, 0.01)
        XCTAssertEqual(items[1].name, "Domo Corn Flour Glut")
        XCTAssertClose(items[1].totalPrice, 69223, 0.01)
        XCTAssertEqual(items[3].name, "Tomato Extra")
        XCTAssertEqual(items[3].quantity, 1.78, accuracy: 0.01)
    }

    func testBoxesOnOneLevelBecomeOneRowLeftToRight() {
        let rows = ReceiptText.rows([
            .init(text: "197,200.00", top: 101, left: 300, height: 20),
            .init(text: "mushroom", top: 100, left: 10, height: 20),
            .init(text: "Total", top: 200, left: 10, height: 20),
        ])
        XCTAssertEqual(rows, ["mushroom 197,200.00", "Total"])
    }
}
