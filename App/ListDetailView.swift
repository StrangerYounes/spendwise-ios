import SwiftUI
import UIKit
import PhotosUI
import SpendWiseCore

/// A list (FEATURES.md §4.2): To buy and In cart, a summary card, Add items, the item editor,
/// undo after a delete, the list's store, photos, reorder, Finish shopping and Reopen.
struct ListDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let listId: Int64

    @State private var addOpen = false
    @State private var editing: ShoppingItem?
    @State private var renaming = false
    @State private var newName = ""
    @State private var storeOpen = false
    @State private var reorder = false
    @State private var confirm: Confirm?
    @State private var photoItem: PhotosPickerItem?
    @State private var viewing: Photo?

    var body: some View {
        let list = model.list(listId)
        let items = model.items(listId)
        let toBuy = items.filter { !$0.purchased }
        let inCart = items.filter { $0.purchased }
        let completed = list?.isCompleted == true
        let photos = model.photos(listId)
        let step = model.onboarding
        let guideItem = step == .FirstItem && items.isEmpty && !completed
        let store = list?.storeId.flatMap { id in model.stores.first { $0.id == id } }
        let estimated = items.reduce(0) { $0 + ($1.unitPrice ?? 0) * $1.quantity }
        let actual = inCart.reduce(0) { $0 + ($1.unitPrice ?? 0) * $1.quantity }

        ScrollView {
            LazyVStack(spacing: 8) {
                SummaryCard(storeName: store?.name, itemCount: items.count, inCartCount: inCart.count, estimated: estimated, actual: actual,
                            currency: model.currency, completed: completed, completedDate: list?.completedDate) { storeOpen = true }
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos) { photo in
                                PhotoThumb(photo: photo, open: { viewing = photo }, remove: {
                                    confirm = Confirm(title: L("remove_photo_q"), message: L("remove_photo_body"), label: L("remove")) {
                                        model.perform { try model.repo.deletePhoto(photo) }
                                        PhotoStore.delete(photo.uri)
                                    }
                                })
                            }
                        }
                    }
                }
                if step == .Tips && !items.isEmpty {
                    GuideCard(icon: "checkmark.circle", title: L("guide_tips_title"), message: L("guide_tips_body"), actionLabel: L("got_it")) {
                        model.setOnboarding(.Done)
                    }
                }
                if guideItem {
                    GuideCard(icon: "cart.badge.plus", title: L("guide_item_title"), message: L("guide_item_body"), actionLabel: L("skip_guide")) {
                        model.setOnboarding(.Done)
                    }
                } else if items.isEmpty {
                    EmptyState(icon: "cart.badge.plus", title: L("list_empty"), message: L("list_empty_sub"))
                }

                if !toBuy.isEmpty {
                    header(L(completed ? "not_bought" : "to_buy"), toBuy.count)
                    ForEach(Array(toBuy.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, section: toBuy, offset: 0, all: items)
                    }
                }
                if toBuy.isEmpty && !inCart.isEmpty && !completed {
                    FinishCard { complete() }
                }
                if !inCart.isEmpty {
                    header(L(completed ? "bought" : "in_cart"), inCart.count)
                    ForEach(Array(inCart.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, section: inCart, offset: toBuy.count, all: items)
                    }
                }
                if !toBuy.isEmpty && !inCart.isEmpty && !completed && !reorder {
                    Button { complete() } label: {
                        Label(L("finish_shopping"), systemImage: "checkmark").font(.labelL).foregroundStyle(Palette.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("finishShopping")
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 96)
            .readableWidth()
        }
        .screen(list?.name ?? "")
        .overlay(alignment: .bottomTrailing) {
            if !reorder {
                Button { addOpen = true } label: {
                    Label(L("add_item"), systemImage: "plus")
                        .font(.labelL).padding(.horizontal, 20).frame(height: 56)
                        .foregroundStyle(Palette.onPrimaryContainer)
                        .background(Palette.primaryContainer, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
                .pulse(guideItem)
                .padding(16)
                .clearOfSnackbar()
                .accessibilityIdentifier("addItem")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { startRename(list) } label: {
                    Text(list?.name ?? "").font(.headline).foregroundStyle(Palette.onSurface).lineLimit(1)
                }
                .accessibilityIdentifier("listTitle")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if reorder {
                    Button(L("done")) { reorder = false }
                } else {
                    PhotosPicker(selection: $photoItem, matching: .images) { Image(systemName: "photo.badge.plus") }
                        .accessibilityLabel(L("attach_photo"))
                    Menu {
                        Button { startRename(list) } label: { Label(L("rename"), systemImage: "pencil") }
                        Button { reorder = true } label: { Label(L("reorder_items"), systemImage: "arrow.up.arrow.down") }.disabled(items.count < 2)
                        if completed {
                            Button {
                                confirm = Confirm(title: L("reopen_q"), message: L("reopen_body"), label: L("reopen"), destructive: false) { reopen() }
                            } label: { Label(L("reopen_list"), systemImage: "arrow.uturn.backward") }
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirm = Confirm(title: L("clear_all_q"), message: P("clear_all_body", items.count), label: L("clear")) {
                                model.perform { try model.repo.deleteItems(listId: listId) }
                            }
                        } label: { Label(L("clear_all_items"), systemImage: "trash") }.disabled(items.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(L("more"))
                }
            }
        }
        .sheet(isPresented: $addOpen) { AddItemsSheet(listId: listId) }
        .sheet(item: $editing) { item in
            ItemEditorSheet(item: item) { updated in
                model.perform { try model.repo.updateShoppingItem(updated) }
            } delete: {
                deleteWithUndo(item)
            }
        }
        .sheet(isPresented: $storeOpen) { StoreChoiceSheet(listId: listId) }
        .fullScreenCover(item: $viewing) { photo in PhotoViewer(photo: photo) { viewing = nil } }
        .alert(L("rename_list"), isPresented: $renaming) {
            TextField(L("list_name"), text: $newName)
            Button(L("rename")) {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if var l = list, !trimmed.isEmpty {
                    l.name = trimmed
                    model.perform { try model.repo.updateShoppingList(l) }
                }
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .confirm($confirm)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let name = PhotoStore.save(data) {
                    model.perform { try model.repo.insertPhoto(Photo(shoppingListId: listId, uri: name)) }
                }
                photoItem = nil
            }
        }
        // The first-run guide's last steps: the first item, then how shopping goes
        .onChange(of: items.isEmpty) { _, empty in if !empty { model.advance(from: .FirstItem, to: .Tips) } }
        .onAppear {
            if !items.isEmpty { model.advance(from: .FirstItem, to: .Tips) }
            #if DEBUG
            DemoMode.openListExtras(addOpen: $addOpen, editing: $editing, storeOpen: $storeOpen, reorder: $reorder, items: items)
            #endif
        }
        // The tips are shown once, in this list
        .onDisappear { model.advance(from: .Tips, to: .Done) }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        Text("\(title) · \(count)").font(.titleS).foregroundStyle(Palette.primary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 2).padding(.leading, 4)
    }

    @ViewBuilder
    private func row(_ item: ShoppingItem, index: Int, section: [ShoppingItem], offset: Int, all: [ShoppingItem]) -> some View {
        let global = offset + index
        ItemRow(item: item, currency: model.currency, reorder: reorder,
                toggle: { setPurchased(item, !item.purchased) },
                open: { editing = item },
                delete: { deleteWithUndo(item) },
                moveUp: index > 0 ? { move(all, global, global - 1) } as () -> Void : nil,
                moveDown: index < section.count - 1 ? { move(all, global, global + 1) } as () -> Void : nil)
    }

    private func startRename(_ list: ShoppingList?) {
        guard let list else { return }
        newName = list.name
        renaming = true
    }

    private func setPurchased(_ item: ShoppingItem, _ purchased: Bool) {
        var i = item
        i.purchased = purchased
        model.perform { try model.repo.updateShoppingItem(i) }
    }

    /// No swipe-to-delete (it fired while scrolling): a visible ✕ and Undo for about 10 s.
    private func deleteWithUndo(_ item: ShoppingItem) {
        model.perform { try model.repo.deleteShoppingItem(item) }
        model.showUndo(L("removed_item", item.itemName)) {
            model.perform { try model.repo.restoreShoppingItem(item) }
        }
    }

    /// Moves an item within its section, by position in the whole list (Android moveItem).
    private func move(_ all: [ShoppingItem], _ from: Int, _ to: Int) {
        guard all.indices.contains(from), all.indices.contains(to) else { return }
        var list = all
        let item = list.remove(at: from)
        list.insert(item, at: to)
        model.perform {
            try model.database.db.transaction {
                for (index, i) in list.enumerated() where i.orderIndex != index {
                    var copy = i
                    copy.orderIndex = index
                    try model.repo.updateShoppingItem(copy)
                }
            }
        }
    }

    private func complete() {
        guard var l = model.list(listId) else { return }
        l.isCompleted = true
        l.completedDate = nowMillis()
        model.perform { try model.repo.updateShoppingList(l) }
    }

    private func reopen() {
        guard var l = model.list(listId) else { return }
        l.isCompleted = false
        l.completedDate = nil
        model.perform { try model.repo.updateShoppingList(l) }
    }
}

private struct SummaryCard: View {
    let storeName: String?
    let itemCount: Int
    let inCartCount: Int
    let estimated: Double
    let actual: Double
    let currency: String
    let completed: Bool
    let completedDate: Millis?
    let chooseStore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: chooseStore) {
                    HStack(spacing: 6) {
                        Image(systemName: "storefront").font(.system(size: 14))
                        Text(storeName ?? L("choose_store")).font(.labelL).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plainRow)
                .accessibilityIdentifier("chooseStore")
                Spacer()
                if completed {
                    Label(L("completed"), systemImage: "checkmark").font(.labelM)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(Palette.onPrimary).background(Palette.primary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(completed ? "total_paid" : "in_cart")).font(.labelL).opacity(0.75)
                    Text(formatMoney(currency, actual)).font(.headlineM)
                    if completed, let completedDate {
                        Text(L("completed_on", Dates.format(completedDate, "EEEMMMdyyyy"))).font(.bodyS).opacity(0.75)
                    }
                }
                Spacer()
                if !completed {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L("estimated")).font(.labelL).opacity(0.75)
                        Text(formatMoney(currency, estimated)).font(.titleL)
                    }
                }
            }
            if !completed && itemCount > 0 {
                ProgressBar(value: Double(inCartCount) / Double(itemCount), color: Palette.primary, track: Palette.surface.opacity(0.6), height: 8)
                Text(P("in_cart_items", itemCount, inCartCount, itemCount)).font(.bodyS).opacity(0.75)
            }
        }
        .foregroundStyle(Palette.onPrimaryContainer)
        .padding(16)
        .card(Palette.primaryContainer)
    }
}

