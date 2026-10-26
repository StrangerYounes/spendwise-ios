import PhotosUI
import SwiftUI
import SpendWiseCore

/// Quick add (FEATURES.md §5.1, §5.2): talk, type or snap a receipt; check the review and save.
/// Closes only with its ✕; what's in it is kept while open.
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let start: QuickAddStart
    let saved: (Int, Bool) -> Void
    let dismiss: () -> Void

    @State private var qa: QuickAddModel?
    @State private var consentPending: (() -> Void)?
    @State private var cameraOpen = false
    @State private var galleryItems: [PhotosPickerItem] = []
    @State private var galleryOpen = false
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar { close() }
            if let qa {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content(qa) }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                        .readableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Palette.containerLow.ignoresSafeArea())
        .consentGate($consentPending)
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker { image in
                cameraOpen = false
                if let image, let photo = ReceiptPhoto.make(image) { qa?.addPhotos([photo]) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $galleryOpen, selection: $galleryItems, maxSelectionCount: max(1, ReceiptReader.maxPhotos - draftCount), matching: .images)
        .onChange(of: galleryItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var photos: [ReceiptPhoto] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let p = ReceiptPhoto.make(data) { photos.append(p) }
                }
                galleryItems = []
                qa?.addPhotos(photos)
            }
        }
        .onAppear {
            if qa == nil { qa = QuickAddModel(model: model) }
            guard !started, let qa else { return }
            started = true
            Task { await model.cloud.ai.refreshAllowances() }
            #if DEBUG
            if DemoMode.prepareQuickAdd(qa, model) { return }
            #endif
            switch start {
            case .record: record { qa.startRecording() }
            case .camera: if receipts { takePhoto() }
            case .nothing: break
            }
        }
    }

    private var receipts: Bool { model.cloud.tier.hasAiExtras }

    private var draftCount: Int {
        if case .draft(let d) = qa?.state { return d.photos.count }
        return 0
    }

    private func close() {
        if let qa {
            switch qa.state {
            case .recording: qa.cancelRecording()
            case .draft(let d) where d.recordingSince != nil: qa.cancelNoteRecording()
            case .review(let r) where r.recordingSince != nil: qa.cancelFixRecording()
            default: break
            }
        }
        dismiss()
    }

    /// Every AI action asks for consent first (once).
    private func withAi(_ action: @escaping () -> Void) {
        if model.consentGranted { action() } else { consentPending = action }
    }

    /// The microphone, after consent and permission.
    private func record(_ begin: @escaping () -> Void) {
        withAi {
            Task {
                if await VoiceRecorder.permission() { begin() } else { model.show(L("mic_denied")) }
            }
        }
    }

    private func takePhoto() {
        withAi {
            if CameraPicker.available { cameraOpen = true } else { model.show(L("camera_unavailable")); galleryOpen = true }
        }
    }

    private func pickPhoto() { withAi { galleryOpen = true } }

    @ViewBuilder
    private func content(_ qa: QuickAddModel) -> some View {
        switch qa.state {
        case .input(let error):
            InputContent(qa: qa, error: error, receipts: receipts, record: { record { qa.startRecording() } }, takePhoto: takePhoto, pickPhoto: pickPhoto,
                         upgrade: { dismiss(); router.upgrade() }, send: { withAi { qa.parseText() } })
        case .recording(let since):
            RecordingContent(since: since, level: { qa.recorder.level() }, cancel: { qa.cancelRecording() }, done: { qa.stopRecordingAndParse() })
        case .draft(let draft):
            DraftContent(qa: qa, draft: draft, takePhoto: takePhoto, pickPhoto: pickPhoto, record: { record { qa.startNoteRecording() } })
        case .understanding(let source, let fixing):
            BusyContent(message: fixing ? L("fix_working") : source == .voice ? L("qa_listening_note") : source == .receipt ? L("qa_reading_receipt") : L("qa_sorting"))
        case .review(let review):
            ReviewContent(qa: qa, review: review,
                          // A receipt read on the phone (no AI receipts in this plan) can't be sent back
                          canFollowUp: review.source != .receipt || receipts,
                          sendFix: { withAi { qa.sendFix() } },
                          recordFix: { record { qa.startFixRecording() } }) {
                qa.save(saved)
            }
        case .saving:
            BusyContent(message: L("saving"))
        }
    }
}

