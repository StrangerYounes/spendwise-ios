import GoogleSignIn
import SwiftUI
import SpendWiseCore

@main
struct SpendWiseApp: App {
    @State private var model: AppModel
    @State private var router = Router()

    init() {
        installCoreText()
        var path = Self.databaseURL.path
        #if DEBUG
        if DemoMode.isOn { path = DemoMode.freshDatabasePath() }
        if TestDriver.isOn { path = TestDriver.databasePath() }
        #endif
        let database: AppDatabase
        do {
            database = try AppDatabase(path: path)
        } catch {
            // Never overwrite a file that can't be opened: keep it aside and start a new one
            let aside = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: path, toPath: aside)
            database = try! AppDatabase(path: path)
        }
        _model = State(initialValue: AppModel(database: database))
    }

    /// Application Support/spendwise.sqlite (backed up to iCloud with the phone, like Android's Auto Backup).
    static var databaseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spendwise.sqlite")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

/// The welcome on a first run, else Home with the screens pushed over it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var prepared = false

    var body: some View {
        @Bindable var router = router
        Group {
            switch model.onboarding {
            case nil:
                Palette.surface.ignoresSafeArea()
            case .Welcome?:
                // "I've used SpendWise before" goes on to Settings, where signing in brings the lists back
                WelcomeView { router.path = [.settings] }
            default:
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { route in destination(route) }
                }
                .tint(Palette.primary)
            }
        }
        .id(model.language)
        .environment(\.layoutDirection, Lang.isArabic ? .rightToLeft : .leftToRight)
        .environment(\.locale, Lang.formatLocale)
        .preferredColorScheme(model.colorScheme)
        .snackbarHost()
        // Signed in while the phone holds another account's lists (any screen, FEATURES.md §6.3)
        .sheet(isPresented: Binding(get: { model.cloud.otherAccount != nil }, set: { _ in })) {
            if let user = model.cloud.otherAccount { OtherAccountSheet(user: user) }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            #if DEBUG
            if DemoMode.isOn { DemoMode.apply(model, router) }
            if TestDriver.isOn { TestDriver.run(model, router) }
            #endif
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .list(let id): ListDetailView(listId: id)
        case .settings: SettingsView()
        case .library: LibraryView()
        case .insights: InsightsView()
        case .analysis: AnalysisView()
        case .report(let id): ReportView(reportId: id)
        case .item(let name): ItemInsightsView(name: name)
        case .upgrade: UpgradeView()
        case .aiInstructions: AiInstructionsView()
        }
    }
}
