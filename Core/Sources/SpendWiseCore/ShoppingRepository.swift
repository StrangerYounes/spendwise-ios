import Foundation

/// Lists, items, the item library and stores (Android data/repository/ShoppingRepository.kt).
public final class ShoppingRepository {
    public let database: AppDatabase
    var db: SQLiteDB { database.db }

    /// Only lists in this category (or with no category) feed the item library.
    public static let trackedCategory = "Groceries"

    /// Colours for categories created by quick add, picked in order, skipping used ones.
    static let newCategoryColors: [Int32] = [0xFF03A9F4, 0xFF9C27B0, 0xFFFF9800, 0xFF009688, 0xFFE91E63, 0xFF3F51B5, 0xFF795548, 0xFF607D8B]
        .map { Int32(bitPattern: UInt32($0)) }

    /// The clock, replaceable in tests.
    public var now: () -> Millis = nowMillis

    public init(_ database: AppDatabase) { self.database = database }

    // MARK: - Quick add

    public func quickAddContext(currencySymbol: String) throws -> QuickAddContext {
        var seen = Set<String>()
        let known = (try database.frequentItemNames(200) + database.allMasterItems().map(\.name))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let open = try database.allShoppingListsWithDetails().filter { !$0.shoppingList.isCompleted }.map { list in
            OpenList(id: list.shoppingList.id, name: list.shoppingList.name,
                     toBuy: try database.itemsForList(list.shoppingList.id).filter { !$0.purchased }.map { $0.itemName.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        return QuickAddContext(categories: try database.allCategories().map(\.name), stores: try database.allStores().map(\.name),
                               knownItems: known, currencySymbol: currencySymbol, openLists: open, now: now())
    }

    /// The last price paid for each name that has one, keyed by the name as given.
    public func lastPrices(_ names: [String]) throws -> [String: Double] {
        var out: [String: Double] = [:]
        for name in Set(names) { if let p = try database.lastPrice(name) { out[name] = p } }
        return out
    }

    /// Saves each purchase as a new list (completed with every item ticked when it was bought, else
    /// open), or into the open list it names. Returns the ids of the lists written to.
    @discardableResult
    public func saveQuickPurchases(_ purchases: [QuickPurchase]) throws -> [Int64] {
        try db.transaction {
            var listIds: [Int64] = []
            for purchase in purchases {
                let asBought = purchase.bought
                if let listId = purchase.existingListId {
                    try addToExistingList(listId, purchase, asBought)
                    listIds.append(listId)
                    continue
                }
                let categoryId = try purchase.categoryName.flatMap { try findOrCreateCategory($0) }
                let storeId = try purchase.storeName.map { try findOrCreateStore($0) }
                let listId = try database.insertShoppingList(ShoppingList(
                    name: purchase.listName.trimmingCharacters(in: .whitespacesAndNewlines), createdDate: purchase.date,
                    completedDate: asBought ? purchase.date : nil, isCompleted: asBought, storeId: storeId, categoryId: categoryId))
                for (index, item) in purchase.items.enumerated() {
                    try insertShoppingItem(ShoppingItem(
                        listId: listId, itemName: item.name.trimmingCharacters(in: .whitespacesAndNewlines), estimatedPrice: item.unitPrice,
                        actualPrice: asBought ? item.unitPrice : nil, quantity: item.quantity, unit: item.unit, purchased: asBought, orderIndex: index))
                }
                listIds.append(listId)
            }
            return listIds
        }
    }

    /// Adds a purchase's items to an open list; bought ones tick off the matching unticked item.
    private func addToExistingList(_ listId: Int64, _ purchase: QuickPurchase, _ asBought: Bool) throws {
        // A receipt tells where the list was bought; fill that in when the list has no store yet
        if var list = try database.shoppingList(id: listId), list.storeId == nil, let storeName = purchase.storeName {
            list.storeId = try findOrCreateStore(storeName)
            try database.updateShoppingList(list)
        }
        var unticked = try database.itemsForList(listId).filter { !$0.purchased }
        var nextIndex = try database.maxOrderIndex(listId) + 1
        for item in purchase.items {
            let wanted = [item.matchedListItem, item.name].compactMap { $0 }.map(QuickAddParser.matchKey)
            let matchIndex = asBought ? unticked.firstIndex { wanted.contains(QuickAddParser.matchKey($0.itemName)) } : nil
            if let i = matchIndex {
                var match = unticked.remove(at: i)
                match.purchased = true
                match.actualPrice = item.unitPrice ?? match.estimatedPrice
                match.quantity = item.quantity
                match.unit = item.unit ?? match.unit
                try updateShoppingItem(match)
            } else {
                try insertShoppingItem(ShoppingItem(
                    listId: listId, itemName: item.name.trimmingCharacters(in: .whitespacesAndNewlines), estimatedPrice: item.unitPrice,
                    actualPrice: asBought ? item.unitPrice : nil, quantity: item.quantity, unit: item.unit, purchased: asBought, orderIndex: nextIndex))
                nextIndex += 1
            }
        }
    }

    func findOrCreateCategory(_ name: String) throws -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == Self.trackedCategory.lowercased() { return nil }
        let all = try database.allCategories()
        if let c = all.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return c.id }
        let used = Set(all.map(\.color))
        let color = Self.newCategoryColors.first { !used.contains($0) } ?? Self.newCategoryColors[all.count % Self.newCategoryColors.count]
        return try database.insertCategory(Category(name: trimmed, color: color))
    }

    func findOrCreateStore(_ name: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = try database.allStores().first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return s.id }
        return try database.insertStore(Store(name: trimmed))
    }

