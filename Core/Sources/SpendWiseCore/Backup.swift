import Foundation

/// The backup file (Android data/backup/BackupModels.kt): the same JSON, so a backup made on one
/// phone restores on the other. Version 1 (the original app) lacks totalQuantity, isTracked and
/// lastConversionRate; those are optional and rebuilt on restore. Fields are only ever added.
public struct BackupData: Sendable {
    public static let currentVersion = 3

    public var version: Int = currentVersion
    public var timestamp: Millis = nowMillis()
    public var masterItems: [MasterItemBackup]? = nil
    public var shoppingLists: [ShoppingListBackup]? = nil
    public var shoppingItems: [ShoppingItemBackup]? = nil
    public var categories: [CategoryBackup]? = nil
    public var stores: [StoreBackup]? = nil
    public var storeItemPrices: [StoreItemPriceBackup]? = nil
    public var settings: AppSettingsBackup? = nil
    /** Added in version 3. */
    public var reports: [AiReportBackup]? = nil
}

public struct MasterItemBackup: Sendable, Equatable {
    public var name: String
    public var averagePrice: Double
    public var lastPrice: Double
    public var lowestPrice: Double
    public var highestPrice: Double
    public var purchaseCount: Int
    public var lastPurchaseDate: Millis
    public var totalQuantity: Double?
}

public struct ShoppingListBackup: Sendable, Equatable {
    /** Used to map shopping items. */
    public var id: Int64
    public var name: String
    public var createdDate: Millis
    public var completedDate: Millis?
    public var isCompleted: Bool
    public var storeName: String?
    public var categoryName: String?
}

public struct ShoppingItemBackup: Sendable, Equatable {
    public var listId: Int64
    public var itemName: String
    public var estimatedPrice: Double?
    public var actualPrice: Double?
    public var quantity: Double
    public var unit: String?
    public var purchased: Bool
    public var orderIndex: Int
    public var notes: String?
    public var storeName: String?
    public var isTracked: Bool?
}

public struct CategoryBackup: Sendable, Equatable { public var name: String; public var color: Int32 }
public struct StoreBackup: Sendable, Equatable { public var name: String }

public struct StoreItemPriceBackup: Sendable, Equatable {
    public var itemName: String
    public var storeName: String
    public var lastPrice: Double
    public var lowestPrice: Double
    public var highestPrice: Double
    public var lastUpdated: Millis
}

public struct AppSettingsBackup: Sendable, Equatable {
    public var darkTheme: Bool?
    public var currencySymbol: String
    public var lastConversionRate: Double?
}

/// A saved AI report; [content] is its JSON exactly as stored.
public struct AiReportBackup: Sendable, Equatable {
    public var createdAt: Millis
    public var request: String
    public var periodStart: Millis
    public var periodEnd: Millis
    public var title: String
    public var content: String
}

public struct RestoreSummary: Equatable, Sendable {
    public var listsAdded: Int
    public var listsSkipped: Int
    public var itemsAdded: Int
    public var libraryItemsAdded: Int
    public var reportsAdded: Int = 0

    public var message: String {
        var out = str("restored", plural("lists_count", listsAdded), plural("items_count", itemsAdded), plural("library_items_n", libraryItemsAdded))
        if reportsAdded > 0 { out += str("restored_reports", reportsAdded) }
        if listsSkipped > 0 { out += plural("restored_skipped", listsSkipped) }
        return out
    }
}

public struct NotABackup: Error, LocalizedError {
    public var errorDescription: String? { str("not_a_backup") }
}

// MARK: - JSON

