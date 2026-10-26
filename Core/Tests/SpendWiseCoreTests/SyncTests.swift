import XCTest
@testable import SpendWiseCore

/// Android SyncMergeTest, FamilyCodeTest and the instrumented SyncTriggersTest, ported.
final class SyncMergeTests: XCTestCase {
    let cols = ["itemName", "actualPrice", "purchased"]

    func remote(_ values: Fields, _ time: Int64, deleted: Bool = false) -> RemoteRow {
        RemoteRow(values: values, times: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, time) }), deleted: deleted, deletedAt: deleted ? time : 0)
    }

    func with(_ f: Fields, _ k: String, _ v: Any?) -> Fields { var c = f; c[k] = .some(v); return c }

    func testUntouchedRowTakesTheAccountsVersion() {
        let local: Fields = ["itemName": "Milk", "actualPrice": 1.0, "purchased": Int64(0)]
        let merged = SyncMerge.merge(local: local, base: local, pendingAt: nil, remote: remote(with(local, "purchased", Int64(1)), 100), columns: cols)
        XCTAssertTrue(SyncMerge.same(merged["purchased"] ?? nil, Int64(1)))
    }

    func testEditsToDifferentFieldsOnTwoPhonesBothSurvive() {
        let base: Fields = ["itemName": "Milk", "actualPrice": 1.0, "purchased": Int64(0)]
        // This phone fixed the price (not uploaded yet); the other phone ticked the item
        let local = with(base, "actualPrice", 1.25)
        let account = RemoteRow(values: with(base, "purchased", Int64(1)), times: ["itemName": 10, "actualPrice": 10, "purchased": 200], deleted: false)
        let merged = SyncMerge.merge(local: local, base: base, pendingAt: 150, remote: account, columns: cols)
        XCTAssertTrue(SyncMerge.same(merged["actualPrice"] ?? nil, 1.25))
        XCTAssertTrue(SyncMerge.same(merged["purchased"] ?? nil, Int64(1)))
        // And the upload then only writes the price
        XCTAssertEqual(SyncMerge.writable(SyncMerge.localChanges(local, base: base, columns: cols), changedAt: 150, remote: account), ["actualPrice"])
    }

    func testTheLaterEditOfTheSameFieldWinsOnBothPhones() {
        let base: Fields = ["itemName": "Milk", "actualPrice": 1.0, "purchased": Int64(0)]
        let local = with(base, "actualPrice", 2.0)
        // The account's change is newer: it wins here, and this phone's upload must not overwrite it
        let newer = RemoteRow(values: with(base, "actualPrice", 3.0), times: ["actualPrice": 300], deleted: false)
        XCTAssertTrue(SyncMerge.same(SyncMerge.merge(local: local, base: base, pendingAt: 200, remote: newer, columns: cols)["actualPrice"] ?? nil, 3.0))
        XCTAssertTrue(SyncMerge.writable(["actualPrice"], changedAt: 200, remote: newer).isEmpty)
        // This phone's change is newer: it stays, and goes up
        let older = RemoteRow(values: with(base, "actualPrice", 3.0), times: ["actualPrice": 100], deleted: false)
        XCTAssertTrue(SyncMerge.same(SyncMerge.merge(local: local, base: base, pendingAt: 200, remote: older, columns: cols)["actualPrice"] ?? nil, 2.0))
        XCTAssertEqual(SyncMerge.writable(["actualPrice"], changedAt: 200, remote: older), ["actualPrice"])
    }

    func testATieGoesToTheAccountOnBothSides() {
        let base: Fields = ["itemName": "Milk", "actualPrice": 1.0, "purchased": Int64(0)]
        let local = with(base, "actualPrice", 2.0)
        let tie = RemoteRow(values: with(base, "actualPrice", 3.0), times: ["actualPrice": 200], deleted: false)
        XCTAssertTrue(SyncMerge.same(SyncMerge.merge(local: local, base: base, pendingAt: 200, remote: tie, columns: cols)["actualPrice"] ?? nil, 3.0))
        XCTAssertTrue(SyncMerge.writable(["actualPrice"], changedAt: 200, remote: tie).isEmpty)
    }

    func testANewRowGoesUpWholeANewAccountRowComesDownWhole() {
        let row: Fields = ["itemName": "Bread", "actualPrice": nil, "purchased": Int64(0)]
        XCTAssertEqual(SyncMerge.localChanges(row, base: nil, columns: cols), Set(cols))
        let merged = SyncMerge.merge(local: nil, base: nil, pendingAt: nil, remote: remote(row, 5), columns: cols)
        for c in cols { XCTAssertTrue(SyncMerge.same(merged[c] ?? nil, row[c] ?? nil), c) }
    }

    func testNumbersCompareByValueWhateverTheirType() {
        XCTAssertTrue(SyncMerge.same(Int64(1), 1.0))
        XCTAssertTrue(SyncMerge.same(true, Int64(1)))
        XCTAssertTrue(SyncMerge.same(NSNumber(value: 7), 7.0))
        XCTAssertFalse(SyncMerge.same("1", Int64(1)))
        XCTAssertTrue(SyncMerge.localChanges(["purchased": Int64(1)], base: ["purchased": 1.0], columns: ["purchased"]).isEmpty)
    }

    func testBaseRowsSurviveTheJsonRoundTrip() {
        let f: Fields = ["a": Int64(3), "b": 2.5, "c": "x \"quoted\"", "d": nil, "e": 1.0]
        let back = SyncMerge.decode(SyncMerge.encode(f))
        XCTAssertTrue(SyncMerge.same(back["a"] ?? nil, Int64(3)))
        XCTAssertTrue(SyncMerge.same(back["b"] ?? nil, 2.5))
        XCTAssertEqual(back["c"] as? String, "x \"quoted\"")
        XCTAssertTrue(back.keys.contains("d"))
        XCTAssertNil(back["d"] ?? nil)
        XCTAssertTrue(SyncMerge.same(1.0, back["e"] ?? nil))
    }

    func testNaturalKeysMatchTheSameRowsAcrossPhones() {
        XCTAssertEqual(SyncMerge.naturalKey("stores", ["name": " Spinneys "]), "spinneys")
        XCTAssertEqual(SyncMerge.naturalKey("shopping_lists", ["name": "Groceries", "createdDate": Int64(1700)]), "groceries|1700")
        XCTAssertEqual(SyncMerge.naturalKey("shopping_items", ["listId": "L1", "itemName": "Milk", "orderIndex": Int64(2)]), "L1|milk|2")
        XCTAssertNil(SyncMerge.naturalKey("app_settings", [:]))
    }
}