/// The title and what to do, with an allowance chip on the side.
struct SheetTitle<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.titleL).foregroundStyle(Palette.onSurface)
                Spacer()
                trailing
            }
            Text(subtitle).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
        }
        .padding(.bottom, 16)
    }
}

extension SheetTitle where Trailing == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

private struct ErrorNote: View {
    let message: String
    var body: some View {
        Text(message).font(.bodyS).foregroundStyle(Palette.onErrorContainer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.errorContainer, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ActionTile: View {
    let icon: String
    let label: String
    let primary: Bool
    var locked = false
    var caption: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 30)).opacity(locked ? 0.4 : 1)
                Text(label).font(.titleS).opacity(locked ? 0.4 : 1).lineLimit(1).minimumScaleFactor(0.7)
                if locked { PremiumBadge() } else if let caption { Text(caption).font(.labelS).opacity(0.75) }
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .foregroundStyle(primary ? Palette.onPrimary : Palette.onSecondaryContainer)
            .background(primary ? Palette.primary : Palette.secondaryContainer, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

private struct InputContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var qa: QuickAddModel
    let error: String?
    let receipts: Bool
    let record: () -> Void
    let takePhoto: () -> Void
    let pickPhoto: () -> Void
    let upgrade: () -> Void
    let send: () -> Void

    var body: some View {
        SheetTitle(title: L("quick_add"), subtitle: L(receipts ? "qa_intro_receipts" : "qa_intro")) { AllowanceChip(feature: .quickAdd) }
        let receiptsLeft = receipts ? model.cloud.ai.current(.receipt)?.left : nil
        HStack(spacing: 12) {
            ActionTile(icon: "mic.fill", label: L("qa_talk"), primary: true, action: record).accessibilityIdentifier("talk")
            ActionTile(icon: "camera.fill", label: L("scan_receipt"), primary: false, locked: !receipts,
                       caption: receiptsLeft.map { $0 == 0 ? L("none_left_today") : L("left_today", $0) },
                       action: receipts ? takePhoto : upgrade)
        }
        HStack {
            Spacer()
            Button(action: receipts ? pickPhoto : upgrade) { Label(L("receipt_from_gallery"), systemImage: "photo.on.rectangle").font(.labelL) }
                .foregroundStyle(Palette.primary).padding(.vertical, 10)
        }
        HStack(spacing: 12) {
            Rectangle().fill(Palette.outlineVariant).frame(height: 1)
            Text(L("or_type_it")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant).fixedSize()
            Rectangle().fill(Palette.outlineVariant).frame(height: 1)
        }
        .padding(.bottom, 12)
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L("qa_example", model.currency), text: $qa.text, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("quickAddText")
            Button(action: send) { Image(systemName: "paperplane.fill").font(.system(size: 18)) }
                .disabled(qa.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(Palette.primary)
                .accessibilityLabel(L("add"))
                .accessibilityIdentifier("quickAddSend")
        }
        .fieldStyle()
        if let error { ErrorNote(message: error).padding(.top, 12) }
    }
}

/// The listening view while a voice note records; also used to ask for an AI report.
struct RecordingContent: View {
    let since: Date
    let level: () -> Float
    var message: String = L("qa_listening_hint")
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            let pulse = 1 + CGFloat(level()) * 0.6
            VStack(spacing: 0) {
                SheetTitle(title: L("listening"), subtitle: message)
                ZStack {
                    Circle().fill(Palette.primary.opacity(0.2)).frame(width: 96, height: 96).scaleEffect(pulse)
                    Button(action: done) {
                        Image(systemName: "stop.fill").font(.system(size: 36)).foregroundStyle(Palette.onPrimary)
                            .frame(width: 88, height: 88).background(Palette.primary, in: Circle())
                    }
                    .accessibilityLabel(L("done"))
                }
                .frame(height: 150)
                Text(clock(seconds)).font(.titleM).frame(maxWidth: .infinity)
                HStack {
                    Button(L("cancel"), action: cancel).foregroundStyle(Palette.primary)
                    Spacer()
                    Button(action: done) { Label(L("done"), systemImage: "checkmark") }.buttonStyle(FilledButtonStyle(height: 44)).frame(maxWidth: 140)
                }
                .padding(.top, 16)
            }
        }
    }
}

