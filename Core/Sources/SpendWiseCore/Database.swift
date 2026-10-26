import Foundation

/// The app's database: the same tables, columns and queries as the Android app's Room database
/// (version 10), so stats, backups and sync behave the same. Android's DAOs are the methods here,
/// with their SQL kept as it is there.
public final class AppDatabase {
    public let db: SQLiteDB

    public static let version = 10
    /// Groceries' colour (#4CAF50), as Android seeds it.
    public static let groceriesColor: Int32 = -12537232

    /// Opens (or creates) the database at [path]; ":memory:" for tests.
    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        if db.userVersion == 0 {
            try db.transaction {
                for sql in Self.schema { try db.execute(sql) }
                // Fresh installs start with Groceries, as on Android
                try db.run("INSERT INTO `categories` (`name`, `color`) VALUES ('Groceries', ?)", [Int64(Self.groceriesColor)])
            }
            db.userVersion = Self.version
        }
        // Sync's change tracking; records nothing until an account syncs
        try SyncSchema.installTriggers(db)
        try SyncSchema.fillMissingUids(db)
    }

    /// Room's CREATE statements for version 10.
    static let schema = [
        "CREATE TABLE IF NOT EXISTS `stores` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL, `uid` TEXT)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_stores_uid` ON `stores` (`uid`)",
        "CREATE TABLE IF NOT EXISTS `categories` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL, `color` INTEGER NOT NULL, `uid` TEXT)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_categories_uid` ON `categories` (`uid`)",
        """
        CREATE TABLE IF NOT EXISTS `shopping_lists` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL,
        `createdDate` INTEGER NOT NULL, `completedDate` INTEGER, `isCompleted` INTEGER NOT NULL, `storeId` INTEGER,
        `categoryId` INTEGER, `uid` TEXT,
        FOREIGN KEY(`storeId`) REFERENCES `stores`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL,
        FOREIGN KEY(`categoryId`) REFERENCES `categories`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL)
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_shopping_lists_uid` ON `shopping_lists` (`uid`)",
        "CREATE INDEX IF NOT EXISTS `index_shopping_lists_storeId` ON `shopping_lists` (`storeId`)",
        "CREATE INDEX IF NOT EXISTS `index_shopping_lists_categoryId` ON `shopping_lists` (`categoryId`)",
        """
        CREATE TABLE IF NOT EXISTS `shopping_items` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `listId` INTEGER NOT NULL,
        `itemName` TEXT NOT NULL, `estimatedPrice` REAL, `actualPrice` REAL, `quantity` REAL NOT NULL, `unit` TEXT,
        `purchased` INTEGER NOT NULL, `orderIndex` INTEGER NOT NULL, `notes` TEXT, `storeId` INTEGER,
        `isTracked` INTEGER NOT NULL, `uid` TEXT,
        FOREIGN KEY(`listId`) REFERENCES `shopping_lists`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE,
        FOREIGN KEY(`storeId`) REFERENCES `stores`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL)
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_shopping_items_uid` ON `shopping_items` (`uid`)",
        "CREATE INDEX IF NOT EXISTS `index_shopping_items_listId` ON `shopping_items` (`listId`)",
        "CREATE INDEX IF NOT EXISTS `index_shopping_items_storeId` ON `shopping_items` (`storeId`)",
        """
        CREATE TABLE IF NOT EXISTS `master_items` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL,
        `averagePrice` REAL NOT NULL, `lastPrice` REAL NOT NULL, `lowestPrice` REAL NOT NULL, `highestPrice` REAL NOT NULL,
        `purchaseCount` INTEGER NOT NULL, `lastPurchaseDate` INTEGER NOT NULL, `totalQuantity` REAL NOT NULL, `uid` TEXT)
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_master_items_uid` ON `master_items` (`uid`)",
        """
        CREATE TABLE IF NOT EXISTS `photos` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `shoppingListId` INTEGER NOT NULL,
        `uri` TEXT NOT NULL,
        FOREIGN KEY(`shoppingListId`) REFERENCES `shopping_lists`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        "CREATE INDEX IF NOT EXISTS `index_photos_shoppingListId` ON `photos` (`shoppingListId`)",
        """
        CREATE TABLE IF NOT EXISTS `app_settings` (`id` INTEGER NOT NULL, `darkTheme` INTEGER, `currencySymbol` TEXT NOT NULL,
        `lastConversionRate` REAL NOT NULL, `uid` TEXT, PRIMARY KEY(`id`))
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_app_settings_uid` ON `app_settings` (`uid`)",
        """
        CREATE TABLE IF NOT EXISTS `store_item_prices` (`masterItemId` INTEGER NOT NULL, `storeId` INTEGER NOT NULL,
        `lastPrice` REAL NOT NULL, `lowestPrice` REAL NOT NULL, `highestPrice` REAL NOT NULL, `lastUpdated` INTEGER NOT NULL,
        `uid` TEXT, PRIMARY KEY(`masterItemId`, `storeId`),
        FOREIGN KEY(`masterItemId`) REFERENCES `master_items`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE,
        FOREIGN KEY(`storeId`) REFERENCES `stores`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_store_item_prices_uid` ON `store_item_prices` (`uid`)",
        "CREATE INDEX IF NOT EXISTS `index_store_item_prices_masterItemId` ON `store_item_prices` (`masterItemId`)",
        "CREATE INDEX IF NOT EXISTS `index_store_item_prices_storeId` ON `store_item_prices` (`storeId`)",
        """
        CREATE TABLE IF NOT EXISTS `ai_reports` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `createdAt` INTEGER NOT NULL,
        `request` TEXT NOT NULL, `periodStart` INTEGER NOT NULL, `periodEnd` INTEGER NOT NULL, `title` TEXT NOT NULL,
        `content` TEXT NOT NULL, `uid` TEXT)
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_ai_reports_uid` ON `ai_reports` (`uid`)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_ai_reports_createdAt` ON `ai_reports` (`createdAt`)",
    ]

    // MARK: - Row mapping

    static func list(_ r: SQLRow) -> ShoppingList {
        ShoppingList(id: r.int("id"), name: r.string("name"), createdDate: r.int("createdDate"), completedDate: r.intOrNil("completedDate"),
                     isCompleted: r.bool("isCompleted"), storeId: r.intOrNil("storeId"), categoryId: r.intOrNil("categoryId"), uid: r.stringOrNil("uid"))
    }

    static func item(_ r: SQLRow) -> ShoppingItem {
        ShoppingItem(id: r.int("id"), listId: r.int("listId"), itemName: r.string("itemName"), estimatedPrice: r.doubleOrNil("estimatedPrice"),
                     actualPrice: r.doubleOrNil("actualPrice"), quantity: r.double("quantity"), unit: r.stringOrNil("unit"),
                     purchased: r.bool("purchased"), orderIndex: Int(r.int("orderIndex")), notes: r.stringOrNil("notes"),
                     storeId: r.intOrNil("storeId"), isTracked: r.bool("isTracked"), uid: r.stringOrNil("uid"))
    }

    static func master(_ r: SQLRow) -> MasterItem {
        MasterItem(id: r.int("id"), name: r.string("name"), averagePrice: r.double("averagePrice"), lastPrice: r.double("lastPrice"),
                   lowestPrice: r.double("lowestPrice"), highestPrice: r.double("highestPrice"), purchaseCount: Int(r.int("purchaseCount")),
                   lastPurchaseDate: r.int("lastPurchaseDate"), totalQuantity: r.double("totalQuantity"), uid: r.stringOrNil("uid"))
    }

    static func store(_ r: SQLRow) -> Store { Store(id: r.int("id"), name: r.string("name"), uid: r.stringOrNil("uid")) }

    static func category(_ r: SQLRow) -> Category {
        Category(id: r.int("id"), name: r.string("name"), color: Int32(truncatingIfNeeded: r.int("color")), uid: r.stringOrNil("uid"))
    }

    static func price(_ r: SQLRow) -> StoreItemPrice {
        StoreItemPrice(masterItemId: r.int("masterItemId"), storeId: r.int("storeId"), lastPrice: r.double("lastPrice"),
                       lowestPrice: r.double("lowestPrice"), highestPrice: r.double("highestPrice"), lastUpdated: r.int("lastUpdated"),
                       uid: r.stringOrNil("uid"))
    }

    static func report(_ r: SQLRow) -> AiReport {
        AiReport(id: r.int("id"), createdAt: r.int("createdAt"), request: r.string("request"), periodStart: r.int("periodStart"),
                 periodEnd: r.int("periodEnd"), title: r.string("title"), content: r.string("content"), uid: r.stringOrNil("uid"))
    }

    // MARK: - Shopping lists

    static let listDetailsSelect = """
        SELECT sl.*,
        s.name as storeName,
        COUNT(si.id) as itemCount,
        COALESCE(SUM(CASE WHEN si.purchased THEN 1 ELSE 0 END), 0) as purchasedCount,
        COALESCE(SUM(COALESCE(si.estimatedPrice, 0) * si.quantity), 0) as estimatedTotal,
        COALESCE(SUM(CASE WHEN si.purchased THEN COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity ELSE 0 END), 0) as actualTotal
        FROM shopping_lists sl
        LEFT JOIN shopping_items si ON sl.id = si.listId
        LEFT JOIN stores s ON sl.storeId = s.id
        """

    private func details(_ rows: [SQLRow]) throws -> [ShoppingListWithDetails] {
        let categories = Dictionary(uniqueKeysWithValues: try allCategories().map { ($0.id, $0) })
        return rows.map { r in
            let list = Self.list(r)
            return ShoppingListWithDetails(
                shoppingList: list, itemCount: Int(r.int("itemCount")), purchasedCount: Int(r.int("purchasedCount")),
                estimatedTotal: r.double("estimatedTotal"), actualTotal: r.double("actualTotal"), storeName: r.stringOrNil("storeName"),
                category: list.categoryId.flatMap { categories[$0] })
        }
    }

    public func allShoppingListsWithDetails() throws -> [ShoppingListWithDetails] {
        try details(db.query(Self.listDetailsSelect + """
             GROUP BY sl.id
             ORDER BY CASE WHEN sl.isCompleted = 1 THEN sl.completedDate ELSE sl.createdDate END DESC
            """))
    }

    public func searchShoppingListsWithDetails(_ query: String) throws -> [ShoppingListWithDetails] {
        try details(db.query(Self.listDetailsSelect + """
             WHERE sl.name LIKE '%' || :query || '%'
             GROUP BY sl.id
             ORDER BY CASE WHEN sl.isCompleted = 1 THEN sl.completedDate ELSE sl.createdDate END DESC
            """, named: ["query": query]))
    }

    public func allShoppingLists() throws -> [ShoppingList] {
        try db.query("SELECT * FROM shopping_lists ORDER BY createdDate DESC").map(Self.list)
    }

    public func hasAnyList() throws -> Bool {
        (try db.scalar("SELECT EXISTS(SELECT 1 FROM shopping_lists)")?.int64 ?? 0) != 0
    }

    public func shoppingList(id: Int64) throws -> ShoppingList? {
        try db.query("SELECT * FROM shopping_lists WHERE id = ?", [id]).first.map(Self.list)
    }

    public func findList(name: String, createdDate: Millis) throws -> ShoppingList? {
        try db.query("SELECT * FROM shopping_lists WHERE name = ? AND createdDate = ? LIMIT 1", [name, createdDate]).first.map(Self.list)
    }

    /// Room's @Insert(onConflict = REPLACE).
    @discardableResult
    public func insertShoppingList(_ l: ShoppingList) throws -> Int64 {
        try db.run("INSERT OR REPLACE INTO shopping_lists (id, name, createdDate, completedDate, isCompleted, storeId, categoryId, uid) VALUES (?,?,?,?,?,?,?,?)",
                   [l.id == 0 ? nil : l.id, l.name, l.createdDate, l.completedDate, l.isCompleted, l.storeId, l.categoryId, l.uid])
        return db.lastInsertRowID
    }

    public func updateShoppingList(_ l: ShoppingList) throws {
        try db.run("UPDATE OR ABORT shopping_lists SET id = ?, name = ?, createdDate = ?, completedDate = ?, isCompleted = ?, storeId = ?, categoryId = ?, uid = ? WHERE id = ?",
                   [l.id, l.name, l.createdDate, l.completedDate, l.isCompleted, l.storeId, l.categoryId, l.uid, l.id])
    }

    public func deleteShoppingList(_ l: ShoppingList) throws {
        try db.run("DELETE FROM shopping_lists WHERE id = ?", [l.id])
    }

    // MARK: - Shopping items

    public func itemsForList(_ listId: Int64) throws -> [ShoppingItem] {
        try db.query("SELECT * FROM shopping_items WHERE listId = ? ORDER BY purchased ASC, orderIndex ASC", [listId]).map(Self.item)
    }

    public func item(id: Int64) throws -> ShoppingItem? {
        try db.query("SELECT * FROM shopping_items WHERE id = ?", [id]).first.map(Self.item)
    }

    @discardableResult
    public func insertItem(_ i: ShoppingItem) throws -> Int64 {
        try db.run("""
            INSERT OR REPLACE INTO shopping_items (id, listId, itemName, estimatedPrice, actualPrice, quantity, unit, purchased, orderIndex, notes, storeId, isTracked, uid)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [i.id == 0 ? nil : i.id, i.listId, i.itemName, i.estimatedPrice, i.actualPrice, i.quantity, i.unit, i.purchased,
                  i.orderIndex, i.notes, i.storeId, i.isTracked, i.uid])
        return db.lastInsertRowID
    }

    public func updateItem(_ i: ShoppingItem) throws {
        try db.run("""
            UPDATE OR ABORT shopping_items SET id = ?, listId = ?, itemName = ?, estimatedPrice = ?, actualPrice = ?, quantity = ?, unit = ?,
            purchased = ?, orderIndex = ?, notes = ?, storeId = ?, isTracked = ?, uid = ? WHERE id = ?
            """, [i.id, i.listId, i.itemName, i.estimatedPrice, i.actualPrice, i.quantity, i.unit, i.purchased, i.orderIndex, i.notes,
                  i.storeId, i.isTracked, i.uid, i.id])
    }

    public func deleteItem(_ i: ShoppingItem) throws {
        try db.run("DELETE FROM shopping_items WHERE id = ?", [i.id])
    }

    public func deleteItems(listId: Int64) throws {
        try db.run("DELETE FROM shopping_items WHERE listId = ?", [listId])
    }

    public func allItems() throws -> [ShoppingItem] {
        try db.query("SELECT * FROM shopping_items").map(Self.item)
    }

    public func searchItems(_ query: String) throws -> [ItemSearchResult] {
        try db.query("""
            SELECT si.*, sl.name as listName, COALESCE(sl.completedDate, sl.createdDate) as listDate
            FROM shopping_items si
            INNER JOIN shopping_lists sl ON si.listId = sl.id
            WHERE si.itemName LIKE '%' || :query || '%'
            ORDER BY COALESCE(sl.completedDate, sl.createdDate) DESC
            LIMIT 50
            """, named: ["query": query]).map { r in
                // sl.name shadows nothing: si.* has no name column
                ItemSearchResult(item: Self.item(r), listName: r.string("listName"), listDate: r.int("listDate"))
            }
    }

    public func purchaseHistory(_ itemName: String) throws -> [PurchaseHistoryItem] {
        try db.query("""
            SELECT si.*, sl.name as listName, COALESCE(sl.completedDate, sl.createdDate) as listDate, s.name as storeName
            FROM shopping_items si
            INNER JOIN shopping_lists sl ON si.listId = sl.id
            LEFT JOIN stores s ON COALESCE(si.storeId, sl.storeId) = s.id
            WHERE si.itemName = :itemName AND si.purchased = 1
            ORDER BY COALESCE(sl.completedDate, sl.createdDate) DESC
            """, named: ["itemName": itemName]).map { r in
                PurchaseHistoryItem(shoppingItem: Self.item(r), listName: r.string("listName"), listDate: r.int("listDate"), storeName: r.stringOrNil("storeName"))
            }
    }

    /// Every item name ever used, in any category, for name suggestions; the price is the latest recorded.
    public func searchItemNames(_ query: String) throws -> [ItemNameSuggestion] {
        try db.query("""
            SELECT si.itemName AS name,
                COUNT(*) AS timesUsed,
                (SELECT COALESCE(s2.actualPrice, s2.estimatedPrice)
                    FROM shopping_items s2 JOIN shopping_lists l2 ON s2.listId = l2.id
                    WHERE s2.itemName = si.itemName AND COALESCE(s2.actualPrice, s2.estimatedPrice) IS NOT NULL
                    ORDER BY COALESCE(l2.completedDate, l2.createdDate) DESC LIMIT 1) AS lastPrice,
                (SELECT s3.unit
                    FROM shopping_items s3 JOIN shopping_lists l3 ON s3.listId = l3.id
                    WHERE s3.itemName = si.itemName AND s3.unit IS NOT NULL AND TRIM(s3.unit) != ''
                    ORDER BY COALESCE(l3.completedDate, l3.createdDate) DESC LIMIT 1) AS lastUnit
            FROM shopping_items si
            WHERE si.itemName LIKE '%' || :query || '%'
            GROUP BY si.itemName
            ORDER BY timesUsed DESC
            LIMIT 20
            """, named: ["query": query]).map { r in
                ItemNameSuggestion(name: r.string("name"), timesUsed: Int(r.int("timesUsed")), lastPrice: r.doubleOrNil("lastPrice"), lastUnit: r.stringOrNil("lastUnit"))
            }
    }

    /// The most recent price recorded for an item name, ignoring case and stray spaces.
    public func lastPrice(_ name: String) throws -> Double? {
        try db.scalar("""
            SELECT COALESCE(si.actualPrice, si.estimatedPrice)
            FROM shopping_items si JOIN shopping_lists sl ON si.listId = sl.id
            WHERE LOWER(TRIM(si.itemName)) = LOWER(TRIM(:name))
                AND COALESCE(si.actualPrice, si.estimatedPrice) IS NOT NULL
            ORDER BY si.purchased DESC, COALESCE(sl.completedDate, sl.createdDate) DESC
            LIMIT 1
            """, named: ["name": name])?.double
    }

    public func maxOrderIndex(_ listId: Int64) throws -> Int {
        Int(try db.scalar("SELECT COALESCE(MAX(orderIndex), -1) FROM shopping_items WHERE listId = ?", [listId])?.int64 ?? -1)
    }

    /// One row per item name that was ever bought, across all categories.
    public func itemSummaries() throws -> [ItemSummary] {
        try db.query("""
            SELECT si.itemName AS name,
                COUNT(*) AS purchaseCount,
                SUM(si.quantity) AS totalQuantity,
                SUM(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) AS totalSpent,
                MAX(COALESCE(sl.completedDate, sl.createdDate)) AS lastDate,
                (SELECT COALESCE(s2.actualPrice, s2.estimatedPrice)
                    FROM shopping_items s2 JOIN shopping_lists l2 ON s2.listId = l2.id
                    WHERE s2.itemName = si.itemName AND s2.purchased = 1
                    ORDER BY COALESCE(l2.completedDate, l2.createdDate) DESC LIMIT 1) AS lastPrice,
                (SELECT COALESCE(c.name, 'Groceries')
                    FROM shopping_items s3 JOIN shopping_lists l3 ON s3.listId = l3.id
                    LEFT JOIN categories c ON l3.categoryId = c.id
                    WHERE s3.itemName = si.itemName AND s3.purchased = 1
                    ORDER BY COALESCE(l3.completedDate, l3.createdDate) DESC LIMIT 1) AS categoryName,
                (SELECT c.color
                    FROM shopping_items s4 JOIN shopping_lists l4 ON s4.listId = l4.id
                    LEFT JOIN categories c ON c.id = COALESCE(l4.categoryId, (SELECT id FROM categories WHERE name = 'Groceries' LIMIT 1))
                    WHERE s4.itemName = si.itemName AND s4.purchased = 1
                    ORDER BY COALESCE(l4.completedDate, l4.createdDate) DESC LIMIT 1) AS categoryColor
            FROM shopping_items si
            INNER JOIN shopping_lists sl ON si.listId = sl.id
            WHERE si.purchased = 1
            GROUP BY si.itemName
            ORDER BY lastDate DESC
            """).map { r in
                ItemSummary(name: r.string("name"), purchaseCount: Int(r.int("purchaseCount")), totalQuantity: r.double("totalQuantity"),
                            totalSpent: r.double("totalSpent"), lastDate: r.int("lastDate"), lastPrice: r.doubleOrNil("lastPrice"),
                            categoryName: r.stringOrNil("categoryName"), categoryColor: r.intOrNil("categoryColor").map { Int32(truncatingIfNeeded: $0) })
            }
    }

    /// Most used item names first, so the AI reuses the person's own names.
    public func frequentItemNames(_ limit: Int) throws -> [String] {
        try db.query("SELECT itemName FROM shopping_items GROUP BY itemName ORDER BY COUNT(*) DESC LIMIT ?", [limit]).map { $0.string("itemName") }
    }

    public func updateItemNames(from oldName: String, to newName: String) throws {
        try db.run("UPDATE shopping_items SET itemName = ? WHERE itemName = ?", [newName, oldName])
    }

    // MARK: - Item library

    public func allMasterItems() throws -> [MasterItem] {
        try db.query("SELECT * FROM master_items ORDER BY name COLLATE NOCASE ASC").map(Self.master)
    }

    public func masterItem(id: Int64) throws -> MasterItem? {
        try db.query("SELECT * FROM master_items WHERE id = ?", [id]).first.map(Self.master)
    }

    public func masterItem(named name: String) throws -> MasterItem? {
        try db.query("SELECT * FROM master_items WHERE name = ?", [name]).first.map(Self.master)
    }

    @discardableResult
    public func insertMasterItem(_ m: MasterItem) throws -> Int64 {
        try db.run("""
            INSERT OR REPLACE INTO master_items (id, name, averagePrice, lastPrice, lowestPrice, highestPrice, purchaseCount, lastPurchaseDate, totalQuantity, uid)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [m.id == 0 ? nil : m.id, m.name, m.averagePrice, m.lastPrice, m.lowestPrice, m.highestPrice, m.purchaseCount,
                  m.lastPurchaseDate, m.totalQuantity, m.uid])
        return db.lastInsertRowID
    }

    public func updateMasterItem(_ m: MasterItem) throws {
        try db.run("""
            UPDATE OR ABORT master_items SET id = ?, name = ?, averagePrice = ?, lastPrice = ?, lowestPrice = ?, highestPrice = ?,
            purchaseCount = ?, lastPurchaseDate = ?, totalQuantity = ?, uid = ? WHERE id = ?
            """, [m.id, m.name, m.averagePrice, m.lastPrice, m.lowestPrice, m.highestPrice, m.purchaseCount, m.lastPurchaseDate,
                  m.totalQuantity, m.uid, m.id])
    }

    public func deleteMasterItem(_ m: MasterItem) throws {
        try db.run("DELETE FROM master_items WHERE id = ?", [m.id])
    }

    public func searchMasterItems(_ query: String) throws -> [MasterItem] {
        try db.query("SELECT * FROM master_items WHERE name LIKE '%' || :query || '%' ORDER BY name COLLATE NOCASE ASC", named: ["query": query]).map(Self.master)
    }

    // MARK: - Categories

    public func allCategories() throws -> [Category] {
        try db.query("SELECT * FROM categories ORDER BY name ASC").map(Self.category)
    }

    public func category(id: Int64) throws -> Category? {
        try db.query("SELECT * FROM categories WHERE id = ?", [id]).first.map(Self.category)
    }

    public func category(named name: String) throws -> Category? {
        try db.query("SELECT * FROM categories WHERE name = ? LIMIT 1", [name]).first.map(Self.category)
    }

    @discardableResult
    public func insertCategory(_ c: Category) throws -> Int64 {
        try db.run("INSERT OR REPLACE INTO categories (id, name, color, uid) VALUES (?,?,?,?)", [c.id == 0 ? nil : c.id, c.name, Int64(c.color), c.uid])
        return db.lastInsertRowID
    }

    public func updateCategory(_ c: Category) throws {
        try db.run("UPDATE OR ABORT categories SET id = ?, name = ?, color = ?, uid = ? WHERE id = ?", [c.id, c.name, Int64(c.color), c.uid, c.id])
    }

    public func deleteCategory(_ c: Category) throws {
        try db.run("DELETE FROM categories WHERE id = ?", [c.id])
    }

    // MARK: - Stores and their prices

    public func allStores() throws -> [Store] {
        try db.query("SELECT * FROM stores ORDER BY name ASC").map(Self.store)
    }

    public func store(id: Int64) throws -> Store? {
        try db.query("SELECT * FROM stores WHERE id = ?", [id]).first.map(Self.store)
    }

    public func store(named name: String) throws -> Store? {
        try db.query("SELECT * FROM stores WHERE name = ? LIMIT 1", [name]).first.map(Self.store)
    }

    public func allStorePrices() throws -> [StoreItemPrice] {
        try db.query("SELECT * FROM store_item_prices").map(Self.price)
    }

    @discardableResult
    public func insertStore(_ s: Store) throws -> Int64 {
        try db.run("INSERT OR REPLACE INTO stores (id, name, uid) VALUES (?,?,?)", [s.id == 0 ? nil : s.id, s.name, s.uid])
        return db.lastInsertRowID
    }

    public func updateStore(_ s: Store) throws {
        try db.run("UPDATE OR ABORT stores SET id = ?, name = ?, uid = ? WHERE id = ?", [s.id, s.name, s.uid, s.id])
    }

    public func deleteStore(_ s: Store) throws {
        try db.run("DELETE FROM stores WHERE id = ?", [s.id])
    }

    public func insertStorePrice(_ p: StoreItemPrice) throws {
        try db.run("""
            INSERT OR REPLACE INTO store_item_prices (masterItemId, storeId, lastPrice, lowestPrice, highestPrice, lastUpdated, uid)
            VALUES (?,?,?,?,?,?,?)
            """, [p.masterItemId, p.storeId, p.lastPrice, p.lowestPrice, p.highestPrice, p.lastUpdated, p.uid])
    }

    public func deleteStorePrice(_ p: StoreItemPrice) throws {
        try db.run("DELETE FROM store_item_prices WHERE masterItemId = ? AND storeId = ?", [p.masterItemId, p.storeId])
    }

    /// Every store with how many lists use it.
    public func storesWithUsage() throws -> [StoreUsage] {
        try db.query("""
            SELECT s.id, s.name,
                (SELECT COUNT(*) FROM shopping_lists sl WHERE sl.storeId = s.id) AS listCount
            FROM stores s
            ORDER BY s.name COLLATE NOCASE
            """).map { StoreUsage(id: $0.int("id"), name: $0.string("name"), listCount: Int($0.int("listCount"))) }
    }

    public func moveLists(fromStore: Int64, toStore: Int64) throws {
        try db.run("UPDATE shopping_lists SET storeId = ? WHERE storeId = ?", [toStore, fromStore])
    }

    public func moveItems(fromStore: Int64, toStore: Int64) throws {
        try db.run("UPDATE shopping_items SET storeId = ? WHERE storeId = ?", [toStore, fromStore])
    }

    public func prices(forStore storeId: Int64) throws -> [StoreItemPrice] {
        try db.query("SELECT * FROM store_item_prices WHERE storeId = ?", [storeId]).map(Self.price)
    }

    public func prices(forItem masterItemId: Int64) throws -> [StoreItemPrice] {
        try db.query("SELECT * FROM store_item_prices WHERE masterItemId = ?", [masterItemId]).map(Self.price)
    }

    public func price(item masterItemId: Int64, store storeId: Int64) throws -> StoreItemPrice? {
        try db.query("SELECT * FROM store_item_prices WHERE masterItemId = ? AND storeId = ?", [masterItemId, storeId]).first.map(Self.price)
    }

    public func cheapestPrice(item masterItemId: Int64) throws -> StoreItemPrice? {
        try db.query("SELECT * FROM store_item_prices WHERE masterItemId = ? ORDER BY lastPrice ASC LIMIT 1", [masterItemId]).first.map(Self.price)
    }

    public func storePricesWithNames(item masterItemId: Int64) throws -> [StorePriceDetail] {
        try db.query("""
            SELECT sip.*, s.name as storeName
            FROM store_item_prices sip
            INNER JOIN stores s ON sip.storeId = s.id
            WHERE sip.masterItemId = ?
            ORDER BY sip.lastPrice ASC
            """, [masterItemId]).map { StorePriceDetail(storeItemPrice: Self.price($0), storeName: $0.string("storeName")) }
    }

    // MARK: - Photos

    public func photos(listId: Int64) throws -> [Photo] {
        try db.query("SELECT * FROM photos WHERE shoppingListId = ?", [listId]).map {
            Photo(id: $0.int("id"), shoppingListId: $0.int("shoppingListId"), uri: $0.string("uri"))
        }
    }

    @discardableResult
    public func insertPhoto(_ p: Photo) throws -> Int64 {
        try db.run("INSERT OR REPLACE INTO photos (id, shoppingListId, uri) VALUES (?,?,?)", [p.id == 0 ? nil : p.id, p.shoppingListId, p.uri])
        return db.lastInsertRowID
    }

    public func deletePhoto(_ p: Photo) throws {
        try db.run("DELETE FROM photos WHERE id = ?", [p.id])
    }

    // MARK: - Settings

    public func settings() throws -> AppSettings? {
        try db.query("SELECT * FROM app_settings WHERE id = 0").first.map { r in
            AppSettings(darkTheme: r.intOrNil("darkTheme").map { $0 != 0 }, currencySymbol: r.string("currencySymbol"),
                        lastConversionRate: r.double("lastConversionRate"), uid: r.stringOrNil("uid"))
        }
    }

    public func updateSettings(_ s: AppSettings) throws {
        try db.run("INSERT OR REPLACE INTO app_settings (id, darkTheme, currencySymbol, lastConversionRate, uid) VALUES (0,?,?,?,?)",
                   [s.darkTheme, s.currencySymbol, s.lastConversionRate, s.uid])
    }

    // MARK: - AI reports

    public func allReports() throws -> [AiReport] {
        try db.query("SELECT * FROM ai_reports ORDER BY createdAt DESC").map(Self.report)
    }

    public func report(id: Int64) throws -> AiReport? {
        try db.query("SELECT * FROM ai_reports WHERE id = ?", [id]).first.map(Self.report)
    }

    public func report(createdAt: Millis) throws -> AiReport? {
        try db.query("SELECT * FROM ai_reports WHERE createdAt = ? LIMIT 1", [createdAt]).first.map(Self.report)
    }

    @discardableResult
    public func insertReport(_ r: AiReport) throws -> Int64 {
        try db.run("INSERT INTO ai_reports (id, createdAt, request, periodStart, periodEnd, title, content, uid) VALUES (?,?,?,?,?,?,?,?)",
                   [r.id == 0 ? nil : r.id, r.createdAt, r.request, r.periodStart, r.periodEnd, r.title, r.content, r.uid])
        return db.lastInsertRowID
    }

    public func deleteReport(_ r: AiReport) throws {
        try db.run("DELETE FROM ai_reports WHERE id = ?", [r.id])
    }
}
