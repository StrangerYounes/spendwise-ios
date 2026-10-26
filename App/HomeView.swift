import SwiftUI
import SpendWiseCore

/// How quick add opens: ready to type, recording straight away, or with the camera.
enum QuickAddStart: Identifiable, Equatable {
    case nothing, record, camera
    var id: Self { self }
}

/// Home (FEATURES.md §4.1): this month's spending, quick add, search, and the lists.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var query = ""
    @State private var showCompleted = false
    @State private var newList = false
    @State private var editing: ShoppingList?
    @State private var confirm: Confirm?
    @State private var categoriesOpen = false
    @State private var storesOpen = false
    @State private var quickAdd: QuickAddStart?
    @FocusState private var searchFocused: Bool

    /// What the screen shows, worked out once per render (kept apart so the type checker copes).
    private struct Shown {
        var all: [ShoppingListWithDetails]
        var active: [ShoppingListWithDetails]
        var completed: [ShoppingListWithDetails]
        var searching: Bool
        var lists: [ShoppingListWithDetails]
        var foundItems: [ItemSearchResult]
        var guide: OnboardingStep?
    }

    private var shown: Shown {
        let all = model.lists
        let active = all.filter { !$0.shoppingList.isCompleted }
        let completed = all.filter { $0.shoppingList.isCompleted }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let matches: Set<Int64>? = searching ? Set(((try? model.repo.searchShoppingLists(query)) ?? []).map(\.id)) : nil
        let lists = (showCompleted ? completed : active).filter { matches?.contains($0.id) ?? true }
        let foundItems: [ItemSearchResult] = searching ? ((try? model.repo.searchItems(query)) ?? []) : []
        let step = model.onboarding
        let guide: OnboardingStep? = (!searching && (step == .FirstList || step == .FirstItem)) ? step : nil
        return Shown(all: all, active: active, completed: completed, searching: searching, lists: lists,
                     foundItems: foundItems, guide: guide)
    }

    var body: some View {
        let d = shown
        let screen = scroll(d)
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.surface.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) { newListButton(d.guide) }
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.surface, for: .navigationBar)
        return withSheets(screen)
            .confirm($confirm)
            .onChange(of: d.all.count) { _, _ in guideFollowsData(model.lists) }
            .onAppear {
                guideFollowsData(model.lists)
                #if DEBUG
                DemoMode.openHomeExtras(newList: $newList, quickAdd: $quickAdd, completed: $showCompleted, query: $query,
                                        categories: $categoriesOpen, stores: $storesOpen, editing: $editing)
                #endif
            }
    }

    private func scroll(_ d: Shown) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                header(d)
                if d.searching && !d.foundItems.isEmpty {
                    SectionTitle(text: L("items"))
                    ForEach(d.foundItems, id: \.item.id) { result in
                        ItemSearchRow(result: result, currency: model.currency) { router.open(.list(result.item.listId)) }
                    }
                    // Android shows a fixed English "Lists" here (no string resource)
                    SectionTitle(text: listsTitle)
                }
                listCards(d)
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 96)
            .readableWidth()
        }
    }

    @ViewBuilder
    private func header(_ d: Shown) -> some View {
        MonthCard(spent: (try? model.database.spentThisMonth()) ?? 0, activeCount: d.active.count, currency: model.currency) {
            router.open(.insights)
        }
        if let guide = d.guide {
            let first = guide == .FirstList
            GuideCard(icon: first ? "text.badge.plus" : "cart.badge.plus",
                      title: L(first ? "guide_list_title" : "guide_open_title"),
                      message: L(first ? "guide_list_body" : "guide_open_body"),
                      actionLabel: L("skip_guide")) { model.setOnboarding(.Done) }
        }
        QuickAddPrompt(open: { quickAdd = .nothing }, record: { quickAdd = .record })
        searchField
        Picker("", selection: $showCompleted) {
            Text(L("active_count", d.active.count)).tag(false)
            Text(L("completed_count", d.completed.count)).tag(true)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func listCards(_ d: Shown) -> some View {
        if d.lists.isEmpty {
            if d.searching {
                EmptyState(icon: "magnifyingglass", title: L("no_matches"),
                           message: L(showCompleted ? "nothing_matches_completed" : "nothing_matches_active", query))
            } else if showCompleted {
                EmptyState(icon: "checkmark.circle", title: L("no_completed"), message: L("no_completed_sub"))
            } else if d.guide == nil {
                EmptyState(icon: "cart", title: L("no_active"), message: L("no_active_sub"))
            }
        } else {
            ForEach(d.lists) { list in listCard(list) }
        }
    }

    private func listCard(_ list: ShoppingListWithDetails) -> some View {
        ListCard(item: list, currency: model.currency, color: model.color(of: list.category),
                 open: { router.open(.list(list.id)) },
                 edit: { editing = list.shoppingList },
                 delete: { askDelete(list.shoppingList) })
    }

    private func askDelete(_ list: ShoppingList) {
        confirm = Confirm(title: L("delete_named_q", list.name), message: L("delete_list_body"), label: L("delete")) {
            model.perform { try model.repo.deleteShoppingList(list) }
        }
    }

    private func newListButton(_ guide: OnboardingStep?) -> some View {
        Button { newList = true } label: {
            Label(L("new_list"), systemImage: "plus")
                .font(.labelL)
                .padding(.horizontal, 20).frame(height: 56)
                .foregroundStyle(Palette.onPrimaryContainer)
                .background(Palette.primaryContainer, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .pulse(guide == .FirstList)
        .padding(16)
        .accessibilityIdentifier("newList")
    }

    private func withSheets<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $newList) {
                ListEditorSheet(title: L("new_list"), confirmLabel: L("create"), name: "", categoryId: nil) { name, categoryId in
                    createList(name, categoryId)
                }
            }
            .sheet(item: $editing) { list in
                ListEditorSheet(title: L("edit_list"), confirmLabel: L("save"), name: list.name, categoryId: list.categoryId) { name, categoryId in
                    saveList(list, name, categoryId)
                }
            }
            .sheet(isPresented: $categoriesOpen) { CategoriesSheet() }
            .sheet(isPresented: $storesOpen) { StoresSheet() }
            .fullScreenCover(item: $quickAdd) { start in
                QuickAddSheet(start: start) { count, completedAll in
                    quickAddSaved(count, completedAll)
                } dismiss: { quickAdd = nil }
            }
    }

    private func createList(_ name: String, _ categoryId: Int64?) {
        model.advance(from: .FirstList, to: .FirstItem)
        let list = ShoppingList(name: name.trimmingCharacters(in: .whitespaces), categoryId: categoryId)
        let id = model.perform { try model.repo.insertShoppingList(list) }
        if let id { router.open(.list(id)) }
    }

    private func saveList(_ list: ShoppingList, _ name: String, _ categoryId: Int64?) {
        var l = list
        l.name = name.trimmingCharacters(in: .whitespaces)
        l.categoryId = categoryId
        model.perform { try model.repo.updateShoppingList(l) }
    }

    private func quickAddSaved(_ count: Int, _ completedAll: Bool) {
        quickAdd = nil
        showCompleted = completedAll
        model.show(count != 1 ? P("saved_lists", count) : L(completedAll ? "saved_to_completed" : "saved_to_active"))
    }

    private var listsTitle: String { Lang.isArabic ? "القوائم" : "Lists" }

    /// Lists that came another way (quick add, sync, a restore) end the guide.
    private func guideFollowsData(_ all: [ShoppingListWithDetails]) {
        if !all.isEmpty { model.advance(from: .FirstList, to: .Done) }
        if all.contains(where: { $0.itemCount > 0 }) { model.advance(from: .FirstItem, to: .Done) }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.onSurfaceVariant)
            TextField(L("search_lists"), text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.onSurfaceVariant)
                }
                .accessibilityLabel(L("clear_search"))
            }
        }
        .padding(.horizontal, 18).frame(height: 52)
        .background(Palette.containerHigh, in: Capsule())
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 4) {
                Text(L("app_name")).font(.title3.weight(.bold)).foregroundStyle(Palette.onSurface)
                SyncIndicator { router.open(.settings) }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Receipts are Premium: on Free the button has a sparkle and opens the Upgrade page
            let receipts = model.cloud.tier.hasAiExtras
            Button { if receipts { quickAdd = .camera } else { router.upgrade() } } label: {
                Image(systemName: "receipt")
                    .overlay(alignment: .topTrailing) {
                        if !receipts { Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.gold).offset(x: 6, y: -5) }
                    }
            }
            .accessibilityLabel(L(receipts ? "scan_receipt" : "scan_receipt_premium"))
            Button { router.open(.insights) } label: { Image(systemName: "chart.bar.xaxis") }
                .accessibilityLabel(L("insights"))
            Menu {
                Button { categoriesOpen = true } label: { Label(L("categories"), systemImage: "square.grid.2x2") }
                Button { storesOpen = true } label: { Label(L("stores"), systemImage: "storefront") }
                Button { router.open(.library) } label: { Label(L("items"), systemImage: "shippingbox") }
                Button { router.open(.settings) } label: { Label(L("settings"), systemImage: "gearshape") }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(L("more"))
        }
    }
}

