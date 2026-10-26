import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SpendWiseCore

let commonCurrencies = ["$", "€", "£", "¥", "₹", "Rp", "₺", "CHF", "kr", "zł"]

/// Settings (FEATURES.md §4.7, §4.9, §5.00, §6): appearance and language, sync and family, the AI,
/// your data, about, and (debug builds) the Developer section.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var currencyOpen = false
    @State private var rateOpen = false
    @State private var languageOpen = false
    @State private var exportOpen = false
    @State private var exportDoc: BackupDocument?
    @State private var importing = false
    @State private var restoring = false
    @State private var versionTaps = 0
    @State private var consentAsk = false

    var body: some View {
        let s = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: L("appearance")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("theme")).font(.bodyL).foregroundStyle(Palette.onSurface)
                        Picker("", selection: Binding(get: { s.darkTheme }, set: { v in model.updateSettings { $0.darkTheme = v } })) {
                            Text(L("theme_system")).tag(Bool?.none)
                            Text(L("theme_light")).tag(Bool?.some(false))
                            Text(L("theme_dark")).tag(Bool?.some(true))
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(16)
                    SettingsRow(icon: "banknote", title: L("currency"), subtitle: model.currency) { currencyOpen = true }
                    SettingsRow(icon: "arrow.left.arrow.right", title: L("local_rate"),
                                subtitle: s.savedRate.map { L("local_rate_set", model.currency, formatRate($0)) } ?? L("local_rate_unset")) { rateOpen = true }
                    SettingsRow(icon: "globe", title: L("language"), subtitle: languageName(model.language)) { languageOpen = true }
                }

                AccountSection()

                SettingsSection(title: L("ai_features")) {
                    Toggle(isOn: Binding(get: { model.consentGranted }, set: { on in
                        // Turning it on asks the same question as the first AI use
                        if on { consentAsk = true } else { model.setConsent(false) }
                    })) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "sparkles").foregroundStyle(Palette.primary).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("use_ai")).font(.bodyL).foregroundStyle(Palette.onSurface)
                                Text(L(model.consentGranted ? "use_ai_on" : "use_ai_off")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                            }
                        }
                    }
                    .tint(Palette.primary)
                    .padding(16)
                    .accessibilityIdentifier("useAi")
                    if model.consentGranted { AllowanceOverview().task { await model.cloud.ai.refreshAllowances() } }
                    SettingsRow(icon: "square.and.pencil", title: L("ai_instructions"), subtitle: L("ai_instructions_sub")) { router.open(.aiInstructions) }
                }

                SettingsSection(title: L("your_data")) {
                    SettingsRow(icon: "shippingbox", title: L("items"), subtitle: L("items_sub")) { router.open(.library) }
                    SettingsRow(icon: "square.and.arrow.up", title: L("back_up"), subtitle: L("back_up_sub")) { exportOpen = true }
                    SettingsRow(icon: "square.and.arrow.down", title: L("restore"), subtitle: L("restore_sub"), trailing: restoring ? .progress : .chevron) { importing = true }
                }

                SettingsSection(title: L("about")) {
                    SettingsRow(icon: "hand.raised", title: L("privacy_policy"), subtitle: L("privacy_policy_sub"), trailing: .external) {
                        UIApplication.shared.open(Links.privacy)
                    }
                    SettingsRow(icon: "person.crop.circle.badge.xmark", title: L("deleting_data"), subtitle: L("deleting_data_sub"), trailing: .external) {
                        UIApplication.shared.open(Links.deleteAccount)
                    }
                    SettingsRow(icon: "envelope", title: L("contact"), subtitle: Links.contactEmail, trailing: .none) {
                        if let url = URL(string: "mailto:\(Links.contactEmail)?subject=SpendWise") { UIApplication.shared.open(url) }
                    }
                }

                #if DEBUG
                if model.devOptionsShown || model.cloud.usingEmulators { DeveloperSection() }
                #endif

                // Debug builds: tapping it 7 times shows or hides the Developer section
                Text("SpendWise \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity).padding(.top, 16)
                    .onTapGesture {
                        #if DEBUG
                        versionTaps += 1
                        if versionTaps >= 7 {
                            versionTaps = 0
                            model.show(model.toggleDevOptions() ? "Developer options shown" : "Developer options hidden")
                        }
                        #endif
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .readableWidth()
        }
        .screen(L("settings"))
        .sheet(isPresented: $currencyOpen) { CurrencySheet(current: model.currency) { symbol in model.updateSettings { $0.currencySymbol = symbol.trimmingCharacters(in: .whitespaces) } } }
        .sheet(isPresented: $rateOpen) { RateSheet(currency: model.currency, current: s.savedRate) { model.setConversionRate($0) } }
        .confirmationDialog(L("language"), isPresented: $languageOpen, titleVisibility: .visible) {
            ForEach(Lang.Choice.allCases, id: \.self) { c in
                Button(languageName(c) + (c == model.language ? " ✓" : "")) { model.setLanguage(c) }
            }
            Button(L("close"), role: .cancel) {}
        } message: { Text(L("language_ios_note")) }
        .confirmationDialog(L("back_up"), isPresented: $exportOpen, titleVisibility: .visible) {
            Button(L("backup_everything")) { export(itemsOnly: false) }
            Button(L("backup_library")) { export(itemsOnly: true) }
            Button(L("cancel"), role: .cancel) {}
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                      contentType: .json, defaultFilename: exportDoc?.name) { result in
            switch result {
            case .success: model.show(L("msg_backup_saved"))
            case .failure(let e): model.show(UserErrors.message(e, L("err_save_backup")))
            }
            exportDoc = nil
        }
        .background {
            Color.clear.fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in restore(result) }
        }
        .sheet(isPresented: $consentAsk) { ConsentSheet { model.setConsent(true) } }
        .onAppear {
            #if DEBUG
            DemoMode.openSettingsExtras(currency: $currencyOpen, rate: $rateOpen)
            #endif
        }
    }

    private func export(itemsOnly: Bool) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let stamp = f.string(from: Date())
        do {
            let text = try model.backup.exportData(itemsOnly: itemsOnly)
            exportDoc = BackupDocument(text: text, name: itemsOnly ? "spendwise_items_backup_\(stamp).json" : "spendwise_full_backup_\(stamp).json")
        } catch {
            model.show(UserErrors.message(error, L("err_make_backup")))
        }
    }

    private func restore(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): model.show(UserErrors.message(e, L("err_open_file")))
        case .success(let url):
            restoring = true
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } ; restoring = false }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return model.show(L("err_open_file")) }
            do {
                let summary = try model.backup.restoreData(text)
                model.refresh()
                model.show(summary.message)
            } catch {
                model.show(L("err_restore"))
            }
        }
    }
}

