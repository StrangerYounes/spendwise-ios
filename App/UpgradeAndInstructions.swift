import SwiftUI
import SpendWiseCore

private let premiumOnGold = Color(rgb: 0x271900)
private let premiumGreen = Color(rgb: 0x00522C)
private let premiumGreenLight = Color(rgb: 0x0F6D3D)

/// What Premium adds (FEATURES.md §3). There's no App Store subscription yet, so the button says
/// it's coming soon; debug builds on the emulators can switch to Premium here.
struct UpgradeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let premium = model.cloud.tier == .premium
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(premiumOnGold)
                        .frame(width: 56, height: 56)
                        .background(LinearGradient(colors: [Palette.goldLight, Palette.gold], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    // Green header, gold accents: mixing the two in a gradient turns olive
                    (Text("SpendWise ").foregroundStyle(.white) + Text("Premium").foregroundStyle(Palette.goldLight))
                        .font(.headlineM).padding(.top, 16)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(L(premium ? "on_premium" : "premium_tagline")).font(.bodyL).foregroundStyle(.white.opacity(0.92)).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(LinearGradient(colors: [premiumGreen, premiumGreenLight], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                Text(L("everything_free_plus")).font(.titleM).foregroundStyle(Palette.onSurface).padding(.top, 24).padding(.bottom, 8).padding(.leading, 4)
                benefit("receipt", L("benefit_receipts"), L("benefit_receipts_sub"))
                benefit("chart.bar.xaxis", L("ai_reports"), L("benefit_reports_sub"))
                benefit("mic.fill", L("benefit_quick"), L("benefit_quick_sub"))
                benefit("iphone.and.arrow.forward", L("benefit_sync"), L("benefit_sync_sub"))
                benefit("figure.2.and.child.holdinghands", L("family_share"), L("benefit_family_sub"))

                if premium {
                    Button(L("back_to_app")) { router.back() }.buttonStyle(OutlineButtonStyle(height: 52)).frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    Button { model.show(L("premium_not_on_sale")) } label: { Label(L("get_premium"), systemImage: "sparkles").font(.titleM) }
                        .buttonStyle(FilledButtonStyle(background: Palette.gold, foreground: premiumOnGold, height: 56))
                        .padding(.top, 24)
                        .accessibilityIdentifier("getPremium")
                    Text(L("premium_coming")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 8)
                    #if DEBUG
                    if model.cloud.planSwitchable {
                        Button("Debug: switch to Premium") { model.cloud.setDebugTier(.premium) }.frame(maxWidth: .infinity).padding(.top, 4)
                    }
                    #endif
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
            .readableWidth()
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func benefit(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color(rgb: 0xB07400))
                .frame(width: 40, height: 40).background(Palette.gold.opacity(0.22), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.titleS).foregroundStyle(Palette.onSurface)
                Text(text).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Settings → Your instructions for the AI (FEATURES.md §5.2.1): each feature's base prompt to read,
/// and the person's own additions, kept on this phone.
struct AiInstructionsView: View {
    @Environment(AppModel.self) private var model
    @State private var prompts: [String: String]?
    @State private var showing: InstructionKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("ai_instructions_intro")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
                ForEach(InstructionKind.allCases, id: \.self) { kind in
                    InstructionCard(kind: kind, text: Binding(get: { model.instructions[kind] ?? "" }, set: { model.setInstructions(kind, $0) })) { showing = kind }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .readableWidth()
        }
        .screen(L("ai_instructions"))
        .sheet(item: Binding(get: { showing.map(KindBox.init) }, set: { showing = $0?.kind })) { box in
            BasePromptSheet(title: title(box.kind), prompt: prompts?[box.kind.feature.id]) { prompts = try await model.cloud.ai.basePrompts() }
        }
    }

    struct KindBox: Identifiable { let kind: InstructionKind; var id: String { kind.rawValue } }
}

func title(_ kind: InstructionKind) -> String {
    switch kind {
    case .QuickAdd: return L("quick_add")
    case .Receipt: return L("ai_instructions_receipts")
    case .Report: return L("ai_instructions_reports")
    }
}

private struct InstructionCard: View {
    let kind: InstructionKind
    @Binding var text: String
    let showPrompt: () -> Void
    var body: some View {
        let (icon, about, hint): (String, String, String) = {
            switch kind {
            case .QuickAdd: return ("sparkles", "ai_instructions_quick_about", "ai_instructions_quick_hint")
            case .Receipt: return ("receipt", "ai_instructions_receipt_about", "ai_instructions_receipt_hint")
            case .Report: return ("chart.bar.xaxis", "ai_instructions_report_about", "ai_instructions_report_hint")
            }
        }()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Palette.onPrimaryContainer)
                    .frame(width: 40, height: 40).background(Palette.primaryContainer, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(kind)).font(.titleM).foregroundStyle(Palette.onSurface)
                    Text(L(about)).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ai_instructions_yours")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
                TextField(L(hint), text: $text, axis: .vertical).lineLimit(3...8).fieldStyle()
                Text("\(text.count) / \(InstructionKind.maxChars)").font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    .environment(\.layoutDirection, .leftToRight)
            }
            HStack {
                Spacer()
                Button(action: showPrompt) { Label(L("ai_instructions_see_base"), systemImage: "eye").font(.labelL) }.foregroundStyle(Palette.primary)
            }
        }
        .padding(16)
        .card(Palette.containerLow)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// The base prompt, read only; the person's instructions are added after it.
private struct BasePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prompt: String?
    let load: () async throws -> Void
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("ai_instructions_base_note")).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    if let prompt {
                        Text(prompt).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(Palette.containerHigh, in: RoundedRectangle(cornerRadius: 10))
                            .environment(\.layoutDirection, .leftToRight)
                    } else if let error {
                        Text(error).font(.bodyM).foregroundStyle(Palette.error)
                        Button(L("try_again")) { attempt += 1 }.foregroundStyle(Palette.primary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
            .task(id: attempt) {
                guard prompt == nil else { return }
                error = nil
                do { try await load() } catch { self.error = UserErrors.message(error, "") }
            }
        }
    }
}