    // MARK: - Lists

    public func allShoppingLists() throws -> [ShoppingListWithDetails] { try database.allShoppingListsWithDetails() }

    public func searchShoppingLists(_ query: String) throws -> [ShoppingListWithDetails] {
        try database.searchShoppingListsWithDetails(query)
    }

    public func shoppingList(id: Int64) throws -> ShoppingList? { try database.shoppingList(id: id) }

    public func hasLists() throws -> Bool { try database.hasAnyList() }

    @discardableResult
    public func insertShoppingList(_ list: ShoppingList) throws -> Int64 { try database.insertShoppingList(list) }

    public func updateShoppingList(_ list: ShoppingList) throws { try database.updateShoppingList(list) }

    public func deleteShoppingList(_ list: ShoppingList) throws { try database.deleteShoppingList(list) }

    // MARK: - Categories

    public func allCategories() throws -> [Category] { try database.allCategories() }
    @discardableResult public func insertCategory(_ c: Category) throws -> Int64 { try database.insertCategory(c) }
    public func updateCategory(_ c: Category) throws { try database.updateCategory(c) }
    public func deleteCategory(_ c: Category) throws { try database.deleteCategory(c) }

    // MARK: - Stores

    public func allStores() throws -> [Store] { try database.allStores() }
    public func store(id: Int64) throws -> Store? { try database.store(id: id) }
    @discardableResult public func insertStore(_ s: Store) throws -> Int64 { try database.insertStore(s) }
    public func deleteStore(_ s: Store) throws { try database.deleteStore(s) }
    public func storesWithUsage() throws -> [StoreUsage] { try database.storesWithUsage() }

    /// A price moved to another item or store is a different row to sync: the old one is deleted
    /// first (so sync hears of it) and the moved one gets its own uid from the trigger.
    private func moved(_ price: StoreItemPrice) -> StoreItemPrice {
        var p = price
        p.uid = nil
        return p
    }

    /// Renames a store. If another store already has the new name (ignoring case), the two are
    /// merged: lists, items and per-store prices move over and this store is removed.
    public func renameStore(_ store: Store, _ newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == store.name { return }
        try db.transaction {
            guard let target = try database.allStores().first(where: { $0.id != store.id && $0.name.lowercased() == trimmed.lowercased() }) else {
                var renamed = store
                renamed.name = trimmed
                try database.updateStore(renamed)
                return
            }
            try database.moveLists(fromStore: store.id, toStore: target.id)
            try database.moveItems(fromStore: store.id, toStore: target.id)
            for price in try database.prices(forStore: store.id) {
                if let existing = try database.price(item: price.masterItemId, store: target.id) {
                    var merged = existing
                    merged.lastPrice = price.lastUpdated > existing.lastUpdated ? price.lastPrice : existing.lastPrice
                    merged.lowestPrice = min(price.lowestPrice, existing.lowestPrice)
                    merged.highestPrice = max(price.highestPrice, existing.highestPrice)
                    merged.lastUpdated = max(price.lastUpdated, existing.lastUpdated)
                    try database.insertStorePrice(merged)
                } else {
                    try database.deleteStorePrice(price)
                    var movedPrice = moved(price)
                    movedPrice.storeId = target.id
                    try database.insertStorePrice(movedPrice)
                }
            }
            // The old store's own price rows go with it (cascade); its lists already moved
            try database.deleteStore(store)
        }
    }

    // MARK: - Store prices

