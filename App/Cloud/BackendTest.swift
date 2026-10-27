#if DEBUG
import FirebaseAuth
import Foundation
import UIKit
import SpendWiseCore

/// CI's end-to-end checks against the Firebase emulators (scripts/backend-test.sh): the app plays a
/// role and writes what it saw to Documents/test-report.json, which scripts/backend_check.py reads
/// together with Firestore's own copy.
///
///  - ai: quick add, receipts, follow-ups, own instructions and reports through the real `ai`
///    function (its Gemini replaced by a stub on CI), with the plan's limits.
///  - owner / member / owner2: one account on two phones; lists made on one reach the other, edits
///    to different fields on both survive, and nothing is left waiting.
@MainActor
enum BackendTest {
    private static var steps: [[String: Any]] = []
    private static var facts: [String: Any] = [:]

    private static func step(_ name: String, _ ok: Bool, _ detail: String = "") {
        steps.append(["name": name, "ok": ok, "detail": detail])
        print("BackendTest \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        write()
    }

    private static func write(done: Bool = false) {
        var report = facts
        report["steps"] = steps
        report["done"] = done
        report["lastError"] = cloudModel?.cloud.lastError ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("test-report.json")
        try? data.write(to: url, options: .atomic)
    }

    private static weak var cloudModel: AppModel?

    /// Waits until [condition] holds, checking twice a second.
    private static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }

    static func run(_ role: String, _ model: AppModel) async {
        cloudModel = model
        facts["role"] = role
        write()
        switch role {
        case "ai": await ai(model)
        case "owner": await owner(model)
        case "member": await member(model)
        case "owner2": await owner2(model)
        default: step("role", false, "unknown role \(role)")
        }
        write(done: true)
    }

    // MARK: - AI

