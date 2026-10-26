import XCTest
@testable import SpendWiseCore

/// Android BackupCompatibilityTest (instrumented there): imports backup_v1.json, a file in the
/// format the original app exported (no version, isTracked, totalQuantity or lastConversionRate).
final class BackupCompatibilityTests: XCTestCase {
    var database: AppDatabase!
    var backup: BackupRepository!
    var repository: ShoppingRepository!
    var v1: String!

    override func setUpWithError() throws {
        database = try freshDatabase()
        backup = BackupRepository(database)
        repository = ShoppingRepository(database)
        v1 = try fixture("backup_v1.json")
    }

    func testImportsEverythingFromVersion1Backup() throws {
        let summary = try backup.restoreData(v1)
        XCTAssertEqual(summary.listsAdded, 24)
        XCTAssertEqual(summary.itemsAdded, 126)
        XCTAssertEqual(summary.libraryItemsAdded, 16)
        XCTAssertEqual(try database.allShoppingLists().count, 24)
        XCTAssertEqual(try database.allItems().count, 126)
        XCTAssertEqual(try database.allStorePrices().count, 42)
        XCTAssertEqual(try database.allStores().count, 3)
        XCTAssertEqual(try database.settings()?.currencySymbol, "₺")

        // Groceries existed on the fresh install; its colour comes from the backup
        let categories = try database.allCategories()
        XCTAssertEqual(categories.count, 2)
        XCTAssertEqual(categories.first { $0.name == "Groceries" }?.color, -14575885)

        // Store and category links survive
        let lists = try database.allShoppingListsWithDetails()
        XCTAssertTrue(lists.allSatisfy { $0.storeName != nil })
        XCTAssertTrue(lists.contains { $0.category?.name == "Household" })
        XCTAssertEqual(lists.filter { !$0.shoppingList.isCompleted }.count, 1)
    }

    func testRebuildsTrackingFieldsMissingFromVersion1() throws {
        _ = try backup.restoreData(v1)
        let items = try database.allItems()
        XCTAssertTrue(items.filter(\.purchased).allSatisfy(\.isTracked), "purchased items are marked tracked")
        XCTAssertFalse(items.filter { !$0.purchased }.contains { $0.isTracked }, "unpurchased items stay untracked")
        XCTAssertGreaterThan(try XCTUnwrap(database.masterItem(named: "Milk")).totalQuantity, 0, "totalQuantity rebuilt from purchases")
    }

    func testEditingAnImportedPurchaseDoesNotDoubleCountIt() throws {
        _ = try backup.restoreData(v1)
        let before = try XCTUnwrap(database.masterItem(named: "Milk"))
        var milk = try XCTUnwrap(database.allItems().first { $0.itemName == "Milk" && $0.purchased })
        milk.notes = "edited"
        try repository.updateShoppingItem(milk)
        let after = try XCTUnwrap(database.masterItem(named: "Milk"))
        XCTAssertEqual(after.purchaseCount, before.purchaseCount)
        XCTAssertEqual(after.averagePrice, before.averagePrice, accuracy: 0.0001)
    }

    func testImportingTwiceDoesNotDuplicate() throws {
        _ = try backup.restoreData(v1)
        let second = try backup.restoreData(v1)
        XCTAssertEqual(second.listsAdded, 0)
        XCTAssertEqual(second.listsSkipped, 24)
        XCTAssertEqual(try database.allShoppingLists().count, 24)
        XCTAssertEqual(try database.allItems().count, 126)
        XCTAssertEqual(try database.allMasterItems().count, 16)
    }