    public func cheapestPrice(item masterItemId: Int64) throws -> StoreItemPrice? { try database.cheapestPrice(item: masterItemId) }
    public func storePricesWithNames(item masterItemId: Int64) throws -> [StorePriceDetail] { try database.storePricesWithNames(item: masterItemId) }
    public func price(item masterItemId: Int64, store storeId: Int64) throws -> StoreItemPrice? { try database.price(item: masterItemId, store: storeId) }

    // MARK: - Items

    public func items(listId: Int64) throws -> [ShoppingItem] { try database.itemsForList(listId) }

    public func insertShoppingItem(_ item: ShoppingItem) throws {
        // Items added as already bought (from a receipt) feed the library too
        if item.purchased && !item.isTracked {
            var tracked = item
            tracked.isTracked = true
            try db.transaction {
                tracked.id = try database.insertItem(tracked)
                try updateMasterItem(from: tracked)
            }
        } else {
            try database.insertItem(item)
        }
    }

    /// Puts back a deleted item exactly as it was (same id, prices and tracking state).
    public func restoreShoppingItem(_ item: ShoppingItem) throws { try database.insertItem(item) }

    public func deleteItems(listId: Int64) throws { try database.deleteItems(listId: listId) }

    /// An item newly bought counts once in the library, the first time it's ticked.
    public func updateShoppingItem(_ item: ShoppingItem) throws {
        if item.purchased && !item.isTracked {
            var tracked = item
            tracked.isTracked = true
            try db.transaction {
                try database.updateItem(tracked)
                try updateMasterItem(from: tracked)
            }
        } else {
            try database.updateItem(item)
        }
    }

    public func deleteShoppingItem(_ item: ShoppingItem) throws { try database.deleteItem(item) }

    public func searchItems(_ query: String) throws -> [ItemSearchResult] { try database.searchItems(query) }
    public func searchItemNames(_ query: String) throws -> [ItemNameSuggestion] { try database.searchItemNames(query) }
    public func itemSummaries() throws -> [ItemSummary] { try database.itemSummaries() }
    public func purchaseHistory(_ name: String) throws -> [PurchaseHistoryItem] { try database.purchaseHistory(name) }

    /// Renames an item in every list; the library's stats and store prices follow (merging into
    /// an existing library item with the new name).
    public func renameItemEverywhere(_ oldName: String, _ newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == oldName { return }
        if let master = try database.masterItem(named: oldName) {
            try renameMasterItem(master, trimmed, lastPrice: master.lastPrice)
        } else {
            try database.updateItemNames(from: oldName, to: trimmed)
        }
    }

    // MARK: - The item library

    public func allMasterItems() throws -> [MasterItem] { try database.allMasterItems() }
    public func searchMasterItems(_ query: String) throws -> [MasterItem] { try database.searchMasterItems(query) }
    public func updateMasterItemManual(_ item: MasterItem) throws { try database.updateMasterItem(item) }
    public func insertMasterItem(_ item: MasterItem) throws { try database.insertMasterItem(item) }
    public func deleteMasterItem(_ item: MasterItem) throws { try database.deleteMasterItem(item) }

