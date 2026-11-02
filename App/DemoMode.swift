#if DEBUG
import SwiftUI
import UIKit
import SpendWiseCore

/// Debug builds only: launch arguments that fill the app with sample data and open a given screen,
/// so screenshots can be taken in the simulator without tapping (scripts/screenshots.sh):
///
///     -SpendWiseDemo YES -SpendWiseScreen list
///
/// The AI answers from canned replies (DemoData) instead of the backend, and Firebase stays off.
@MainActor
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "SpendWiseDemo") }
    static var screen: String { UserDefaults.standard.string(forKey: "SpendWiseScreen") ?? "home" }

    /// A new, empty database for this run.
    static func freshDatabasePath() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("demo.sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        return url.path
    }

    private static let free: Set<String> = ["home_free", "quickadd_free", "analysis_free", "insights_free", "upgrade", "settings"]

    static func apply(_ model: AppModel, _ router: Router) {
        let s = screen
        DemoMode.model = model
        // The language comes from the launch's -AppleLanguages, not an earlier run's choice
        if Lang.choice != .phone { model.setLanguage(.phone) }
        // Per-install choices start fresh in each demo
        model.setConsent(!["consent"].contains(s))
        for k in InstructionKind.allCases { model.setInstructions(k, "") }
        if s == "ai_instructions" { model.setInstructions(.QuickAdd, Lang.isArabic ? "سمِّ الأصناف بالإنكليزي. «أبو سامي» هو الفرن." : "Name items in English. \"Abu Sami\" is the bakery.") }
        model.setOnboarding(s.hasPrefix("welcome") ? .Welcome : s == "home_guide" ? .FirstList : s == "list_guide" ? .FirstItem : .Done)
        if s != "home_guide" && s != "home_empty" && !s.hasPrefix("welcome") { DemoData.load(model) }
        model.cloud.overrideTier(free.contains(s) ? .free : .premium)
        model.cloud.ai.demoAnswer = { feature, _ in
            try await Task.sleep(for: .milliseconds(300))
            switch feature {
            case .quickAdd: return DemoData.quickAddAnswer
            case .receipt: return DemoData.receiptAnswer
            case .analysisRequest: return DemoData.analysisRequestAnswer
            case .analysisReport: return DemoData.reportAnswer
            }
        }
        // What the allowance chips show
        let now = nowMillis()
        model.cloud.ai.setAllowance(.quickAdd, Allowance(used: 12, limit: 100, weekly: false, asOf: now))
        model.cloud.ai.setAllowance(.receipt, Allowance(used: 3, limit: 20, weekly: false, asOf: now))
        model.cloud.ai.setAllowance(.analysisRequest, Allowance(used: 2, limit: 20, weekly: false, asOf: now))
        model.cloud.ai.setAllowance(.analysisReport, Allowance(used: 1, limit: 3, weekly: true, asOf: now))
        // The welcome's language page shows only on "welcome"; its other pages come after it
        model.welcomeLanguageChosen = s.hasPrefix("welcome") && s != "welcome"
        if s == "welcome_signed_in" {
            model.cloud.demo(user: SignedIn(uid: "me", name: Lang.isArabic ? "ريما خوري" : "Rima Khoury", email: "rima@example.com"),
                             family: nil, status: SyncStatus())
        }
        // Whose data is on the phone starts unknown in each demo
        model.cloud.setDataOwner(nil)
        if s == "settings_apple" {
            // Sign in with Apple: no name and a private relay email, a family member likewise
            let me = SignedIn(uid: "me", name: "", email: "x7k2p9@privaterelay.appleid.com", apple: true)
            let family = Family(id: "fam", ownerUid: "me", members: [
                FamilyMember(uid: "me", name: "", email: me.email, owner: true),
                FamilyMember(uid: "sami", name: Lang.isArabic ? "سامي خوري" : "Sami Khoury", email: "q1w2e3@privaterelay.appleid.com", owner: false),
            ], isOwner: true)
            model.cloud.demo(user: me, family: family, status: SyncStatus(state: .synced, waiting: 0, lastSyncedAt: nowMillis() - 20_000))
        }
        if s.hasPrefix("other_account") {
            // Signed in as another account while the phone holds someone else's lists
            let tester = SignedIn(uid: "tester", name: "Tester", email: "tester@example.com")
            model.cloud.setDataOwner("me")
            model.cloud.demo(user: tester, family: nil, status: SyncStatus())
            model.cloud.otherAccount = tester
        }
        if s.hasPrefix("settings_signed") || s == "settings_family" || s == "sign_out" {
            let me = SignedIn(uid: "me", name: Lang.isArabic ? "ريما خوري" : "Rima Khoury", email: "rima@example.com")
            let family = s == "settings_family" ? Family(id: "fam", ownerUid: "me", members: [
                FamilyMember(uid: "me", name: me.name, email: me.email, owner: true),
                FamilyMember(uid: "sami", name: Lang.isArabic ? "سامي خوري" : "Sami Khoury", email: "sami@example.com", owner: false),
            ], isOwner: true) : nil
            model.cloud.demo(user: me, family: family, status: SyncStatus(state: .synced, waiting: 0, lastSyncedAt: nowMillis() - 20_000))
        }

        let lists = model.lists
        let open = lists.first { !$0.shoppingList.isCompleted }?.id ?? 0
        let completed = lists.first { $0.shoppingList.isCompleted }?.id ?? 0
        let firstReport = model.reports.first?.id ?? 0
        let n = DemoData.names
        switch s {
        case "list", "list_add", "list_edit_item", "list_store", "list_reorder", "list_undo", "list_photo": router.path = [.list(open)]
        case "list_completed": router.path = [.list(completed)]
        case "list_guide":
            let id = model.perform { try model.repo.insertShoppingList(ShoppingList(name: n.weekly)) } ?? 0
            router.path = [.list(id)]
        case "library", "library_prices", "library_item": router.path = [.library]
        case "item": router.path = [.item(n.gas)]
        case "item_milk": router.path = [.item(n.milk)]
        case "insights", "insights_category", "insights_filter", "insights_free": router.path = [.insights]
        case "settings", "settings_signed_in", "settings_family", "settings_currency", "settings_rate", "settings_ai", "settings_apple", "sign_out":
            router.path = [.settings]
        case "ai_instructions": router.path = [.settings, .aiInstructions]
        case "upgrade": router.path = [.upgrade]
        case "analysis", "analysis_ready", "analysis_free": router.path = [.insights, .analysis]
        case "report": router.path = [.insights, .analysis, .report(firstReport)]
        default: break
        }
        if s == "list_undo" {
            if let item = model.items(open).first(where: { !$0.purchased }) {
                model.perform { try model.repo.deleteShoppingItem(item) }
                model.showUndo(L("removed_item", item.itemName), seconds: 60) {}
            }
        }
        if s == "list_photo", let image = sampleReceiptImage(), let name = PhotoStore.save(image.jpegData(compressionQuality: 0.8) ?? Data()) {
            model.perform { try model.repo.insertPhoto(Photo(shoppingListId: open, uri: name)) }
        }
        if s == "settings_signed_in" || s == "settings_ai" { model.cloud.ai.setAllowance(.quickAdd, Allowance(used: 12, limit: 100, weekly: false, asOf: now)) }
    }

    // MARK: - Screens' own sheets and states

    static func openHomeExtras(newList: Binding<Bool>, quickAdd: Binding<QuickAddStart?>, completed: Binding<Bool>, query: Binding<String>,
                               categories: Binding<Bool>, stores: Binding<Bool>, editing: Binding<ShoppingList?>) {
        guard isOn else { return }
        switch screen {
        case "new_list": after { newList.wrappedValue = true }
        case "home_completed": completed.wrappedValue = true
        case "home_search": query.wrappedValue = Lang.isArabic ? "حليب" : "milk"
        case "categories", "category_editor": after { categories.wrappedValue = true }
        case "stores": after { stores.wrappedValue = true }
        case let s where s.hasPrefix("quickadd"): after { quickAdd.wrappedValue = .nothing }
        case "consent": after { quickAdd.wrappedValue = .record }
        default: break
        }
    }

    static func openListExtras(addOpen: Binding<Bool>, editing: Binding<ShoppingItem?>, storeOpen: Binding<Bool>, reorder: Binding<Bool>, items: [ShoppingItem]) {
        guard isOn else { return }
        switch screen {
        case "list_add": after { addOpen.wrappedValue = true }
        case "list_edit_item": after { editing.wrappedValue = items.first { $0.purchased } }
        case "list_store": after { storeOpen.wrappedValue = true }
        case "list_reorder": reorder.wrappedValue = true
        default: break
        }
    }

    static func openLibraryExtras(groceryPrices: Binding<Bool>, detail: Binding<MasterItem?>) {
        guard isOn else { return }
        switch screen {
        case "library_prices": groceryPrices.wrappedValue = true
        case "library_item":
            groceryPrices.wrappedValue = true
            after { detail.wrappedValue = DemoMode.model?.masterItems.first { $0.name == DemoData.names.milk } }
        default: break
        }
    }

    static func openInsightsExtras(range: Binding<DateRange?>) {
        guard isOn, screen == "insights_filter" else { return }
        let now = Date()
        range.wrappedValue = DateRange.days(from: Calendar.current.date(byAdding: .day, value: -30, to: now)!, to: now)
    }

    static func openSettingsExtras(currency: Binding<Bool>, rate: Binding<Bool>) {
        guard isOn else { return }
        if screen == "settings_currency" { after { currency.wrappedValue = true } }
        if screen == "settings_rate" { after { rate.wrappedValue = true } }
    }

    static func openAccountExtras(signingOut: Binding<Bool>) {
        guard isOn, screen == "sign_out" else { return }
        after { signingOut.wrappedValue = true }
    }

    /// Puts quick add in the state the screen shows; true when it did.
    static func prepareQuickAdd(_ qa: QuickAddModel, _ model: AppModel) -> Bool {
        guard isOn else { return false }
        switch screen {
        case "quickadd_review":
            qa.text = "x"
            qa.parseText()
            return true
        case "quickadd_receipt":
            qa.addPhotos([sampleReceiptImage(), sampleReceiptImage(lower: true)].compactMap { $0 }.compactMap { ReceiptPhoto.make($0) })
            qa.note = Lang.isArabic ? "سمِّ الأصناف بالإنكليزي" : "Use English names"
            return true
        case "quickadd_receipt_review":
            qa.addPhotos([sampleReceiptImage()].compactMap { $0 }.compactMap { ReceiptPhoto.make($0) })
            qa.readReceipt()
            return true
        case "quickadd_convert":
            model.setConversionRate(nil)
            qa.addPhotos([sampleReceiptImage()].compactMap { $0 }.compactMap { ReceiptPhoto.make($0) })
            qa.readReceipt()
            return true
        case "quickadd_recording":
            qa.setState(.recording(since: Date().addingTimeInterval(-7)))
            return true
        case "quickadd_error":
            qa.setState(.input(error: L("qa_heard", Lang.isArabic ? "مرحبا" : "hello") + L("qa_nothing_found")))
            return true
        case "quickadd_busy":
            qa.setState(.understanding(.receipt, fixing: false))
            return true
        default:
            return screen.hasPrefix("quickadd")
        }
    }

    static func prepareAnalysis(_ a: AnalysisModel) {
        guard isOn else { return }
        if screen == "analysis_ready" { a.usePreset(.lastMonth) }
    }

    static weak var model: AppModel?

    private static func after(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: action)
    }

    /// A drawn receipt, for the receipt screens (no photo library on CI).
    static func sampleReceiptImage(lower: Bool = false) -> UIImage? {
        let size = CGSize(width: 600, height: 1100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let lines = lower
                ? ["Coffee 815,000", "Halloumi 1,180,000", "", "TOTAL L.L. 2,434,000", "CASH 2,500,000", "Thank you!"]
                : ["SUPERMARKET", "26/10/2026  11:42", "", "Tomatoes 1.2 kg", "  120,000  144,000", "Labneh 295,000", "Halloumi 1,180,000", "Coffee 815,000"]
            let font = UIFont.monospacedSystemFont(ofSize: 30, weight: .regular)
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 60 + CGFloat(i) * 70), withAttributes: [.font: font, .foregroundColor: UIColor.darkGray])
            }
        }
    }
}

extension Cloud {
    /// Demo mode: an account, family and sync state without a server.
    func demo(user: SignedIn?, family: Family?, status: SyncStatus) {
        setDemoUser(user)
        self.family = family
        syncStatus = status
    }
}
#endif