private struct FinishCard: View {
    let finish: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "party.popper")
            Text(L("all_in_cart")).font(.bodyL).frame(maxWidth: .infinity, alignment: .leading)
            Button(L("finish"), action: finish).buttonStyle(TonalButtonStyle(height: 40)).accessibilityIdentifier("finish")
        }
        .foregroundStyle(Palette.onTertiaryContainer)
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .card(Palette.tertiaryContainer, radius: 12)
    }
}

/// One item: tick box, name and details, the line total and a ✕ (or move buttons when reordering).
struct ItemRow: View {
    let item: ShoppingItem
    let currency: String
    var reorder = false
    let toggle: () -> Void
    let open: () -> Void
    var delete: (() -> Void)? = nil
    var moveUp: (() -> Void)? = nil
    var moveDown: (() -> Void)? = nil

    var body: some View {
        let unitPrice = item.unitPrice
        let muted = Palette.onSurfaceVariant
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: item.purchased ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(item.purchased ? Palette.primary : Palette.onSurfaceVariant)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plainRow)
            .accessibilityLabel(item.itemName)
            .accessibilityValue(item.purchased ? L("in_cart") : L("to_buy"))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.itemName).font(.bodyL)
                    .strikethrough(item.purchased)
                    .foregroundStyle(item.purchased ? muted : Palette.onSurface)
                    .lineLimit(2)
                let details = detailText(unitPrice)
                if !details.isEmpty { Text(details).font(.bodyS).foregroundStyle(muted) }
                if let notes = item.notes, !notes.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "text.alignleft").font(.system(size: 10))
                        Text(notes).font(.bodyS).italic().lineLimit(1)
                    }
                    .foregroundStyle(muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !reorder { open() } }
            if reorder {
                Button { moveUp?() } label: { Image(systemName: "chevron.up").frame(width: 40, height: 40) }
                    .disabled(moveUp == nil).accessibilityLabel(L("move_up"))
                Button { moveDown?() } label: { Image(systemName: "chevron.down").frame(width: 40, height: 40) }
                    .disabled(moveDown == nil).accessibilityLabel(L("move_down"))
            } else {
                if let unitPrice {
                    Text(formatMoney(currency, unitPrice * item.quantity)).font(.titleS)
                        .foregroundStyle(item.purchased ? muted : Palette.onSurface)
                }
                if let delete {
                    Button(action: delete) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(muted).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plainRow)
                    .accessibilityLabel(L("remove_named", item.itemName))
                }
            }
        }
        .padding(.leading, 0).padding(.trailing, 8).padding(.vertical, 2)
        .card(item.purchased ? Palette.containerLowest : Palette.containerLow, radius: 16)
    }

    private func detailText(_ unitPrice: Double?) -> String {
        var parts: [String] = []
        if item.quantity != 1 || item.unit != nil {
            parts.append(formatQuantity(item.quantity) + (item.unit.map { " \($0)" } ?? ""))
        }
        if let unitPrice, item.quantity != 1 {
            let unit = item.unit?.trimmingCharacters(in: .whitespaces)
            parts.append(formatUnitPrice(currency, unitPrice) + ((unit?.isEmpty == false) ? "/\(unit!)" : L("each_suffix")))
        }
        if let a = item.actualPrice, let e = item.estimatedPrice, a != e {
            parts.append(L("est_price", formatMoney(currency, e)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Add items: stays open; Enter adds and gets ready for the next, with suggestions from everything
/// bought before. Closes only with its ✕.
struct AddItemsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let listId: Int64

    @State private var name = ""
    @State private var price = ""
    @State private var quantity = "1"
    @State private var unit = ""
    @State private var notes = ""
    @State private var showNotes = false
    @State private var lastAdded: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let storeId = model.list(listId)?.storeId
        let suggestions = (try? model.repo.suggestions(name, listStoreId: storeId, listCategory: model.categoryName(ofList: listId))) ?? []
        VStack(spacing: 0) {
            SheetCloseBar { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("add_items")).font(.titleL)
                        Spacer()
                        if let lastAdded {
                            Text(L("added_named", lastAdded)).font(.labelL).foregroundStyle(Palette.primary).lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("item")).font(.labelM).foregroundStyle(nameFocused ? Palette.primary : Palette.onSurfaceVariant)
                        HStack {
                            TextField("", text: $name)
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit { add(name, parseAmount(price), nil) }
                                .accessibilityIdentifier("itemName")
                            if !name.isEmpty {
                                Button { name = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.onSurfaceVariant) }
                                    .accessibilityLabel(L("clear"))
                            }
                        }
                        .fieldStyle(focused: nameFocused)
                    }
                    if !suggestions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.name) { s in
                                Button { add(s.name, s.suggestedPrice ?? parseAmount(price), s.lastUnit) } label: {
                                    SuggestionRow(suggestion: s, currency: model.currency)
                                }
                                .buttonStyle(.plainRow)
                            }
                        }
                        .card(Palette.containerHigh, radius: 16)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        LabeledField(title: L("qty"), text: $quantity, keyboard: .decimalPad).frame(maxWidth: 80)
                        LabeledField(title: L("unit"), text: $unit, placeholder: L("unit_hint")).frame(maxWidth: 100)
                        AmountField(title: L("price_each"), text: $price, currency: model.currency) { add(name, parseAmount(price), nil) }
                    }
                    if showNotes {
                        LabeledField(title: L("note"), text: $notes)
                    }
                    HStack {
                        if !showNotes {
                            Button { showNotes = true } label: { Label(L("add_note"), systemImage: "text.alignleft").font(.labelL) }
                                .foregroundStyle(Palette.primary)
                        }
                        Spacer()
                        Button { add(name, parseAmount(price), nil) } label: { Label(L("add"), systemImage: "plus") }
                            .buttonStyle(FilledButtonStyle(height: 44)).frame(maxWidth: 140)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("addButton")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(Palette.containerLow.ignoresSafeArea())
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nameFocused = true } }
    }

    private func add(_ itemName: String, _ estimated: Double?, _ suggestedUnit: String?) {
        let trimmed = itemName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let qty = parseDecimal(quantity).flatMap { $0 > 0 ? $0 : nil } ?? 1
        let u = unit.trimmingCharacters(in: .whitespaces)
        let n = notes.trimmingCharacters(in: .whitespaces)
        let order = (model.items(listId).map(\.orderIndex).max() ?? -1) + 1
        model.perform {
            try model.repo.insertShoppingItem(ShoppingItem(listId: listId, itemName: trimmed, estimatedPrice: estimated, quantity: qty,
                                                           unit: u.isEmpty ? suggestedUnit : u, orderIndex: order, notes: n.isEmpty ? nil : n))
        }
        withAnimation { lastAdded = trimmed }
        name = ""; price = ""; quantity = "1"; unit = ""; notes = ""; showNotes = false
        nameFocused = true
    }
}