struct BusyContent: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(Palette.primary)
            Text(message).font(.bodyL).multilineTextAlignment(.center).foregroundStyle(Palette.onSurface)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// A voice note being recorded inline: level dot, time, cancel and stop.
private struct InlineRecording: View {
    let since: Date
    let level: () -> Float
    let stopLabel: String
    let stop: () -> Void
    let cancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: since, by: 0.1)) { context in
            HStack(spacing: 8) {
                Circle().fill(Palette.error).frame(width: 10, height: 10).scaleEffect(1 + CGFloat(level()) * 0.8)
                Text(L("listening")).font(.titleS)
                Text(clock(Int(context.date.timeIntervalSince(since)))).font(.bodyM).frame(maxWidth: .infinity, alignment: .leading)
                Button(L("cancel"), action: cancel).font(.labelL)
                Button(action: stop) { Label(stopLabel, systemImage: "stop.fill") }.buttonStyle(TonalButtonStyle(height: 36))
            }
            .foregroundStyle(Palette.onPrimaryContainer)
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
            .card(Palette.primaryContainer)
        }
    }
}

/// The receipt before it's read: up to three photos, top to bottom, and a note typed or spoken.
private struct DraftContent: View {
    @Bindable var qa: QuickAddModel
    let draft: DraftState
    let takePhoto: () -> Void
    let pickPhoto: () -> Void
    let record: () -> Void

