import XCTest
@testable import SpendWiseCore

/// Whose data is on the phone (Android DataOwnerTest), and removing it all (signing in fresh, or
/// signing out and removing the lists).
final class DataOwnerTests: XCTestCase {
    let reviewer = "review-uid", tester = "tester-uid"

    func testTheSameAccountAgainMergesSilently() {
        XCTAssertEqual(DataOwner.decide(owner: reviewer, signingIn: reviewer, hasData: true), .merge)
    }

    func testAnotherAccountsListsAreAskedAbout() {
        XCTAssertEqual(DataOwner.decide(owner: reviewer, signingIn: tester, hasData: true), .ask)
    }

    func testListsThatBelongToNobodyMergeSilently() {
        // Made before any sign-in: the "Your data in the cloud" notice covers it
        XCTAssertEqual(DataOwner.decide(owner: nil, signingIn: tester, hasData: true), .merge)
    }

    func testAnEmptyPhoneHasNothingToAskAbout() {
        XCTAssertEqual(DataOwner.decide(owner: reviewer, signingIn: tester, hasData: false), .merge)
    }

    func testAFamilysListsBelongToTheAccountThatSyncedThem() {
        let owner = DataOwner.ownerAfterJoining(uid: reviewer, space: "family-space")
        XCTAssertEqual(owner, reviewer)
        // So another account doesn't silently receive the family's lists, and the same one does
        XCTAssertEqual(DataOwner.decide(owner: owner, signingIn: tester, hasData: true), .ask)
        XCTAssertEqual(DataOwner.decide(owner: owner, signingIn: reviewer, hasData: true), .merge)
    }

    func testAnAccountsOwnDataBelongsToIt() {
        XCTAssertEqual(DataOwner.ownerAfterJoining(uid: tester, space: nil), tester)
    }

    func testHasDataAndWipe() throws {
        let database = try freshDatabase()
        let repo = ShoppingRepository(database)
        let store = SyncStore(database)
        XCTAssertFalse(try store.hasData(), "the default categories alone aren't data to ask about")

        try store.setMode(SyncSchema.modeRecording)
        let shop = try repo.insertStore(Store(name: "Supermarket"))
        let list = try repo.insertShoppingList(ShoppingList(name: "Weekly", storeId: shop))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk", actualPrice: 2, purchased: true))
        _ = try repo.insertCategory(Category(name: "Pets", color: 1))
        var settings = try database.settings() ?? AppSettings()
        settings.currencySymbol = "€"
        try database.updateSettings(settings)
        XCTAssertTrue(try store.hasData())
        XCTAssertGreaterThan(try store.waitingCount(), 0)

        try store.wipe()
        XCTAssertFalse(try store.hasData())
        XCTAssertTrue(try database.allShoppingLists().isEmpty)
        XCTAssertTrue(try database.allItems().isEmpty)
        XCTAssertTrue(try database.allMasterItems().isEmpty)
        XCTAssertTrue(try database.allStores().isEmpty)
        XCTAssertEqual(Set(try database.allCategories().map(\.name)), Set(AppDatabase.defaultCategories.map(\.name)))
        // The defaults have uids again, nothing is waiting to go up, sync is off, settings stay
        XCTAssertTrue(try database.allCategories().allSatisfy { $0.uid != nil })
        XCTAssertEqual(try store.waitingCount(), 0)
        XCTAssertTrue(try store.tombstones().isEmpty)
        XCTAssertEqual(try store.mode(), SyncSchema.modeOff)
        XCTAssertEqual(try database.settings()?.currencySymbol, "€")
    }
}
