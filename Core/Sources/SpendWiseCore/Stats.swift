import Foundation

/// A date filter for Insights: from the start of the first day to the end of the last, local time.
public struct DateRange: Hashable, Sendable {
    public var start: Millis
    public var end: Millis
    public init(start: Millis, end: Millis) { self.start = start; self.end = end }
    public static let all = DateRange(start: Int64.min, end: Int64.max)

    /// The days picked (local calendar days) as a filter; a single day filters that day.
    public static func days(from first: Date, to last: Date?, calendar: Calendar = .current) -> DateRange {
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last ?? first)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)!
        return DateRange(start: start.millis, end: end.millis - 1)
    }
}

/// Android's StatsDao: what Insights and AI reports are built from. Purchased items only, dated by
/// their list's completion (or creation) date; Groceries is the category of lists with none.
public extension AppDatabase {
    /// Every purchased item between two dates with its list, store and category, oldest first.
    func purchaseLines(start: Millis, end: Millis) throws -> [PurchaseLine] {
        try db.query("""
            SELECT si.itemName AS itemName, si.quantity AS quantity, si.unit AS unit,
                COALESCE(si.actualPrice, si.estimatedPrice, 0) AS unitPrice,
                COALESCE(sl.completedDate, sl.createdDate) AS date,
                sl.id AS listId, sl.name AS listName, s.name AS storeName, c.name AS categoryName
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            LEFT JOIN stores s ON COALESCE(si.storeId, sl.storeId) = s.id
            LEFT JOIN categories c ON COALESCE(sl.categoryId, (SELECT id FROM categories WHERE name = 'Groceries' LIMIT 1)) = c.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            ORDER BY date ASC, sl.id ASC, si.orderIndex ASC
            """, named: ["startDate": start, "endDate": end]).map { r in
                PurchaseLine(itemName: r.string("itemName"), quantity: r.double("quantity"), unit: r.stringOrNil("unit"),
                             unitPrice: r.double("unitPrice"), date: r.int("date"), listId: r.int("listId"), listName: r.string("listName"),
                             storeName: r.stringOrNil("storeName"), categoryName: r.stringOrNil("categoryName"))
            }
    }

    func firstListDate() throws -> Millis? {
        try db.scalar("SELECT MIN(COALESCE(completedDate, createdDate)) FROM shopping_lists")?.int64
    }

    private func bounds(_ range: DateRange?) -> [String: Any?] {
        let r = range ?? .all
        return ["startDate": r.start, "endDate": r.end]
    }

    func itemStats(_ range: DateRange? = nil) throws -> [ItemStat] {
        try db.query("""
            SELECT itemName, COUNT(*) as purchaseCount, SUM(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) as totalSpent
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY itemName
            ORDER BY totalSpent DESC
            """, named: bounds(range)).map { ItemStat(itemName: $0.string("itemName"), purchaseCount: Int($0.int("purchaseCount")), totalSpent: $0.double("totalSpent")) }
    }

    func mostExpensiveItems(_ range: DateRange? = nil) throws -> [ExpensiveItem] {
        try db.query("""
            SELECT itemName, MAX(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) as maxPrice
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY itemName
            ORDER BY maxPrice DESC
            LIMIT 5
            """, named: bounds(range)).map { ExpensiveItem(itemName: $0.string("itemName"), maxPrice: $0.double("maxPrice")) }
    }

    func spentPerMonth(_ range: DateRange? = nil) throws -> [PeriodStat] {
        try db.query("""
            SELECT
                strftime('%Y-%m', COALESCE(sl.completedDate, sl.createdDate) / 1000, 'unixepoch', 'localtime') as period,
                SUM(COALESCE(actualPrice, estimatedPrice, 0) * quantity) as totalSpent
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY period
            ORDER BY period DESC
            """, named: bounds(range)).map { PeriodStat(period: $0.string("period"), totalSpent: $0.double("totalSpent")) }
    }

    func spentByCategory(_ range: DateRange? = nil) throws -> [CategoryStat] {
        try db.query("""
            SELECT
                c.id as categoryId,
                c.name as categoryName,
                c.color as categoryColor,
                SUM(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) as totalSpent
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            JOIN categories c ON COALESCE(sl.categoryId, (SELECT id FROM categories WHERE name = 'Groceries' LIMIT 1)) = c.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY c.id
            ORDER BY totalSpent DESC
            """, named: bounds(range)).map {
                CategoryStat(categoryId: $0.int("categoryId"), categoryName: $0.string("categoryName"),
                             categoryColor: Int32(truncatingIfNeeded: $0.int("categoryColor")), totalSpent: $0.double("totalSpent"))
            }
    }

    /// What each list cost, with its category, for the lists under a category on Insights.
    func listSpend(_ range: DateRange? = nil) throws -> [ListSpend] {
        try db.query("""
            SELECT
                sl.id as listId,
                sl.name as listName,
                COALESCE(sl.completedDate, sl.createdDate) as date,
                c.id as categoryId,
                s.name as storeName,
                SUM(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) as totalSpent
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            JOIN categories c ON COALESCE(sl.categoryId, (SELECT id FROM categories WHERE name = 'Groceries' LIMIT 1)) = c.id
            LEFT JOIN stores s ON sl.storeId = s.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY sl.id
            ORDER BY date DESC
            """, named: bounds(range)).map {
                ListSpend(listId: $0.int("listId"), listName: $0.string("listName"), date: $0.int("date"), categoryId: $0.int("categoryId"),
                          storeName: $0.stringOrNil("storeName"), totalSpent: $0.double("totalSpent"))
            }
    }

    func spentByStore(_ range: DateRange? = nil) throws -> [StoreStat] {
        try db.query("""
            SELECT
                s.name as storeName,
                SUM(COALESCE(si.actualPrice, si.estimatedPrice, 0) * si.quantity) as totalSpent
            FROM shopping_items si
            JOIN shopping_lists sl ON si.listId = sl.id
            JOIN stores s ON COALESCE(si.storeId, sl.storeId) = s.id
            WHERE si.purchased = 1 AND COALESCE(sl.completedDate, sl.createdDate) BETWEEN :startDate AND :endDate
            GROUP BY s.id
            ORDER BY totalSpent DESC
            """, named: bounds(range)).map { StoreStat(storeName: $0.string("storeName"), totalSpent: $0.double("totalSpent")) }
    }

    /// Spent in the current calendar month, for Home's card.
    func spentThisMonth(now: Date = Date()) throws -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        let current = f.string(from: now)
        return try spentPerMonth().first { $0.period == current }?.totalSpent ?? 0
    }
}