    var body: some View {
        SheetTitle(title: L("receipt_draft_title"), subtitle: L("receipt_draft_body")) { AllowanceChip(feature: .receipt) }
        let canAdd = draft.photos.count < ReceiptReader.maxPhotos
        HStack(spacing: 10) {
            ForEach(Array(draft.photos.enumerated()), id: \.element.id) { i, photo in
                ZStack {
                    Image(uiImage: photo.image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 150).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(L("receipt_photo_n", i + 1))
                    if draft.photos.count > 1 {
                        Text("\(i + 1)").font(.labelM).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                    }
                    Button { qa.removePhoto(photo) } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.onSecondaryContainer)
                            .frame(width: 30, height: 30).background(Palette.secondaryContainer, in: Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
                    .accessibilityLabel(L("remove_photo"))
                }
                .frame(maxWidth: .infinity)
            }
            if canAdd {
                Button(action: takePhoto) {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.badge.plus").font(.system(size: 26))
                        Text(L("receipt_add_photo")).font(.labelL).multilineTextAlignment(.center).padding(.horizontal, 8)
                    }
                    .foregroundStyle(Palette.onSecondaryContainer)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Palette.secondaryContainer, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            // Keeps one photo from stretching across the whole sheet
            ForEach(0..<max(0, ReceiptReader.maxPhotos - draft.photos.count - (canAdd ? 1 : 0)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
        if canAdd {
            HStack {
                Spacer()
                Button(action: pickPhoto) { Label(L("photo_from_gallery"), systemImage: "photo.on.rectangle").font(.labelL) }
                    .foregroundStyle(Palette.primary).padding(.vertical, 10)
            }
        } else {
            Spacer().frame(height: 12)
        }
        if let since = draft.recordingSince {
            InlineRecording(since: since, level: { qa.recorder.level() }, stopLabel: L("done"), stop: { qa.stopNoteRecording() }, cancel: { qa.cancelNoteRecording() })
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("receipt_note")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
                HStack(alignment: .top) {
                    TextField(L("receipt_note_hint"), text: $qa.note, axis: .vertical).lineLimit(2...4)
                    if draft.voiceSeconds == nil {
                        Button(action: record) { Image(systemName: "mic.fill") }.foregroundStyle(Palette.primary).accessibilityLabel(L("receipt_voice_note"))
                    }
                }
                .fieldStyle()
            }
            if let s = draft.voiceSeconds {
                Button { qa.deleteVoiceNote() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        Text(L("receipt_voice_attached", clock(s)))
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .font(.labelL).foregroundStyle(Palette.onSurfaceVariant)
                    .padding(.horizontal, 10).frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.outline))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityLabel(L("delete"))
            }
        }
        if let error = draft.error { ErrorNote(message: error).padding(.top, 12) }
        Button { qa.readReceipt() } label: { Label(L("receipt_read"), systemImage: "sparkles") }
            .buttonStyle(FilledButtonStyle(height: 48))
            .disabled(draft.recordingSince != nil)
            .padding(.top, 16)
            .accessibilityIdentifier("readReceipt")
        // What it uses: a receipt scan per photo, and a quick add for the note
        let scans = P("receipt_uses_scans", draft.photos.count)
        Text(!qa.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.voiceSeconds != nil ? L("receipt_uses_with_note", scans) : scans)
            .font(.labelM).foregroundStyle(Palette.onSurfaceVariant).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.top, 6)
        Button(L("cancel")) { qa.backToInput() }.foregroundStyle(Palette.primary).frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

/// "Check and save": the purchases as cards, the conversion, follow-ups, Save.
private struct ReviewContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var qa: QuickAddModel
    let review: ReviewState
    let canFollowUp: Bool
    let sendFix: () -> Void
    let recordFix: () -> Void
    let save: () -> Void
    @State private var editingRate = false

    var body: some View {
        let isReceipt = review.source == .receipt
        SheetTitle(title: L("check_and_save"), subtitle: L("tap_to_fix"))
        VStack(spacing: 12) {
            if let transcript = review.transcript {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 14)).accessibilityLabel(L("heard"))
                    Text("“\(transcript)”").font(.bodyM).italic().frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Palette.onSurfaceVariant)
                .padding(12)
                .card(Palette.containerHigh, radius: 16)
            }
            if let currency = review.conversion?.currency ?? review.needsRate {
                let needsRate = review.conversion == nil
                Button { editingRate = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text(review.conversion.map { L(isReceipt ? "conv_receipt" : "conv_some", currency, grouped(javaFixed($0.rate, 0)), model.currency) }
                             ?? L(isReceipt ? "conv_need_receipt" : "conv_need_some", currency, model.currency))
                            .font(.bodyM).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L(needsRate ? "set_rate" : "change")).font(.labelL).foregroundStyle(Palette.primary)
                    }
                    .foregroundStyle(needsRate ? Palette.onErrorContainer : Palette.onSurface)
                    .padding(12)
                    .card(needsRate ? Palette.errorContainer : Palette.containerHigh, radius: 16)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversion")
            }
            // Until a rate is set, prices given in the other currency show as given, in it
            let unconverted = review.needsRate.map { "\($0) " }
            ForEach(review.purchases) { p in
                PurchaseCard(qa: qa, purchase: p, canChooseBought: !isReceipt, unconvertedSymbol: unconverted)
            }
        }
        if canFollowUp {
            FollowUpBar(qa: qa, recordingSince: review.recordingSince, send: sendFix, record: recordFix).padding(.top, 12)
        }
        if let error = review.error { ErrorNote(message: error).padding(.top, 8) }
        Button(action: save) {
            Label(review.purchases.count == 1 ? L("save") : L("save_all", review.purchases.count), systemImage: "checkmark")
        }
        .buttonStyle(FilledButtonStyle(height: 48))
        .disabled(review.recordingSince != nil)
        .padding(.top, 16)
        .accessibilityIdentifier("saveQuickAdd")
        Button(L("start_over")) { qa.backToInput() }.foregroundStyle(Palette.primary).frame(maxWidth: .infinity).padding(.vertical, 8)
            .sheet(isPresented: $editingRate) {
                ReviewRateSheet(currency: review.conversion?.currency ?? review.needsRate ?? "", symbol: model.currency, initial: review.conversion?.rate,
                                convert: { qa.setConversionRate($0) }, keep: { qa.removeConversion() })
            }
    }
}

