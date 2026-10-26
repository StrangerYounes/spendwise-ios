import SwiftUI
import SpendWiseCore

/// One-tap requests that skip understanding a sentence.
enum AnalysisPreset: CaseIterable {
    case thisMonth, lastMonth, lastThreeMonths, priceTrends
    var label: String {
        switch self {
        case .thisMonth: return L("preset_this_month")
        case .lastMonth: return L("preset_last_month")
        case .lastThreeMonths: return L("preset_last_3_months")
        case .priceTrends: return L("preset_price_trends")
        }
    }
}

enum AnalysisState {
    case idle(error: String?)
    case recording(since: Date)
    case understanding
    /// The request is understood and its data gathered; shown before anything is sent.
    case ready(AnalysisRequest, AnalysisDigest)
    case writing(AnalysisRequest)
}

/// AI reports (Android viewmodel/AnalysisViewModel.kt): ask by voice, text or a preset, see what
/// will be sent, then the report is written and saved.
@MainActor @Observable
final class AnalysisModel {
    private(set) var state: AnalysisState = .idle(error: nil)
    var text = ""
    /// Why writing the last report failed, shown on the preview.
    var writeError: String?
    @ObservationIgnored let recorder: VoiceRecorder
    @ObservationIgnored private let model: AppModel

    init(model: AppModel) {
        self.model = model
        recorder = VoiceRecorder()
    }

    func setState(_ s: AnalysisState) { state = s }

    func startRecording() {
        do {
            try recorder.start { [weak self] in self?.stopRecordingAndUnderstand() }
            state = .recording(since: Date())
        } catch {
            state = .idle(error: L("err_mic"))
        }
    }

    func cancelRecording() {
        recorder.cancel()
        state = .idle(error: nil)
    }

    func stopRecordingAndUnderstand() {
        guard case .recording = state else { return }
        guard let audio = recorder.stop() else { state = .idle(error: L("analysis_too_short")); return }
        understand(nil, audio)
    }

    func submitText() {
        let d = String(text.prefix(QuickAddModel.maxText)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return }
        understand(d, nil)
    }

    func usePreset(_ preset: AnalysisPreset) {
        let now = nowMillis()
        let (start, end): (Millis, Millis)
        switch preset {
        case .thisMonth: (start, end) = AnalysisRequest.thisMonth(now)
        case .lastMonth: (start, end) = AnalysisRequest.lastMonth(now)
        case .lastThreeMonths, .priceTrends: (start, end) = AnalysisRequest.lastMonths(now, 3)
        }
        let focus: [AnalysisFocus] = preset == .priceTrends ? [.Prices] : AnalysisFocus.allCases
        state = prepare(AnalysisRequest(start: start, end: end, focus: focus, said: preset.label))
    }

    private func understand(_ description: String?, _ audio: Data?) {
        state = .understanding
        Task {
            do {
                let quick = try model.repo.quickAddContext(currencySymbol: model.currency)
                let context = AnalysisRequestContext(categories: quick.categories, stores: quick.stores, knownItems: quick.knownItems,
                                                     firstRecord: try model.database.firstListDate())
                let json = try await model.cloud.ai.generate(.analysisRequest,
                    AnalysisRequestParser.payload(text: description, audioBase64: audio?.base64EncodedString(), context: context))
                state = prepare(try AnalysisRequestParser.parseResponse(json, description: description, context: context))
            } catch {
                state = .idle(error: UserErrors.message(error, L("err_finish_report")))
            }
        }
    }

    /// Gathers the request's data so the person sees what will be sent before sending it.
    private func prepare(_ request: AnalysisRequest) -> AnalysisState {
        let lines = (try? model.database.purchaseLines(start: AnalysisDigest.historyStart(request), end: request.end)) ?? []
        let digest = AnalysisDigest.build(request, lines, currencySymbol: model.currency, conversionRate: model.settings.savedRate,
                                          firstRecord: try? model.database.firstListDate(), words: .localized())
        return .ready(request, digest)
    }

    /// Sends the prepared data to the AI and saves the report; [saved] gets its id.
    func writeReport(_ saved: @escaping (Int64) -> Void) {
        guard case .ready(let request, let digest) = state, digest.purchaseCount > 0 else { return }
        state = .writing(request)
        Task {
            do {
                let label = AnalysisRequest.periodLabel(request.start, request.end, locale: Lang.dateLocale)
                let json = try await model.cloud.ai.generate(.analysisReport, SpendingAnalyst.payload(request, digest, periodLabel: label, language: Lang.reportLanguage))
                let written = try SpendingAnalyst.parseResponse(json, digest: digest)
                let id = try model.database.insertReport(AiReport(createdAt: nowMillis(), request: request.said, periodStart: request.start,
                                                                  periodEnd: request.end, title: written.title, content: written.content.json))
                text = ""
                state = .idle(error: nil)
                saved(id)
            } catch {
                // Back to the preview, so trying again doesn't mean asking again
                state = .ready(request, digest)
                writeError = UserErrors.message(error, L("err_finish_report"))
            }
        }
    }

