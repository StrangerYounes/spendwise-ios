import XCTest
@testable import SpendWiseCore

/// Lists, items and the item library (Android ShoppingRepository), and the queries behind the
/// screens. Android tests these by hand on emulators; here they run on every push.
final class RepositoryTests: XCTestCase {
    var database: AppDatabase!
    var repo: ShoppingRepository!
    var clock: Millis = at(2026, 10, 20, 10)

    override func setUpWithError() throws {
        database = try freshDatabase()
        repo = ShoppingRepository(database)
        repo.now = { [unowned self] in self.clock }
    }

    func groceries(_ name: String = "Weekly", store: Int64? = nil) throws -> Int64 {
        try repo.insertShoppingList(ShoppingList(name: name, createdDate: clock, storeId: store))
    }

    func testTickingAGroceryItemCountsItOnceInTheLibrary() throws {
        let spinneys = try repo.insertStore(Store(name: "Spinneys"))
        let list = try groceries(store: spinneys)
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk", estimatedPrice: 2, quantity: 2))
        var milk = try XCTUnwrap(repo.items(listId: list).first)
        milk.purchased = true
        milk.actualPrice = 2.5
        try repo.updateShoppingItem(milk)
        let master = try XCTUnwrap(database.masterItem(named: "Milk"))
        XCTAssertEqual(master.purchaseCount, 1)
        XCTAssertEqual(master.lastPrice, 2.5)
        XCTAssertEqual(master.totalQuantity, 2)
        XCTAssertEqual(try database.price(item: master.id, store: spinneys)?.lastPrice, 2.5)

        // Un-ticking and ticking again doesn't count it twice
        milk = try XCTUnwrap(repo.items(listId: list).first)
        XCTAssertTrue(milk.isTracked)
        milk.purchased = false
        try repo.updateShoppingItem(milk)
        milk.purchased = true
        try repo.updateShoppingItem(milk)
        XCTAssertEqual(try database.masterItem(named: "Milk")?.purchaseCount, 1)
    }

    func testFreshInstallHasTheDefaultCategories() throws {
        let names = try database.allCategories().map(\.name)
        XCTAssertEqual(Set(names), ["Groceries", "Gifts", "Car", "Miscellaneous"])
        XCTAssertEqual(try database.category(named: "Groceries")?.color, AppDatabase.groceriesColor)
    }

    func testEveryCategoryFeedsTheLibrary() throws {
        let car = try XCTUnwrap(database.category(named: "Car")).id
        let total = try repo.insertStore(Store(name: "Total"))
        let list = try repo.insertShoppingList(ShoppingList(name: "Gas", storeId: total, categoryId: car))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Gas", actualPrice: 40, purchased: true))
        let gas = try XCTUnwrap(database.masterItem(named: "Gas"))
        XCTAssertEqual(gas.purchaseCount, 1)
        XCTAssertEqual(try database.price(item: gas.id, store: total)?.lastPrice, 40)
        XCTAssertTrue(try XCTUnwrap(repo.items(listId: list).first).isTracked)
    }

    /// Before every category fed the library, other categories' purchases were marked tracked
    /// without reaching it: the catch-up adds those names once, with their own dates.
    func testCatchUpAddsOtherCategoriesOnce() throws {
        let car = try XCTUnwrap(database.category(named: "Car")).id
        let total = try repo.insertStore(Store(name: "Total"))
        let old = at(2026, 9, 1, 9), later = at(2026, 9, 20, 9)
        for (date, price) in [(old, 38.0), (later, 41.0)] {
            let list = try database.insertShoppingList(ShoppingList(name: "Gas", createdDate: date, completedDate: date, isCompleted: true,
                                                                    storeId: total, categoryId: car))
            _ = try database.insertItem(ShoppingItem(listId: list, itemName: "Gas", actualPrice: price, purchased: true, isTracked: true))
        }
        // Milk is already in the library (bought in Groceries): left as it is
        let gifts = try XCTUnwrap(database.category(named: "Gifts")).id
        let giftList = try database.insertShoppingList(ShoppingList(name: "Party", createdDate: later, completedDate: later, isCompleted: true, categoryId: gifts))
        _ = try database.insertItem(ShoppingItem(listId: giftList, itemName: "Milk", actualPrice: 9, purchased: true, isTracked: true))
        _ = try database.insertMasterItem(MasterItem(name: "Milk", averagePrice: 2, lastPrice: 2, lowestPrice: 2, highestPrice: 2, purchaseCount: 3, lastPurchaseDate: old))

        XCTAssertEqual(try repo.catchUpLibraryWithAllCategories(), 1)
        let gas = try XCTUnwrap(database.masterItem(named: "Gas"))
        XCTAssertEqual(gas.purchaseCount, 2)
        XCTAssertEqual(gas.lastPrice, 41)
        XCTAssertEqual(gas.lowestPrice, 38)
        XCTAssertEqual(gas.lastPurchaseDate, later)
        XCTAssertEqual(try database.price(item: gas.id, store: total)?.lastPrice, 41)
        XCTAssertEqual(try database.masterItem(named: "Milk")?.purchaseCount, 3)
        // A second run (another phone, or a relaunch) adds nothing
        XCTAssertEqual(try repo.catchUpLibraryWithAllCategories(), 0)
        XCTAssertEqual(try database.masterItem(named: "Gas")?.purchaseCount, 2)
    }

