import XCTest
@testable import SpendWiseCore

/// Android QuickAddParserTest, ported.
final class QuickAddParserTests: XCTestCase {
    // Tuesday 2026-10-13 15:30 local time
    let now = at(2026, 10, 13, 15, 30)

    lazy var context = QuickAddContext(categories: ["Groceries", "Car 🚗", "Eating out"], stores: ["Spinneys", "Shell"],
                                       knownItems: ["Gas", "Milk", "Bread 🍞"], currencySymbol: "$", now: now)

    func testGasForFortyBecomesOneItemInTheExistingCategory() throws {
        let json = """
            {"purchases": [{"listName": "Gas fill-up", "category": "car 🚗", "store": null, "date": null,
              "items": [{"name": "gas", "quantity": 1, "unit": null, "unitPrice": null, "totalPrice": 40}]}]}
            """
        let result = try XCTUnwrap(QuickAddParser.parseResponse(json, context).purchases.first)
        XCTAssertEqual(result.listName, "Gas fill-up")
        XCTAssertEqual(result.categoryName, "Car 🚗")
        XCTAssertNil(result.storeName)
        XCTAssertEqual(result.date, now)
        let item = result.items[0]
        XCTAssertEqual(item.name, "Gas") // snapped to the known item
        XCTAssertEqual(item.quantity, 1)
        XCTAssertEqual(item.unitPrice, 40)
    }

    func testLitresAndTotalGiveAPricePerLitre() throws {
        let json = """
            {"purchases": [{"listName": "Gas", "category": "Car 🚗", "store": "shell", "date": null,
              "items": [{"name": "Gas", "quantity": 35, "unit": "l", "unitPrice": null, "totalPrice": 40.25}]}]}
            """
        let result = try QuickAddParser.parseResponse(json, context).purchases[0]
        XCTAssertEqual(result.storeName, "Shell")
        let item = result.items[0]
        XCTAssertEqual(item.unit, "l")
        XCTAssertClose(item.unitPrice, 1.15, 0.0001)
        XCTAssertClose(item.total, 40.25, 0.001)
    }

    func testSeparatesPurchasesAndMapsGroceriesToDefault() throws {
        let json = """
            {"purchases": [
              {"listName": "Gas fill-up", "category": "Car 🚗", "store": null, "date": "2026-10-12",
               "items": [{"name": "Gas", "quantity": 1, "unit": null, "unitPrice": 40, "totalPrice": 40}]},
              {"listName": "Groceries at Spinneys", "category": "Groceries", "store": "Spinneys", "date": null,
               "items": [
                 {"name": "milk", "quantity": 1, "unit": null, "unitPrice": 3.5, "totalPrice": null},
                 {"name": "Bread 🍞", "quantity": 2, "unit": null, "unitPrice": 1.2, "totalPrice": 2.4}
               ]}
            ]}
            """
        let purchases = try QuickAddParser.parseResponse(json, context).purchases
        let gas = purchases[0], groceries = purchases[1]
        // Yesterday is stored at noon
        XCTAssertEqual(gas.date, at(2026, 10, 12, 12, 0))
        XCTAssertNil(groceries.categoryName, "Groceries is stored as no category")
        XCTAssertEqual(groceries.items.map(\.name), ["Milk", "Bread 🍞"])
        XCTAssertEqual(groceries.total, 5.9, accuracy: 0.001)
    }

    func testKeepsNewNamesAndItemsWithoutPrice() throws {
        let json = """
            {"purchases": [{"listName": "Haircut", "category": "Personal care", "store": "Joe's", "date": null,
              "items": [{"name": "Haircut", "quantity": 1, "unit": null, "unitPrice": null, "totalPrice": null}]}]}
            """
        let result = try QuickAddParser.parseResponse(json, context).purchases[0]
        XCTAssertEqual(result.categoryName, "Personal care")
        XCTAssertEqual(result.storeName, "Joe's")
        XCTAssertNil(result.items[0].unitPrice)
        XCTAssertEqual(result.total, 0)
    }

    func testFutureAndInvalidDatesFallBackToNow() {
        XCTAssertEqual(QuickAddParser.resolveDate("2026-12-01", now: now), now)
        XCTAssertEqual(QuickAddParser.resolveDate("not a date", now: now), now)
        XCTAssertEqual(QuickAddParser.resolveDate("2026-10-13", now: now), now)
        XCTAssertEqual(QuickAddParser.resolveDate(nil, now: now), now)
        XCTAssertEqual(QuickAddParser.resolveDate("2026-02-30", now: now), now, "not lenient")
    }

