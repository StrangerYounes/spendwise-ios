import SwiftUI
import Charts
import SpendWiseCore

/// Insights (FEATURES.md §4.5): KPIs, spending per month, a category donut whose categories
/// expand into their lists, stores, biggest purchases, top items, a date filter, and the way
/// into AI reports.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var range: DateRange?
    @State private var picking = false

    var body: some View {
        let _ = model.revision
        let db = model.database
        let months = (try? db.spentPerMonth(range)) ?? []
        let byCategory = (try? db.spentByCategory(range)) ?? []
        let lists = (try? db.listSpend(range)) ?? []
        let byStore = (try? db.spentByStore(range)) ?? []
        let expensive = (try? db.mostExpensiveItems(range)) ?? []
        let items = (try? db.itemStats(range)) ?? []
        let total = months.reduce(0) { $0 + $1.totalSpent }
        let average = months.isEmpty ? 0 : total / Double(months.count)
        let currency = model.currency

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let locked = !model.cloud.tier.hasAiExtras
                AskAiCard(locked: locked) { if locked { router.upgrade() } else { router.open(.analysis) } }
                if let range {
                    HStack {
                        Text(L("period_range", Dates.format(range.start, "MMMddyyyy"), Dates.format(range.end, "MMMddyyyy")))
                            .font(.labelL).foregroundStyle(Palette.onSecondaryContainer)
                        Spacer()
                        Button(L("reset")) { self.range = nil }.font(.labelL).foregroundStyle(Palette.primary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .card(Palette.secondaryContainer, radius: 16)
                }
                HStack(spacing: 12) {
                    KpiCard(label: L(range == nil ? "total_spent" : "spent_in_period"), value: formatMoney(currency, total, decimals: 0),
                            icon: "chart.line.uptrend.xyaxis", color: Palette.primary)
                    KpiCard(label: L("monthly_average"), value: formatMoney(currency, average, decimals: 0), icon: "calendar", color: Palette.tertiary)
                }
                if !months.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("spending_by_month"))
                        MonthBars(data: Array(months.prefix(12).reversed()), currency: currency)
                            .padding(16)
                            .card(Palette.surfaceVariant.opacity(0.3), radius: 12)
                    }
                }
                if !byCategory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("by_category"))
                        CategoryBreakdown(data: byCategory, lists: lists, currency: currency) { router.open(.list($0)) }
                    }
                }
                if !byStore.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("by_store"))
                        ForEach(byStore.prefix(5), id: \.storeName) { s in StatRow(title: s.storeName, value: formatMoney(currency, s.totalSpent)) }
                    }
                }
                if !expensive.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("biggest_purchases"))
                        ForEach(expensive, id: \.itemName) { e in
                            StatRow(title: e.itemName, value: formatMoney(currency, e.maxPrice)) { router.open(.item(e.itemName)) }
                        }
                    }
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("top_items"))
                        ForEach(items.prefix(10), id: \.itemName) { s in
                            StatRow(title: s.itemName, subtitle: L("bought_times", s.purchaseCount), value: formatMoney(currency, s.totalSpent)) {
                                router.open(.item(s.itemName))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .readableWidth()
        }
        .screen(L("insights"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { router.open(.analysis) } label: { Image(systemName: "sparkles") }.accessibilityLabel(L("ai_reports"))
                Button { picking = true } label: { Image(systemName: range == nil ? "calendar" : "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel(L("filter_by_date"))
            }
        }
        .sheet(isPresented: $picking) { DateRangeSheet(range: $range) }
        .onAppear {
            #if DEBUG
            DemoMode.openInsightsExtras(range: $range)
            #endif
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.titleM).foregroundStyle(Palette.primary) }
}

private struct AskAiCard: View {
    let locked: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 20)).opacity(locked ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ask_ai_spending")).font(.titleM)
                    Text(L(locked ? "ask_ai_locked" : "ask_ai_sub")).font(.bodyS)
                }
                .opacity(locked ? 0.5 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if locked { PremiumBadge() } else { Image(systemName: "chevron.forward") }
            }
            .foregroundStyle(Palette.onSecondaryContainer)
            .padding(16)
            .card(Palette.secondaryContainer)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("askAi")
    }
}

private struct KpiCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headlineS.weight(.bold)).foregroundStyle(Palette.onSurface).lineLimit(1).minimumScaleFactor(0.5)
                Text(label).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card(color.opacity(0.12))
    }
}