struct SuggestionRow: View {
    let suggestion: ItemSuggestion
    let currency: String
    var body: some View {
        let s = suggestion
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.bodyL).foregroundStyle(Palette.onSurface)
                if let cheaper = s.bestPrice, let here = s.listStorePrice, cheaper < here {
                    Text(L("cheaper_at", s.bestStoreName ?? "", formatMoney(currency, cheaper))).font(.labelM).foregroundStyle(Palette.tertiary)
                } else if s.timesBought > 0 {
                    Text(L("used_times", s.timesBought)).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            Spacer()
            if let p = s.suggestedPrice {
                Text(formatUnitPrice(currency, p) + (s.lastUnit.map { "/\($0)" } ?? "")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The item editor: name (with suggestions once changed), quantity, unit, estimated and paid
/// price, note, store ("Same as list"), In cart, Delete.
struct ItemEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ShoppingItem
    let save: (ShoppingItem) -> Void
    let delete: () -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var estimated = ""
    @State private var paid = ""
    @State private var quantity = ""
    @State private var unit = ""
    @State private var storeId: Int64?
    @State private var purchased = false
    @State private var nameEdited = false
    @State private var loaded = false

    var body: some View {
        let suggestions = nameEdited ? Array(((try? model.repo.suggestions(name, listStoreId: model.list(item.listId)?.storeId, listCategory: model.categoryName(ofList: item.listId))) ?? []).prefix(4)) : []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField(title: L("item"), text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    if !suggestions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.name) { s in
                                Button {
                                    name = s.name
                                    if let p = s.suggestedPrice { estimated = formatPriceInput(p) }
                                    nameEdited = false
                                } label: {
                                    HStack {
                                        Text(s.name).foregroundStyle(Palette.onSurface)
                                        Spacer()
                                        if let p = s.suggestedPrice { Text(formatMoney(model.currency, p)).foregroundStyle(Palette.onSurfaceVariant) }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                                }
                                .buttonStyle(.plainRow)
                            }
                        }
                        .card(Palette.containerHighest, radius: 16)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        LabeledField(title: L("qty"), text: $quantity, keyboard: .decimalPad)
                        LabeledField(title: L("unit"), text: $unit, placeholder: L("unit_hint"))
                    }
                    HStack(alignment: .top, spacing: 8) {
                        AmountField(title: L("estimated"), text: $estimated, currency: model.currency)
                        AmountField(title: L("paid"), text: $paid, currency: model.currency)
                    }
                    Text(L("per_unit_hint")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    LabeledField(title: L("note"), text: $notes)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("bought_at")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
                        Menu {
                            Button(L("same_as_list")) { storeId = nil }
                            ForEach(model.stores) { s in Button(s.name) { storeId = s.id } }
                        } label: {
                            HStack {
                                Text(model.stores.first { $0.id == storeId }?.name ?? L("same_as_list")).foregroundStyle(Palette.onSurface)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Palette.onSurfaceVariant)
                            }
                            .fieldStyle()
                        }
                    }
                    Toggle(L("in_cart"), isOn: $purchased).tint(Palette.primary).padding(.vertical, 4)
                    Button(L("delete"), role: .destructive) { dismiss(); delete() }
                        .foregroundStyle(Palette.error).padding(.top, 4)
                }
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("edit_item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        var updated = item
                        updated.itemName = name.trimmingCharacters(in: .whitespaces)
                        let n = notes.trimmingCharacters(in: .whitespaces)
                        updated.notes = n.isEmpty ? nil : n
                        updated.estimatedPrice = parseAmount(estimated)
                        updated.actualPrice = parseAmount(paid)
                        updated.quantity = parseDecimal(quantity).flatMap { $0 > 0 ? $0 : nil } ?? item.quantity
                        let u = unit.trimmingCharacters(in: .whitespaces)
                        updated.unit = u.isEmpty ? nil : u
                        updated.storeId = storeId
                        updated.purchased = purchased
                        save(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = item.itemName
            notes = item.notes ?? ""
            estimated = formatPriceInput(item.estimatedPrice)
            paid = formatPriceInput(item.actualPrice)
            quantity = formatQuantity(item.quantity)
            unit = item.unit ?? ""
            storeId = item.storeId
            purchased = item.purchased
        }
    }
}

/// "Where are you shopping?": no store, a store, or a new one.
struct StoreChoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let listId: Int64
    @State private var adding = false
    @State private var newStore = ""

