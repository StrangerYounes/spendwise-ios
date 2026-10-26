import Foundation
import Observation
import SpendWiseCore

enum QuickAddSource { case text, voice, receipt }

/// Receipt prices were converted from [currency] at [rate] receipt units per app unit.
struct Conversion: Equatable { var currency: String; var rate: Double }

/// The review of what the AI understood.
struct ReviewState: Equatable {
    var purchases: [QuickPurchase]
    var transcript: String?
    var source: QuickAddSource = .text
    var conversion: Conversion? = nil
    /** A receipt (or prices) in another currency with no rate saved yet; prices are as given. */
    var needsRate: String? = nil
    /** The currency the receipt was read in, sent back with a follow-up. */
    var scanCurrency: String? = nil
    /** A voice note asking for changes is being recorded. */
    var recordingSince: Date? = nil
    /** Why the last follow-up didn't work; the review is as it was. */
    var error: String? = nil
}

/// Photos of one receipt (up to three) and an optional note for the AI.
struct DraftState: Equatable {
    var photos: [ReceiptPhoto]
    var voiceSeconds: Int? = nil
    var recordingSince: Date? = nil
    var error: String? = nil
}

enum QuickAddState: Equatable {
    /// Typing or about to record; [error] says why the last attempt didn't work.
    case input(error: String?)
    case recording(since: Date)
    case draft(DraftState)
    /// [fixing]: a follow-up on the review is being made.
    case understanding(QuickAddSource, fixing: Bool)
    case review(ReviewState)
    case saving
}

/// Quick add (Android viewmodel/QuickAddViewModel.kt): typed or spoken purchases, receipt photos,
/// the review with conversions, pack hints and follow-ups, then saving.
@MainActor @Observable
final class QuickAddModel {
    private(set) var state: QuickAddState = .input(error: nil)
    /// What's typed; each is cut to maxText when sent (the backend's cap).
    var text = ""
    var note = ""
    var fixText = ""

    static let maxText = 1_000

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored let recorder: VoiceRecorder
    @ObservationIgnored private var draftAudio: Data?
    /// The receipt's photos as sent, so a follow-up can send them again.
    @ObservationIgnored private var receiptPhotos: [String] = []
    @ObservationIgnored private var receiptImages: [ReceiptPhoto] = []

    init(model: AppModel) {
        self.model = model
        recorder = VoiceRecorder()
    }

    func setState(_ s: QuickAddState) { state = s }

    private func capped(_ s: String) -> String { String(s.prefix(Self.maxText)) }

    private var currency: String { model.currency }
    private var savedRate: Double? { model.settings.savedRate }

    private func context() throws -> QuickAddContext {
        var c = try model.repo.quickAddContext(currencySymbol: currency)
        c.conversionRate = savedRate
        return c
    }

    // MARK: - Voice and text

    private func onMaxDuration() {
        switch state {
        case .recording: stopRecordingAndParse()
        case .draft(let d) where d.recordingSince != nil: stopNoteRecording()
        case .review(let r) where r.recordingSince != nil: stopFixRecording()
        default: break
        }
    }

    func startRecording() {
        do {
            try recorder.start { [weak self] in self?.onMaxDuration() }
            state = .recording(since: Date())
        } catch {
            state = .input(error: L("err_mic"))
        }
    }

    func cancelRecording() {
        recorder.cancel()
        state = .input(error: nil)
    }

    func stopRecordingAndParse() {
        guard case .recording = state else { return }
        guard let audio = recorder.stop() else { state = .input(error: L("qa_too_short")); return }
        understand(text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : capped(text), audio: audio)
    }