    func backToIdle() {
        writeError = nil
        state = .idle(error: nil)
    }
}

func periodLabel(_ start: Millis, _ end: Millis) -> String { AnalysisRequest.periodLabel(start, end, locale: Lang.dateLocale) }

/// AI reports (FEATURES.md §5.3): ask, preview, write; the saved reports below.
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var analysis: AnalysisModel?
    @State private var consentPending: (() -> Void)?

    var body: some View {
        let reports = model.reports
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    if let analysis { composer(analysis) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(Palette.containerLow)

                Text(reports.isEmpty ? L("saved_reports") : L("saved_reports_count", reports.count)).font(.titleS).foregroundStyle(Palette.primary)
                    .padding(.top, 8).padding(.leading, 4)
                if reports.isEmpty {
                    Text(L("reports_saved_here")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant).padding(.horizontal, 4)
                }
                ForEach(reports) { r in
                    Button { router.open(.report(r.id)) } label: { ReportRow(report: r) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
            .readableWidth()
        }
        .screen(L("ai_reports"))
        .consentGate($consentPending)
        .onAppear {
            if analysis == nil { analysis = AnalysisModel(model: model) }
            Task { await model.cloud.ai.refreshAllowances() }
            #if DEBUG
            if let analysis { DemoMode.prepareAnalysis(analysis) }
            #endif
        }
    }

    private func withAi(_ action: @escaping () -> Void) {
        if model.consentGranted { action() } else { consentPending = action }
    }

    @ViewBuilder
    private func composer(_ a: AnalysisModel) -> some View {
        switch a.state {
        case .idle(let error):
            if !model.cloud.tier.hasAiExtras {
                HStack {
                    Text(L("ask_about_spending")).font(.titleL).foregroundStyle(Palette.onSurface)
                    Spacer()
                    PremiumBadge()
                }
                Text(L("reports_locked")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant).padding(.top, 8)
                Button(L("see_premium")) { router.upgrade() }.buttonStyle(FilledButtonStyle(height: 44)).frame(maxWidth: 200).padding(.top, 12)
            } else {
                AskContent(analysis: a, error: error, send: { withAi { a.submitText() } }, record: {
                    withAi { Task { if await VoiceRecorder.permission() { a.startRecording() } else { model.show(L("mic_denied")) } } }
                })
            }
        case .recording(let since):
            RecordingContent(since: since, level: { a.recorder.level() }, message: L("analysis_listen_hint"),
                             cancel: { a.cancelRecording() }, done: { a.stopRecordingAndUnderstand() })
        case .understanding:
            BusyContent(message: L("understanding"))
        case .ready(let request, let digest):
            PreviewContent(request: request, digest: digest, error: a.writeError, cancel: { a.backToIdle() }) {
                a.writeError = nil
                withAi { a.writeReport { id in router.open(.report(id)) } }
            }
        case .writing(let request):
            BusyContent(message: L("writing_report", periodLabel(request.start, request.end)))
        }
    }
}

private struct AskContent: View {
    @Bindable var analysis: AnalysisModel
    let error: String?
    let send: () -> Void
    let record: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("ask_about_spending")).font(.titleL).foregroundStyle(Palette.onSurface)
                Text(L("ask_sub")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: record) {
                Image(systemName: "mic.fill").font(.system(size: 26)).foregroundStyle(Palette.onPrimary)
                    .frame(width: 64, height: 64).background(Palette.primary, in: Circle())
            }
            .accessibilityLabel(L("ask_by_voice"))
        }
        AllowanceLine(feature: .analysisReport).padding(.top, 10)
        HStack(alignment: .bottom) {
            TextField(L("ask_hint"), text: $analysis.text, axis: .vertical).lineLimit(1...4).submitLabel(.send).onSubmit(send)
                .accessibilityIdentifier("askText")
            Button(action: send) { Image(systemName: "paperplane.fill") }.foregroundStyle(Palette.primary)
                .disabled(analysis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L("ask"))
        }
        .fieldStyle()
        .padding(.top, 12)
        if let error { Text(error).font(.bodyS).foregroundStyle(Palette.error).padding(.top, 8) }
        FlowLayout(spacing: 8) {
            ForEach(AnalysisPreset.allCases, id: \.self) { p in
                Button(p.label) { analysis.usePreset(p) }
                    .font(.labelL).foregroundStyle(Palette.onSurface)
                    .padding(.horizontal, 12).frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.outline))
            }
        }
        .padding(.top, 8)
    }
}

