import Foundation

/// One purchase of an item, oldest first in ItemInsights.purchases.
public struct ItemPurchase: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var date: Millis
    public var unitPrice: Double
    public var quantity: Double
    public var unit: String?
    public var storeName: String?
    public var listName: String
    public var spent: Double { unitPrice * quantity }
}

/// What an item's insights screen shows (Android viewmodel/ItemInsightsViewModel.kt's build).
public struct ItemInsights: Sendable {
    public var name: String
    public var purchases: [ItemPurchase]
    /// Purchases in commonUnit, the only ones whose unit prices compare ("$40 of gas" isn't $40 a litre).
    public var unitPricePurchases: [ItemPurchase]
    public var totalSpent: Double
    public var totalQuantity: Double
    /** Total spent / total quantity, so litres bought at different prices weigh correctly. */
    public var averageUnitPrice: Double
    public var averagePerPurchase: Double
    public var lastUnitPrice: Double?
    /** Change of the latest unit price against the first, as a fraction (0.12 = +12%). */
    public var unitPriceChange: Double?
    public var averageDaysBetween: Double?
    /** The unit most purchases were recorded in, e.g. "l" for gas. */
    public var commonUnit: String?

    /// Every purchase is quantity 1, so unit price and amount spent are the same line.
    public var quantitiesAllOne: Bool { purchases.allSatisfy { $0.quantity == 1 } }

    public static func build(_ name: String, _ history: [PurchaseHistoryItem]) -> ItemInsights {
        let recorded = history.map { h -> ItemPurchase in
            let unit = h.shoppingItem.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ItemPurchase(id: h.shoppingItem.id, date: h.listDate, unitPrice: h.shoppingItem.actualPrice ?? h.shoppingItem.estimatedPrice ?? 0,
                                quantity: h.shoppingItem.quantity, unit: (unit?.isEmpty ?? true) ? nil : QuickAddParser.normalizeUnit(unit!),
                                storeName: h.storeName, listName: h.listName)
        }.enumerated().sorted { a, b in a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset }.map(\.element)

        let commonUnit = QuickAddParser.mostCommon(recorded.compactMap(\.unit))
        // "Gas 25.4 × 1.57" saved without its unit is still litres: an amount other than 1 means it was measured
        let purchases = commonUnit == nil ? recorded : recorded.map { p in
            var q = p
            if p.unit == nil && p.quantity != 1 { q.unit = commonUnit }
            return q
        }
        let comparable = commonUnit == nil ? purchases : purchases.filter { $0.unit == commonUnit }

        let totalSpent = purchases.reduce(0) { $0 + $1.spent }
        let totalQuantity = purchases.reduce(0) { $0 + $1.quantity }
        let comparableSpent = comparable.reduce(0) { $0 + $1.spent }
        let comparableQuantity = comparable.reduce(0) { $0 + $1.quantity }
        let priced = comparable.filter { $0.unitPrice > 0 }
        let first = priced.first?.unitPrice
        let last = priced.last?.unitPrice

        // Whole days since the epoch, as TimeUnit.MILLISECONDS.toDays
        var days: [Int64] = []
        for p in purchases { let d = p.date / 86_400_000; if !days.contains(d) { days.append(d) } }
        let between = days.count >= 2 ? Double(days.last! - days.first!) / Double(days.count - 1) : nil

        return ItemInsights(
            name: name, purchases: purchases, unitPricePurchases: comparable, totalSpent: totalSpent, totalQuantity: totalQuantity,
            averageUnitPrice: comparableQuantity > 0 ? comparableSpent / comparableQuantity : 0,
            averagePerPurchase: purchases.isEmpty ? 0 : totalSpent / Double(purchases.count),
            lastUnitPrice: last,
            unitPriceChange: (first != nil && last != nil && first! > 0 && priced.count >= 2) ? (last! - first!) / first! : nil,
            averageDaysBetween: between, commonUnit: commonUnit)
    }
}

/// A name to suggest while adding items (Android ListDetailViewModel's ItemSuggestion): library
/// items carry per-store prices; names only in purchase history carry their last price.
public struct ItemSuggestion: Hashable, Sendable {
    public var name: String
    public var timesBought: Int
    public var lastPrice: Double?
    public var lastUnit: String? = nil
    public var bestPrice: Double? = nil
    public var bestStoreName: String? = nil
    public var listStorePrice: Double? = nil

    /// Price to pre-fill: this list's store first, then the cheapest store, then the last price paid.
    public var suggestedPrice: Double? { listStorePrice ?? bestPrice ?? lastPrice.flatMap { $0 > 0 ? $0 : nil } }
}

public extension ShoppingRepository {
    /// Suggestions for what's typed in Add items, up to 8, names starting with it first.
    func suggestions(_ rawQuery: String, listStoreId: Int64?) throws -> [ItemSuggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return [] }
        let history = try searchItemNames(query)
        var unitsByName: [String: String?] = [:]
        for h in history { unitsByName[h.name.lowercased()] = h.lastUnit }
        let fromLibrary = try searchMasterItems(query).map { master -> ItemSuggestion in
            let cheapest = try cheapestPrice(item: master.id)
            let cheapestStore = try cheapest.flatMap { try store(id: $0.storeId) }
            let atListStore = try listStoreId.flatMap { try price(item: master.id, store: $0) }
            return ItemSuggestion(name: master.name, timesBought: master.purchaseCount, lastPrice: master.lastPrice,
                                  lastUnit: unitsByName[master.name.lowercased()] ?? nil, bestPrice: cheapest?.lastPrice,
                                  bestStoreName: cheapestStore?.name, listStorePrice: atListStore?.lastPrice)
        }
        let known = Set(fromLibrary.map { $0.name.lowercased() })
        let fromHistory = history.filter { !known.contains($0.name.lowercased()) }
            .map { ItemSuggestion(name: $0.name, timesBought: $0.timesUsed, lastPrice: $0.lastPrice, lastUnit: $0.lastUnit) }
        let q = query.lowercased()
        return (fromLibrary + fromHistory).enumerated().sorted { a, b in
            let x = !a.element.name.lowercased().hasPrefix(q), y = !b.element.name.lowercased().hasPrefix(q)
            if x != y { return !x }
            if a.element.timesBought != b.element.timesBought { return a.element.timesBought > b.element.timesBought }
            return a.offset < b.offset
        }.prefix(8).map(\.element)
    }
}