    /// Renames a library item and the shopping items that use its name; renaming onto an existing
    /// item's name merges the two instead.
    public func renameMasterItem(_ item: MasterItem, _ newName: String, lastPrice: Double) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.transaction {
            if trimmed != item.name, let existing = try database.masterItem(named: trimmed), existing.id != item.id {
                try mergeMasterItems(item, into: existing)
                return
            }
            if trimmed != item.name { try database.updateItemNames(from: item.name, to: trimmed) }
            var renamed = item
            renamed.name = trimmed
            renamed.lastPrice = lastPrice
            try database.updateMasterItem(renamed)
        }
    }

    public func mergeMasterItems(_ sourceItem: MasterItem, into targetItem: MasterItem) throws {
        try db.transaction {
            // 1. Shopping items that used the source name
            try database.updateItemNames(from: sourceItem.name, to: targetItem.name)

            // 2. Store prices
            for sourcePrice in try database.prices(forItem: sourceItem.id) {
                if let existing = try database.price(item: targetItem.id, store: sourcePrice.storeId) {
                    var merged = existing
                    merged.lastPrice = sourcePrice.lastUpdated > existing.lastUpdated ? sourcePrice.lastPrice : existing.lastPrice
                    merged.lowestPrice = min(sourcePrice.lowestPrice, existing.lowestPrice)
                    merged.highestPrice = max(sourcePrice.highestPrice, existing.highestPrice)
                    merged.lastUpdated = max(sourcePrice.lastUpdated, existing.lastUpdated)
                    try database.insertStorePrice(merged)
                } else {
                    try database.deleteStorePrice(sourcePrice)
                    var movedPrice = moved(sourcePrice)
                    movedPrice.masterItemId = targetItem.id
                    try database.insertStorePrice(movedPrice)
                }
            }

            // 3. The target's stats, as a simple average of unit prices
            let count = targetItem.purchaseCount + sourceItem.purchaseCount
            var t = targetItem
            t.averagePrice = count > 0
                ? (targetItem.averagePrice * Double(targetItem.purchaseCount) + sourceItem.averagePrice * Double(sourceItem.purchaseCount)) / Double(count)
                : targetItem.averagePrice
            t.lastPrice = sourceItem.lastPurchaseDate > targetItem.lastPurchaseDate ? sourceItem.lastPrice : targetItem.lastPrice
            if targetItem.purchaseCount == 0 && sourceItem.purchaseCount == 0 { t.lowestPrice = 0 }
            else if targetItem.purchaseCount == 0 { t.lowestPrice = sourceItem.lowestPrice }
            else if sourceItem.purchaseCount == 0 { t.lowestPrice = targetItem.lowestPrice }
            else { t.lowestPrice = min(targetItem.lowestPrice, sourceItem.lowestPrice) }
            t.highestPrice = max(targetItem.highestPrice, sourceItem.highestPrice)
            t.totalQuantity = targetItem.totalQuantity + sourceItem.totalQuantity
            t.purchaseCount = count
            t.lastPurchaseDate = max(targetItem.lastPurchaseDate, sourceItem.lastPurchaseDate)
            try database.updateMasterItem(t)

            // 4. The source goes
            try database.deleteMasterItem(sourceItem)
        }
    }

    /// Counts a newly bought grocery item in the library (and its store's price).
    private func updateMasterItem(from shoppingItem: ShoppingItem) throws {
        guard let shoppingList = try database.shoppingList(id: shoppingItem.listId) else { return }
        // Only Groceries (or no category) feeds the library
        let category = try shoppingList.categoryId.flatMap { try database.category(id: $0) }
        let categoryName = category?.name ?? Self.trackedCategory
        guard categoryName == Self.trackedCategory else { return }

        let name = shoppingItem.itemName
        let unitPrice = shoppingItem.actualPrice ?? shoppingItem.estimatedPrice ?? 0
        let qty = shoppingItem.quantity
        let date = now()
        let effectiveStoreId = shoppingItem.storeId ?? shoppingList.storeId

        let masterId: Int64
        if var existing = try database.masterItem(named: name) {
            let newCount = existing.purchaseCount + 1
            let newAverage = (existing.averagePrice * Double(existing.purchaseCount) + unitPrice) / Double(newCount)
            existing.lowestPrice = existing.purchaseCount == 0 ? unitPrice : min(existing.lowestPrice, unitPrice)
            existing.averagePrice = newAverage
            existing.lastPrice = unitPrice
            existing.highestPrice = max(existing.highestPrice, unitPrice)
            existing.totalQuantity += qty
            existing.purchaseCount = newCount
            existing.lastPurchaseDate = date
            try database.updateMasterItem(existing)
            masterId = existing.id
        } else {
            masterId = try database.insertMasterItem(MasterItem(
                name: name, averagePrice: unitPrice, lastPrice: unitPrice, lowestPrice: unitPrice, highestPrice: unitPrice,
                purchaseCount: 1, lastPurchaseDate: date, totalQuantity: qty))
        }

        guard let storeId = effectiveStoreId else { return }
        if var existing = try database.price(item: masterId, store: storeId) {
            existing.lastPrice = unitPrice
            existing.lowestPrice = min(existing.lowestPrice, unitPrice)
            existing.highestPrice = max(existing.highestPrice, unitPrice)
            existing.lastUpdated = date
            try database.insertStorePrice(existing)
        } else {
            try database.insertStorePrice(StoreItemPrice(masterItemId: masterId, storeId: storeId, lastPrice: unitPrice,
                                                         lowestPrice: unitPrice, highestPrice: unitPrice, lastUpdated: date))
        }
    }

    // MARK: - Photos

    public func photos(listId: Int64) throws -> [Photo] { try database.photos(listId: listId) }
    public func insertPhoto(_ p: Photo) throws { try database.insertPhoto(p) }
    public func deletePhoto(_ p: Photo) throws { try database.deletePhoto(p) }
}