/// Under the review: ask the AI for changes, typed or spoken.
private struct FollowUpBar: View {
    @Bindable var qa: QuickAddModel
    let recordingSince: Date?
    let send: () -> Void
    let record: () -> Void
    var body: some View {
        if let since = recordingSince {
            InlineRecording(since: since, level: { qa.recorder.level() }, stopLabel: L("send"), stop: { qa.stopFixRecording() }, cancel: { qa.cancelFixRecording() })
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.primary)
                    TextField(L("fix_hint"), text: $qa.fixText, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("fixText")
                    if qa.fixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: record) { Image(systemName: "mic.fill") }.accessibilityLabel(L("fix_speak"))
                    } else {
                        Button(action: send) { Image(systemName: "paperplane.fill") }.accessibilityLabel(L("send")).accessibilityIdentifier("fixSend")
                    }
                }
                .foregroundStyle(Palette.primary)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Palette.containerLowest, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.outline))
                Text(L("fix_uses")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).padding(.leading, 16)
            }
        }
    }
}

private struct ReviewRateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currency: String
    let symbol: String
    let initial: Double?
    let convert: (Double) -> Void
    let keep: () -> Void
    @State private var text = ""

    var body: some View {
        let rate = parseRate(text).flatMap { $0 > 0 ? $0 : nil }
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("rate_question", currency, symbol)).font(.bodyM)
                LabeledField(title: L("rate_label", currency, symbol), text: Binding(get: { text }, set: { text = String($0.filter { $0.isNumber || $0 == "." || $0 == "," }) }),
                             keyboard: .decimalPad, autofocus: true)
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("conversion_rate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("dont_convert")) { keep(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("convert")) { if let rate { convert(rate) }; dismiss() }.disabled(rate == nil) }
            }
        }
        .presentationDetents([.medium])
        .onAppear { text = initial.map(formatRate) ?? "" }
    }
}

/// One purchase: list name and total, Bought / To buy, category, store, date, target list, items.
private struct PurchaseCard: View {
    @Environment(AppModel.self) private var model
    @Bindable var qa: QuickAddModel
    let purchase: QuickPurchase
    let canChooseBought: Bool
    let unconvertedSymbol: String?
    @State private var editingName = false
    @State private var editingStore = false
    @State private var pickingDate = false
    @State private var fieldText = ""
    @State private var editingItem: QuickItem?

    private func symbol(_ item: QuickItem) -> String { (unconvertedSymbol != nil && item.otherCurrency) ? unconvertedSymbol! : model.currency }