    func testSuggestionsPutTheListsCategoryFirst() throws {
        let car = try XCTUnwrap(database.category(named: "Car")).id
        let gasList = try repo.insertShoppingList(ShoppingList(name: "Gas", categoryId: car))
        for _ in 0..<3 { try repo.insertShoppingItem(ShoppingItem(listId: gasList, itemName: "Gas", actualPrice: 40, purchased: true)) }
        try repo.insertShoppingItem(ShoppingItem(listId: try groceries(), itemName: "Garlic", actualPrice: 1, purchased: true))
        // Gas is bought more, but in a Groceries list Garlic comes first; in a Car list, Gas
        XCTAssertEqual(try repo.suggestions("ga", listStoreId: nil, listCategory: "Groceries").map(\.name), ["Garlic", "Gas"])
        XCTAssertEqual(try repo.suggestions("ga", listStoreId: nil, listCategory: "Car").map(\.name), ["Gas", "Garlic"])
        XCTAssertEqual(try repo.suggestions("ga", listStoreId: nil).map(\.name), ["Gas", "Garlic"])
    }

    func testLibraryStatsAverageLowestAndHighest() throws {
        let list = try groceries()
        for price in [2.0, 4.0, 3.0] {
            try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Eggs", actualPrice: price, purchased: true))
        }
        let eggs = try XCTUnwrap(database.masterItem(named: "Eggs"))
        XCTAssertEqual(eggs.purchaseCount, 3)
        XCTAssertEqual(eggs.averagePrice, 3, accuracy: 1e-9)
        XCTAssertEqual(eggs.lowestPrice, 2)
        XCTAssertEqual(eggs.highestPrice, 4)
        XCTAssertEqual(eggs.lastPrice, 3)
    }

    func testQuickPurchasesBecomeListsWithCategoriesAndStores() throws {
        let purchases = [
            QuickPurchase(listName: "Gas fill-up", categoryName: "Car 🚗", storeName: "Shell", date: clock, items: [QuickItem(name: "Gas", quantity: 25, unit: "l", unitPrice: 1.6)]),
            QuickPurchase(listName: "To buy", categoryName: nil, storeName: nil, date: clock, items: [QuickItem(name: "Eggs"), QuickItem(name: "Laban", unitPrice: 1)], bought: false),
        ]
        let ids = try repo.saveQuickPurchases(purchases)
        XCTAssertEqual(ids.count, 2)
        let gas = try XCTUnwrap(repo.shoppingList(id: ids[0]))
        XCTAssertTrue(gas.isCompleted)
        XCTAssertEqual(gas.completedDate, clock)
        XCTAssertEqual(try database.category(id: gas.categoryId!)?.name, "Car 🚗")
        // A colour no other category has (Car, a default, already took the first one)
        let color = try XCTUnwrap(database.category(id: gas.categoryId!)?.color)
        XCTAssertTrue(ShoppingRepository.newCategoryColors.contains(color))
        XCTAssertFalse(AppDatabase.defaultCategories.map(\.color).contains(color))
        XCTAssertEqual(try database.store(id: gas.storeId!)?.name, "Shell")
        XCTAssertEqual(try repo.items(listId: ids[0]).first?.actualPrice, 1.6)

        let toBuy = try XCTUnwrap(repo.shoppingList(id: ids[1]))
        XCTAssertFalse(toBuy.isCompleted)
        XCTAssertNil(toBuy.categoryId)
        let items = try repo.items(listId: ids[1])
        XCTAssertEqual(items.map(\.itemName), ["Eggs", "Laban"])
        XCTAssertTrue(items.allSatisfy { !$0.purchased && $0.actualPrice == nil })
        XCTAssertEqual(items[1].estimatedPrice, 1)
    }

