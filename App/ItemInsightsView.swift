import SwiftUI
import Charts
import SpendWiseCore

/// An item's insights (FEATURES.md §4.4): tiles, a price chart by real date, the purchases, and
/// Rename everywhere.
struct ItemInsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State var name: String
    @State private var renaming = false

    var body: some View {
        let data = ItemInsights.build(name, model.history(name))
        Group {
            if data.purchases.isEmpty {
                VStack {
                    Spacer()
                    EmptyState(icon: "chart.xyaxis.line", title: L("no_purchases_yet"), message: L("insights_empty", name))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Tiles(data: data, currency: model.currency)
                        TrendCard(data: data, currency: model.currency)
                        Text(L("purchases_count", data.purchases.count)).font(.titleS).foregroundStyle(Palette.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.leading, 4)
                        ForEach(data.purchases.reversed()) { p in PurchaseRow(purchase: p, currency: model.currency) }
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
                    .readableWidth()
                }
            }
        }
        .screen(name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { renaming = true } label: { Image(systemName: "pencil") }.accessibilityLabel(L("rename_everywhere"))
            }
        }
        .sheet(isPresented: $renaming) {
            RenameEverywhereSheet(current: name, existing: Set(model.itemSummaries.map(\.name))) { newName in
                renameEverywhere(to: newName)
            }
        }
    }

    private func renameEverywhere(to newName: String) {
        let old = name
        let done = model.perform { try model.repo.renameItemEverywhere(old, newName) }
        if done != nil { name = newName }
    }
}

private struct Tiles: View {
    let data: ItemInsights
    let currency: String
    var body: some View {
        let unitSuffix = data.commonUnit.map { "/\($0)" } ?? ""
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                InsightTile(label: L("total_spent"), value: formatMoney(currency, data.totalSpent))
                InsightTile(label: L("stat_bought"), value: "\(data.purchases.count)×")
                InsightTile(label: L("how_often"), value: data.averageDaysBetween.map { days in
                    if days < 1.5 { return L("daily") }
                    if days < 13.5 { let n = Int(javaRound(days)); return P("every_days", n) }
                    let w = Int(javaRound(days / 7))
                    return P("every_weeks", w)
                } ?? "—")
            }
            HStack(spacing: 8) {
                if data.quantitiesAllOne {
                    InsightTile(label: L("avg_purchase"), value: formatMoney(currency, data.averagePerPurchase))
                } else {
                    InsightTile(label: L("avg_price", unitSuffix), value: formatUnitPrice(currency, (data.averageUnitPrice * 1000).rounded(.toNearestOrEven) / 1000))
                }
                InsightTile(label: L("last_price_s", unitSuffix), value: data.lastUnitPrice.map { formatUnitPrice(currency, $0) } ?? "—")
                let change = data.unitPriceChange
                InsightTile(label: L("since_first"),
                            value: change.map { ($0 >= 0 ? "+" : "−") + "\(javaRound(abs($0) * 100))%" } ?? "—",
                            color: change.map { abs($0) < 0.005 ? Palette.onSurface : $0 > 0 ? Palette.error : Palette.primary } ?? Palette.onSurface)
            }
        }
    }
}

private struct InsightTile: View {
    let label: String
    let value: String
    var color: Color = Palette.onSurface
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.labelM).foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
            Text(value).font(.titleM).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card(Palette.containerLow, radius: 16)
    }
}

private enum TrendMetric { case unitPrice, spent }

private struct TrendCard: View {
    let data: ItemInsights
    let currency: String
    @State private var metric: TrendMetric = .unitPrice
    @State private var selected: Int?

