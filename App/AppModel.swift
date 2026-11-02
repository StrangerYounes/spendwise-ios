import Foundation
import SwiftUI
import SpendWiseCore

/// The first-run guide's steps (Android util/Onboarding.kt): per install, never synced.
enum OnboardingStep: String { case Welcome, FirstList, FirstItem, Tips, Done }

/// The features that take the person's own instructions (Android util/AiInstructions.kt).
enum InstructionKind: String, CaseIterable {
    case QuickAdd, Receipt, Report
    var feature: AiFeature {
        switch self {
        case .QuickAdd: return .quickAdd
        case .Receipt: return .receipt
        case .Report: return .analysisReport
        }
    }
    /** The backend's cap (firebase/functions/src/request.ts). */
    static let maxChars = 1_000
}

/// A message at the bottom of the screen, with an optional action (Undo).
struct Snack: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var seconds: Double = 4
    static func == (a: Snack, b: Snack) -> Bool { a.id == b.id }
}

/// Everything the screens share: the database (the same as Android's), the app's settings, the
/// per-install choices (AI consent, the guide, the person's AI instructions) and messages.
@MainActor @Observable
final class AppModel {
    let database: AppDatabase
    /// The welcome's language page was answered (this run only): the screen is rebuilt in the
    /// chosen language and goes on to the next page.
    var welcomeLanguageChosen = false
    let repo: ShoppingRepository
    let backup: BackupRepository
    let cloud: Cloud

    /// Bumped on every database change; screens re-read their data when it moves.
    private(set) var revision = 0
    private(set) var settings = AppSettings()
    var snack: Snack?
    /// The app's language choice, kept here so every screen redraws when it changes.
    private(set) var language: Lang.Choice = Lang.choice

    private let prefs = UserDefaults.standard

    init(database: AppDatabase) {
        self.database = database
        repo = ShoppingRepository(database)
        backup = BackupRepository(database)
        cloud = Cloud()
        let defaults = UserDefaults.standard
        consentGranted = defaults.bool(forKey: Keys.consent)
        onboarding = defaults.string(forKey: Keys.onboarding).flatMap(OnboardingStep.init(rawValue:))
        devOptionsShown = defaults.bool(forKey: Keys.devOptions)
        var all: [InstructionKind: String] = [:]
        for k in InstructionKind.allCases { all[k] = defaults.string(forKey: Keys.instructions + k.rawValue) ?? "" }
        instructions = all
        settings = (try? database.settings()) ?? AppSettings()
        database.db.onChange = { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        // Once per install: things bought outside Groceries before every category fed the library
        if !defaults.bool(forKey: Keys.libraryAllCategories) {
            if (try? repo.catchUpLibraryWithAllCategories()) != nil { defaults.set(true, forKey: Keys.libraryAllCategories) }
        }
        // The first start checks for lists; an install that has some skips the welcome
        if onboarding == nil { setOnboarding((try? repo.hasLists()) == true ? .Done : .Welcome) }
        cloud.attach(self)
    }

    private func changed() {
        revision += 1
        settings = (try? database.settings()) ?? AppSettings()
        if Cloud.configured { cloud.sync?.localChanged() }
    }

    /// Re-reads everything (after the sync engine or a restore wrote rows).
    func refresh() { changed() }

    // MARK: - Data for the screens (re-read when revision moves)

    var lists: [ShoppingListWithDetails] { _ = revision; return (try? repo.allShoppingLists()) ?? [] }
    var categories: [SpendWiseCore.Category] { _ = revision; return (try? repo.allCategories()) ?? [] }
    var stores: [Store] { _ = revision; return (try? repo.allStores()) ?? [] }
    var storeUsage: [StoreUsage] { _ = revision; return (try? repo.storesWithUsage()) ?? [] }
    var masterItems: [MasterItem] { _ = revision; return (try? repo.allMasterItems()) ?? [] }
    var itemSummaries: [ItemSummary] { _ = revision; return (try? repo.itemSummaries()) ?? [] }
    var reports: [AiReport] { _ = revision; return (try? database.allReports()) ?? [] }
    var currency: String { settings.currencySymbol.isEmpty ? "$" : settings.currencySymbol }

    func list(_ id: Int64) -> ShoppingList? { _ = revision; return try? repo.shoppingList(id: id) }
    /// The stored name of a list's category (Groceries when it has none).
    func categoryName(ofList id: Int64) -> String {
        guard let categoryId = list(id)?.categoryId else { return ShoppingRepository.trackedCategory }
        return categories.first { $0.id == categoryId }?.name ?? ShoppingRepository.trackedCategory
    }
    func items(_ listId: Int64) -> [ShoppingItem] { _ = revision; return (try? repo.items(listId: listId)) ?? [] }
    func photos(_ listId: Int64) -> [Photo] { _ = revision; return (try? repo.photos(listId: listId)) ?? [] }
    func report(_ id: Int64) -> AiReport? { _ = revision; return try? database.report(id: id) }
    func history(_ name: String) -> [PurchaseHistoryItem] { _ = revision; return (try? repo.purchaseHistory(name)) ?? [] }

    var groceriesColor: Int32 { categories.first { $0.name == "Groceries" }?.color ?? AppDatabase.groceriesColor }

    func color(of category: SpendWiseCore.Category?) -> Color { Color(argb: category?.color ?? groceriesColor) }

    /// Runs a database change; a failure shows a message people can act on, never the error's text.
    @discardableResult
    func perform<T>(_ whatFailed: String = L("err_save"), _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            print("SpendWise: \(whatFailed): \(error)")
            show(UserErrors.message(error, whatFailed))
            return nil
        }
    }