/// A backup to save with the system's file picker.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    var name: String
    init(text: String, name: String) { self.text = text; self.name = name }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
        name = "backup.json"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Each language in its own words, so it can be found whatever the app shows now.
func languageName(_ c: Lang.Choice) -> String {
    switch c {
    case .phone: return L("language_phone")
    case .en: return "English"
    case .ar: return "العربية"
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.titleS).foregroundStyle(Palette.primary).padding(.leading, 4).padding(.top, 12)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(Palette.containerLow)
        }
    }
}

enum RowTrailing { case chevron, external, none, progress, premium }

struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: RowTrailing = .chevron
    var tint: Color = Palette.primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bodyL).foregroundStyle(Palette.onSurface)
                    Text(subtitle).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch trailing {
                case .chevron: Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.onSurfaceVariant)
                case .external: Image(systemName: "arrow.up.forward.square").foregroundStyle(Palette.onSurfaceVariant)
                case .progress: ProgressView()
                case .premium: PremiumBadge()
                case .none: EmptyView()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The currency symbol: common ones, or any other (up to 4 characters).
struct CurrencySheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let select: (String) -> Void
    @State private var custom = ""
    @State private var editingCustom = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                FlowChips(items: commonCurrencies + [L("other")]) { label in
                    let isOther = label == L("other")
                    FilterChip(label: label, selected: isOther ? !commonCurrencies.contains(current) : label == current) {
                        if isOther { editingCustom = true } else { select(label); dismiss() }
                    }
                }
                if editingCustom {
                    LabeledField(title: L("symbol"), text: Binding(get: { custom }, set: { custom = String($0.prefix(4)) }), autofocus: true) {
                        if !custom.trimmingCharacters(in: .whitespaces).isEmpty { select(custom); dismiss() }
                    }
                }
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("currency_symbol"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } }
                if editingCustom {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("use")) { select(custom); dismiss() }.disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { custom = commonCurrencies.contains(current) ? "" : current }
    }
}