/// "Spent in October": this month's purchases and the number of active lists; opens Insights.
struct MonthCard: View {
    let spent: Double
    let activeCount: Int
    let currency: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("spent_in", Dates.monthName())).font(.labelL).opacity(0.8)
                    Text(formatMoney(currency, spent)).font(.system(size: 32, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(activeCount == 0 ? L("no_active") : P("active_lists", activeCount)).font(.bodyM).opacity(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chart.bar.xaxis").font(.system(size: 34)).opacity(0.6)
            }
            .foregroundStyle(Palette.onPrimary)
            .padding(20)
            .background(Palette.primary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("monthCard")
    }
}

/// The "What did you spend on?" bar: opens quick add; its mic starts a voice note straight away.
struct QuickAddPrompt: View {
    let open: () -> Void
    let record: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Palette.onSecondaryContainer)
            Text(L("what_did_you_spend")).font(.bodyL).foregroundStyle(Palette.onSecondaryContainer).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: record) {
                Image(systemName: "mic.fill").font(.system(size: 18)).foregroundStyle(Palette.onPrimary)
                    .frame(width: 42, height: 42).background(Palette.primary, in: Circle())
            }
            .accessibilityLabel(L("quick_add_voice"))
        }
        .padding(.leading, 20).padding(.trailing, 6).padding(.vertical, 6)
        .background(Palette.secondaryContainer, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        .accessibilityIdentifier("quickAddPrompt")
    }
}

