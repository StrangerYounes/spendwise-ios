import Foundation

/// Epoch milliseconds, as the Android app stores every date.
public typealias Millis = Int64

public func nowMillis() -> Millis { Millis((Date().timeIntervalSince1970 * 1000).rounded()) }

public extension Date {
    init(millis: Millis) { self.init(timeIntervalSince1970: Double(millis) / 1000) }
    var millis: Millis { Millis((timeIntervalSince1970 * 1000).rounded()) }
}

// MARK: - Tables (Room entities on Android; the same columns)

public struct ShoppingList: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var name: String
    public var createdDate: Millis = nowMillis()
    public var completedDate: Millis? = nil
    public var isCompleted: Bool = false
    public var storeId: Int64? = nil
    public var categoryId: Int64? = nil
    /** Permanent id shared across devices by sync; set by a database trigger when nil. */
    public var uid: String? = nil

    public init(id: Int64 = 0, name: String, createdDate: Millis = nowMillis(), completedDate: Millis? = nil,
                isCompleted: Bool = false, storeId: Int64? = nil, categoryId: Int64? = nil, uid: String? = nil) {
        self.id = id; self.name = name; self.createdDate = createdDate; self.completedDate = completedDate
        self.isCompleted = isCompleted; self.storeId = storeId; self.categoryId = categoryId; self.uid = uid
    }
}

public struct ShoppingItem: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var listId: Int64
    public var itemName: String
    public var estimatedPrice: Double? = nil
    public var actualPrice: Double? = nil
    public var quantity: Double = 1
    public var unit: String? = nil
    public var purchased: Bool = false
    public var orderIndex: Int = 0
    public var notes: String? = nil
    public var storeId: Int64? = nil
    public var isTracked: Bool = false
    public var uid: String? = nil

    public init(id: Int64 = 0, listId: Int64, itemName: String, estimatedPrice: Double? = nil, actualPrice: Double? = nil,
                quantity: Double = 1, unit: String? = nil, purchased: Bool = false, orderIndex: Int = 0,
                notes: String? = nil, storeId: Int64? = nil, isTracked: Bool = false, uid: String? = nil) {
        self.id = id; self.listId = listId; self.itemName = itemName; self.estimatedPrice = estimatedPrice
        self.actualPrice = actualPrice; self.quantity = quantity; self.unit = unit; self.purchased = purchased
        self.orderIndex = orderIndex; self.notes = notes; self.storeId = storeId; self.isTracked = isTracked; self.uid = uid
    }

    /// What one unit cost: paid, else estimated.
    public var unitPrice: Double? { actualPrice ?? estimatedPrice }
}

public struct MasterItem: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var name: String
    /** Per unit, like the other prices. */
    public var averagePrice: Double = 0
    public var lastPrice: Double = 0
    public var lowestPrice: Double = 0
    public var highestPrice: Double = 0
    public var purchaseCount: Int = 0
    public var lastPurchaseDate: Millis = 0
    public var totalQuantity: Double = 0
    public var uid: String? = nil

    public init(id: Int64 = 0, name: String, averagePrice: Double = 0, lastPrice: Double = 0, lowestPrice: Double = 0,
                highestPrice: Double = 0, purchaseCount: Int = 0, lastPurchaseDate: Millis = 0, totalQuantity: Double = 0, uid: String? = nil) {
        self.id = id; self.name = name; self.averagePrice = averagePrice; self.lastPrice = lastPrice
        self.lowestPrice = lowestPrice; self.highestPrice = highestPrice; self.purchaseCount = purchaseCount
        self.lastPurchaseDate = lastPurchaseDate; self.totalQuantity = totalQuantity; self.uid = uid
    }
}

public struct Store: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var name: String
    public var uid: String? = nil
    public init(id: Int64 = 0, name: String, uid: String? = nil) { self.id = id; self.name = name; self.uid = uid }
}

public struct Category: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var name: String
    /** ARGB colour as Android's Color Int (signed 32-bit). */
    public var color: Int32
    public var uid: String? = nil
    public init(id: Int64 = 0, name: String, color: Int32, uid: String? = nil) {
        self.id = id; self.name = name; self.color = color; self.uid = uid
    }
    public var isGroceries: Bool { name == ShoppingRepository.trackedCategory }
}

public struct StoreItemPrice: Hashable, Sendable {
    public var masterItemId: Int64
    public var storeId: Int64
    public var lastPrice: Double
    public var lowestPrice: Double
    public var highestPrice: Double
    public var lastUpdated: Millis
    /** Sync id: always "<item uid>_<store uid>", kept so by a database trigger. */
    public var uid: String? = nil

    public init(masterItemId: Int64, storeId: Int64, lastPrice: Double, lowestPrice: Double? = nil, highestPrice: Double? = nil,
                lastUpdated: Millis = nowMillis(), uid: String? = nil) {
        self.masterItemId = masterItemId; self.storeId = storeId; self.lastPrice = lastPrice
        self.lowestPrice = lowestPrice ?? lastPrice; self.highestPrice = highestPrice ?? lastPrice
        self.lastUpdated = lastUpdated; self.uid = uid
    }
}