    private static func ai(_ model: AppModel) async {
        let cloud = model.cloud
        step("emulators", cloud.usingEmulators, "plan switch \(cloud.planSwitchable)")
        model.setConsent(true)
        cloud.setDebugTier(.free)
        DemoData.load(model)

        await cloud.ai.refreshAllowances()
        let free = cloud.ai.current(.quickAdd)
        step("free allowance", free?.limit == 10, "quickAdd \(String(describing: free))")
        step("anonymous account", Auth.auth().currentUser?.isAnonymous == true, Auth.auth().currentUser?.uid ?? "none")
        facts["anonymousUid"] = Auth.auth().currentUser?.uid ?? ""

        // Quick add, typed
        let qa = QuickAddModel(model: model)
        qa.text = "filled gas for 40 and milk at the supermarket"
        qa.parseText()
        _ = await wait(60) { if case .review = qa.state { return true }; if case .input(let e) = qa.state, e != nil { return true }; return false }
        if case .review(let r) = qa.state {
            step("quick add review", r.purchases.count == 2, r.purchases.map { "\($0.listName): \($0.items.map(\.name))" }.joined(separator: "; "))
            let listsBefore = model.lists.count
            var savedCount = 0
            qa.save { count, _ in savedCount = count }
            step("quick add saved", savedCount == 2 && model.lists.count == listsBefore + 2, "lists \(listsBefore) -> \(model.lists.count)")
        } else {
            step("quick add review", false, "\(qa.state)")
        }
        let used = cloud.ai.current(.quickAdd)
        step("quick add counted", used?.used == 1, "\(String(describing: used))")

        // Receipts are Premium: on Free the backend says so in the app's words
        let photo = DemoMode.sampleReceiptImage().flatMap(ReceiptPhoto.make)
        do {
            _ = try await cloud.ai.generate(.receipt, .object([("images", .array([.string(photo?.jpeg.base64EncodedString() ?? "")])),
                                                              ("context", AiPayload.names(try model.repo.quickAddContext(currencySymbol: "$")))]))
            step("receipt refused on free", false, "answered")
        } catch {
            step("receipt refused on free", (error as? AiError)?.message.isEmpty == false, (error as? AiError)?.message ?? "\(error)")
        }

        // Premium: a receipt with a note and the person's own instructions, then a follow-up
        cloud.setDebugTier(.premium)
        model.setInstructions(.Receipt, "Write every item name in CAPITAL LETTERS")
        let rq = QuickAddModel(model: model)
        if let photo { rq.addPhotos([photo]) }
        rq.note = "The last line is a 2-for-1"
        rq.readReceipt()
        _ = await wait(60) { if case .review = rq.state { return true }; if case .draft(let d) = rq.state, d.error != nil { return true }; return false }
        if case .review(let r) = rq.state {
            let names = r.purchases.flatMap { $0.items.map(\.name) }
            step("receipt read", !names.isEmpty, names.joined(separator: ", "))
            step("own instructions reached the AI", names.allSatisfy { $0 == $0.uppercased() }, names.joined(separator: ", "))
            step("receipt converted", r.conversion?.rate == 89_500, "\(String(describing: r.conversion))")
            rq.fixText = "remove the coffee"
            rq.sendFix()
            _ = await wait(60) { if case .review(let x) = rq.state { return x != r }; return false }
            if case .review(let after) = rq.state {
                let names2 = after.purchases.flatMap { $0.items.map(\.name) }
                step("follow-up applied", names2.count == names.count - 1 && after.error == nil, names2.joined(separator: ", ") + (after.error ?? ""))
            } else {
                step("follow-up applied", false, "\(rq.state)")
            }
        } else {
            step("receipt read", false, "\(rq.state)")
        }
        let receipts = cloud.ai.current(.receipt)
        step("receipt counted per photo", receipts?.used == 1, "\(String(describing: receipts))")
        let quick = cloud.ai.current(.quickAdd)
        // The note and the follow-up are a quick add each, on top of the typed one
        step("note and follow-up counted as quick adds", quick?.used == 3, "\(String(describing: quick))")

        // An AI report: the request understood, then written and saved
        let analysis = AnalysisModel(model: model)
        analysis.text = "How did I spend last month?"
        analysis.submitText()
        _ = await wait(60) { if case .ready = analysis.state { return true }; if case .idle(let e) = analysis.state, e != nil { return true }; return false }
        if case .ready(let request, let digest) = analysis.state {
            step("report request understood", digest.purchaseCount > 0, "\(periodLabel(request.start, request.end)), \(digest.basedOn)")
            var savedId: Int64?
            analysis.writeReport { savedId = $0 }
            _ = await wait(90) { savedId != nil || analysis.writeError != nil }
            let report = savedId.flatMap { model.report($0) }
            step("report written", report != nil, report?.title ?? (analysis.writeError ?? "none"))
            step("report facts are the phone's", report.flatMap { ReportContent.from(json: $0.content) }?.facts.first?.value.hasPrefix("$") == true, "")
        } else {
            step("report request understood", false, "\(analysis.state)")
        }

        // Base prompts need neither consent nor an account
        do {
            let prompts = try await cloud.ai.basePrompts()
            step("base prompts", prompts["quickAdd"]?.isEmpty == false, prompts.keys.sorted().joined(separator: ","))
        } catch {
            step("base prompts", false, "\(error)")
        }
    }

    // MARK: - Sync

    static let account = "Test User"
    static let listName = "Shared from iPhone A"

    private static func signedInAndSyncing(_ model: AppModel) async -> Bool {
        let cloud = model.cloud
        model.setConsent(true)
        // On the emulators the plan comes from the debug switch (the rules check entitlements/{uid},
        // which the test script writes)
        cloud.setDebugTier(.premium)
        var signed = false
        for _ in 0..<3 where !signed {
            signed = await cloud.signInForTest(account)
            if !signed { try? await Task.sleep(for: .seconds(3)) }
        }
        step("signed in", signed && cloud.user != nil,
             "\(cloud.user?.uid ?? "no user") emulators=\(cloud.usingEmulators) returned=\(signed) auth=\(Auth.auth().currentUser?.uid ?? "nil") \(cloud.lastError ?? "")")
        facts["uid"] = cloud.user?.uid ?? ""
        // Premium comes from entitlements/{uid}, written by the test script before the phones start
        let premium = await wait(30) { cloud.tier == .premium }
        step("premium from the server", premium, "\(cloud.tier)")
        let synced = await wait(90) { cloud.syncStatus.state == .synced }
        step("synced", synced, "\(cloud.syncStatus)")
        return synced
    }