    var body: some View {
        let existing = purchase.existingListId != nil
        let categories = model.categories
        let existingCategory = categories.first { $0.name.lowercased() == (purchase.categoryName ?? "Groceries").lowercased() }
        let label = purchase.categoryName ?? "Groceries"
        let openLists = qa.openLists
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if existing { Image(systemName: "text.badge.plus").foregroundStyle(Palette.primary) }
                Button { if !existing { fieldText = purchase.listName; editingName = true } } label: {
                    Text(existing ? L("add_to_list_named", purchase.listName) : purchase.listName).font(.titleM).foregroundStyle(Palette.onSurface).lineLimit(1)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A total mixing unconverted prices with converted ones would mean nothing
                let symbols = Set(purchase.items.filter { $0.unitPrice != nil }.map(symbol))
                if symbols.count == 1 { Text(formatMoney(symbols.first!, purchase.total)).font(.titleM).foregroundStyle(Palette.onSurface) }
                Button { qa.removePurchase(purchase.id) } label: { Image(systemName: "xmark").foregroundStyle(Palette.onSurfaceVariant).frame(width: 36, height: 36) }
                    .accessibilityLabel(L("remove_named", purchase.listName))
            }
            if canChooseBought {
                Picker("", selection: Binding(get: { purchase.bought }, set: { var p = purchase; p.bought = $0; qa.updatePurchase(p) })) {
                    Text(L("bought")).tag(true)
                    Text(L("to_buy")).tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.trailing, 12)
            }
            FlowLayout(spacing: 8) {
                if !existing {
                    Menu {
                        if existingCategory == nil { Button(L("category_new", label)) {} }
                        ForEach(categories.sorted { ($0.name != "Groceries" ? 1 : 0) < ($1.name != "Groceries" ? 1 : 0) }) { c in
                            Button(categoryLabel(c.name)) { var p = purchase; p.categoryName = c.name == "Groceries" ? nil : c.name; qa.updatePurchase(p) }
                        }
                    } label: {
                        chip(nil, existingCategory == nil ? L("category_new", label) : categoryLabel(label), dot: Color(argb: existingCategory?.color ?? AppDatabase.groceriesColor))
                    }
                    Button { fieldText = purchase.storeName ?? ""; editingStore = true } label: { chip("storefront", purchase.storeName ?? L("add_store")) }
                        .buttonStyle(.plain)
                    Button { pickingDate = true } label: { chip("calendar", Dates.format(purchase.date, "EEEMMMd")) }.buttonStyle(.plain)
                }
                if !openLists.isEmpty || existing {
                    Menu {
                        Button { qa.setTarget(purchase.id, nil) } label: { Label(L("new_list"), systemImage: "plus") }
                        ForEach(openLists, id: \.id) { list in
                            Button { qa.setTarget(purchase.id, list) } label: {
                                if list.id == purchase.existingListId { Label(list.name, systemImage: "checkmark") } else { Text(list.name) }
                            }
                        }
                    } label: { chip("text.badge.plus", L(existing ? "change_list" : "add_to_a_list")) }
                }
            }
            .padding(.trailing, 12)
            ForEach(purchase.items) { item in
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.bodyL).foregroundStyle(Palette.onSurface)
                        let details = itemDetails(item, existing: existing)
                        if !details.isEmpty {
                            Text(details).font(.bodyS).foregroundStyle(item.unitPrice == nil ? Palette.error : Palette.onSurfaceVariant)
                        }
                        if let count = item.packOf {
                            HStack(spacing: 4) {
                                Button { qa.acceptPack(purchase.id, item) } label: {
                                    // Two lines when needed: the whole sentence says what accepting does
                                    Label(L("pack_of", count), systemImage: "shippingbox").font(.labelL)
                                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 32)
                                        .foregroundStyle(Palette.onTertiaryContainer)
                                        .background(Palette.tertiaryContainer, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                Button { qa.dismissPack(purchase.id, item) } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 32, height: 32) }
                                    .accessibilityLabel(L("pack_not"))
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingItem = item }
                    if let total = item.total { Text(formatMoney(symbol(item), total)).font(.titleS).foregroundStyle(Palette.onSurface) }
                    Button { qa.removeItem(purchase.id, item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Palette.onSurfaceVariant).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(L("remove_named", item.name))
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.leading, 16).padding(.trailing, 4).padding(.top, 8).padding(.bottom, 12)
        .card(Palette.containerHighest)
        .alert(L("list_name"), isPresented: $editingName) {
            TextField("", text: $fieldText)
            Button(L("ok")) { let t = fieldText.trimmingCharacters(in: .whitespaces); if !t.isEmpty { var p = purchase; p.listName = t; qa.updatePurchase(p) } }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("store"), isPresented: $editingStore) {
            TextField("", text: $fieldText)
            Button(L("ok")) { let t = fieldText.trimmingCharacters(in: .whitespaces); var p = purchase; p.storeName = t.isEmpty ? nil : t; qa.updatePurchase(p) }
            Button(L("cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $pickingDate) {
            PurchaseDateSheet(date: purchase.date) { var p = purchase; p.date = $0; qa.updatePurchase(p) }
        }
        .sheet(item: $editingItem) { item in
            QuickItemSheet(item: item, names: qa.itemNames, currency: symbol(item)) { qa.updateItem(purchase.id, $0) }
        }
    }

    private func chip(_ icon: String?, _ text: String, dot: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let dot { ColorDot(color: dot, size: 10) }
            if let icon { Image(systemName: icon).font(.system(size: 13)) }
            Text(text).font(.labelL).lineLimit(1)
        }
        .foregroundStyle(Palette.onSurface)
        .padding(.horizontal, 10).frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.outline))
    }

    private func itemDetails(_ item: QuickItem, existing: Bool) -> String {
        var parts: [String] = []
        if item.quantity != 1 || item.unit != nil { parts.append(formatQuantity(item.quantity) + (item.unit.map { " \($0)" } ?? "")) }
        if let p = item.unitPrice, item.quantity != 1 { parts.append(formatUnitPrice(symbol(item), p) + (item.unit.map { "/\($0)" } ?? L("each_suffix"))) }
        if item.priceFromHistory { parts.append(L("last_price")) }
        if existing, let m = item.matchedListItem { parts.append(L("ticks_off", m)) }
        // Only spending needs a price; a list to shop from can fill it in later
        if item.unitPrice == nil && purchase.bought { parts.append(L("no_price_tap")) }
        return parts.joined(separator: " · ")
    }
}