struct StatRow: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    var open: (() -> Void)? = nil
    var body: some View {
        let content = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyL).foregroundStyle(Palette.onSurface).lineLimit(1)
                if let subtitle { Text(subtitle).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant) }
            }
            Spacer()
            Text(value).font(.titleS).foregroundStyle(Palette.onSurface)
            if open != nil { Image(systemName: "chevron.forward").font(.system(size: 13)).foregroundStyle(Palette.onSurfaceVariant) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(Palette.containerLow, radius: 16)
        if let open {
            Button(action: open) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Bars per month, the newest selected; tapping a bar shows its month.
private struct MonthBars: View {
    let data: [PeriodStat]
    let currency: String
    @State private var selected: String?

    static func date(_ period: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.date(from: period)
    }

    var body: some View {
        let current = selected ?? data.last?.period
        let stat = data.first { $0.period == current }
        VStack(alignment: .leading, spacing: 0) {
            if let stat {
                Text(Self.date(stat.period).map { Dates.format($0.millis, "MMMMyyyy") } ?? stat.period).font(.labelL).foregroundStyle(Palette.onSurfaceVariant)
                Text(formatMoney(currency, stat.totalSpent)).font(.headlineS).foregroundStyle(Palette.primary)
            }
            Spacer().frame(height: 16)
            Chart(data, id: \.period) { s in
                BarMark(x: .value("Month", s.period), y: .value("Spent", s.totalSpent), width: .ratio(0.7))
                    .foregroundStyle(s.period == current ? Palette.primary : Palette.primary.opacity(0.35))
                    .cornerRadius(6)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let p = v.as(String.self), let d = Self.date(p) {
                            // Arabic month names can't be cut to three letters; they're short enough whole
                            let name = Dates.format(d.millis, "MMM")
                            Text(Lang.isArabic ? name : String(name.prefix(3)))
                                .font(.system(size: Lang.isArabic && data.count > 6 ? 9 : 11))
                                .foregroundStyle(p == current ? Palette.onSurface : Palette.onSurfaceVariant)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        if let p: String = proxy.value(atX: location.x - g[plot].origin.x) { selected = p }
                    }
                }
            }
            .frame(height: 180)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// The category donut and its legend; a category opens to the lists behind it, newest first.
private struct CategoryBreakdown: View {
    let data: [CategoryStat]
    let lists: [ListSpend]
    let currency: String
    let openList: (Int64) -> Void
    @State private var selectedId: Int64?
    @State private var angle: Double?

    var body: some View {
        let total = data.reduce(0) { $0 + $1.totalSpent }
        let selected = data.first { $0.categoryId == selectedId }
        VStack(spacing: 16) {
            ZStack {
                Chart(data, id: \.categoryId) { s in
                    SectorMark(angle: .value("Spent", s.totalSpent), innerRadius: .ratio(s.categoryId == selectedId ? 0.58 : 0.64),
                               outerRadius: .ratio(s.categoryId == selectedId ? 1 : 0.92), angularInset: data.count > 1 ? 1 : 0)
                        .foregroundStyle(Color(argb: s.categoryColor).opacity(selectedId != nil && selectedId != s.categoryId ? 0.35 : 1))
                }
                .chartAngleSelection(value: $angle)
                .frame(width: 200, height: 200)
                VStack(spacing: 0) {
                    Text(selected.map { categoryLabel($0.categoryName) } ?? L("total")).font(.labelL).foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
                    Text(formatMoney(currency, selected?.totalSpent ?? total, decimals: 0)).font(.titleL).foregroundStyle(Palette.onSurface).lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let selected { Text(L("percent_of_spending", String(percent(selected.totalSpent, total)))).font(.labelS).foregroundStyle(Palette.onSurfaceVariant) }
                }
                .frame(width: 120)
            }
            .onChange(of: angle) { _, value in
                guard let value else { return }
                // The slice under the tapped angle
                var running = 0.0
                for s in data {
                    running += s.totalSpent
                    if value <= running { toggle(s.categoryId); break }
                }
            }
            VStack(spacing: 0) {
                ForEach(data, id: \.categoryId) { s in
                    let isSelected = s.categoryId == selectedId
                    Button { toggle(s.categoryId) } label: {
                        HStack(spacing: 10) {
                            ColorDot(color: Color(argb: s.categoryColor), size: 12)
                            Text(categoryLabel(s.categoryName)).font(.bodyM).foregroundStyle(Palette.onSurface).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(percent(s.totalSpent, total))%").font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).padding(.horizontal, 12)
                            Text(formatMoney(currency, s.totalSpent)).font(.titleS).foregroundStyle(Palette.onSurface)
                            Image(systemName: isSelected ? "chevron.up" : "chevron.down").font(.system(size: 12)).foregroundStyle(Palette.onSurfaceVariant)
                                .accessibilityLabel(L(isSelected ? "hide_lists" : "show_lists"))
                        }
                        .padding(8)
                        .background(isSelected ? Color(argb: s.categoryColor).opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    if isSelected {
                        CategoryLists(lists: lists.filter { $0.categoryId == s.categoryId }, color: Color(argb: s.categoryColor), currency: currency, open: openList)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(16)
        .card(Palette.containerLow)
        .onAppear {
            #if DEBUG
            if DemoMode.screen == "insights_category" { selectedId = data.first?.categoryId }
            #endif
        }
    }

    private func percent(_ v: Double, _ total: Double) -> Int64 { total > 0 ? javaRound(v / total * 100) : 0 }

    private func toggle(_ id: Int64) {
        withAnimation(.easeInOut(duration: 0.2)) { selectedId = selectedId == id ? nil : id }
    }
}

private struct CategoryLists: View {
    let lists: [ListSpend]
    let color: Color
    let currency: String
    let open: (Int64) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(P("lists_count", lists.count)).font(.labelM).foregroundStyle(Palette.onSurfaceVariant).padding(.leading, 12).padding(.vertical, 4)
            ForEach(lists, id: \.listId) { l in
                Button { open(l.listId) } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.6)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.listName).font(.bodyM).foregroundStyle(Palette.onSurface).lineLimit(1)
                            Text(Dates.format(l.date, "EEEMMMdyyyy") + (l.storeName.map { " · \($0)" } ?? "")).font(.bodyS)
                                .foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatMoney(currency, l.totalSpent)).font(.bodyM).foregroundStyle(Palette.onSurface)
                        Image(systemName: "chevron.forward").font(.system(size: 12)).foregroundStyle(Palette.onSurfaceVariant)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14).padding(.top, 2).padding(.bottom, 8)
    }
}

/// From the start of the first day to the end of the last; a single day works.
private struct DateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var range: DateRange?
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(L("select_date_range"), selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker("", selection: $end, in: Calendar.current.startOfDay(for: start)...Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_399),
                           displayedComponents: .date)
            }
            .navigationTitle(L("filter_by_date"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("clear")) { range = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("apply")) { range = DateRange.days(from: start, to: max(start, end)); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if let range { start = Date(millis: range.start); end = Date(millis: range.end) }
        }
    }
}