struct ItemSearchRow: View {
    let result: ItemSearchResult
    let currency: String
    let open: () -> Void
    var body: some View {
        let item = result.item
        // The line total, so 25 l of gas shows what it cost rather than the price of a litre
        let price = item.unitPrice.map { $0 * item.quantity }
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.itemName).font(.bodyL).foregroundStyle(Palette.onSurface)
                    Text(L("in_list_on", result.listName, Dates.format(result.listDate, "MMMd"))).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let price { Text(formatMoney(currency, price)).font(.bodyM).foregroundStyle(Palette.onSurface) }
                if item.purchased {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.primary).font(.system(size: 16))
                        .accessibilityLabel(L("purchased"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .card(Palette.containerLow, radius: 16)
        }
        .buttonStyle(.plain)
    }
}

/// One list on Home: name, category, date and store, progress and total.
struct ListCard: View {
    let item: ShoppingListWithDetails
    let currency: String
    let color: Color
    let open: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        let list = item.shoppingList
        let date = list.isCompleted ? (list.completedDate ?? list.createdDate) : list.createdDate
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text(list.name).font(.titleM).foregroundStyle(Palette.onSurface).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.trailing, 44)
                HStack(spacing: 8) {
                    CategoryChip(name: item.category?.name ?? "Groceries", color: color)
                    Text(Dates.format(date, "EEEMMMd") + (item.storeName.map { " · \($0)" } ?? ""))
                        .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).lineLimit(1)
                }
                .padding(.trailing, 12)
                Spacer().frame(height: 14)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !list.isCompleted && item.itemCount > 0 {
                            Text(L("in_cart_of", item.purchasedCount, item.itemCount)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                            ProgressBar(value: Double(item.purchasedCount) / Double(item.itemCount)).frame(maxWidth: 220)
                        } else {
                            Text(item.itemCount == 0 ? L("no_items_yet") : P("items_count", item.itemCount)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L(list.isCompleted ? "spent" : "estimated")).font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
                        Text(formatMoney(currency, list.isCompleted ? item.actualTotal : item.estimatedTotal))
                            .font(.titleM).foregroundStyle(list.isCompleted ? Palette.primary : Palette.onSurface)
                    }
                    .padding(.trailing, 12)
                }
            }
            .padding(.leading, 16).padding(.trailing, 4).padding(.top, 8).padding(.bottom, 16)
            .card(Palette.containerLow)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("list_\(list.name)")
        // The ⋮ menu sits over the card, not inside its button, so its taps reach it
        .overlay(alignment: .topTrailing) {
            Menu {
                Button(action: edit) { Label(L("edit"), systemImage: "pencil") }
                Button(role: .destructive, action: delete) { Label(L("delete"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18)).foregroundStyle(Palette.onSurfaceVariant)
                    .frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .padding(.top, 8).padding(.trailing, 4)
            .accessibilityLabel(L("list_actions"))
        }
    }
}

/// New list / Edit list: a name (keyboard opens straight away) and an optional category.
struct ListEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let confirmLabel: String
    @State var name: String
    @State var categoryId: Int64?
    let confirm: (String, Int64?) -> Void

    var body: some View {
        let canSave = !name.trimmingCharacters(in: .whitespaces).isEmpty
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LabeledField(title: L("name"), text: $name, placeholder: L("list_name_hint"), autofocus: true) {
                    if canSave { confirm(name, categoryId); dismiss() }
                }
                CategoryPicker(categories: model.categories, selected: $categoryId)
                Spacer()
            }
            .padding(20)
            .background(Palette.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) { confirm(name, categoryId); dismiss() }.disabled(!canSave).accessibilityIdentifier("confirmList")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