    func testMatchesNamesWhoseEmojiTheModelGarbled() throws {
        // Real response: the model returned control characters where the emoji were
        let json = "{\"purchases\": [{\"listName\": \"Gas fill-up\", \"category\": \"Car \\u0012\", \"store\": null, \"date\": null," +
            " \"items\": [{\"name\": \"Bread \\u0013\", \"quantity\": 2, \"unit\": null, \"unitPrice\": 1.2, \"totalPrice\": 2.4}]}]}"
        let result = try QuickAddParser.parseResponse(json, context).purchases[0]
        XCTAssertEqual(result.categoryName, "Car 🚗")
        XCTAssertEqual(result.items[0].name, "Bread 🍞")
    }

    func testUnmatchedNamesLoseControlCharacters() throws {
        let json = "{\"purchases\": [{\"listName\": \"Pets\", \"category\": \"Pets \\u0007\", \"store\": null, \"date\": null," +
            " \"items\": [{\"name\": \"Cat food\", \"quantity\": 1, \"unit\": null, \"unitPrice\": 5, \"totalPrice\": 5}]}]}"
        XCTAssertEqual(try QuickAddParser.parseResponse(json, context).purchases[0].categoryName, "Pets")
    }

    func testNormalizesUnitSpellings() {
        XCTAssertEqual(QuickAddParser.normalizeUnit("litre"), "l")
        XCTAssertEqual(QuickAddParser.normalizeUnit("Liters"), "l")
        XCTAssertEqual(QuickAddParser.normalizeUnit("لتر"), "l")
        XCTAssertEqual(QuickAddParser.normalizeUnit("Kilo"), "kg")
        XCTAssertEqual(QuickAddParser.normalizeUnit(" box "), "box")
    }

    func testDropsPurchasesWithoutItems() throws {
        let json = #"{"purchases": [{"listName": "Nothing", "category": null, "store": null, "date": null, "items": []}]}"#
        XCTAssertTrue(try QuickAddParser.parseResponse(json, context).purchases.isEmpty)
    }

    func testMalformedJsonIsRetryable() {
        XCTAssertThrowsError(try QuickAddParser.parseResponse("{not json", context)) { error in
            XCTAssertEqual((error as? AiError)?.retryable, true)
            XCTAssertEqual((error as? AiError)?.message, "The AI's answer came back broken. Try again.")
        }
    }

    func testVoiceNoteTranscriptComesBack() throws {
        let json = """
            {"transcript": "3abbet benzine b 40 dollar", "purchases": [{"listName": "Gas fill-up", "category": "Car 🚗",
              "store": null, "date": null, "items": [{"name": "Gas", "quantity": 1, "unit": null, "unitPrice": null, "totalPrice": 40}]}]}
            """
        let result = try QuickAddParser.parseResponse(json, context)
        XCTAssertEqual(result.transcript, "3abbet benzine b 40 dollar")
        XCTAssertEqual(result.purchases[0].items[0].name, "Gas")
    }

    func testSmallPerGramPricesKeepTheExactTotal() throws {
        let json = """
            {"purchases": [{"listName": "Groceries", "category": "Groceries", "store": null, "date": null,
              "items": [{"name": "Halloumi", "quantity": 400, "unit": "g", "unitPrice": null, "totalPrice": 3.5}]}]}
            """
        let item = try QuickAddParser.parseResponse(json, context).purchases[0].items[0]
        // 3.50 / 400 rounded to 0.009 used to make this 3.60
        XCTAssertClose(item.total, 3.5)
    }

    func testItemsForAnOpenListGoIntoIt() throws {
        var withLists = context
        withLists.openLists = [OpenList(id: 7, name: "Weekly 🛒"), OpenList(id: 9, name: "Party")]
        let json = """
            {"purchases": [{"bought": false, "listName": "Weekly", "existingList": "weekly", "category": null,
              "store": null, "date": null, "items": [{"name": "milk", "quantity": 1}]}]}
            """
        let purchase = try QuickAddParser.parseResponse(json, withLists).purchases[0]
        XCTAssertFalse(purchase.bought)
        XCTAssertEqual(purchase.existingListId, 7)
        XCTAssertEqual(purchase.listName, "Weekly 🛒")
    }

    func testUnknownOpenListMakesANewList() throws {
        let json = """
            {"purchases": [{"bought": true, "listName": "Hardware", "existingList": "Nope", "category": null,
              "store": null, "date": null, "items": [{"name": "Screws", "quantity": 1, "totalPrice": 2}]}]}
            """
        let p = try QuickAddParser.parseResponse(json, context).purchases[0]
        XCTAssertTrue(p.bought)
        XCTAssertNil(p.existingListId)
        XCTAssertEqual(p.listName, "Hardware")
    }

