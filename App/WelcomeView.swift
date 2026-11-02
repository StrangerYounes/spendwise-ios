import SwiftUI
import SpendWiseCore

/// The first-run welcome (FEATURES.md §4.10): the language on a page of its own, what the app does,
/// the currency (and a second, local currency's rate), then signing in, and on to the first list.
/// (Android's page for closed testers isn't here: it exists only in Android testing builds.)
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let returning: () -> Void
    @State private var page = 0
    @State private var rateText = ""
    @State private var custom = ""
    @State private var editingCustom = false
    @State private var signInWith: SignInProvider?
    /// What, Adding, Prices, Setup, Sign in
    private let pages = 5
    private let setupPage = 3
    private let signInPage = 4

    var body: some View {
        if model.welcomeLanguageChosen {
            pager
        } else {
            LanguagePage { choice in
                model.welcomeLanguageChosen = true
                model.setLanguage(choice)
            }
        }
    }

    private var pager: some View {
        let rate = parseRate(rateText)
        let rateOk = rateText.trimmingCharacters(in: .whitespaces).isEmpty || (rate ?? 0) > 1
        let cloud = model.cloud
        return VStack(spacing: 0) {
            HStack {
                // English ⇄ العربية, each named in its own words
                Button { model.setLanguage(Lang.isArabic ? .en : .ar) } label: {
                    Label(Lang.isArabic ? "English" : "العربية", systemImage: "globe").font(.labelL)
                }
                .foregroundStyle(Palette.primary)
                .accessibilityIdentifier("welcomeLanguage")
                Spacer()
                if page < setupPage { Button(L("skip")) { model.setOnboarding(.Done) }.foregroundStyle(Palette.primary) }
            }
            .frame(height: 44)
            TabView(selection: $page) {
                IntroPage(main: "cart.fill", left: "checklist", right: "chart.bar.xaxis", title: L("welcome_title"), message: L("welcome_body")).tag(0)
                IntroPage(main: "sparkles", left: "mic.fill", right: "receipt", title: L("welcome_add_title"), message: L("welcome_add_body")).tag(1)
                IntroPage(main: "chart.bar.xaxis", left: "storefront", right: "chart.line.downtrend.xyaxis", title: L("welcome_prices_title"), message: L("welcome_prices_body")).tag(2)
                setup(rateOk).tag(setupPage)
                signIn.tag(signInPage)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 8) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == page ? Palette.primary : Palette.outlineVariant).frame(width: i == page ? 22 : 8, height: 8)
                }
            }
            .animation(.easeInOut, value: page)
            .padding(.vertical, 16)
            bottom(rateOk: rateOk, rate: rate, signedIn: cloud.user != nil)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .readableWidth()
        .background(Palette.surface.ignoresSafeArea())
        .sheet(item: $signInWith) { provider in
            SignInNotice(syncs: cloud.tier.syncs) { Task { await cloud.signIn(with: provider) } }
        }
        .onAppear {
            rateText = model.settings.savedRate.map(formatRate) ?? ""
            editingCustom = !commonCurrencies.contains(model.currency)
            custom = editingCustom ? model.currency : ""
            #if DEBUG
            if DemoMode.screen == "welcome_setup" { page = setupPage }
            if DemoMode.screen == "welcome_add" { page = 1 }
            if DemoMode.screen.hasPrefix("welcome_signin") || DemoMode.screen == "welcome_signed_in" { page = signInPage }
            #endif
        }
    }

    /// Next on the intro and setup pages; on the sign-in page, Apple and Google then Not now, or
    /// Make my first list once signed in.
    @ViewBuilder
    private func bottom(rateOk: Bool, rate: Double?, signedIn: Bool) -> some View {
        if page == signInPage && !signedIn {
            VStack(spacing: 10) {
                // Apple's button first and at least as prominent as Google's (Apple's guidelines)
                AppleSignInButton { signInWith = .apple }
                    .id(colorScheme)
                    .frame(height: 52)
                    .accessibilityLabel(L("sign_in_apple"))
                Button { signInWith = .google } label: { Label(L("sign_in_google"), systemImage: "person.crop.circle") }
                    .buttonStyle(FilledButtonStyle(height: 52))
                    .disabled(model.cloud.busy)
                    .accessibilityIdentifier("welcomeGoogle")
                #if DEBUG
                if model.cloud.usingEmulators {
                    Button("Sign in as test user (emulators)") { Task { await model.cloud.signInForTest("Test User") } }
                        .font(.labelL).foregroundStyle(Palette.primary)
                }
                #endif
                Button(L("not_now")) { start(rate) }
                    .foregroundStyle(Palette.primary).frame(height: 44)
                    .accessibilityIdentifier("welcomeNotNow")
            }
        } else {
            Button {
                if page == signInPage { start(rate) } else { withAnimation { page += 1 } }
            } label: { Text(L(page == signInPage ? "welcome_start" : "next")) }
            .buttonStyle(FilledButtonStyle(height: 52))
            .disabled(page == setupPage && !rateOk)
            .accessibilityIdentifier("welcomeNext")
            Group {
                if page == setupPage { Button(L("welcome_returning")) { model.setOnboarding(.Done); returning() }.foregroundStyle(Palette.primary) } else { Color.clear }
            }
            .frame(height: 48)
        }
    }

    /// The guide to the first list, with the rate typed on the setup page. An account's lists that
    /// arrive end the guide (HomeView), as on Android.
    private func start(_ rate: Double?) {
        if let rate, rate > 1 { model.setConversionRate(rate) }
        model.setOnboarding(.FirstList)
    }

    private var signIn: some View {
        let user = model.cloud.user
        return ScrollView {
            VStack(spacing: 12) {
                Spacer(minLength: 24)
                ZStack {
                    Bubble(icon: "iphone.gen3", size: 64, background: Palette.secondaryContainer, tint: Palette.onSecondaryContainer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    Bubble(icon: "figure.2.and.child.holdinghands", size: 64, background: Palette.tertiaryContainer, tint: Palette.onTertiaryContainer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    Bubble(icon: "arrow.triangle.2.circlepath.icloud", size: 140, background: Palette.primaryContainer, tint: Palette.onPrimaryContainer)
                }
                .frame(width: 240, height: 180)
                Text(L("welcome_signin_title")).font(.headlineM).multilineTextAlignment(.center).foregroundStyle(Palette.onSurface).padding(.top, 24)
                Text(L("welcome_signin_body")).font(.bodyL).multilineTextAlignment(.center).foregroundStyle(Palette.onSurfaceVariant).frame(maxWidth: 420)
                if let user {
                    Label(L("welcome_signed_in", user.email.isEmpty ? accountTitle(user.name, user.email) : user.email), systemImage: "checkmark.circle.fill")
                        .font(.titleS).foregroundStyle(Palette.onSurface)
                        .accessibilityIdentifier("welcomeSignedIn")
                } else {
                    Text(L("welcome_signin_note")).font(.bodyS).multilineTextAlignment(.center).foregroundStyle(Palette.onSurfaceVariant).frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity)
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

/// The first page, alone on the screen: English or العربية, each in its own language, the one
/// showing now filled in. Choosing applies it at once (as Settings → Language does) and moves on.
private struct LanguagePage: View {
    let choose: (Lang.Choice) -> Void
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Bubble(icon: "globe", size: 96, background: Palette.primaryContainer, tint: Palette.onPrimaryContainer)
                .padding(.bottom, 12)
            ForEach([Lang.Choice.en, Lang.Choice.ar], id: \.self) { choice in
                let current = (choice == .ar) == Lang.isArabic
                Button { choose(choice) } label: {
                    Text(choice == .ar ? "العربية" : "English").font(.headlineS).frame(maxWidth: .infinity).frame(height: 76)
                        .foregroundStyle(current ? Palette.onPrimary : Palette.primary)
                        .background(current ? Palette.primary : Color.clear, in: RoundedRectangle(cornerRadius: 38))
                        .overlay(RoundedRectangle(cornerRadius: 38).stroke(current ? Color.clear : Palette.outline))
                }
                .buttonStyle(.plainRow)
                .frame(maxWidth: 420)
                .accessibilityIdentifier(choice == .en ? "welcomeEnglish" : "welcomeArabic")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
    }
}