final class FamilyCodeTests: XCTestCase {
    func testCodesAre8CharactersPeopleCanReadOut() {
        for _ in 0..<200 {
            let code = FamilyCodes.newCode()
            XCTAssertEqual(code.count, 8)
            XCTAssertFalse(code.contains { "01OILl".contains($0) }, code)
        }
    }

    func testTypedCodesAreCleanedUp() {
        XCTAssertEqual(FamilyCodes.normalize("ybwx-supg"), "YBWXSUPG")
        XCTAssertEqual(FamilyCodes.normalize(" YBWX SUPG "), "YBWXSUPG")
        XCTAssertEqual(FamilyCodes.display("YBWXSUPG"), "YBWX SUPG")
    }
}

/// The change-tracking triggers while sync records changes (Android SyncTriggersTest).
final class SyncTriggersTests: XCTestCase {
    var database: AppDatabase!
    var db: SQLiteDB { database.db }

    override func setUpWithError() throws {
        database = try freshDatabase()
        try db.execute("UPDATE sync_flags SET mode = 1 WHERE id = 0")
    }

    func outbox(_ table: String) throws -> Int { Int(try db.scalar("SELECT COUNT(*) FROM sync_outbox WHERE tbl = ?", [table])?.int64 ?? 0) }

    func strings(_ sql: String) throws -> Set<String> { Set(try db.query(sql).compactMap { $0[0].string }) }

    func testSavingAReportWhileSyncing() throws {
        try database.insertReport(AiReport(createdAt: 1, request: "Price trends", periodStart: 0, periodEnd: 1, title: "T", content: "{}"))
        XCTAssertEqual(try outbox("ai_reports"), 1)
    }

    func testChangingARowAgainBeforeItIsUploaded() throws {
        let id = try database.insertCategory(Category(name: "Snacks", color: 1))
        try database.updateCategory(Category(id: id, name: "Snacks", color: 2))
        try database.updateCategory(Category(id: id, name: "Treats", color: 2))
        XCTAssertEqual(try outbox("categories"), 1)
        // The update had no uid: the trigger kept the one the row had
        XCTAssertNotNil(try database.category(id: id)?.uid)
    }