    var body: some View {
        let current = model.list(listId)?.storeId
        NavigationStack {
            List {
                option(L("no_store"), selected: current == nil) { set(nil) }
                ForEach(model.stores) { s in option(s.name, selected: current == s.id) { set(s.id) } }
            }
            .listStyle(.plain)
            .navigationTitle(L("where_shopping"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newStore = ""; adding = true } label: { Label(L("new_store"), systemImage: "plus") }
                }
            }
            .alert(L("new_store"), isPresented: $adding) {
                TextField(L("store_name"), text: $newStore)
                Button(L("add"), action: addStore)
                Button(L("cancel"), role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func option(_ name: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Palette.primary : Palette.onSurfaceVariant)
                Text(name).foregroundStyle(Palette.onSurface)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func addStore() {
        let trimmed = newStore.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = model.perform { try model.repo.insertStore(Store(name: trimmed)) }
        if let id { set(id) }
    }

    private func set(_ storeId: Int64?) {
        guard var l = model.list(listId) else { return }
        l.storeId = storeId
        model.perform { try model.repo.updateShoppingList(l) }
        dismiss()
    }
}

/// List photos, kept in Application Support (left out of iCloud backup, as on Android: photos
/// stay on the phone that took them and never sync).
enum PhotoStore {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("photos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var d = dir
            try? d.setResourceValues(values)
        }
        return dir
    }

    /// Saves a photo as JPEG; returns its file name.
    static func save(_ data: Data) -> String? {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    static func image(_ name: String) -> UIImage? { UIImage(contentsOfFile: folder.appendingPathComponent(name).path) }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
}

private struct PhotoThumb: View {
    let photo: Photo
    let open: () -> Void
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                Group {
                    if let image = PhotoStore.image(photo.uri) { Image(uiImage: image).resizable().scaledToFill() } else { Palette.containerHigh }
                }
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityLabel(L("attached_photo"))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.onSurface)
                    .frame(width: 24, height: 24).background(Palette.surface.opacity(0.85), in: Circle())
            }
            .padding(4)
            .accessibilityLabel(L("remove_photo"))
        }
    }
}

struct PhotoViewer: View {
    let photo: Photo
    let close: () -> Void
    @State private var scale: CGFloat = 1
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image = PhotoStore.image(photo.uri) {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = min(5, max(1, $0.magnification)) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L("photo"))
            }
            Button(action: close) { Image(systemName: "xmark").font(.title2).foregroundStyle(.white).padding(20) }
                .accessibilityLabel(L("close"))
        }
    }
}