    func testExistingCategoriesAndStoresAreReusedIgnoringCase() throws {
        // Car is one of the default categories
        _ = try repo.insertStore(Store(name: "Shell"))
        _ = try repo.saveQuickPurchases([QuickPurchase(listName: "Gas", categoryName: "car", storeName: "SHELL", date: clock, items: [QuickItem(name: "Gas", unitPrice: 40)])])
        XCTAssertEqual(try database.allCategories().count, AppDatabase.defaultCategories.count)
        XCTAssertEqual(try database.allStores().count, 1)
    }

    func testReceiptsTickOffTheOpenListsItems() throws {
        let list = try groceries()
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Labneh", estimatedPrice: 3, orderIndex: 0))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Butter", estimatedPrice: 2, orderIndex: 1))
        let purchase = QuickPurchase(listName: "Weekly", categoryName: nil, storeName: "Spinneys", date: clock, items: [
            QuickItem(name: "لبنة 450 غ", unitPrice: 3.2, matchedListItem: "Labneh"),
            QuickItem(name: "Bread", unitPrice: 1),
        ], existingListId: list)
        _ = try repo.saveQuickPurchases([purchase])
        let items = try repo.items(listId: list)
        let labneh = try XCTUnwrap(items.first { $0.itemName == "Labneh" })
        XCTAssertTrue(labneh.purchased, "ticked, keeping the name the list had")
        XCTAssertEqual(labneh.actualPrice, 3.2)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.itemName == "Butter" }).purchased)
        let bread = try XCTUnwrap(items.first { $0.itemName == "Bread" })
        XCTAssertTrue(bread.purchased)
        XCTAssertEqual(bread.orderIndex, 2)
        XCTAssertEqual(try repo.shoppingList(id: list)?.storeId.flatMap { try database.store(id: $0)?.name }, "Spinneys", "the receipt says where")
    }

    func testRenamingAStoreOntoAnotherMergesThem() throws {
        let a = try repo.insertStore(Store(name: "Spinneys"))
        let b = try repo.insertStore(Store(name: "Spinneys Achrafieh"))
        _ = try repo.insertShoppingList(ShoppingList(name: "W", storeId: b))
        try repo.renameStore(XCTUnwrap(repo.store(id: b)), "spinneys")
        XCTAssertEqual(try repo.allStores().map(\.name), ["Spinneys"])
        XCTAssertEqual(try database.allShoppingLists().first?.storeId, a)
        XCTAssertEqual(try repo.storesWithUsage().first?.listCount, 1)
    }

    func testRenamingAnItemEverywhereMergesIntoTheLibrary() throws {
        let list = try groceries()
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk 1L", actualPrice: 2, purchased: true))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk", actualPrice: 4, purchased: true))
        try repo.renameItemEverywhere("Milk 1L", "Milk")
        let milk = try XCTUnwrap(database.masterItem(named: "Milk"))
        XCTAssertEqual(milk.purchaseCount, 2)
        XCTAssertEqual(milk.averagePrice, 3, accuracy: 1e-9)
        XCTAssertNil(try database.masterItem(named: "Milk 1L"))
        XCTAssertEqual(Set(try repo.items(listId: list).map(\.itemName)), ["Milk"])
        // A name the library doesn't know just renames the items
        let car = try repo.insertCategory(Category(name: "Car", color: 1))
        let gasList = try repo.insertShoppingList(ShoppingList(name: "Gas", categoryId: car))
        try repo.insertShoppingItem(ShoppingItem(listId: gasList, itemName: "Benzine", actualPrice: 40, purchased: true))
        try repo.renameItemEverywhere("Benzine", "Gas")
        XCTAssertEqual(try repo.items(listId: gasList).first?.itemName, "Gas")
    }

    func testRestoringADeletedItemPutsItBackExactly() throws {
        let list = try groceries()
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk", estimatedPrice: 2, notes: "full fat"))
        let item = try XCTUnwrap(repo.items(listId: list).first)
        try repo.deleteShoppingItem(item)
        XCTAssertTrue(try repo.items(listId: list).isEmpty)
        try repo.restoreShoppingItem(item)
        XCTAssertEqual(try repo.items(listId: list).first, item)
    }

    func testDeletingAListDeletesItsItemsAndACategoryLeavesItsLists() throws {
        let car = try repo.insertCategory(Category(name: "Car", color: 1))
        let list = try repo.insertShoppingList(ShoppingList(name: "Gas", categoryId: car))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Gas"))
        try repo.deleteCategory(XCTUnwrap(database.category(id: car)))
        XCTAssertNil(try repo.shoppingList(id: list)?.categoryId)
        try repo.deleteShoppingList(XCTUnwrap(repo.shoppingList(id: list)))
        XCTAssertTrue(try database.allItems().isEmpty)
    }

    func testListDetailsCountTotalsAndOrderNewestFirst() throws {
        let old = try repo.insertShoppingList(ShoppingList(name: "Old", createdDate: at(2026, 9, 1), completedDate: at(2026, 9, 2), isCompleted: true))
        let new = try repo.insertShoppingList(ShoppingList(name: "New", createdDate: at(2026, 10, 1)))
        try repo.insertShoppingItem(ShoppingItem(listId: new, itemName: "A", estimatedPrice: 2, quantity: 3))
        try repo.insertShoppingItem(ShoppingItem(listId: new, itemName: "B", estimatedPrice: 1, actualPrice: 1.5, purchased: true))
        let lists = try repo.allShoppingLists()
        XCTAssertEqual(lists.map(\.id), [new, old])
        XCTAssertEqual(lists[0].itemCount, 2)
        XCTAssertEqual(lists[0].purchasedCount, 1)
        XCTAssertEqual(lists[0].estimatedTotal, 7)
        XCTAssertEqual(lists[0].actualTotal, 1.5)
        XCTAssertEqual(try repo.searchShoppingLists("ne").map(\.shoppingList.name), ["New"])
        XCTAssertEqual(try repo.searchItems("a").map(\.listName), ["New"])
    }

    func testSuggestionsPreferTheListsStoreThenTheCheapest() throws {
        let spinneys = try repo.insertStore(Store(name: "Spinneys"))
        let carrefour = try repo.insertStore(Store(name: "Carrefour"))
        let l1 = try groceries("A", store: spinneys)
        try repo.insertShoppingItem(ShoppingItem(listId: l1, itemName: "Milk", actualPrice: 2.5, unit: "l", purchased: true))
        let l2 = try groceries("B", store: carrefour)
        try repo.insertShoppingItem(ShoppingItem(listId: l2, itemName: "Milk", actualPrice: 2.0, unit: "l", purchased: true))
        let atSpinneys = try XCTUnwrap(repo.suggestions("mil", listStoreId: spinneys).first)
        XCTAssertEqual(atSpinneys.name, "Milk")
        XCTAssertEqual(atSpinneys.suggestedPrice, 2.5)
        XCTAssertEqual(atSpinneys.bestStoreName, "Carrefour")
        XCTAssertEqual(atSpinneys.lastUnit, "l")
        XCTAssertEqual(try repo.suggestions("mil", listStoreId: nil).first?.suggestedPrice, 2.0)
        XCTAssertTrue(try repo.suggestions("  ", listStoreId: nil).isEmpty)
    }

    func testQuickAddContextHoldsNamesAndOpenLists() throws {
        let list = try groceries("Weekly")
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: " Eggs "))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "eggs", purchased: true))
        let c = try repo.quickAddContext(currencySymbol: "$")
        XCTAssertEqual(Set(c.categories), Set(AppDatabase.defaultCategories.map(\.name)))
        XCTAssertEqual(c.knownItems.map { $0.lowercased() }, ["eggs"], "trimmed, once ignoring case")
        XCTAssertEqual(c.openLists.map(\.name), ["Weekly"])
        XCTAssertEqual(c.openLists[0].toBuy, ["Eggs"])
        XCTAssertEqual(try repo.lastPrices(["eggs", "nope"]), [:])
    }

    func testLastPriceIgnoresCaseAndPrefersPurchases() throws {
        let list = try groceries()
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Tuna", estimatedPrice: 9))
        try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "tuna ", actualPrice: 1.5, purchased: true))
        XCTAssertEqual(try repo.lastPrices(["TUNA"])["TUNA"], 1.5)
    }

    func testItemInsightsCountUnitlessAmountsInTheUsualUnit() throws {
        let car = try repo.insertCategory(Category(name: "Car", color: 1))
        for (day, qty, unit, price) in [(1, 20.0, "l", 1.5), (11, 25.4, nil, 1.57), (21, 1.0, nil, 40.0), (25, 22.0, "litres", 1.6)] as [(Int, Double, String?, Double)] {
            let list = try repo.insertShoppingList(ShoppingList(name: "Gas", createdDate: at(2026, 9, day), completedDate: at(2026, 9, day), isCompleted: true, categoryId: car))
            try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Gas", actualPrice: price, quantity: qty, unit: unit, purchased: true))
        }
        let insights = ItemInsights.build("Gas", try repo.purchaseHistory("Gas"))
        XCTAssertEqual(insights.commonUnit, "l")
        XCTAssertEqual(insights.purchases.count, 4)
        XCTAssertEqual(insights.unitPricePurchases.count, 3, "$40 of gas has no litres")
        XCTAssertEqual(insights.lastUnitPrice, 1.6)
        XCTAssertClose(insights.unitPriceChange, (1.6 - 1.5) / 1.5)
        XCTAssertEqual(insights.averageDaysBetween ?? 0, 8, accuracy: 0.01)
        XCTAssertFalse(insights.quantitiesAllOne)
    }
}

