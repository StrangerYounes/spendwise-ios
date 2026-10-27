import SwiftUI
import SpendWiseCore

/// The colours offered for a category (Android's presets).
let presetColors: [Int32] = [0xFF4CAF50, 0xFF009688, 0xFF03A9F4, 0xFF3F51B5, 0xFF9C27B0, 0xFFE91E63, 0xFFF44336, 0xFFFF9800, 0xFFFFC107, 0xFF795548, 0xFF607D8B]
    .map { Int32(bitPattern: UInt32($0)) }

/// Categories (FEATURES.md §4.6): add, rename, recolour (presets or any colour), delete.
struct CategoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SpendWiseCore.Category?
    @State private var creating = false
    @State private var confirm: Confirm?

    var body: some View {
        let categories = model.categories.sorted { ($0.name != "Groceries" ? 1 : 0) < ($1.name != "Groceries" ? 1 : 0) }
        NavigationStack {
            List {
                ForEach(categories) { c in
                    HStack(spacing: 16) {
                        ColorDot(color: Color(argb: c.color), size: 16)
                        Text(categoryLabel(c.name)).foregroundStyle(Palette.onSurface).frame(maxWidth: .infinity, alignment: .leading)
                        Button { editing = c } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            .accessibilityLabel(L("edit_named", categoryLabel(c.name)))
                        if c.name != "Groceries" {
                            Button {
                                confirm = Confirm(title: L("delete_named_q", categoryLabel(c.name)), message: L("category_delete_body"), label: L("delete")) {
                                    model.perform { try model.repo.deleteCategory(c) }
                                }
                            } label: { Image(systemName: "trash").foregroundStyle(Palette.error) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("delete_named", c.name))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = c }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle(L("categories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("done")) { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { creating = true } label: { Label(L("new_category"), systemImage: "plus") }
                }
            }
            .sheet(isPresented: $creating) {
                CategoryEditor(category: nil) { name, color in
                    model.perform { try model.repo.insertCategory(SpendWiseCore.Category(name: name, color: color)) }
                }
            }
            .sheet(item: $editing) { c in
                CategoryEditor(category: c) { name, color in
                    var updated = c
                    updated.name = name
                    updated.color = color
                    model.perform { try model.repo.updateCategory(updated) }
                }
            }
            .confirm($confirm)
        }
        .onAppear {
            #if DEBUG
            if DemoMode.screen == "category_editor" { editing = categories.dropFirst().first }
            #endif
        }
    }
}

private struct CategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let category: SpendWiseCore.Category?
    let save: (String, Int32) -> Void

    /// What to store: Groceries stays Groceries; a default saved under its shown name keeps its
    /// English name (so it still syncs and merges); anything typed is stored as typed.
    private var storedName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard let original = category?.name else { return typed }
        if original == ShoppingRepository.trackedCategory { return original }
        return typed == categoryLabel(original) ? original : typed
    }
    @State private var name = ""
    @State private var color: Int32 = presetColors[0]
    @State private var custom = Color.green
    @State private var showCustom = false
    @State private var loaded = false

    var body: some View {
        let isGroceries = category?.name == "Groceries"
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isGroceries {
                        LabeledField(title: L("name"), text: .constant(categoryLabel(category?.name))).disabled(true)
                        Text(L("groceries_no_rename")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    } else {
                        LabeledField(title: L("name"), text: $name, autofocus: category == nil)
                    }
                    Text(L("colour")).font(.labelL)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                        ForEach(presetColors, id: \.self) { preset in
                            Button { color = preset; custom = Color(argb: preset) } label: {
                                Circle().fill(Color(argb: preset)).frame(width: 36, height: 36)
                                    .overlay { if preset == color { Image(systemName: "checkmark").foregroundStyle(.white).font(.system(size: 14, weight: .bold)) } }
                            }
                            .accessibilityLabel(preset == color ? L("selected") : L("colour"))
                        }
                    }
                    Button(L(showCustom ? "hide_custom_colour" : "custom_colour")) { showCustom.toggle() }.foregroundStyle(Palette.primary)
                    if showCustom {
                        ColorPicker(L("custom_colour"), selection: Binding(get: { custom }, set: { custom = $0; color = $0.argb }), supportsOpacity: false)
                    }
                }
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L(category == nil ? "new_category" : "edit_category"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        save(storedName, color)
                        dismiss()
                    }
                    .disabled(!isGroceries && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            // A default category shows its name in the app's language
            name = category.map { categoryLabel($0.name) } ?? ""
            color = category?.color ?? presetColors[0]
            custom = Color(argb: color)
            showCustom = category != nil && !presetColors.contains(color)
        }
    }
}

/// Stores (FEATURES.md §4.6): how many lists use each; rename (merging onto an existing name) or delete.
struct StoresSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: StoreUsage?
    @State private var confirm: Confirm?

    var body: some View {
        let stores = model.storeUsage
        NavigationStack {
            List {
                Text(L("stores_merge_hint")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).listRowBackground(Color.clear)
                if stores.isEmpty {
                    Text(L("no_stores")).font(.bodyM).padding(.vertical, 16).listRowBackground(Color.clear)
                }
                ForEach(stores) { s in
                    HStack(spacing: 16) {
                        Image(systemName: "storefront").foregroundStyle(Palette.onSurfaceVariant)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(Palette.onSurface)
                            Text(s.listCount == 0 ? L("no_lists") : P("lists_count", s.listCount)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { renaming = s } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            .accessibilityLabel(L("rename_named", s.name))
                        Button {
                            let lists = s.listCount > 0 ? P("store_delete_lists", s.listCount) + " " : ""
                            confirm = Confirm(title: L("delete_named_q", s.name), message: lists + L("store_delete_prices"), label: L("delete")) {
                                model.perform { try model.repo.deleteStore(s.toStore()) }
                            }
                        } label: { Image(systemName: "trash").foregroundStyle(Palette.error) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("delete_named", s.name))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { renaming = s }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle(L("stores"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("done")) { dismiss() } } }
            .sheet(item: $renaming) { s in
                RenameStoreSheet(store: s, others: stores.filter { $0.id != s.id }) { name in
                    model.perform { try model.repo.renameStore(s.toStore(), name) }
                }
            }
            .confirm($confirm)
        }
    }
}

private struct RenameStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: StoreUsage
    let others: [StoreUsage]
    let save: (String) -> Void
    @State private var name = ""

    var body: some View {
        let mergeInto = others.first { $0.name.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() }
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: L("name"), text: $name, autofocus: true)
                if let mergeInto { Text(L("store_exists_merge", mergeInto.name)).font(.bodyS).foregroundStyle(Palette.tertiary) }
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("rename_store"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(mergeInto != nil ? "merge" : "save")) { save(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { if name.isEmpty { name = store.name } }
    }
}