    func testNewExportRoundTripsIntoAnotherFreshInstall() throws {
        _ = try backup.restoreData(v1)
        let report = AiReport(createdAt: 1_760_000_000_000, request: "How did I spend in September?", periodStart: 1, periodEnd: 2,
                              title: "September", content: #"{"summary":"Fine"}"#)
        try database.insertReport(report)
        let exported = try backup.exportData(itemsOnly: false)

        let parsed = try JSON.parse(exported)
        XCTAssertEqual(parsed["version"]?.content, "3")
        XCTAssertNotNil(parsed["shoppingItems"]?.array?.first?["isTracked"])
        XCTAssertNotNil(parsed["masterItems"]?.array?.first?["totalQuantity"])

        let other = try freshDatabase()
        let summary = try BackupRepository(other).restoreData(exported)
        XCTAssertEqual(summary.listsAdded, 24)
        XCTAssertEqual(summary.reportsAdded, 1)
        var restored = try XCTUnwrap(other.allReports().first)
        restored.id = 0; restored.uid = nil
        XCTAssertEqual(restored, report)
        XCTAssertEqual(try BackupRepository(other).restoreData(exported).reportsAdded, 0)
        XCTAssertEqual(summary.itemsAdded, 126)
        func strip(_ m: [MasterItem]) -> [MasterItem] { m.map { var c = $0; c.id = 0; c.uid = nil; return c } }
        XCTAssertEqual(strip(try database.allMasterItems()), strip(try other.allMasterItems()))
        XCTAssertEqual(try database.allItems().filter(\.isTracked).count, try other.allItems().filter(\.isTracked).count)
    }

    func testTrimsNamesAndCombinesDuplicatesFromOldApp() throws {
        // The original app kept trailing spaces, so "Milk " and "Milk" could both exist
        let json = """
            {
              "masterItems": [
                {"name": "Milk ", "averagePrice": 2.0, "lastPrice": 2.0, "lowestPrice": 2.0, "highestPrice": 2.0, "purchaseCount": 2, "lastPurchaseDate": 100},
                {"name": "Milk", "averagePrice": 4.0, "lastPrice": 4.0, "lowestPrice": 4.0, "highestPrice": 4.0, "purchaseCount": 2, "lastPurchaseDate": 200}
              ],
              "shoppingLists": [
                {"id": 1, "name": "Week ", "createdDate": 1, "completedDate": 2, "isCompleted": true, "storeName": "Shop ", "categoryName": null}
              ],
              "shoppingItems": [
                {"listId": 1, "itemName": "Milk ", "estimatedPrice": 2.0, "actualPrice": 2.0, "quantity": 1.0, "unit": null, "purchased": true, "orderIndex": 0, "notes": null, "storeName": null}
              ],
              "stores": [{"name": "Shop "}],
              "storeItemPrices": [
                {"itemName": "Milk ", "storeName": "Shop ", "lastPrice": 2.0, "lowestPrice": 2.0, "highestPrice": 2.0, "lastUpdated": 100}
              ]
            }
            """
        _ = try backup.restoreData(json)
        let masters = try database.allMasterItems()
        XCTAssertEqual(masters.map(\.name), ["Milk"])
        XCTAssertEqual(masters[0].purchaseCount, 4)
        XCTAssertEqual(masters[0].averagePrice, 3, accuracy: 0.0001)
        XCTAssertEqual(masters[0].lastPrice, 4, accuracy: 0.0001)
        XCTAssertEqual(try database.allItems().map(\.itemName), ["Milk"])
        XCTAssertEqual(try database.allStores().map(\.name), ["Shop"])
        XCTAssertEqual(try database.allStorePrices().count, 1)
        XCTAssertEqual(try repository.purchaseHistory("Milk").count, 1)
    }

    func testRejectsFilesThatAreNotBackups() throws {
        XCTAssertThrowsError(try backup.restoreData(#"{"hello": "world"}"#))
        XCTAssertThrowsError(try backup.restoreData("not json"))
        XCTAssertEqual(try database.allShoppingLists().count, 0)
    }

    // New on iOS

    func testItemsOnlyBackupHoldsTheLibraryAlone() throws {
        _ = try backup.restoreData(v1)
        let parsed = try JSON.parse(backup.exportData(itemsOnly: true))
        XCTAssertEqual(parsed["masterItems"]?.array?.count, 16)
        XCTAssertEqual(parsed["shoppingLists"], .null)
        XCTAssertEqual(parsed["settings"], .null)
    }

    func testSummaryMessageReadsLikeAndroid() {
        let s = RestoreSummary(listsAdded: 2, listsSkipped: 1, itemsAdded: 1, libraryItemsAdded: 3, reportsAdded: 1)
        XCTAssertEqual(s.message, "Restored 2 lists, 1 item, 3 library items, 1 AI reports (1 list already existed)")
    }

    func testAnAndroidVersion3ExportImports() throws {
        // Written as kotlinx writes it: every field, nulls included, settings with a rate
        let json = """
            {
                "version": 3,
                "timestamp": 1761300000000,
                "masterItems": [],
                "shoppingLists": [{"id": 9, "name": "Gas", "createdDate": 1761300000000, "completedDate": 1761300000000, "isCompleted": true, "storeName": null, "categoryName": "Car"}],
                "shoppingItems": [{"listId": 9, "itemName": "Gas", "estimatedPrice": 1.5, "actualPrice": 1.5, "quantity": 25.0, "unit": "l", "purchased": true, "orderIndex": 0, "notes": null, "storeName": null, "isTracked": true}],
                "categories": [{"name": "Car", "color": -16537100}],
                "stores": [],
                "storeItemPrices": [],
                "settings": {"darkTheme": null, "currencySymbol": "$", "lastConversionRate": 89500.0},
                "reports": [],
                "someFutureField": {"ignored": true}
            }
            """
        let s = try backup.restoreData(json)
        XCTAssertEqual(s.listsAdded, 1)
        XCTAssertEqual(try database.settings()?.lastConversionRate, 89500)
        XCTAssertEqual(try database.allShoppingListsWithDetails().first?.category?.name, "Car")
        XCTAssertEqual(try database.allItems().first?.unit, "l")
    }
}