/// Insights' queries (Android StatsDao).
final class StatsTests: XCTestCase {
    var database: AppDatabase!
    var repo: ShoppingRepository!

    override func setUpWithError() throws {
        database = try freshDatabase()
        repo = ShoppingRepository(database)
        let car = try repo.insertCategory(Category(name: "Car", color: 7))
        let shell = try repo.insertStore(Store(name: "Shell"))
        let spinneys = try repo.insertStore(Store(name: "Spinneys"))
        func list(_ name: String, _ date: Millis, category: Int64? = nil, store: Int64? = nil) throws -> Int64 {
            try repo.insertShoppingList(ShoppingList(name: name, createdDate: date, completedDate: date, isCompleted: true, storeId: store, categoryId: category))
        }
        let gas = try list("Gas", at(2026, 9, 5, 12), category: car, store: shell)
        try repo.insertShoppingItem(ShoppingItem(listId: gas, itemName: "Gas", actualPrice: 1.5, quantity: 20, unit: "l", purchased: true))
        let food = try list("Weekly", at(2026, 10, 2, 12), store: spinneys)
        try repo.insertShoppingItem(ShoppingItem(listId: food, itemName: "Milk", actualPrice: 2, quantity: 2, purchased: true))
        try repo.insertShoppingItem(ShoppingItem(listId: food, itemName: "Eggs", estimatedPrice: 5, purchased: true))
        try repo.insertShoppingItem(ShoppingItem(listId: food, itemName: "Not bought", estimatedPrice: 50))
    }