extension BackupData {
    /// Pretty JSON with every field (nulls too), in the declared order, as the Android app writes it.
    public var jsonText: String {
        func list<T>(_ items: [T]?, _ f: (T) -> JSON) -> JSON { items.map { .array($0.map(f)) } ?? .null }
        return JSON.object([
            ("version", .integer(Int64(version))),
            ("timestamp", .integer(timestamp)),
            ("masterItems", list(masterItems) { m in .object([
                ("name", .string(m.name)), ("averagePrice", .number(m.averagePrice)), ("lastPrice", .number(m.lastPrice)),
                ("lowestPrice", .number(m.lowestPrice)), ("highestPrice", .number(m.highestPrice)),
                ("purchaseCount", .integer(Int64(m.purchaseCount))), ("lastPurchaseDate", .integer(m.lastPurchaseDate)),
                ("totalQuantity", .num(m.totalQuantity)),
            ]) }),
            ("shoppingLists", list(shoppingLists) { l in .object([
                ("id", .integer(l.id)), ("name", .string(l.name)), ("createdDate", .integer(l.createdDate)),
                ("completedDate", .int(l.completedDate)), ("isCompleted", .bool(l.isCompleted)),
                ("storeName", .str(l.storeName)), ("categoryName", .str(l.categoryName)),
            ]) }),
            ("shoppingItems", list(shoppingItems) { i in .object([
                ("listId", .integer(i.listId)), ("itemName", .string(i.itemName)), ("estimatedPrice", .num(i.estimatedPrice)),
                ("actualPrice", .num(i.actualPrice)), ("quantity", .number(i.quantity)), ("unit", .str(i.unit)),
                ("purchased", .bool(i.purchased)), ("orderIndex", .integer(Int64(i.orderIndex))), ("notes", .str(i.notes)),
                ("storeName", .str(i.storeName)), ("isTracked", i.isTracked.map(JSON.bool) ?? .null),
            ]) }),
            ("categories", list(categories) { .object([("name", .string($0.name)), ("color", .integer(Int64($0.color)))]) }),
            ("stores", list(stores) { .object([("name", .string($0.name))]) }),
            ("storeItemPrices", list(storeItemPrices) { p in .object([
                ("itemName", .string(p.itemName)), ("storeName", .string(p.storeName)), ("lastPrice", .number(p.lastPrice)),
                ("lowestPrice", .number(p.lowestPrice)), ("highestPrice", .number(p.highestPrice)), ("lastUpdated", .integer(p.lastUpdated)),
            ]) }),
            ("settings", settings.map { s in .object([
                ("darkTheme", s.darkTheme.map(JSON.bool) ?? .null), ("currencySymbol", .string(s.currencySymbol)),
                ("lastConversionRate", .num(s.lastConversionRate)),
            ]) } ?? .null),
            ("reports", list(reports) { r in .object([
                ("createdAt", .integer(r.createdAt)), ("request", .string(r.request)), ("periodStart", .integer(r.periodStart)),
                ("periodEnd", .integer(r.periodEnd)), ("title", .string(r.title)), ("content", .string(r.content)),
            ]) }),
        ]).prettyText
    }

    struct Missing: Error {}