    /// A price moved by merging stores or items is deleted where it was, so the cloud copy goes too.
    func testMovedPricesLeaveTombstones() throws {
        let milk = try database.insertMasterItem(MasterItem(name: "Milk"))
        let bread = try database.insertMasterItem(MasterItem(name: "Bread"))
        let s1 = try database.insertStore(Store(name: "Spinneys"))
        let s2 = try database.insertStore(Store(name: "spinneys"))
        for p in [StoreItemPrice(masterItemId: milk, storeId: s1, lastPrice: 2), StoreItemPrice(masterItemId: bread, storeId: s1, lastPrice: 3),
                  StoreItemPrice(masterItemId: bread, storeId: s2, lastPrice: 3.5)] { try database.insertStorePrice(p) }
        func uid(_ item: Int64, _ store: Int64) throws -> String {
            try XCTUnwrap(strings("SELECT uid FROM store_item_prices WHERE masterItemId = \(item) AND storeId = \(store)").first)
        }
        let milkAtS1 = try uid(milk, s1), breadAtS1 = try uid(bread, s1)

        let repo = ShoppingRepository(database)
        try repo.renameStore(XCTUnwrap(database.store(id: s1)), "spinneys")

        XCTAssertEqual(try strings("SELECT uid FROM sync_tombstones WHERE tbl = 'store_item_prices'"), [milkAtS1, breadAtS1])
        let milkUid = try XCTUnwrap(strings("SELECT uid FROM master_items WHERE id = \(milk)").first)
        let s2Uid = try XCTUnwrap(strings("SELECT uid FROM stores WHERE id = \(s2)").first)
        XCTAssertEqual(try uid(milk, s2), "\(milkUid)_\(s2Uid)")

        // Merging Milk into a new item moves its price too
        let dairy = try database.insertMasterItem(MasterItem(name: "Dairy milk"))
        let milkAtS2 = try uid(milk, s2)
        try repo.mergeMasterItems(XCTUnwrap(database.masterItem(id: milk)), into: XCTUnwrap(database.masterItem(id: dairy)))
        XCTAssertTrue(try strings("SELECT uid FROM sync_tombstones WHERE tbl = 'store_item_prices'").contains(milkAtS2))
        let dairyUid = try XCTUnwrap(strings("SELECT uid FROM master_items WHERE id = \(dairy)").first)
        XCTAssertEqual(try uid(dairy, s2), "\(dairyUid)_\(s2Uid)")
    }

    // New on iOS

    func testNothingIsRecordedWhileSyncIsOff() throws {
        try db.execute("UPDATE sync_flags SET mode = 0 WHERE id = 0")
        try database.insertStore(Store(name: "Spinneys"))
        XCTAssertEqual(try outbox("stores"), 0)
    }

    func testUndoingADeleteCancelsItsTombstone() throws {
        let listId = try database.insertShoppingList(ShoppingList(name: "Weekly"))
        try database.insertItem(ShoppingItem(listId: listId, itemName: "Milk"))
        let item = try XCTUnwrap(database.itemsForList(listId).first)
        try database.deleteItem(item)
        XCTAssertEqual(try strings("SELECT uid FROM sync_tombstones"), [item.uid!])
        try database.insertItem(item) // undo puts the same row back
        XCTAssertTrue(try strings("SELECT uid FROM sync_tombstones").isEmpty)
        XCTAssertEqual(try database.itemsForList(listId).first?.uid, item.uid)
    }

    func testFreshInstallsGroceriesGetsAUid() throws {
        XCTAssertNotNil(try database.category(named: "Groceries")?.uid)
    }
}

/// The database side of sync: applying the account's rows and finding what to upload.
final class SyncStoreTests: XCTestCase {
    var database: AppDatabase!
    var store: SyncStore!

    override func setUpWithError() throws {
        database = try freshDatabase()
        store = SyncStore(database)
        try store.setMode(SyncSchema.modeRecording)
    }

    func table(_ name: String) -> SyncTable { SyncSchema.byName[name]! }