    private static func owner(_ model: AppModel) async {
        guard await signedInAndSyncing(model) else { return }
        let repo = model.repo
        let ok = model.perform {
            let store = try repo.insertStore(Store(name: "Supermarket"))
            let list = try repo.insertShoppingList(ShoppingList(name: listName, storeId: store))
            try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Milk", estimatedPrice: 1.8, quantity: 2, unit: "l", orderIndex: 0))
            try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Bread", estimatedPrice: 0.9, orderIndex: 1))
            try repo.insertShoppingItem(ShoppingItem(listId: list, itemName: "Eggs", estimatedPrice: 4, orderIndex: 2))
            return list
        }
        step("list made", ok != nil, "")
        let uploaded = await wait(60) { model.cloud.syncStatus.waiting == 0 && model.cloud.syncStatus.state == .synced }
        step("uploaded", uploaded, "\(model.cloud.syncStatus)")
        if let id = ok, let list = model.list(id) {
            facts["listUid"] = list.uid ?? ""
            facts["itemUids"] = model.items(id).compactMap(\.uid)
        }
    }

    private static func member(_ model: AppModel) async {
        guard await signedInAndSyncing(model) else { return }
        let arrived = await wait(90) { model.lists.contains { $0.shoppingList.name == listName } }
        step("list arrived on the other phone", arrived, model.lists.map(\.shoppingList.name).joined(separator: ", "))
        guard let list = model.lists.first(where: { $0.shoppingList.name == listName })?.shoppingList else { return }
        let items = model.items(list.id)
        step("items arrived", Set(items.map(\.itemName)) == ["Milk", "Bread", "Eggs"], items.map(\.itemName).joined(separator: ", "))
        step("store arrived", list.storeId.flatMap { id in model.stores.first { $0.id == id }?.name } == "Supermarket", "")
        // Tick Bread here (the first phone changes its price meanwhile), add an item, delete Eggs
        if var bread = items.first(where: { $0.itemName == "Bread" }) {
            bread.purchased = true
            model.perform { try model.repo.updateShoppingItem(bread) }
        }
        model.perform { try model.repo.insertShoppingItem(ShoppingItem(listId: list.id, itemName: "From the other phone", estimatedPrice: 2.5, orderIndex: 3)) }
        if let eggs = items.first(where: { $0.itemName == "Eggs" }) { model.perform { try model.repo.deleteShoppingItem(eggs) } }
        let uploaded = await wait(60) { model.cloud.syncStatus.waiting == 0 && model.cloud.syncStatus.state == .synced }
        step("member changes uploaded", uploaded, "\(model.cloud.syncStatus)")
    }

    private static func owner2(_ model: AppModel) async {
        let cloud = model.cloud
        let signed = await wait(20) { cloud.user != nil }
        step("still signed in", signed, cloud.user?.uid ?? "")
        // Change Bread's price while the other phone has ticked it: both changes must survive
        guard let list = model.lists.first(where: { $0.shoppingList.name == listName })?.shoppingList else { step("list still here", false); return }
        let seen = await wait(90) { model.items(list.id).contains { $0.itemName == "From the other phone" } }
        step("other phone's item arrived", seen, model.items(list.id).map(\.itemName).joined(separator: ", "))
        let eggsGone = await wait(30) { !model.items(list.id).contains { $0.itemName == "Eggs" } }
        step("delete reached this phone", eggsGone, "")
        if var bread = model.items(list.id).first(where: { $0.itemName == "Bread" }) {
            step("tick reached this phone", bread.purchased, "")
            bread.actualPrice = 1.1
            model.perform { try model.repo.updateShoppingItem(bread) }
        }
        let uploaded = await wait(60) { cloud.syncStatus.waiting == 0 && cloud.syncStatus.state == .synced }
        step("price change uploaded", uploaded, "\(cloud.syncStatus)")
        let bread = model.items(list.id).first { $0.itemName == "Bread" }
        step("both edits kept", bread?.purchased == true && bread?.actualPrice == 1.1, "\(String(describing: bread))")
        facts["breadUid"] = bread?.uid ?? ""
    }
}
#endif