    /// Reads a backup, ignoring fields it doesn't know (kotlinx `ignoreUnknownKeys`).
    public static func parse(_ text: String) throws -> BackupData {
        let root = try JSON.parse(text)
        guard root.object != nil else { throw NotABackup() }
        func req<T>(_ v: T?) throws -> T { guard let v else { throw Missing() }; return v }
        func array<T>(_ key: String, _ f: (JSON) throws -> T) throws -> [T]? {
            guard let v = root[key], !v.isNull else { return nil }
            guard let a = v.array else { throw Missing() }
            return try a.map(f)
        }
        func optString(_ o: JSON, _ k: String) -> String? { o[k].flatMap { $0.isNull ? nil : $0.content } }
        var b = BackupData()
        b.version = Int(root["version"]?.int64 ?? 1)
        b.timestamp = root["timestamp"]?.int64 ?? 0
        b.masterItems = try array("masterItems") { o in
            MasterItemBackup(name: try req(o["name"]?.content), averagePrice: try req(o["averagePrice"]?.double),
                             lastPrice: try req(o["lastPrice"]?.double), lowestPrice: try req(o["lowestPrice"]?.double),
                             highestPrice: try req(o["highestPrice"]?.double), purchaseCount: Int(try req(o["purchaseCount"]?.int64)),
                             lastPurchaseDate: try req(o["lastPurchaseDate"]?.int64), totalQuantity: o["totalQuantity"]?.double)
        }
        b.shoppingLists = try array("shoppingLists") { o in
            ShoppingListBackup(id: try req(o["id"]?.int64), name: try req(o["name"]?.content), createdDate: try req(o["createdDate"]?.int64),
                               completedDate: o["completedDate"]?.int64, isCompleted: try req(o["isCompleted"]?.bool),
                               storeName: optString(o, "storeName"), categoryName: optString(o, "categoryName"))
        }
        b.shoppingItems = try array("shoppingItems") { o in
            ShoppingItemBackup(listId: try req(o["listId"]?.int64), itemName: try req(o["itemName"]?.content),
                               estimatedPrice: o["estimatedPrice"]?.double, actualPrice: o["actualPrice"]?.double,
                               quantity: try req(o["quantity"]?.double), unit: optString(o, "unit"), purchased: try req(o["purchased"]?.bool),
                               orderIndex: Int(try req(o["orderIndex"]?.int64)), notes: optString(o, "notes"), storeName: optString(o, "storeName"),
                               isTracked: o["isTracked"]?.bool)
        }
        b.categories = try array("categories") { o in
            CategoryBackup(name: try req(o["name"]?.content), color: Int32(truncatingIfNeeded: try req(o["color"]?.int64)))
        }
        b.stores = try array("stores") { o in StoreBackup(name: try req(o["name"]?.content)) }
        b.storeItemPrices = try array("storeItemPrices") { o in
            StoreItemPriceBackup(itemName: try req(o["itemName"]?.content), storeName: try req(o["storeName"]?.content),
                                 lastPrice: try req(o["lastPrice"]?.double), lowestPrice: try req(o["lowestPrice"]?.double),
                                 highestPrice: try req(o["highestPrice"]?.double), lastUpdated: try req(o["lastUpdated"]?.int64))
        }
        if let s = root["settings"], !s.isNull {
            b.settings = AppSettingsBackup(darkTheme: s["darkTheme"]?.bool, currencySymbol: try req(s["currencySymbol"]?.content),
                                           lastConversionRate: s["lastConversionRate"]?.double)
        }
        b.reports = try array("reports") { o in
            AiReportBackup(createdAt: try req(o["createdAt"]?.int64), request: try req(o["request"]?.content),
                           periodStart: try req(o["periodStart"]?.int64), periodEnd: try req(o["periodEnd"]?.int64),
                           title: try req(o["title"]?.content), content: try req(o["content"]?.content))
        }
        return b
    }
}

// MARK: - Export and restore