public struct AppSettings: Hashable, Sendable {
    public var id: Int = 0
    /** nil follows the system. Per phone, never synced. */
    public var darkTheme: Bool? = nil
    public var currencySymbol: String = "$"
    /** The local currency's units per app unit; 1 means not set. */
    public var lastConversionRate: Double = 1
    public var uid: String? = nil
    public init(darkTheme: Bool? = nil, currencySymbol: String = "$", lastConversionRate: Double = 1, uid: String? = nil) {
        self.darkTheme = darkTheme; self.currencySymbol = currencySymbol; self.lastConversionRate = lastConversionRate; self.uid = uid
    }
    /// The saved rate, or nil when none was set.
    public var savedRate: Double? { lastConversionRate > 1 ? lastConversionRate : nil }
}

public struct AiReport: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var createdAt: Millis
    /** What was asked, as typed or heard. */
    public var request: String
    public var periodStart: Millis
    public var periodEnd: Millis
    public var title: String
    /** A ReportContent as JSON. */
    public var content: String
    public var uid: String? = nil
    public init(id: Int64 = 0, createdAt: Millis, request: String, periodStart: Millis, periodEnd: Millis, title: String, content: String, uid: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.request = request; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.title = title; self.content = content; self.uid = uid
    }
}

public struct Photo: Identifiable, Hashable, Sendable {
    public var id: Int64 = 0
    public var shoppingListId: Int64
    /** The photo's file name in the app's photo folder (Android keeps a content URI). */
    public var uri: String
    public init(id: Int64 = 0, shoppingListId: Int64, uri: String) { self.id = id; self.shoppingListId = shoppingListId; self.uri = uri }
}

// MARK: - Query results (Room's POJOs)

public struct ShoppingListWithDetails: Identifiable, Hashable, Sendable {
    public var shoppingList: ShoppingList
    public var itemCount: Int
    public var purchasedCount: Int
    public var estimatedTotal: Double
    public var actualTotal: Double
    public var storeName: String?
    public var category: Category?
    public var id: Int64 { shoppingList.id }
}

public struct ItemNameSuggestion: Hashable, Sendable {
    public var name: String
    public var timesUsed: Int
    public var lastPrice: Double?
    public var lastUnit: String?
}

public struct ItemSummary: Hashable, Sendable {
    public var name: String
    public var purchaseCount: Int
    public var totalQuantity: Double
    public var totalSpent: Double
    public var lastDate: Millis
    public var lastPrice: Double?
    public var categoryName: String?
    public var categoryColor: Int32?
}

public struct ItemSearchResult: Hashable, Sendable {
    public var item: ShoppingItem
    public var listName: String
    public var listDate: Millis
}

public struct PurchaseHistoryItem: Hashable, Sendable {
    public var shoppingItem: ShoppingItem
    public var listName: String
    public var listDate: Millis
    public var storeName: String?
}

public struct ItemStat: Hashable, Sendable {
    public var itemName: String
    public var purchaseCount: Int
    public var totalSpent: Double
}

public struct ExpensiveItem: Hashable, Sendable {
    public var itemName: String
    /** The most spent on the item in one purchase. */
    public var maxPrice: Double
}

public struct PeriodStat: Hashable, Sendable {
    /** "yyyy-MM", local time. */
    public var period: String
    public var totalSpent: Double
}

public struct CategoryStat: Hashable, Sendable {
    public var categoryId: Int64
    public var categoryName: String
    public var categoryColor: Int32
    public var totalSpent: Double
}

public struct ListSpend: Hashable, Sendable {
    public var listId: Int64
    public var listName: String
    public var date: Millis
    public var categoryId: Int64
    public var storeName: String?
    public var totalSpent: Double
}

public struct StoreStat: Hashable, Sendable {
    public var storeName: String
    public var totalSpent: Double
}

public struct PurchaseLine: Hashable, Sendable {
    public var itemName: String
    public var quantity: Double
    public var unit: String?
    public var unitPrice: Double
    public var date: Millis
    public var listId: Int64
    public var listName: String
    public var storeName: String?
    public var categoryName: String?
    public var total: Double { unitPrice * quantity }

    public init(itemName: String, quantity: Double, unit: String?, unitPrice: Double, date: Millis, listId: Int64,
                listName: String, storeName: String?, categoryName: String?) {
        self.itemName = itemName; self.quantity = quantity; self.unit = unit; self.unitPrice = unitPrice; self.date = date
        self.listId = listId; self.listName = listName; self.storeName = storeName; self.categoryName = categoryName
    }
}

public struct StorePriceDetail: Hashable, Sendable {
    public var storeItemPrice: StoreItemPrice
    public var storeName: String
}

public struct StoreUsage: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var listCount: Int
    public func toStore() -> Store { Store(id: id, name: name) }
}