    func testBoughtAndToBuyBecomeSeparatePurchases() throws {
        let json = """
            {"purchases": [
              {"bought": true, "listName": "Groceries", "store": "Spinneys", "date": "2026-10-12",
               "items": [{"name": "Halloumi 400g", "quantity": 1, "totalPrice": 3.5}]},
              {"bought": false, "listName": "To buy", "store": "Spinneys", "date": null,
               "items": [{"name": "Eggs", "quantity": 1}, {"name": "Laban", "quantity": 1}]}
            ]}
            """
        let p = try QuickAddParser.parseResponse(json, context).purchases
        XCTAssertTrue(p[0].bought)
        XCTAssertFalse(p[1].bought)
        XCTAssertEqual(p[1].date, now)
        XCTAssertEqual(p[1].items.map(\.name), ["Eggs", "Laban"])
    }

    func testMissingBoughtMeansBought() throws {
        let json = #"{"purchases": [{"listName": "Gas", "items": [{"name": "Gas", "quantity": 1, "totalPrice": 40}]}]}"#
        XCTAssertTrue(try QuickAddParser.parseResponse(json, context).purchases[0].bought)
    }

    func testPricesSaidInAnotherCurrencyAreFlaggedForConversion() throws {
        let json = """
            {"purchases": [{"listName": "Bakery", "category": "Groceries", "store": null, "date": null,
              "items": [
                {"name": "Bread", "quantity": 2, "unit": null, "unitPrice": 80000, "totalPrice": null, "currency": "lbp"},
                {"name": "Milk", "quantity": 1, "unit": null, "unitPrice": 3, "totalPrice": null, "currency": "USD"},
                {"name": "Eggs", "quantity": 1, "unit": null, "unitPrice": 4, "totalPrice": null, "currency": null}
              ]}]}
            """
        let result = try QuickAddParser.parseResponse(json, context)
        XCTAssertEqual(result.otherCurrency, "LBP")
        let items = result.purchases[0].items
        XCTAssertTrue(items[0].otherCurrency)
        XCTAssertEqual(items[0].unitPrice, 80000) // as said; the review converts it
        XCTAssertFalse(items[1].otherCurrency) // USD is the app's $
        XCTAssertFalse(items[2].otherCurrency)
    }

    func testNoOtherCurrencyWhenEverythingIsInTheAppsCurrency() throws {
        let json = """
            {"purchases": [{"listName": "Gas", "category": null, "store": null, "date": null,
              "items": [{"name": "Gas", "quantity": 1, "unit": null, "unitPrice": null, "totalPrice": 40}]}]}
            """
        let result = try QuickAddParser.parseResponse(json, context)
        XCTAssertNil(result.otherCurrency)
        XCTAssertFalse(result.purchases[0].items[0].otherCurrency)
    }

    func testSameCurrencyMatchesCodesToSymbols() {
        XCTAssertTrue(QuickAddParser.sameCurrency("usd", "$"))
        XCTAssertTrue(QuickAddParser.sameCurrency("LBP", "L.L."))
        XCTAssertFalse(QuickAddParser.sameCurrency("LBP", "$"))
    }

    // New on iOS

    func testNumbersWrittenAsStringsStillRead() throws {
        // kotlinx's doubleOrNull reads "40" in quotes too
        let json = #"{"purchases": [{"listName": "Gas", "bought": "false", "items": [{"name": "Gas", "quantity": "2", "totalPrice": "40"}]}]}"#
        let p = try QuickAddParser.parseResponse(json, context).purchases[0]
        XCTAssertEqual(p.items[0].quantity, 2)
        XCTAssertEqual(p.items[0].unitPrice, 20)
        XCTAssertFalse(p.bought)
    }

    func testMatchKeyIgnoresCaseEmojiAndExtraSpaces() {
        XCTAssertEqual(QuickAddParser.matchKey("  Car   🚗 "), "car")
        XCTAssertEqual(QuickAddParser.matchKey("حليب المراعي 1ل"), "حليب المراعي 1ل")
        XCTAssertEqual(QuickAddParser.matchKey("Bread\u{0013}"), "bread")
    }

    func testNegativeAndZeroQuantitiesBecomeOne() throws {
        let json = #"{"purchases": [{"listName": "x", "items": [{"name": "A", "quantity": 0, "unitPrice": 2}, {"name": "B", "quantity": -3, "unitPrice": -1}]}]}"#
        let items = try QuickAddParser.parseResponse(json, context).purchases[0].items
        XCTAssertEqual(items.map(\.quantity), [1, 1])
        XCTAssertEqual(items[0].unitPrice, 2)
        XCTAssertNil(items[1].unitPrice)
    }

    func testNoPurchasesKeyMeansNothingFoundButKeepsTranscript() throws {
        let r = try QuickAddParser.parseResponse(#"{"transcript": "hello"}"#, context)
        XCTAssertTrue(r.purchases.isEmpty)
        XCTAssertEqual(r.transcript, "hello")
    }
}