/// Android data/repository/BackupRepository.kt.
public final class BackupRepository {
    let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func exportData(itemsOnly: Bool) throws -> String {
        let masterItems = try database.allMasterItems()
        let masters = masterItems.map {
            MasterItemBackup(name: $0.name, averagePrice: $0.averagePrice, lastPrice: $0.lastPrice, lowestPrice: $0.lowestPrice,
                             highestPrice: $0.highestPrice, purchaseCount: $0.purchaseCount, lastPurchaseDate: $0.lastPurchaseDate,
                             totalQuantity: $0.totalQuantity)
        }
        if itemsOnly { return BackupData(masterItems: masters).jsonText }

        let stores = try database.allStores()
        let categories = try database.allCategories()
        let storeMap = Dictionary(uniqueKeysWithValues: stores.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let masterMap = Dictionary(uniqueKeysWithValues: masterItems.map { ($0.id, $0) })
        var b = BackupData(masterItems: masters)
        b.shoppingLists = try database.allShoppingLists().map { l in
            ShoppingListBackup(id: l.id, name: l.name, createdDate: l.createdDate, completedDate: l.completedDate, isCompleted: l.isCompleted,
                               storeName: l.storeId.flatMap { storeMap[$0]?.name }, categoryName: l.categoryId.flatMap { categoryMap[$0]?.name })
        }
        b.shoppingItems = try database.allItems().map { i in
            ShoppingItemBackup(listId: i.listId, itemName: i.itemName, estimatedPrice: i.estimatedPrice, actualPrice: i.actualPrice,
                               quantity: i.quantity, unit: i.unit, purchased: i.purchased, orderIndex: i.orderIndex, notes: i.notes,
                               storeName: i.storeId.flatMap { storeMap[$0]?.name }, isTracked: i.isTracked)
        }
        b.categories = categories.map { CategoryBackup(name: $0.name, color: $0.color) }
        b.stores = stores.map { StoreBackup(name: $0.name) }
        b.storeItemPrices = try database.allStorePrices().compactMap { p in
            guard let item = masterMap[p.masterItemId]?.name, let store = storeMap[p.storeId]?.name else { return nil }
            return StoreItemPriceBackup(itemName: item, storeName: store, lastPrice: p.lastPrice, lowestPrice: p.lowestPrice,
                                        highestPrice: p.highestPrice, lastUpdated: p.lastUpdated)
        }
        b.settings = try database.settings().map {
            AppSettingsBackup(darkTheme: $0.darkTheme, currencySymbol: $0.currencySymbol, lastConversionRate: $0.lastConversionRate)
        }
        b.reports = try database.allReports().map {
            AiReportBackup(createdAt: $0.createdAt, request: $0.request, periodStart: $0.periodStart, periodEnd: $0.periodEnd,
                           title: $0.title, content: $0.content)
        }
        return b.jsonText
    }

    /// Merges a backup into the database. Existing categories, stores and library items (by name)
    /// are kept, and lists that already exist (same name and creation time) are skipped, so
    /// importing the same file twice adds nothing.
    public func restoreData(_ text: String) throws -> RestoreSummary {
        let parsed: BackupData
        do { parsed = try BackupData.parse(text) } catch { throw NotABackup() }
        let backup = Self.normalizeNames(parsed)
        guard backup.masterItems != nil || backup.shoppingLists != nil || backup.categories != nil else { throw NotABackup() }

        var summary = RestoreSummary(listsAdded: 0, listsSkipped: 0, itemsAdded: 0, libraryItemsAdded: 0)
        try database.db.transaction {
            // 1. Categories (the backup's colour wins, so a fresh install takes the old Groceries colour)
            for c in backup.categories ?? [] {
                if var existing = try database.category(named: c.name) {
                    if existing.color != c.color { existing.color = c.color; try database.updateCategory(existing) }
                } else {
                    try database.insertCategory(Category(name: c.name, color: c.color))
                }
            }
            // 2. Stores
            for s in backup.stores ?? [] where try database.store(named: s.name) == nil {
                try database.insertStore(Store(name: s.name))
            }
            // 3. The library; version 1 lacks totalQuantity, rebuilt from purchased Groceries items
            let rebuilt = Self.rebuildTotalQuantities(backup)
            for m in backup.masterItems ?? [] where try database.masterItem(named: m.name) == nil {
                try database.insertMasterItem(MasterItem(
                    name: m.name, averagePrice: m.averagePrice, lastPrice: m.lastPrice, lowestPrice: m.lowestPrice,
                    highestPrice: m.highestPrice, purchaseCount: m.purchaseCount, lastPurchaseDate: m.lastPurchaseDate,
                    totalQuantity: m.totalQuantity ?? rebuilt[m.name] ?? 0))
                summary.libraryItemsAdded += 1
            }
            // 4. Store prices
            for p in backup.storeItemPrices ?? [] {
                if let item = try database.masterItem(named: p.itemName), let store = try database.store(named: p.storeName),
                   try database.price(item: item.id, store: store.id) == nil {
                    try database.insertStorePrice(StoreItemPrice(masterItemId: item.id, storeId: store.id, lastPrice: p.lastPrice,
                                                                 lowestPrice: p.lowestPrice, highestPrice: p.highestPrice, lastUpdated: p.lastUpdated))
                }
            }
            // 5. Lists and items
            var listIds: [Int64: Int64] = [:]
            for l in backup.shoppingLists ?? [] {
                if try database.findList(name: l.name, createdDate: l.createdDate) != nil {
                    summary.listsSkipped += 1
                    continue
                }
                let store = try l.storeName.flatMap { try database.store(named: $0) }
                let category = try l.categoryName.flatMap { try database.category(named: $0) }
                listIds[l.id] = try database.insertShoppingList(ShoppingList(
                    name: l.name, createdDate: l.createdDate, completedDate: l.completedDate, isCompleted: l.isCompleted,
                    storeId: store?.id, categoryId: category?.id))
                summary.listsAdded += 1
            }
            for i in backup.shoppingItems ?? [] {
                guard let listId = listIds[i.listId] else { continue }
                let store = try i.storeName.flatMap { try database.store(named: $0) }
                try database.insertItem(ShoppingItem(
                    listId: listId, itemName: i.itemName, estimatedPrice: i.estimatedPrice, actualPrice: i.actualPrice,
                    quantity: i.quantity, unit: i.unit, purchased: i.purchased, orderIndex: i.orderIndex, notes: i.notes,
                    storeId: store?.id,
                    // Purchased items were already counted in the library stats being restored
                    isTracked: i.isTracked ?? i.purchased))
                summary.itemsAdded += 1
            }
            // 6. Settings
            if let s = backup.settings {
                var current = try database.settings() ?? AppSettings()
                current.darkTheme = s.darkTheme
                current.currencySymbol = s.currencySymbol
                current.lastConversionRate = s.lastConversionRate ?? current.lastConversionRate
                try database.updateSettings(current)
            }
            // 7. AI reports, matched by creation time
            for r in backup.reports ?? [] where try database.report(createdAt: r.createdAt) == nil {
                try database.insertReport(AiReport(createdAt: r.createdAt, request: r.request, periodStart: r.periodStart,
                                                   periodEnd: r.periodEnd, title: r.title, content: r.content))
                summary.reportsAdded += 1
            }
        }
        return summary
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Kotlin's distinctBy: the first of each key, in order.
    private static func distinct<T>(_ items: [T], _ key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    /// Kotlin's groupBy: groups in the order their keys first appear.
    private static func grouped<T>(_ items: [T], _ key: (T) -> String) -> [[T]] {
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for item in items {
            let k = key(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        return order.map { groups[$0]! }
    }

    /// The original app kept names exactly as typed ("Milk "); trim them and combine duplicates.
    static func normalizeNames(_ b: BackupData) -> BackupData {
        var out = b
        out.masterItems = b.masterItems.map { items in
            grouped(items.map { var m = $0; m.name = trim(m.name); return m }, \.name).map { $0.dropFirst().reduce($0[0], combine) }
        }
        out.shoppingLists = b.shoppingLists?.map {
            var l = $0; l.name = trim(l.name); l.storeName = l.storeName.map(trim); l.categoryName = l.categoryName.map(trim); return l
        }
        out.shoppingItems = b.shoppingItems?.map { var i = $0; i.itemName = trim(i.itemName); i.storeName = i.storeName.map(trim); return i }
        out.categories = b.categories.map { distinct($0.map { var c = $0; c.name = trim(c.name); return c }, \.name) }
        out.stores = b.stores.map { distinct($0.map { StoreBackup(name: trim($0.name)) }, \.name) }
        out.storeItemPrices = b.storeItemPrices.map { prices in
            grouped(prices.map { var p = $0; p.itemName = trim(p.itemName); p.storeName = trim(p.storeName); return p }, { $0.itemName + "\u{0}" + $0.storeName })
                .map { same in
                    // maxBy: the first with the latest update
                    var latest = same[0]
                    for p in same where p.lastUpdated > latest.lastUpdated { latest = p }
                    latest.lowestPrice = same.map(\.lowestPrice).min()!
                    latest.highestPrice = same.map(\.highestPrice).max()!
                    return latest
                }
        }
        return out
    }

    static func combine(_ a: MasterItemBackup, _ b: MasterItemBackup) -> MasterItemBackup {
        let count = a.purchaseCount + b.purchaseCount
        let latest = b.lastPurchaseDate > a.lastPurchaseDate ? b : a
        func lowest(_ x: MasterItemBackup) -> Double? { x.purchaseCount > 0 ? x.lowestPrice : nil }
        var c = a
        c.averagePrice = count > 0 ? (a.averagePrice * Double(a.purchaseCount) + b.averagePrice * Double(b.purchaseCount)) / Double(count) : a.averagePrice
        c.lastPrice = latest.lastPrice
        c.lowestPrice = [lowest(a), lowest(b)].compactMap { $0 }.min() ?? 0
        c.highestPrice = max(a.highestPrice, b.highestPrice)
        c.purchaseCount = count
        c.lastPurchaseDate = latest.lastPurchaseDate
        c.totalQuantity = (a.totalQuantity == nil && b.totalQuantity == nil) ? nil : (a.totalQuantity ?? 0) + (b.totalQuantity ?? 0)
        return c
    }

    static func rebuildTotalQuantities(_ b: BackupData) -> [String: Double] {
        guard let lists = b.shoppingLists else { return [:] }
        let tracked = Set(lists.filter { $0.categoryName == nil || $0.categoryName == ShoppingRepository.trackedCategory }.map(\.id))
        var out: [String: Double] = [:]
        for i in b.shoppingItems ?? [] where i.purchased && tracked.contains(i.listId) { out[i.itemName, default: 0] += i.quantity }
        return out
    }
}
