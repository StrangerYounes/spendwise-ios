import SwiftUI
import SpendWiseCore

/// The first-run welcome (FEATURES.md §4.10): what the app does, then the currency and a second,
/// local currency's rate, then on to the first list.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let returning: () -> Void
    @State private var page = 0
    @State private var rateText = ""
    @State private var custom = ""
    @State private var editingCustom = false
    private let pages = 4

    var body: some View {
        let last = page == pages - 1
        let rate = parseRate(rateText)
        let rateOk = rateText.trimmingCharacters(in: .whitespaces).isEmpty || (rate ?? 0) > 1
        VStack(spacing: 0) {
            HStack {
                // English ⇄ العربية, each named in its own words
                Button { model.setLanguage(Lang.isArabic ? .en : .ar) } label: {
                    Label(Lang.isArabic ? "English" : "العربية", systemImage: "globe").font(.labelL)
                }
                .foregroundStyle(Palette.primary)
                .accessibilityIdentifier("welcomeLanguage")
                Spacer()
                if !last { Button(L("skip")) { model.setOnboarding(.Done) }.foregroundStyle(Palette.primary) }
            }
            .frame(height: 44)
            TabView(selection: $page) {
                IntroPage(main: "cart.fill", left: "checklist", right: "chart.bar.xaxis", title: L("welcome_title"), message: L("welcome_body")).tag(0)
                IntroPage(main: "sparkles", left: "mic.fill", right: "receipt", title: L("welcome_add_title"), message: L("welcome_add_body")).tag(1)
                IntroPage(main: "chart.bar.xaxis", left: "storefront", right: "chart.line.downtrend.xyaxis", title: L("welcome_prices_title"), message: L("welcome_prices_body")).tag(2)
                setup(rateOk).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 8) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == page ? Palette.primary : Palette.outlineVariant).frame(width: i == page ? 22 : 8, height: 8)
                }
            }
            .animation(.easeInOut, value: page)
            .padding(.vertical, 16)
            Button {
                if last {
                    if let rate, rate > 1 { model.setConversionRate(rate) }
                    model.setOnboarding(.FirstList)
                } else {
                    withAnimation { page += 1 }
                }
            } label: { Text(L(last ? "welcome_start" : "next")) }
            .buttonStyle(FilledButtonStyle(height: 52))
            .disabled(last && !rateOk)
            .accessibilityIdentifier("welcomeNext")
            Group {
                if last { Button(L("welcome_returning")) { model.setOnboarding(.Done); returning() }.foregroundStyle(Palette.primary) } else { Color.clear }
            }
            .frame(height: 48)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .readableWidth()
        .background(Palette.surface.ignoresSafeArea())
        .onAppear {
            rateText = model.settings.savedRate.map(formatRate) ?? ""
            editingCustom = !commonCurrencies.contains(model.currency)
            custom = editingCustom ? model.currency : ""
            #if DEBUG
            if DemoMode.screen == "welcome_setup" { page = 3 }
            if DemoMode.screen == "welcome_add" { page = 1 }
            #endif
        }
    }

    private func setup(_ rateOk: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Bubble(icon: "banknote", size: 72, background: Palette.primaryContainer, tint: Palette.onPrimaryContainer)
                Text(L("welcome_currency_title")).font(.headlineS).foregroundStyle(Palette.onSurface)
                Text(L("welcome_currency_body")).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
                FlowLayout(spacing: 8) {
                    ForEach(commonCurrencies, id: \.self) { symbol in
                        FilterChip(label: symbol, selected: symbol == model.currency && !editingCustom) {
                            editingCustom = false
                            model.updateSettings { $0.currencySymbol = symbol }
                        }
                    }
                    FilterChip(label: L("other"), selected: editingCustom) { editingCustom = true }
                }
                if editingCustom {
                    LabeledField(title: L("symbol"), text: Binding(get: { custom }, set: { v in
                        custom = String(v.prefix(4))
                        let t = custom.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { model.updateSettings { $0.currencySymbol = t } }
                    }))
                }
                Text(L("local_rate_title")).font(.titleM).foregroundStyle(Palette.onSurface).padding(.top, 8)
                Text(L("local_rate_body", model.currency)).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant)
                RateField(text: $rateText, currency: model.currency, ok: rateOk)
            }
            .padding(.top, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct IntroPage: View {
    let main: String
    let left: String
    let right: String
    let title: String
    let message: String
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                ZStack {
                    Bubble(icon: left, size: 64, background: Palette.secondaryContainer, tint: Palette.onSecondaryContainer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    Bubble(icon: right, size: 64, background: Palette.tertiaryContainer, tint: Palette.onTertiaryContainer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    Bubble(icon: main, size: 140, background: Palette.primaryContainer, tint: Palette.onPrimaryContainer)
                }
                .frame(width: 240, height: 180)
                Text(title).font(.headlineM).multilineTextAlignment(.center).foregroundStyle(Palette.onSurface).padding(.top, 36)
                Text(message).font(.bodyL).multilineTextAlignment(.center).foregroundStyle(Palette.onSurfaceVariant)
                    .frame(maxWidth: 420).padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Bubble: View {
    let icon: String
    let size: CGFloat
    let background: Color
    let tint: Color
    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.4)).foregroundStyle(tint)
            .frame(width: size, height: size).background(background, in: Circle())
    }
}