/// A purchase's day: today or earlier, stored at noon (now for today).
private struct PurchaseDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let date: Millis
    let pick: (Millis) -> Void
    @State private var day = Date()
    var body: some View {
        NavigationStack {
            DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("ok")) {
                            let cal = Calendar.current
                            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
                            let now = Date()
                            pick(cal.isDateInToday(noon) || noon > now ? now.millis : noon.millis)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .onAppear { day = Date(millis: date) }
    }
}

/// An item of the review: name (with names already in use), quantity, unit, price each and total.
private struct QuickItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: QuickItem
    let names: [(String, Int)]
    let currency: String
    let save: (QuickItem) -> Void
    @State private var name = ""
    @State private var quantity = ""
    @State private var unit = ""
    @State private var price = ""
    @State private var total = ""
    @State private var loaded = false

    var body: some View {
        let suggestions = NameSuggestions.rank(name, names, limit: 5)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledField(title: L("item"), text: $name)
                    // Names already in use, so the item joins its history instead of starting a new one
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { name = s } label: {
                                    Label(s, systemImage: "clock.arrow.circlepath").font(.labelL).lineLimit(1)
                                        .padding(.horizontal, 10).frame(height: 32)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.outline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        LabeledField(title: L("qty"), text: Binding(get: { quantity }, set: { v in
                            quantity = v
                            // Keep the total, recompute the unit price
                            if let q = parseDecimal(v), q > 0, let t = parseAmount(total) { price = formatPriceInput(Double(javaRound(t / q * 1000)) / 1000) }
                        }), keyboard: .decimalPad)
                        LabeledField(title: L("unit"), text: $unit, placeholder: L("unit_hint2"))
                    }
                    HStack(alignment: .top, spacing: 8) {
                        AmountField(title: L("price_each"), text: Binding(get: { price }, set: { v in
                            price = v
                            // While a sum is half typed ("4.2/"), the total waits for it
                            let p = parseAmount(v)
                            let q = parseDecimal(quantity) ?? 1
                            if p != nil || v.trimmingCharacters(in: .whitespaces).isEmpty { total = p.map { formatPriceInput(Double(javaRound($0 * q * 100)) / 100) } ?? "" }
                        }), currency: currency)
                        AmountField(title: L("total"), text: Binding(get: { total }, set: { v in
                            total = v
                            let t = parseAmount(v)
                            let q = parseDecimal(quantity).flatMap { $0 > 0 ? $0 : nil } ?? 1
                            if t != nil || v.trimmingCharacters(in: .whitespaces).isEmpty { price = t.map { formatPriceInput(Double(javaRound($0 / q * 1000)) / 1000) } ?? "" }
                        }), currency: currency)
                    }
                }
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("edit_item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("ok")) {
                        let q = parseDecimal(quantity).flatMap { $0 > 0 ? $0 : nil } ?? item.quantity
                        var edited = item
                        edited.name = name.trimmingCharacters(in: .whitespaces)
                        edited.quantity = q
                        let u = unit.trimmingCharacters(in: .whitespaces)
                        edited.unit = u.isEmpty ? nil : u
                        // The total is what was paid; the price each is rounded for display
                        edited.unitPrice = parseAmount(total).map { $0 / q } ?? parseAmount(price)
                        // Still the remembered price unless it was changed
                        let unchanged = edited.unitPrice != nil && item.unitPrice != nil && abs(edited.unitPrice! - item.unitPrice!) < 0.005
                        edited.priceFromHistory = item.priceFromHistory && unchanged
                        save(edited)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = item.name
            quantity = formatQuantity(item.quantity)
            unit = item.unit ?? ""
            price = formatPriceInput(item.unitPrice)
            total = formatPriceInput(item.total)
        }
    }
}