    func testReferencesTravelAsUids() throws {
        let storeId = try database.insertStore(Store(name: "Spinneys"))
        let listId = try database.insertShoppingList(ShoppingList(name: "Weekly", createdDate: 1700, storeId: storeId))
        let row = try XCTUnwrap(store.row(table("shopping_lists"), rid: listId))
        XCTAssertEqual(row.fields["storeId"] as? String, try database.store(id: storeId)?.uid)
        XCTAssertNil(row.fields["categoryId"] ?? nil)
        XCTAssertTrue(SyncMerge.same(row.fields["createdDate"] ?? nil, Int64(1700)))
    }

    func testARowWaitsForWhatItPointsTo() throws {
        let t = table("shopping_items")
        let fields: Fields = ["listId": "list-uid", "itemName": "Milk", "estimatedPrice": nil, "actualPrice": nil, "quantity": 1.0,
                              "unit": nil, "purchased": Int64(0), "orderIndex": Int64(0), "notes": nil, "storeId": nil, "isTracked": Int64(0)]
        XCTAssertFalse(try store.applying { try store.write(t, uid: "item-uid", fields: fields, existing: nil) })
        // The list arrives, then the item can be placed
        let lists = table("shopping_lists")
        XCTAssertTrue(try store.applying {
            try store.write(lists, uid: "list-uid", fields: ["name": "Weekly", "createdDate": Int64(5), "completedDate": nil, "isCompleted": Int64(0),
                                                              "storeId": nil, "categoryId": nil], existing: nil)
        })
        XCTAssertTrue(try store.applying { try store.write(t, uid: "item-uid", fields: fields, existing: nil) })
        let list = try XCTUnwrap(database.allShoppingLists().first)
        XCTAssertEqual(list.uid, "list-uid")
        XCTAssertEqual(try database.itemsForList(list.id).map(\.itemName), ["Milk"])
        // Applied rows aren't this phone's own changes
        XCTAssertEqual(try store.waitingCount(), 0)
    }

    func testLocalChangesArePendingWithTheirTime() throws {
        try database.insertStore(Store(name: "Spinneys"))
        let p = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(p.table, "stores")
        XCTAssertGreaterThan(p.changedAt, 0)
        try store.clearPending(p)
        XCTAssertEqual(try store.waitingCount(), 0)
    }

    func testPendingRowsComeParentsFirst() throws {
        let listId = try database.insertShoppingList(ShoppingList(name: "Weekly"))
        try database.insertItem(ShoppingItem(listId: listId, itemName: "Milk"))
        try database.insertStore(Store(name: "Spinneys"))
        XCTAssertEqual(try store.pending().map(\.table), ["stores", "shopping_lists", "shopping_items"])
    }

    func testAChangeIsNeverStampedBeforeOneHeardFromTheAccount() throws {
        let future = nowMillis() + 3_600_000
        try store.heard(future)
        try database.insertStore(Store(name: "Spinneys"))
        XCTAssertGreaterThan(try XCTUnwrap(store.pending().first).changedAt, future)
    }

    func testCatchUpFindsWhatChangedWhileOff() throws {
        try store.setMode(SyncSchema.modeOff)
        let id = try database.insertStore(Store(name: "Spinneys"))
        let uid = try XCTUnwrap(database.store(id: id)?.uid)
        try store.setBase(table("stores"), uid: uid, ["name": "Spinneys"])
        try store.setBase(table("stores"), uid: "gone", ["name": "Old"])
        try database.updateStore(Store(id: id, name: "Spinneys Achrafieh", uid: uid))
        XCTAssertEqual(try store.waitingCount(), 0)
        try store.catchUp(now: 42)
        // Groceries was never uploaded either
        XCTAssertEqual(try store.pending().map(\.table), ["stores", "categories"])
        XCTAssertEqual(try store.tombstones(), [Tombstone(table: "stores", uid: "gone", deletedAt: 42)])
    }

    func testSettingsComeDownIntoTheirOneRow() throws {
        let t = table("app_settings")
        XCTAssertTrue(try store.applying { try store.write(t, uid: "settings", fields: ["currencySymbol": "€", "lastConversionRate": 1.0], existing: nil) })
        XCTAssertEqual(try database.settings()?.currencySymbol, "€")
        XCTAssertEqual(try database.settings()?.uid, "settings")
    }

    func testResetForgetsTheAccountButKeepsTheRows() throws {
        try database.insertStore(Store(name: "Spinneys"))
        try store.reset()
        XCTAssertEqual(try store.waitingCount(), 0)
        XCTAssertEqual(try store.mode(), SyncSchema.modeOff)
        XCTAssertEqual(try database.allStores().count, 1)
    }
}
