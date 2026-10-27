import SwiftUI
import SpendWiseCore

private enum LibrarySort: CaseIterable { case name, mostBought, recent
    var label: String {
        switch self {
        case .name: return L("sort_az")
        case .mostBought: return L("sort_most_bought")
        case .recent: return L("sort_recent")
        }
    }
}

/// Items (FEATURES.md §4.3): everything ever bought, and the library with per-store prices (every
/// category feeds it since 27 Oct 2026); both filter by category.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var groceryPrices = false
    @State private var query = ""
    @State private var sort: LibrarySort = .name
    @State private var categoryFilter: String?
    @State private var detail: MasterItem?
    @State private var adding = false

    var body: some View {
        let summaries = model.itemSummaries
        let categoryNames = Array(Set(summaries.compactMap(\.categoryName))).sorted()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = sorted(summaries.filter { (q.isEmpty || $0.name.lowercased().contains(q)) && (categoryFilter == nil || $0.categoryName == categoryFilter) })
        // A library item's category: the latest list it was bought in (Groceries when never bought)
        let categoryOf = Dictionary(summaries.map { ($0.name.lowercased(), $0.categoryName ?? ShoppingRepository.trackedCategory) }, uniquingKeysWith: { a, _ in a })
        let masters = sortedMasters((q.isEmpty ? model.masterItems : ((try? model.repo.searchMasterItems(q)) ?? []))
            .filter { categoryFilter == nil || (categoryOf[$0.name.lowercased()] ?? ShoppingRepository.trackedCategory) == categoryFilter })

        ScrollView {
            LazyVStack(spacing: 8) {
                Picker("", selection: $groceryPrices) {
                    Text(L("all_items")).tag(false)
                    Text(L("prices_tab")).tag(true)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.onSurfaceVariant)
                    TextField(L("search_items"), text: $query).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.onSurfaceVariant) }
                            .accessibilityLabel(L("clear_search"))
                    }
                }
                .padding(.horizontal, 18).frame(height: 52)
                .background(Palette.containerHigh, in: Capsule())
                chips(LibrarySort.allCases.map { option -> (String, Bool, () -> Void) in (option.label, option == sort, { sort = option }) })
                if categoryNames.count > 1 {
                    let all: (String, Bool, () -> Void) = (L("all_categories"), categoryFilter == nil, { categoryFilter = nil })
                    chips([all] + categoryNames.map { name -> (String, Bool, () -> Void) in
                        (categoryLabel(name), categoryFilter == name, { categoryFilter = categoryFilter == name ? nil : name })
                    })
                }
                if !groceryPrices {
                    if visible.isEmpty {
                        EmptyState(icon: "shippingbox", title: L(summaries.isEmpty ? "nothing_bought" : "no_matches"),
                                   message: L(summaries.isEmpty ? "nothing_bought_sub" : "no_item_matches"))
                    }
                    ForEach(visible, id: \.name) { s in
                        Button { router.open(.item(s.name)) } label: { SummaryRow(summary: s, currency: model.currency) }.buttonStyle(.plainRow)
                    }
                } else {
                    if masters.isEmpty {
                        if model.masterItems.isEmpty {
                            EmptyState(icon: "shippingbox", title: L("library_empty"), message: L("library_empty_sub"))
                        } else {
                            EmptyState(icon: "shippingbox", title: L("no_matches"),
                                       message: query.isEmpty ? L("no_item_matches") : L("no_library_match", query))
                        }
                    }
                    ForEach(masters) { m in
                        Button { detail = m } label: { MasterRow(item: m, currency: model.currency) }.buttonStyle(.plainRow)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 96)
            .readableWidth()
        }
        .screen(L("items"))
        .overlay(alignment: .bottomTrailing) {
            if groceryPrices {
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.title2).foregroundStyle(Palette.onPrimaryContainer)
                        .frame(width: 56, height: 56).background(Palette.primaryContainer, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
                .padding(16)
                .clearOfSnackbar()
                .accessibilityLabel(L("add_item"))
            }
        }
        .sheet(item: $detail) { item in LibraryItemSheet(itemId: item.id) { router.open(.item($0)) } }
        .sheet(isPresented: $adding) { LibraryAddSheet() }
        .onAppear {
            #if DEBUG
            DemoMode.openLibraryExtras(groceryPrices: $groceryPrices, detail: $detail)
            #endif
        }
    }

    private func chips(_ options: [(String, Bool, () -> Void)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in FilterChip(label: o.0, selected: o.1, action: o.2) }
            }
        }
    }

    private func sorted(_ list: [ItemSummary]) -> [ItemSummary] {
        switch sort {
        case .name: return list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .mostBought: return stable(list) { Double($0.purchaseCount) }
        case .recent: return stable(list) { Double($0.lastDate) }
        }
    }

    private func sortedMasters(_ list: [MasterItem]) -> [MasterItem] {
        switch sort {
        case .name: return list
        case .mostBought: return stable(list) { Double($0.purchaseCount) }
        case .recent: return stable(list) { Double($0.lastPurchaseDate) }
        }
    }

    private func stable<T>(_ list: [T], _ key: (T) -> Double) -> [T] {
        list.enumerated().sorted { a, b in key(a.element) != key(b.element) ? key(a.element) > key(b.element) : a.offset < b.offset }.map(\.element)
    }
}

struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                Text(label).font(.labelL)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(selected ? Palette.onSecondaryContainer : Palette.onSurfaceVariant)
            .background(selected ? Palette.secondaryContainer : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? .clear : Palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plainRow)
    }
}

private struct SummaryRow: View {
    let summary: ItemSummary
    let currency: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name).font(.bodyL).foregroundStyle(Palette.onSurface).lineLimit(1)
                HStack(spacing: 6) {
                    if let c = summary.categoryColor { ColorDot(color: Color(argb: c), size: 8) }
                    Text(L("times_last", summary.purchaseCount, Dates.format(summary.lastDate, "MMMd"))).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMoney(currency, summary.totalSpent)).font(.titleS).foregroundStyle(Palette.onSurface)
                Text(L("total_small")).font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(Palette.containerLow, radius: 16)
    }
}

private struct MasterRow: View {
    let item: MasterItem
    let currency: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.bodyL).foregroundStyle(Palette.onSurface).lineLimit(1)
                Text(item.purchaseCount == 0 ? L("not_bought_yet") : item.purchaseCount == 1 ? L("bought_once")
                     : L("bought_avg", item.purchaseCount, formatMoney(currency, item.averagePrice)))
                    .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMoney(currency, item.lastPrice)).font(.titleS).foregroundStyle(Palette.onSurface)
                Text(L("last_small")).font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(Palette.containerLow, radius: 16)
    }
}