    func testSpendingPerMonthAndCategory() throws {
        XCTAssertEqual(try database.spentPerMonth().map(\.period), ["2026-10", "2026-09"])
        XCTAssertEqual(try database.spentPerMonth().map(\.totalSpent), [9, 30])
        let byCategory = try database.spentByCategory()
        XCTAssertEqual(byCategory.map(\.categoryName), ["Car", "Groceries"])
        XCTAssertEqual(byCategory.map(\.totalSpent), [30, 9])
        XCTAssertEqual(try database.spentByStore().map(\.storeName), ["Shell", "Spinneys"])
        XCTAssertEqual(try database.spentThisMonth(now: Date(millis: at(2026, 10, 20))), 9)
    }

    func testTheDateFilterCoversWholeDays() throws {
        let october = DateRange.days(from: Date(millis: at(2026, 10, 2, 18)), to: nil)
        XCTAssertEqual(october.start, at(2026, 10, 2))
        XCTAssertEqual(october.end, at(2026, 10, 3) - 1)
        XCTAssertEqual(try database.itemStats(october).map(\.itemName), ["Eggs", "Milk"])
        XCTAssertEqual(try database.mostExpensiveItems().first?.itemName, "Gas")
        XCTAssertEqual(try database.listSpend(october).map(\.listName), ["Weekly"])
    }

    func testItemSummariesAndPurchaseLines() throws {
        let summaries = try database.itemSummaries()
        XCTAssertEqual(Set(summaries.map(\.name)), ["Gas", "Milk", "Eggs"])
        let gas = try XCTUnwrap(summaries.first { $0.name == "Gas" })
        XCTAssertEqual(gas.categoryName, "Car")
        XCTAssertEqual(gas.totalSpent, 30)
        XCTAssertEqual(try XCTUnwrap(summaries.first { $0.name == "Milk" }).categoryName, "Groceries")
        XCTAssertEqual(try XCTUnwrap(summaries.first { $0.name == "Milk" }).categoryColor, AppDatabase.groceriesColor)
        let lines = try database.purchaseLines(start: 0, end: Int64.max)
        XCTAssertEqual(lines.map(\.itemName), ["Gas", "Milk", "Eggs"])
        XCTAssertEqual(lines[1].categoryName, "Groceries")
        XCTAssertEqual(lines[0].storeName, "Shell")
        XCTAssertEqual(try database.firstListDate(), at(2026, 9, 5, 12))
    }
}