/// What will be analyzed and sent, before anything leaves the phone.
private struct PreviewContent: View {
    let request: AnalysisRequest
    let digest: AnalysisDigest
    let error: String?
    let cancel: () -> Void
    let write: () -> Void
    var body: some View {
        Text(periodLabel(request.start, request.end)).font(.titleL).foregroundStyle(Palette.onSurface)
        if !request.said.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("“\(request.said)”").font(.bodyM).italic().foregroundStyle(Palette.onSurfaceVariant).padding(.top, 2)
        }
        VStack(alignment: .leading, spacing: 8) {
            line("chart.bar.xaxis", L("looks_at", focusText(request)))
            if let f = request.filterLabel { line("line.3.horizontal.decrease", L("only_filter", f)) }
            if let q = request.question { line("questionmark.bubble", q) }
            if digest.purchaseCount == 0 { line("info.circle", L("no_purchases_period")) } else { line("receipt", L("will_be_sent", digest.basedOn)) }
        }
        .padding(.top, 12)
        if let error { Text(error).font(.bodyS).foregroundStyle(Palette.error).padding(.top, 8) }
        HStack {
            Spacer()
            Button(L("cancel"), action: cancel).foregroundStyle(Palette.primary)
            Button(action: write) { Label(error != nil ? L("try_again") : L("write_report"), systemImage: "sparkles") }
                .buttonStyle(FilledButtonStyle(height: 44)).frame(maxWidth: 200)
                .disabled(digest.purchaseCount == 0)
                .accessibilityIdentifier("writeReport")
        }
        .padding(.top, 12)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Palette.primary).frame(width: 18)
            Text(text).font(.bodyM).foregroundStyle(Palette.onSurface)
        }
    }
}

/// What a report looks at, in the app's language ("spending and price trends").
func focusText(_ r: AnalysisRequest) -> String {
    if Set(r.focus) == Set(AnalysisFocus.allCases) { return L("focus_everything") }
    return r.focus.map { f -> String in
        switch f {
        case .Spending: return L("focus_spending")
        case .Prices: return L("focus_prices")
        case .Habits: return L("focus_habits")
        }
    }.joined(separator: L("and_separator"))
}

private struct ReportRow: View {
    let report: AiReport
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").foregroundStyle(Palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.title).font(.bodyL).foregroundStyle(Palette.onSurface).lineLimit(1)
                Text(periodLabel(report.periodStart, report.periodEnd)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Dates.format(report.createdAt, "MMMd")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card(Palette.containerLow, radius: 16)
    }
}

/// A saved report, laid out as cards.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let reportId: Int64
    @State private var confirm: Confirm?

    var body: some View {
        let report = model.report(reportId)
        let content = report.flatMap { ReportContent.from(json: $0.content) }
        ScrollView {
            if let r = report {
                LazyVStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(periodLabel(r.periodStart, r.periodEnd)).font(.titleM).foregroundStyle(Palette.primary)
                        if !r.request.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("“\(r.request)”").font(.bodyM).italic().foregroundStyle(Palette.onSurfaceVariant)
                        }
                    }
                    .padding(.horizontal, 4)
                    if let content {
                        if !content.facts.isEmpty { FactGrid(facts: content.facts) }
                        Text(content.summary).font(.bodyL).foregroundStyle(Palette.onPrimaryContainer)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).card(Palette.primaryContainer)
                        ForEach(Array(content.sections.enumerated()), id: \.offset) { _, s in SectionCard(section: s) }
                        if !content.tips.isEmpty { SectionCard(section: ReportSection(kind: "tips", heading: L("tips"), body: "", points: content.tips)) }
                        let created = Dates.format(r.createdAt, "MMMdyyyyjmm")
                        Text(content.basedOn.map { L("report_footer_from", created, $0) } ?? L("report_footer", created))
                            .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).padding(4)
                    } else {
                        Text(L("report_unreadable")).foregroundStyle(Palette.error)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
                .readableWidth()
            }
        }
        .screen(report?.title ?? "")
        .toolbar {
            if let report {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        confirm = Confirm(title: L("delete_report_q"), message: L("delete_report_body", report.title), label: L("delete")) {
                            model.perform { try model.database.deleteReport(report) }
                            router.back()
                        }
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel(L("delete_report"))
                }
            }
        }
        .confirm($confirm)
    }
}

private struct FactGrid: View {
    let facts: [ReportFact]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
                    Text(f.value).font(.titleM).foregroundStyle(Palette.onSurface).lineLimit(1).minimumScaleFactor(0.6)
                    if let change = f.change {
                        Text(change).font(.bodyS).lineLimit(1)
                            .foregroundStyle(f.direction == 1 ? Palette.error : f.direction == -1 ? Palette.primary : Palette.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .card(Palette.containerLow, radius: 16)
            }
        }
    }
}

private struct SectionCard: View {
    let section: ReportSection
    var body: some View {
        let icon: String = {
            switch section.kind {
            case "spending": return "banknote"
            case "prices": return "chart.line.uptrend.xyaxis"
            case "habits": return "repeat"
            case "stores": return "storefront"
            case "tips": return "lightbulb"
            default: return "chart.bar.xaxis"
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Palette.primary)
                Text(section.heading).font(.titleM).foregroundStyle(Palette.onSurface)
            }
            if !section.body.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(section.body).font(.bodyM).foregroundStyle(Palette.onSurface).padding(.top, 2)
            }
            ForEach(Array(section.points.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Palette.primary)
                    Text(p).font(.bodyM).foregroundStyle(Palette.onSurface).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card(Palette.containerLow)
    }
}