/// Chips that wrap onto new lines.
struct FlowChips<Content: View>: View {
    let items: [String]
    @ViewBuilder let chip: (String) -> Content
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items, id: \.self) { chip($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// "1 $ = 89,500": the local currency's rate; commas are thousands here.
struct RateField: View {
    @Binding var text: String
    let currency: String
    let ok: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("local_rate_label", currency)).font(.labelM).foregroundStyle(ok ? Palette.onSurfaceVariant : Palette.error)
            HStack(spacing: 4) {
                Text("1\u{00A0}\(currency) = ").foregroundStyle(Palette.onSurfaceVariant)
                TextField("89,500", text: Binding(get: { text }, set: { text = String($0.filter { $0.isNumber || ".,٫٬".contains($0) }.prefix(12)) }))
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("rateField")
            }
            .environment(\.layoutDirection, .leftToRight)
            .fieldStyle(error: !ok)
            if !ok { Text(L("local_rate_too_small", currency)).font(.bodyS).foregroundStyle(Palette.error) }
        }
    }
}

/// Sets or clears the local currency's rate.
struct RateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currency: String
    let current: Double?
    let save: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        let rate = parseRate(text)
        let ok = text.trimmingCharacters(in: .whitespaces).isEmpty || (rate ?? 0) > 1
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("local_rate_dialog", currency)).font(.bodyM).foregroundStyle(Palette.onSurface)
                RateField(text: $text, currency: currency, ok: ok)
                Spacer()
            }
            .padding(20)
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("local_rate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if current != nil { Button(L("clear")) { save(nil); dismiss() } } else { Button(L("cancel")) { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) { save(rate); dismiss() }.disabled(!ok || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { text = current.map(formatRate) ?? "" }
    }
}

// MARK: - The AI's allowances (Android AllowanceUi.kt)

extension AiFeature {
    /// What people call each feature's uses ("quick adds").
    var noun: String {
        switch self {
        case .quickAdd: return L("feature_quick_adds")
        case .receipt: return L("feature_receipt_scans")
        case .analysisRequest: return L("feature_report_questions")
        case .analysisReport: return L("feature_ai_reports")
        }
    }
}

extension Allowance {
    var period: String { L(weekly ? "period_this_week" : "period_today") }
    var resets: String { L(weekly ? "resets_monday" : "resets_midnight") }
    /// "2 of 10 quick adds used today. Resets at midnight."
    func sentence(_ f: AiFeature) -> String {
        guard let limit else { return L("part_of_premium") }
        return L("allowance_sentence", f.noun, used, limit, period, resets)
    }
}