/// A library item: last, average and times bought, prices by store, purchase history, and
/// rename, delete or merge.
struct LibraryItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var itemId: Int64
    let showTrend: (String) -> Void

    @State private var showAll = false
    @State private var editing = false
    @State private var merging = false
    @State private var confirm: Confirm?

    var body: some View {
        let item = model.masterItems.first { $0.id == itemId }
        NavigationStack {
            ScrollView {
                if let item {
                    let prices = (try? model.repo.storePricesWithNames(item: item.id)) ?? []
                    let history = model.history(item.name)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            StatTile(label: L("stat_last"), value: formatMoney(model.currency, item.lastPrice))
                            StatTile(label: L("stat_average"), value: formatMoney(model.currency, item.averagePrice))
                            StatTile(label: L("stat_bought"), value: "\(item.purchaseCount)×")
                        }
                        if item.purchaseCount > 1 && item.highestPrice > item.lowestPrice {
                            Text(L("price_range", formatMoney(model.currency, item.lowestPrice), formatMoney(model.currency, item.highestPrice)))
                                .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                        }
                        if !prices.isEmpty {
                            Text(L("by_store")).font(.titleS).foregroundStyle(Palette.primary)
                            let cheapest = prices.map(\.storeItemPrice.lastPrice).min() ?? 0
                            ForEach(prices, id: \.storeName) { p in
                                HStack {
                                    Text(p.storeName).foregroundStyle(Palette.onSurface)
                                    Spacer()
                                    if p.storeItemPrice.lastPrice == cheapest && prices.count > 1 {
                                        Text(L("cheapest")).font(.labelS).foregroundStyle(Palette.primary)
                                    }
                                    Text(formatMoney(model.currency, p.storeItemPrice.lastPrice)).font(.titleS).foregroundStyle(Palette.onSurface)
                                }
                            }
                        }
                        Text(L("purchase_history")).font(.titleS).foregroundStyle(Palette.primary)
                        if history.isEmpty {
                            Text(L("no_purchases")).font(.bodyM).italic().foregroundStyle(Palette.onSurfaceVariant)
                        } else {
                            ForEach(showAll ? history : Array(history.prefix(5)), id: \.shoppingItem.id) { h in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Dates.format(h.listDate, "MMMdyyyy")).font(.bodyM).foregroundStyle(Palette.onSurface)
                                        Text([h.storeName, h.listName].compactMap { $0 }.joined(separator: " · ")).font(.bodyS)
                                            .foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(formatMoney(model.currency, h.shoppingItem.unitPrice ?? 0)).font(.titleS).foregroundStyle(Palette.onSurface)
                                        if h.shoppingItem.quantity != 1 {
                                            Text("× \(formatQuantity(h.shoppingItem.quantity))").font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
                                        }
                                    }
                                }
                            }
                            if !showAll && history.count > 5 {
                                Button(L("show_all", history.count)) { showAll = true }.foregroundStyle(Palette.primary)
                            }
                        }
                        HStack(spacing: 16) {
                            Button(L("delete"), role: .destructive) {
                                confirm = Confirm(title: L("delete_named_q", item.name), message: L("delete_library_body"), label: L("delete")) {
                                    model.perform { try model.repo.deleteMasterItem(item) }
                                    dismiss()
                                }
                            }
                            .foregroundStyle(Palette.error)
                            Button { merging = true } label: { Label(L("merge"), systemImage: "arrow.triangle.merge") }
                                .foregroundStyle(Palette.primary)
                        }
                        .font(.labelL)
                    }
                    .padding(20)
                    .navigationTitle(item.name)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } }
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { dismiss(); showTrend(item.name) } label: { Image(systemName: "chart.xyaxis.line") }
                                .accessibilityLabel(L("price_trend"))
                            Button { editing = true } label: { Image(systemName: "pencil") }
                                .accessibilityLabel(L("rename_or_price"))
                        }
                    }
                    .sheet(isPresented: $editing) { LibraryEditSheet(item: item) }
                    .sheet(isPresented: $merging) {
                        MergeSheet(current: item) { target in
                            model.perform { try model.repo.mergeMasterItems(item, into: target) }
                            itemId = target.id
                        }
                    }
                }
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .confirm($confirm)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
            Text(value).font(.titleM).foregroundStyle(Palette.onSurface).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card(Palette.containerHighest, radius: 16)
    }
}

/// "Merge “Milk 1L” into…": pick the item to keep.
private struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let current: MasterItem
    let merge: (MasterItem) -> Void
    @State private var query = ""
    @State private var target: MasterItem?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let options = model.masterItems.filter { $0.id != current.id && (q.isEmpty || $0.name.lowercased().contains(q)) }
        NavigationStack {
            List {
                Text(L("merge_body")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).listRowBackground(Color.clear)
                ForEach(options) { m in
                    Button { target = m } label: {
                        HStack(spacing: 14) {
                            Image(systemName: target?.id == m.id ? "largecircle.fill.circle" : "circle").foregroundStyle(target?.id == m.id ? Palette.primary : Palette.onSurfaceVariant)
                            Text(m.name).foregroundStyle(Palette.onSurface)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("search"))
            .navigationTitle(L("merge_into", current.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("merge")) { if let target { merge(target); dismiss() } }.disabled(target == nil)
                }
            }
        }
    }
}

/// Rename (merging onto an existing name) or set the last price.
private struct LibraryEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: MasterItem
    @State private var name = ""
    @State private var price = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: L("item"), text: $name)
                Text(L("rename_merges")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                AmountField(title: L("last_price_label"), text: $price, currency: model.currency)
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("edit_library_item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        model.perform { try model.repo.renameMasterItem(item, name, lastPrice: parseAmount(price) ?? item.lastPrice) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if !loaded { loaded = true; name = item.name; price = formatPriceInput(item.lastPrice) }
        }
    }
}

/// Add to library: a name and a price.
private struct LibraryAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var price = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: L("item"), text: $name, autofocus: true)
                AmountField(title: L("price"), text: $price, currency: model.currency)
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("add_to_library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("add")) {
                        let p = parseAmount(price) ?? 0
                        model.perform {
                            try model.repo.insertMasterItem(MasterItem(name: name.trimmingCharacters(in: .whitespaces), averagePrice: p, lastPrice: p,
                                                                       lowestPrice: p > 0 ? p : 0, highestPrice: p > 0 ? p : 0, purchaseCount: p > 0 ? 1 : 0))
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