    var body: some View {
        let showToggle = !data.quantitiesAllOne
        let effective: TrendMetric = showToggle ? metric : .spent
        let shown = effective == .unitPrice ? data.unitPricePurchases : data.purchases
        let values = shown.map { effective == .unitPrice ? $0.unitPrice : $0.spent }
        let index = min(selected ?? shown.count - 1, shown.count - 1)
        let fmt: (Double) -> String = { effective == .unitPrice ? formatUnitPrice(currency, $0) : formatMoney(currency, $0) }

        VStack(alignment: .leading, spacing: 0) {
            if showToggle {
                Picker("", selection: $metric) {
                    Text(data.commonUnit.map { L("price_per_named", $0) } ?? L("price_per_unit")).tag(TrendMetric.unitPrice)
                    Text(L("per_purchase")).tag(TrendMetric.spent)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
                .onChange(of: metric) { _, _ in selected = nil }
            }
            if index >= 0, index < shown.count {
                let p = shown[index]
                Text([Dates.format(p.date, "MMMdyyyy"), p.storeName].compactMap { $0 }.joined(separator: " · ")).font(.labelL).foregroundStyle(Palette.onSurfaceVariant)
                Text(fmt(values[index])).font(.headlineS).foregroundStyle(Palette.primary)
                if effective == .spent && !data.quantitiesAllOne {
                    Text("\(formatQuantity(p.quantity))\(p.unit.map { " \($0)" } ?? "") × \(formatUnitPrice(currency, p.unitPrice))")
                        .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            Spacer().frame(height: 12)
            if shown.count < 2 {
                Text(L("buy_again_hint")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
            } else {
                Chart {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                        AreaMark(x: .value("Date", Date(millis: p.date)), y: .value("Price", values[i]))
                            .foregroundStyle(LinearGradient(colors: [Palette.primary.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", Date(millis: p.date)), y: .value("Price", values[i]))
                            .foregroundStyle(Palette.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("Date", Date(millis: p.date)), y: .value("Price", values[i]))
                            .foregroundStyle(Palette.primary)
                            .symbolSize(i == index ? 120 : 30)
                    }
                    if index >= 0, index < shown.count {
                        RuleMark(x: .value("Date", Date(millis: shown[index].date))).foregroundStyle(Palette.primary.opacity(0.4))
                    }
                }
                .chartYScale(domain: (values.min() ?? 0)...(max(values.max() ?? 1, (values.min() ?? 0) + 0.0001)))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [values.min() ?? 0, values.max() ?? 0]) { v in
                        AxisGridLine().foregroundStyle(Palette.outlineVariant)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(fmt(d)).font(.labelS) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - g[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let target = date.millis
                                selected = shown.indices.min { abs(shown[$0].date - target) < abs(shown[$1].date - target) }
                            }
                    }
                }
                .frame(height: 160)
                .environment(\.layoutDirection, .leftToRight)
                HStack {
                    Text(Dates.format(shown.first!.date, "MMMd"))
                    Spacer()
                    Text(Dates.format(shown.last!.date, "MMMd"))
                }
                .font(.labelS).foregroundStyle(Palette.onSurfaceVariant).padding(.top, 6)
                .environment(\.layoutDirection, .leftToRight)
            }
            let skipped = data.purchases.count - data.unitPricePurchases.count
            if effective == .unitPrice && skipped > 0 {
                Text(P("skipped_unit", skipped, skipped, data.commonUnit ?? "")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).padding(.top, 8)
            }
            if data.quantitiesAllOne && data.purchases.count >= 2 {
                Text(L("unit_tip")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).padding(.top, 8)
            }
        }
        .padding(16)
        .card(Palette.containerLow)
    }
}

private struct PurchaseRow: View {
    let purchase: ItemPurchase
    let currency: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Dates.format(purchase.date, "EEEMMMdyyyy")).font(.bodyL).foregroundStyle(Palette.onSurface)
                Text([purchase.storeName, purchase.listName].compactMap { $0 }.joined(separator: " · ")).font(.bodyS)
                    .foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMoney(currency, purchase.spent)).font(.titleS).foregroundStyle(Palette.onSurface)
                if purchase.quantity != 1 || purchase.unit != nil {
                    Text("\(formatQuantity(purchase.quantity))\(purchase.unit.map { " \($0)" } ?? "") × \(formatUnitPrice(currency, purchase.unitPrice))")
                        .font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(Palette.containerLow, radius: 16)
    }
}

/// Rename everywhere: onto an existing name it combines the two.
struct RenameEverywhereSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let existing: Set<String>
    let rename: (String) -> Void
    @State private var value = ""

    var body: some View {
        let newName = value.trimmingCharacters(in: .whitespaces)
        let merges = existing.contains(newName) && newName != current
        let canSave = !newName.isEmpty && newName != current
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("rename_everywhere_body", current)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                LabeledField(title: L("name"), text: $value, autofocus: true) { if canSave { rename(newName); dismiss() } }
                if merges { Text(L("exists_combined", newName)).font(.bodyS).foregroundStyle(Palette.tertiary) }
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("rename_everywhere"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(merges ? "combine" : "rename")) { rename(newName); dismiss() }.disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { if value.isEmpty { value = current } }
    }
}