    // MARK: - Settings (the synced app_settings row; theme stays per phone as on Android)

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = (try? database.settings()) ?? AppSettings()
        change(&s)
        perform { try database.updateSettings(s) }
    }

    /// The local currency's rate (its units per app unit), or nil to forget it (stored as 1).
    func setConversionRate(_ rate: Double?) {
        updateSettings { $0.lastConversionRate = (rate ?? 0) > 1 ? rate! : 1 }
    }

    var colorScheme: ColorScheme? {
        switch settings.darkTheme {
        case true?: return .dark
        case false?: return .light
        case nil: return nil
        }
    }

    func setLanguage(_ choice: Lang.Choice) {
        Lang.set(choice)
        Dates.reset()
        language = choice
        revision += 1
        cloud.ai.languageChanged()
    }

    // MARK: - Per-install choices

    enum Keys {
        static let consent = "ai_consent.granted"
        static let onboarding = "onboarding.step"
        static let instructions = "ai_instructions."
        static let devOptions = "dev_options.shown"
        static let libraryAllCategories = "library_all_categories_done"
    }

    /// Whether the person agreed to send AI requests (asked once; Settings → AI features).
    private(set) var consentGranted: Bool
    func setConsent(_ granted: Bool) {
        consentGranted = granted
        prefs.set(granted, forKey: Keys.consent)
        if granted { Task { await cloud.ai.refreshAllowances() } }
    }

    /// nil only before the first start's check.
    private(set) var onboarding: OnboardingStep?
    func setOnboarding(_ step: OnboardingStep) {
        onboarding = step
        prefs.set(step.rawValue, forKey: Keys.onboarding)
    }
    /// Moves on only from [from], so a hint seen late can't undo a later step.
    func advance(from: OnboardingStep, to: OnboardingStep) { if onboarding == from { setOnboarding(to) } }

    private(set) var instructions: [InstructionKind: String]
    func setInstructions(_ kind: InstructionKind, _ text: String) {
        let value = String(text.prefix(InstructionKind.maxChars))
        instructions[kind] = value
        prefs.set(value, forKey: Keys.instructions + kind.rawValue)
    }
    func instructions(for feature: AiFeature) -> String? {
        guard let kind = InstructionKind.allCases.first(where: { $0.feature == feature }) else { return nil }
        let t = (instructions[kind] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Settings' Developer section (debug builds): hidden unless on the emulators or tapped 7 times.
    private(set) var devOptionsShown: Bool
    func toggleDevOptions() -> Bool {
        devOptionsShown.toggle()
        prefs.set(devOptionsShown, forKey: Keys.devOptions)
        return devOptionsShown
    }

    // MARK: - Messages

    func show(_ message: String) { snack = Snack(message: message) }

    func showUndo(_ message: String, seconds: Double = 10, undo: @escaping () -> Void) {
        snack = Snack(message: message, actionLabel: L("undo"), action: undo, seconds: seconds)
    }
}

/// A message people can act on, for any failure (Android util/UserErrors.kt): what failed, then
/// what to do. Error text written for developers never reaches the screen.
enum UserErrors {
    static func message(_ error: Error, _ whatFailed: String) -> String {
        if let ai = error as? AiError { return ai.message }
        if let shown = error as? ShownToPeople { return shown.message }
        return L("err_joined", whatFailed, advice(error))
    }

    static func advice(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || Cloud.isOffline(error) { return L("err_offline") }
        if Cloud.needsRecentLogin(error) { return L("err_recent_login") }
        if Cloud.isDenied(error) { return L("err_denied") }
        if Cloud.isUnavailable(error) { return L("err_unavailable") }
        return L("err_contact", Links.contactEmail)
    }
}

/// A failure whose message was written for people and can be shown as it is.
struct ShownToPeople: Error { let message: String }

/// SpendWise's public pages on the shared younes.app site.
enum Links {
    static let site = "https://younes.app/spendwise"
    static let contactEmail = "hello@younes.app"
    static func page(_ path: String) -> URL { URL(string: Lang.isArabic ? "\(site)/ar/\(path)" : "\(site)/\(path)")! }
    static var privacy: URL { page("privacy") }
    static var deleteAccount: URL { page("delete-account") }
}

/// Where the app is: a stack of screens over Home, and the sheets that can open from anywhere.
enum Route: Hashable {
    case list(Int64)
    case settings
    case library
    case insights
    case analysis
    case report(Int64)
    case item(String)
    case upgrade
    case aiInstructions
}

@MainActor @Observable
final class Router {
    var path: [Route] = []
    func open(_ r: Route) { path.append(r) }
    func back() { if !path.isEmpty { path.removeLast() } }
    /// Every locked Premium feature opens the Upgrade page.
    func upgrade() { if path.last != .upgrade { path.append(.upgrade) } }
}