    func parseText() {
        let description = capped(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        understand(description, audio: nil)
    }

    private func quickAddPayload(_ text: String?, _ audio: Data?, _ c: QuickAddContext, previous: String? = nil) -> JSON {
        .object([
            ("text", .str(text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)),
            ("audio", .str(audio?.base64EncodedString())),
            // A follow-up: the review as it is now, which the words above change
            ("previous", .str(previous)),
            ("context", AiPayload.names(c)),
        ])
    }

    private func understand(_ description: String?, audio: Data?) {
        let source: QuickAddSource = audio != nil ? .voice : .text
        state = .understanding(source, fixing: false)
        Task {
            do {
                let c = try context()
                let json = try await model.cloud.ai.generate(.quickAdd, quickAddPayload(description, audio, c))
                let result = try QuickAddParser.parseResponse(json, c)
                if result.purchases.isEmpty {
                    state = .input(error: (result.transcript.map { L("qa_heard", $0) } ?? "") + L("qa_nothing_found"))
                } else {
                    state = .review(withPackHints(convertSpoken(ReviewState(purchases: withLastPrices(result.purchases), transcript: result.transcript, source: source),
                                                                result.otherCurrency)))
                }
            } catch let e as AiError {
                state = .input(error: e.message)
            } catch {
                state = .input(error: UserErrors.message(error, L("err_sort")))
            }
        }
    }

    // MARK: - The receipt draft

    /// Adds photos to the receipt being prepared (starting one), up to three.
    func addPhotos(_ photos: [ReceiptPhoto]) {
        guard !photos.isEmpty else { return }
        var draft: DraftState
        if case .draft(let d) = state { draft = d } else {
            draftAudio = nil
            note = ""
            draft = DraftState(photos: [])
        }
        draft.photos = Array((draft.photos + photos).prefix(ReceiptReader.maxPhotos))
        draft.error = nil
        state = .draft(draft)
    }

    func removePhoto(_ photo: ReceiptPhoto) {
        guard case .draft(var d) = state else { return }
        d.photos.removeAll { $0 == photo }
        state = d.photos.isEmpty ? .input(error: nil) : .draft(d)
    }

    func startNoteRecording() {
        guard case .draft(var d) = state else { return }
        do {
            try recorder.start { [weak self] in self?.onMaxDuration() }
            d.recordingSince = Date()
            d.error = nil
        } catch {
            d.error = L("err_mic")
        }
        state = .draft(d)
    }

    func stopNoteRecording() {
        guard case .draft(var d) = state, let since = d.recordingSince else { return }
        let audio = recorder.stop()
        draftAudio = audio ?? draftAudio
        d.recordingSince = nil
        if audio == nil { d.error = L("qa_too_short") } else { d.voiceSeconds = Int(Date().timeIntervalSince(since)) }
        state = .draft(d)
    }

    func cancelNoteRecording() {
        guard case .draft(var d) = state else { return }
        recorder.cancel()
        d.recordingSince = nil
        state = .draft(d)
    }

    func deleteVoiceNote() {
        guard case .draft(var d) = state else { return }
        draftAudio = nil
        d.voiceSeconds = nil
        state = .draft(d)
    }

    private func receiptPayload(_ photos: [String], _ note: String?, _ audio: Data?, _ c: QuickAddContext, previous: String? = nil) -> JSON {
        .object([
            ("images", .array(photos.map(JSON.string))),
            ("text", .str(note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)),
            ("audio", .str(audio?.base64EncodedString())),
            ("previous", .str(previous)),
            ("context", AiPayload.names(c)),
        ])
    }

    /// Reads the draft's photos with the AI and its note; on-device text recognition when the AI
    /// can't be reached (items only).
    func readReceipt() {
        guard case .draft(var draft) = state else { return }
        if draft.recordingSince != nil { stopNoteRecording(); if case .draft(let d) = state { draft = d } }
        let noteText = capped(note).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let audio = draftAudio
        state = .understanding(.receipt, fixing: false)
        Task {
            do {
                let c = try context()
                var aiError: String?
                var scan: ReceiptScan?
                do {
                    receiptImages = draft.photos
                    receiptPhotos = draft.photos.map { $0.jpeg.base64EncodedString() }
                    let json = try await model.cloud.ai.generate(.receipt, receiptPayload(receiptPhotos, noteText, audio, c))
                    scan = try ReceiptReader.parseResponse(json, c)
                } catch {
                    aiError = UserErrors.message(error, L("err_read_receipt"))
                }
                var result = scan
                if result?.purchase.items.isEmpty ?? true {
                    let items = await OnDeviceReceipt.items(from: draft.photos)
                    result = ReceiptScan(purchase: QuickPurchase(listName: L("receipt_list_name"), categoryName: nil, storeName: nil, date: c.now, items: items), currency: nil)
                }
                guard let result, !result.purchase.items.isEmpty else {
                    // Back to the draft, so the photos and the note aren't lost
                    draft.recordingSince = nil
                    draft.error = aiError ?? L("receipt_no_items")
                    state = .draft(draft)
                    return
                }
                state = .review(withPackHints(convertReceipt(result)))
            } catch {
                draft.recordingSince = nil
                draft.error = UserErrors.message(error, L("err_read_photo"))
                state = .draft(draft)
            }
        }
    }

    // MARK: - Follow-ups

    func startFixRecording() {
        guard case .review(var r) = state else { return }
        do {
            try recorder.start { [weak self] in self?.onMaxDuration() }
            r.recordingSince = Date()
            r.error = nil
        } catch {
            r.error = L("err_mic")
        }
        state = .review(r)
    }

    func cancelFixRecording() {
        guard case .review(var r) = state else { return }
        recorder.cancel()
        r.recordingSince = nil
        state = .review(r)
    }

    func stopFixRecording() {
        guard case .review(var r) = state, r.recordingSince != nil else { return }
        r.recordingSince = nil
        guard let audio = recorder.stop() else {
            r.error = L("qa_too_short")
            state = .review(r)
            return
        }
        followUp(r, capped(fixText).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank, audio)
    }

    func sendFix() {
        guard case .review(let r) = state else { return }
        let words = capped(fixText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        followUp(r, words, nil)
    }

    /// Sends the review as it is now and what to change; a receipt goes with its photos again.
    private func followUp(_ review: ReviewState, _ words: String?, _ audio: Data?) {
        let isReceipt = review.source == .receipt
        var shown = review
        shown.error = nil
        state = .understanding(review.source, fixing: true)
        Task {
            do {
                let c = try context()
                let sentCurrency = review.conversion?.currency ?? review.needsRate ?? review.scanCurrency
                var next: ReviewState?
                if isReceipt {
                    let previous = FollowUp.receipt(review.purchases[0], currency: sentCurrency, rate: review.conversion?.rate)
                    let json = try await model.cloud.ai.generate(.receipt, receiptPayload(receiptPhotos, words, audio, c, previous: previous))
                    let scan = try ReceiptReader.parseResponse(json, c)
                    if !scan.purchase.items.isEmpty {
                        var r = receiptAfterFix(scan, review, sentCurrency)
                        r.transcript = scan.transcript ?? review.transcript
                        next = r
                    }
                } else {
                    let previous = FollowUp.quickAdd(review.purchases, otherCurrency: review.conversion?.currency ?? review.needsRate, rate: review.conversion?.rate)
                    let json = try await model.cloud.ai.generate(.quickAdd, quickAddPayload(words, audio, c, previous: previous))
                    let result = try QuickAddParser.parseResponse(json, c)
                    if !result.purchases.isEmpty {
                        next = convertSpoken(ReviewState(purchases: withLastPrices(result.purchases), transcript: result.transcript ?? review.transcript,
                                                         source: review.source), result.otherCurrency)
                    }
                }
                if let next {
                    state = .review(withPackHints(next))
                    fixText = ""
                } else {
                    shown.error = L("fix_emptied")
                    state = .review(shown)
                }
            } catch {
                shown.error = UserErrors.message(error, L("err_ai_down"))
                state = .review(shown)
            }
        }
    }

    /// A corrected receipt keeps the conversion it had, unless the follow-up changed the currency.
    private func receiptAfterFix(_ scan: ReceiptScan, _ review: ReviewState, _ sentCurrency: String?) -> ReviewState {
        let sameCurrency = scan.currency == nil || sentCurrency == nil || scan.currency!.lowercased() == sentCurrency!.lowercased()
        let converted = review.conversion != nil || review.needsRate != nil
        if !sameCurrency || !converted { return convertReceipt(scan) }
        var flagged = scan.purchase
        flagged.items = flagged.items.map { var i = $0; i.otherCurrency = true; return i }
        var base = ReviewState(purchases: [flagged], transcript: nil, source: .receipt, scanCurrency: scan.currency ?? review.scanCurrency)
        guard let conversion = review.conversion else { base.needsRate = review.needsRate; return base }
        base.purchases = base.purchases.map { $0.scalingPrices(1 / conversion.rate) }
        base.conversion = conversion
        return base
    }

    // MARK: - Currencies

    /// Prices said in another currency ("bread for 80,000") use the saved rate, or ask for one.
    private func convertSpoken(_ review: ReviewState, _ currency: String?) -> ReviewState {
        guard let currency, review.purchases.contains(where: { $0.items.contains(where: \.otherCurrency) }) else { return review }
        var r = review
        guard let rate = savedRate else { r.needsRate = currency; return r }
        r.purchases = r.purchases.map { $0.scalingPrices(1 / rate) }
        r.conversion = Conversion(currency: currency, rate: rate)
        return r
    }

    /// A receipt in another currency: converted with the last rate used, or asks for one.
    private func convertReceipt(_ scan: ReceiptScan) -> ReviewState {
        let base = ReviewState(purchases: [scan.purchase], transcript: scan.transcript, source: .receipt, scanCurrency: scan.currency)
        let inAppCurrency = scan.currency == nil || QuickAddParser.sameCurrency(scan.currency!, currency)
        // A misread currency: with a saved rate of 89,500, prices in the tens of thousands can't be the app's
        let prices = scan.purchase.items.compactMap(\.unitPrice).sorted()
        let median = prices.isEmpty ? nil : prices[prices.count / 2]
        let tooBig = savedRate != nil && median != nil && median! >= savedRate! / 100
        if inAppCurrency && !tooBig { return base }
        var flagged = base
        flagged.purchases = base.purchases.map { p in var q = p; q.items = p.items.map { var i = $0; i.otherCurrency = true; return i }; return q }
        let receiptCurrency = inAppCurrency ? L("receipt_currency") : (scan.currency ?? L("receipt_currency"))
        guard let rate = savedRate else { flagged.needsRate = receiptCurrency; return flagged }
        flagged.purchases = flagged.purchases.map { $0.scalingPrices(1 / rate) }
        flagged.conversion = Conversion(currency: receiptCurrency, rate: rate)
        return flagged
    }

    /// Sets the rate and remembers it; prices are rescaled from the current rate so edits stay.
    func setConversionRate(_ rate: Double) {
        guard case .review(var r) = state, let currency = r.conversion?.currency ?? r.needsRate, rate > 0 else { return }
        let old = r.conversion?.rate ?? 1
        r.purchases = r.purchases.map { $0.scalingPrices(old / rate) }
        r.conversion = Conversion(currency: currency, rate: rate)
        r.needsRate = nil
        model.updateSettings { $0.lastConversionRate = rate }
        // Converted prices can now be compared with what was paid before
        state = .review(withPackHints(r))
    }

    /// Keeps the other-currency prices as given.
    func removeConversion() {
        guard case .review(var r) = state else { return }
        if let c = r.conversion { r.purchases = r.purchases.map { $0.scalingPrices(c.rate) } }
        r.conversion = nil
        r.needsRate = nil
        state = .review(r)
    }

    // MARK: - Last prices and pack hints

    /// Items with no price said get the last price paid for them, marked as such.
    private func withLastPrices(_ purchases: [QuickPurchase]) -> [QuickPurchase] {
        let missing = purchases.flatMap { $0.items.filter { $0.unitPrice == nil }.map(\.name) }
        if missing.isEmpty { return purchases }
        let prices = (try? model.repo.lastPrices(missing)) ?? [:]
        return purchases.map { p in
            var q = p
            q.items = p.items.map { item in
                guard item.unitPrice == nil, let last = prices[item.name] else { return item }
                var i = item
                i.unitPrice = last
                i.priceFromHistory = true
                return i
            }
            return q
        }
    }

    /// Single items priced near a whole multiple of the last price for one: maybe a pack.
    private func withPackHints(_ review: ReviewState) -> ReviewState {
        let unconverted = review.needsRate != nil
        let candidates = review.purchases.flatMap { p in
            p.items.filter { $0.quantity == 1 && $0.unit == nil && $0.unitPrice != nil && !$0.priceFromHistory && !(unconverted && $0.otherCurrency) }
        }
        if candidates.isEmpty { return review }
        let ids = Set(candidates.map(\.id))
        let last = (try? model.repo.lastPrices(candidates.map(\.name))) ?? [:]
        var r = review
        r.purchases = review.purchases.map { p in
            var q = p
            q.items = p.items.map { item in
                guard ids.contains(item.id), let price = last[item.name] else { return item }
                var i = item
                i.packOf = PackHint.guess(item.unitPrice!, price)
                return i
            }
            return q
        }
        return r
    }

    /// Counts a hinted pack as that many items, at the same total.
    func acceptPack(_ purchaseId: String, _ item: QuickItem) {
        guard let count = item.packOf else { return }
        var i = item
        i.quantity = item.quantity * Double(count)
        i.unitPrice = item.unitPrice.map { $0 / Double(count) }
        i.packOf = nil
        updateItem(purchaseId, i)
    }

    func dismissPack(_ purchaseId: String, _ item: QuickItem) {
        var i = item
        i.packOf = nil
        updateItem(purchaseId, i)
    }

    // MARK: - Review edits

    private func updateReview(_ transform: ([QuickPurchase]) -> [QuickPurchase]) {
        guard case .review(var r) = state else { return }
        let updated = transform(r.purchases).filter { !$0.items.isEmpty }
        if updated.isEmpty { backToInput(); return }
        r.purchases = updated
        state = .review(r)
    }

    func updatePurchase(_ purchase: QuickPurchase) { updateReview { $0.map { $0.id == purchase.id ? purchase : $0 } } }

    func removePurchase(_ id: String) { updateReview { $0.filter { $0.id != id } } }

    func updateItem(_ purchaseId: String, _ item: QuickItem) {
        updateReview { list in
            list.map { p in
                guard p.id == purchaseId else { return p }
                var q = p
                q.items = p.items.map { $0.id == item.id ? item : $0 }
                return q
            }
        }
    }

    func removeItem(_ purchaseId: String, _ itemId: String) {
        updateReview { list in
            list.map { p in
                guard p.id == purchaseId else { return p }
                var q = p
                q.items = p.items.filter { $0.id != itemId }
                return q
            }
        }
    }

    func setTarget(_ purchaseId: String, _ list: OpenList?) {
        updateReview { purchases in
            purchases.map { p in
                guard p.id == purchaseId else { return p }
                var q = p
                if let list { q.existingListId = list.id; q.listName = list.name } else { q.existingListId = nil }
                return q
            }
        }
    }

    func backToInput() {
        recorder.cancel()
        clearReceipt()
        state = .input(error: nil)
    }

    private func clearReceipt() {
        receiptPhotos = []
        receiptImages = []
        draftAudio = nil
        note = ""
        fixText = ""
    }

    /// Saves every purchase; [saved] gets how many and whether all went to completed lists.
    func save(_ saved: @escaping (Int, Bool) -> Void) {
        guard case .review(let r) = state else { return }
        state = .saving
        do {
            try model.repo.saveQuickPurchases(r.purchases)
            text = ""
            clearReceipt()
            state = .input(error: nil)
            saved(r.purchases.count, r.purchases.allSatisfy { $0.bought && $0.existingListId == nil })
        } catch {
            state = .review(r)
            model.show(UserErrors.message(error, L("err_save")))
        }
    }

    /// Unfinished lists a purchase can go into.
    var openLists: [OpenList] {
        model.lists.filter { !$0.shoppingList.isCompleted }.map { OpenList(id: $0.shoppingList.id, name: $0.shoppingList.name) }
    }

    /// Every item name used so far with how often it was bought, for name suggestions.
    var itemNames: [(String, Int)] {
        model.itemSummaries.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.purchaseCount) }
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