/// A small ring that empties as the allowance is used.
struct AllowanceRing: View {
    let a: Allowance
    var size: CGFloat = 14
    var body: some View {
        let limit = max(a.limit ?? 1, 1)
        let left = a.left ?? 0
        ZStack {
            Circle().stroke(Palette.outlineVariant, lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(left) / CGFloat(limit))
                .stroke(left == 0 ? Palette.error : Palette.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// "8 left": a quiet chip; tapping it says what was used and when it resets.
struct AllowanceChip: View {
    @Environment(AppModel.self) private var model
    let feature: AiFeature
    @State private var open = false
    var body: some View {
        if let a = model.cloud.ai.current(feature), let left = a.left {
            Button { open = true } label: {
                HStack(spacing: 6) {
                    AllowanceRing(a: a)
                    Text(left == 0 ? L("none_left") : L("n_left", left)).font(.labelM)
                }
                .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 5)
                .foregroundStyle(left == 0 ? Palette.onErrorContainer : Palette.onSurfaceVariant)
                .background(left == 0 ? Palette.errorContainer : Palette.containerHigh, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open) {
                Text(a.sentence(feature)).font(.bodyM).padding().frame(maxWidth: 260).presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// One caption line with a ring: "2 of 3 AI reports left this week · Resets on Monday".
struct AllowanceLine: View {
    @Environment(AppModel.self) private var model
    let feature: AiFeature
    var body: some View {
        if let a = model.cloud.ai.current(feature), let limit = a.limit {
            HStack(spacing: 8) {
                AllowanceRing(a: a)
                Text(L("allowance_line", feature.noun, a.left ?? 0, limit, a.period, a.resets)).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
    }
}

/// Settings: every feature's use this period, with a bar.
struct AllowanceOverview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        // Report questions too: running out of them stops reports even with reports left
        let features: [AiFeature] = [.quickAdd, .receipt, .analysisRequest, .analysisReport]
        let shown = features.filter { f in
            guard let a = model.cloud.ai.current(f) else { return false }
            // On Free, the AI reports row already says Premium
            return !(f == .analysisRequest && a.limit == nil)
        }
        if !shown.isEmpty {
            VStack(spacing: 14) {
                ForEach(shown, id: \.self) { f in
                    let a = model.cloud.ai.current(f) ?? Allowance(used: 0, limit: nil, weekly: false)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(f.noun.prefix(1)).uppercased() + String(f.noun.dropFirst())).font(.bodyM).foregroundStyle(Palette.onSurface)
                            Spacer()
                            if let limit = a.limit {
                                Text(L("n_of_m_left", a.left ?? 0, limit)).font(.labelL).foregroundStyle(Palette.onSurface)
                            } else {
                                Text("Premium").font(.labelL).foregroundStyle(Palette.gold)
                            }
                        }
                        if let limit = a.limit {
                            ProgressBar(value: limit == 0 ? 0 : Double(a.used) / Double(limit), color: a.left == 0 ? Palette.error : Palette.primary,
                                        track: Palette.containerHighest, height: 4)
                            Text(L("used_period", a.used, a.period, a.resets)).font(.labelS).foregroundStyle(Palette.onSurfaceVariant)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}

// MARK: - AI consent (Android AiConsentDialog.kt)

/// What goes to Google Gemini, asked once before the first AI use.
struct ConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let allow: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Palette.primary).frame(maxWidth: .infinity)
                    Text(L("consent_intro")).font(.bodyM)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["consent_typed", "consent_photo", "consent_names", "consent_figures"], id: \.self) { key in
                            HStack(alignment: .top, spacing: 8) { Text("•"); Text(L(key)).frame(maxWidth: .infinity, alignment: .leading) }.font(.bodyM)
                        }
                    }
                    Text(L("consent_never")).font(.bodyM.weight(.semibold))
                    Text(L("consent_google")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
                    Button(L("privacy_policy")) { UIApplication.shared.open(Links.privacy) }.foregroundStyle(Palette.primary)
                }
                .foregroundStyle(Palette.onSurface)
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("consent_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("not_now")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("allow")) { dismiss(); allow() }.accessibilityIdentifier("allowAi") }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}

/// Runs an AI action once the person agreed to the AI (asking the first time).
struct ConsentGate: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: (() -> Void)?
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            ConsentSheet {
                model.setConsent(true)
                let action = pending
                pending = nil
                action?()
            }
        }
    }
}

extension View {
    func consentGate(_ pending: Binding<(() -> Void)?>) -> some View { modifier(ConsentGate(pending: pending)) }
}
