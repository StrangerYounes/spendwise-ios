import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn
import Network
import Observation
import UIKit
import SpendWiseCore

/// The plan (PLAN.md, Tiers): Free keeps everything on the phone; Premium adds sync and more AI.
enum Tier: Hashable {
    case free, premium
    /// Lists, items and the library on every device signed in to the same account.
    var syncs: Bool { self == .premium }
    /// Reading receipts and writing reports with the AI (quick add is in every plan).
    var hasAiExtras: Bool { self == .premium }
}

/// Who is signed in with Google (the anonymous account the AI uses isn't one).
struct SignedIn: Equatable { let uid: String; let name: String; let email: String }

struct FamilyMember: Equatable { let uid: String; let name: String; let email: String; let owner: Bool }

/// A family: several accounts sharing one set of lists (Android sync/Family.kt).
struct Family: Equatable {
    let id: String
    let ownerUid: String
    let members: [FamilyMember]
    let isOwner: Bool

    static func from(_ d: DocumentSnapshot, me: String) -> Family? {
        guard let owner = d.get("owner") as? String else { return nil }
        let raw = d.get("members") as? [String: Any] ?? [:]
        let members = raw.map { uid, value -> FamilyMember in
            let m = value as? [String: Any] ?? [:]
            return FamilyMember(uid: uid, name: m["name"] as? String ?? "", email: m["email"] as? String ?? "", owner: uid == owner)
        }.sorted { a, b in a.owner != b.owner ? a.owner : a.name.lowercased() < b.name.lowercased() }
        return Family(id: d.documentID, ownerUid: owner, members: members, isOwner: owner == me)
    }
}

/// Everything that talks to Firebase (project spendwise-unes, the same as Android's): the account,
/// the plan, sync, families and the AI backend. The app works without any of it.
@MainActor @Observable
final class Cloud {
    private(set) var user: SignedIn?
    private(set) var tier: Tier = .free
    var syncStatus = SyncStatus()
    var family: Family?
    var busy = false
    var inviteCode: String?

    let ai: AiGateway
    @ObservationIgnored private(set) var sync: CloudSync!
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var planListener: ListenerRegistration?
    @ObservationIgnored private let prefs = UserDefaults.standard

    /// Firebase is off in demo mode (screenshots) and when the config is missing.
    var enabled: Bool { Self.configured }

    init() {
        ai = AiGateway()
        Self.setUp()
        guard Self.configured else { return }
        user = Auth.auth().currentUser.flatMap(Self.signedIn)
        tier = planSwitchable ? debugTier : (user == nil ? .free : lastTier)
        if previewPremium { tier = .premium }
    }

    /// Debug builds: Premium's screens on this phone only (Appetize, no account); the server still
    /// decides what the AI and sync allow.
    var previewPremium: Bool {
        #if DEBUG
        return prefs.bool(forKey: "plan.preview_premium")
        #else
        return false
        #endif
    }

    func setPreviewPremium(_ on: Bool) {
        prefs.set(on, forKey: "plan.preview_premium")
        tier = on ? .premium : (planSwitchable ? debugTier : (user == nil ? .free : lastTier))
    }

    func attach(_ model: AppModel) {
        self.model = model
        ai.attach(model: model, cloud: self)
        guard Self.configured else { return }
        sync = CloudSync(cloud: self, model: model)
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Who is signed in when this runs, not when it was queued: a late "nobody" from
                // start-up must not undo a sign-in that finished meanwhile
                let u = Auth.auth().currentUser
                let signed = u.flatMap(Self.signedIn)
                self.ai.accountChanged(u?.uid)
                if self.user != signed {
                    self.user = signed
                    self.watchPlan()
                    self.sync.update()
                }
            }
        }
        watchPlan()
        sync.update()
    }

    // MARK: - Plan (entitlements/{uid}, written only by the server)

    var planSwitchable: Bool {
        #if DEBUG
        return usingEmulators
        #else
        return false
        #endif
    }

    private var debugTier: Tier { prefs.string(forKey: "plan.debug_tier") == "Premium" ? .premium : .free }
    private var lastTier: Tier { prefs.string(forKey: "plan.last_tier") == "Premium" ? .premium : .free }

    /// Debug builds on the emulators: the Settings switch decides the plan.
    func setDebugTier(_ t: Tier) {
        #if DEBUG
        prefs.set(t == .premium ? "Premium" : "Free", forKey: "plan.debug_tier")
        if planSwitchable { setTier(t) }
        #endif
    }

    /// Demo mode and tests: the plan without a server.
    func overrideTier(_ t: Tier) { tier = t }

    #if DEBUG
    func setDemoUser(_ u: SignedIn?) { user = u }
    #endif

    private func setTier(_ server: Tier) {
        if !planSwitchable { prefs.set(server == .premium ? "Premium" : "Free", forKey: "plan.last_tier") }
        let t: Tier = previewPremium ? .premium : server
        guard t != tier else { return }
        tier = t
        sync?.update()
        Task { await ai.refreshAllowances() }
    }

    private func watchPlan() {
        planListener?.remove()
        planListener = nil
        if planSwitchable { setTier(debugTier); return }
        guard let user else { setTier(.free); return }
        planListener = Self.firestore.collection("entitlements").document(user.uid).addSnapshotListener { [weak self] snap, error in
            guard error == nil else { return } // offline or signed out: keep the last answer
            // "max" (the owner, testers) is Premium with higher limits, counted on the server
            let t = snap?.get("tier") as? String
            let until = (snap?.get("until") as? Timestamp)?.dateValue()
            let premium = (t == "premium" || t == "max") && (until.map { $0 > Date() } ?? true)
            Task { @MainActor in self?.setTier(premium ? .premium : .free) }
        }
    }

    // MARK: - Account

    var canSignInWithGoogle: Bool { Bundle.main.object(forInfoDictionaryKey: "GIDClientID") != nil }

    /// Shows Google's account picker and signs in with the chosen account.
    func signIn() async {
        guard Self.configured else { return }
        busy = true
        defer { busy = false }
        do {
            guard let top = UIApplication.topController else { return }
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: top)
            guard let idToken = result.user.idToken?.tokenString else { return }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            await ai.signInStarting()
            defer { ai.signInEnded() }
            user = Self.signedIn(try await Auth.auth().signIn(with: credential).user)
            watchPlan()
            sync.update()
        } catch {
            if let e = error as? GIDSignInError, e.code == .canceled {
                model?.show(L("msg_sign_in_cancelled"))
            } else {
                print("SpendWise: sign-in failed: \(error)")
                model?.show(UserErrors.message(error, L("err_sign_in")))
            }
        }
    }

    static let testPassword = "test-only"

    /// Emulators only: signs in as a made-up account, so two test phones can share one.
    @discardableResult
    func signInForTest(_ name: String) async -> Bool {
        guard usingEmulators else { return false }
        let email = name.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
        await ai.signInStarting()
        defer { ai.signInEnded() }
        do {
            // The Auth emulator's accounts: made on first use, the display name standing in for Google's
            let u: User
            if let r = try? await Auth.auth().signIn(withEmail: email, password: Self.testPassword) { u = r.user }
            else { u = try await Auth.auth().createUser(withEmail: email, password: Self.testPassword).user }
            if u.displayName != name {
                let change = u.createProfileChangeRequest()
                change.displayName = name
                try await change.commitChanges()
                try await u.reload()
            }
            // The rules compare member entries with the sign-in's token: get one with the name
            _ = try await u.getIDTokenResult(forcingRefresh: true)
            user = Auth.auth().currentUser.flatMap(Self.signedIn)
            watchPlan()
            sync.update()
            return true
        } catch {
            lastError = "\(error)"
            model?.show(UserErrors.message(error, "Test sign-in failed"))
            return false
        }
    }

    /// Why the last call failed, for the test driver's report.
    @ObservationIgnored var lastError: String?

    func signOut() async {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        user = nil
        watchPlan()
        sync.update()
        model?.show(L("msg_signed_out"))
    }

    /// Erases the account's own cloud copy (users/{uid}, never a family's) and the sign-in itself;
    /// the backend's forgetAccount then takes it out of its family. The lists on this phone stay.
    func deleteAccount() async {
        guard let user, let current = Auth.auth().currentUser else { return }
        busy = true
        defer { busy = false }
        do {
            let own = Self.firestore.collection(CloudSync.users).document(user.uid)
            for t in SyncSchema.tables {
                while true {
                    let docs = try await own.collection(t.name).limit(to: 400).getDocuments(source: .server).documents
                    if docs.isEmpty { break }
                    let batch = Self.firestore.batch()
                    docs.forEach { batch.deleteDocument($0.reference) }
                    try await batch.commit()
                }
            }
            try await own.delete()
            var removed = true
            do { try await current.delete() } catch { removed = false }
            try? Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            self.user = nil
            watchPlan()
            sync.update()
            // Firebase only removes a sign-in that was used recently
            model?.show(removed ? L("msg_deleted") : L("delete_needs_login"))
        } catch {
            lastError = "\(error)"
            model?.show(UserErrors.message(error, L("err_delete_account")))
        }
    }

    // MARK: - Family (Android sync/Family.kt)

    private func member(_ u: SignedIn, _ role: String, invite: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["name": u.name, "email": u.email, "role": role, "joinedAt": FieldValue.serverTimestamp()]
        if let invite { m["invite"] = invite }
        return m
    }

    /// Starts a family with this account as owner; its phones then sync with it.
    func createFamily() async {
        guard let user else { return }
        await work(L("err_family_start"), success: L("msg_family_started")) {
            let db = Self.firestore
            let space = db.collection(CloudSync.spaces).document()
            let batch = db.batch()
            batch.setData(["owner": user.uid, "members": [user.uid: self.member(user, "owner")], "createdAt": FieldValue.serverTimestamp()], forDocument: space)
            batch.setData([CloudSync.space: space.documentID], forDocument: db.collection(CloudSync.users).document(user.uid), merge: true)
            try await batch.commit()
        }
    }

    /// A single-use code, valid for 7 days, shown as XXXX XXXX.
    func invite() async {
        guard let user, let family else { return }
        await work(L("err_code"), success: nil) {
            let code = FamilyCodes.newCode()
            try await Self.firestore.collection(CloudSync.invites).document(code).setData([
                "space": family.id, "by": user.uid, "byName": user.name.isEmpty ? user.email : user.name,
                "createdAt": FieldValue.serverTimestamp(), "expiresAt": Timestamp(date: Date().addingTimeInterval(7 * 86_400)),
                "usedBy": NSNull(),
            ])
            self.inviteCode = FamilyCodes.display(code)
        }
    }

    enum JoinResult { case joined, notFound, expired }

    /// Joins with a code (spaces, dashes and lowercase are fine); this phone's lists are merged in.
    @discardableResult
    func joinFamily(_ input: String) async -> JoinResult? {
        guard let user else { return nil }
        let code = FamilyCodes.normalize(input)
        var outcome: JoinResult?
        await work(L("err_join"), success: nil) {
            guard code.count == FamilyCodes.length else { outcome = .notFound; return }
            let db = Self.firestore
            let invite = try await db.collection(CloudSync.invites).document(code).getDocument(source: .server)
            guard invite.exists, let space = invite.get("space") as? String else { outcome = .notFound; return }
            let expires = (invite.get("expiresAt") as? Timestamp)?.dateValue() ?? .distantPast
            if invite.get("usedBy") is String || expires < Date() { outcome = .expired; return }
            let batch = db.batch()
            batch.updateData(["usedBy": user.uid], forDocument: invite.reference)
            batch.updateData(["members.\(user.uid)": self.member(user, "member", invite: code)], forDocument: db.collection(CloudSync.spaces).document(space))
            batch.setData([CloudSync.space: space], forDocument: db.collection(CloudSync.users).document(user.uid), merge: true)
            do {
                try await batch.commit()
                outcome = .joined
            } catch where Cloud.isDenied(error) {
                // The rules refuse a code someone else used a moment ago, or one already in this family
                outcome = .expired
            }
        }
        switch outcome {
        case .joined?: model?.show(L("msg_joined"))
        case .notFound?: model?.show(L("msg_join_not_found"))
        case .expired?: model?.show(L("msg_join_expired"))
        case nil: break
        }
        return outcome
    }

    /// A member leaves; their phones keep a copy of the lists.
    func leaveFamily() async {
        guard let user, let family else { return }
        await work(L("err_leave"), success: L("msg_left")) {
            let db = Self.firestore
            let batch = db.batch()
            batch.updateData(["members.\(user.uid)": FieldValue.delete()], forDocument: db.collection(CloudSync.spaces).document(family.id))
            batch.setData([CloudSync.space: NSNull()], forDocument: db.collection(CloudSync.users).document(user.uid), merge: true)
            try await batch.commit()
        }
    }

    /// The owner takes someone off the family; their phones notice and stop syncing with it.
    func removeMember(_ m: FamilyMember) async {
        guard let family else { return }
        await work(L("err_remove"), success: L("msg_removed", m.name.isEmpty ? m.email : m.name)) {
            try await Self.firestore.collection(CloudSync.spaces).document(family.id).updateData(["members.\(m.uid)": FieldValue.delete()])
        }
    }

    /// The owner closes the family: members are taken off, its copy and unused codes erased.
    func closeFamily() async {
        guard let user, let family else { return }
        await work(L("err_close"), success: L("msg_closed")) {
            let db = Self.firestore
            let space = db.collection(CloudSync.spaces).document(family.id)
            // Members first, so their phones stop writing while the rows go
            try await space.updateData(["members": [user.uid: ["name": user.name, "email": user.email, "role": "owner"]]])
            for t in SyncSchema.tables {
                while true {
                    let docs = try await space.collection(t.name).limit(to: 400).getDocuments(source: .server).documents
                    if docs.isEmpty { break }
                    let batch = db.batch()
                    docs.forEach { batch.deleteDocument($0.reference) }
                    try await batch.commit()
                }
            }
            let batch = db.batch()
            // Its codes too: an unused one still carries the owner's name
            let codes = try await db.collection(CloudSync.invites).whereField("by", isEqualTo: user.uid).whereField("space", isEqualTo: family.id)
                .getDocuments(source: .server).documents
            codes.forEach { batch.deleteDocument($0.reference) }
            batch.deleteDocument(space)
            batch.setData([CloudSync.space: NSNull()], forDocument: db.collection(CloudSync.users).document(user.uid), merge: true)
            try await batch.commit()
        }
    }

    private func work(_ whatFailed: String, success: String?, _ body: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
            if let success { model?.show(success) }
        } catch {
            lastError = "\(error)"
            print("SpendWise: \(whatFailed): \(error)")
            model?.show(UserErrors.message(error, whatFailed))
        }
    }

    // MARK: - Errors

    nonisolated static func isDenied(_ error: Error?) -> Bool {
        guard let ns = error as NSError? else { return false }
        // gRPC's PERMISSION_DENIED, which Firestore passes on as its own code 7
        return ns.domain == FirestoreErrorDomain && ns.code == 7
    }

    nonisolated static func isUnavailable(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == FirestoreErrorDomain && ns.code == 14
    }

    nonisolated static func needsRecentLogin(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == AuthErrorDomain && ns.code == AuthErrorCode.requiresRecentLogin.rawValue
    }

    nonisolated static func isOffline(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let ns = e {
            if ns.domain == NSURLErrorDomain { return true }
            if ns.domain == AuthErrorDomain && ns.code == AuthErrorCode.networkError.rawValue { return true }
            e = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: - Firebase set-up

    private(set) static var configured = false
    private static var setUpDone = false

    /// Before anything touches Firebase: App Check, then debug builds may use the local emulators.
    static func setUp() {
        guard !setUpDone else { return }
        setUpDone = true
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        // Proves to the backend that requests come from this app. Debug builds (the simulator, Appetize)
        // use App Check's debug provider with a token registered in the console
        #if DEBUG
        if let token = Bundle.main.object(forInfoDictionaryKey: "AppCheckDebugToken") as? String, !token.isEmpty, !token.hasPrefix("$(") {
            UserDefaults.standard.set(token, forKey: "FIRAAppCheckDebugToken")
        }
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AttestFactory())
        #endif
        FirebaseApp.configure()
        configured = true
        if emulatorsWanted {
            // The simulator shares the computer's network: the emulators are on its 127.0.0.1
            Auth.auth().useEmulator(withHost: "127.0.0.1", port: authPort)
            usingEmulatorsNow = true
        }
        // First use, before anything listens: a pending clear of the offline copy runs now
        _ = firestore
    }

    static let authPort = 9196
    static let firestorePort = 8196
    static let functionsPort = 5196

    private static var usingEmulatorsNow = false
    var usingEmulators: Bool { Self.usingEmulatorsNow }

    /// Debug builds: talk to the emulators on the computer instead of the real project. Also settable
    /// at launch: `-debug_use_emulators YES`.
    static var emulatorsWanted: Bool {
        get {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "debug_use_emulators")
            #else
            return false
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: "debug_use_emulators") }
    }

    private static var store: Firestore?
    private static let clearKey = "clear_firestore_cache"

    /// The Firestore to use; clears its offline copy first when asked (only safe before first use).
    static var firestore: Firestore {
        if let store { return store }
        let f = Firestore.firestore()
        if usingEmulatorsNow {
            let settings = f.settings
            settings.host = "127.0.0.1:\(firestorePort)"
            settings.isSSLEnabled = false
            f.settings = settings
        }
        if UserDefaults.standard.bool(forKey: clearKey) {
            f.clearPersistence { error in if error == nil { UserDefaults.standard.set(false, forKey: clearKey) } }
        }
        store = f
        return f
    }

    /// Forgets Firestore's offline copy (signing out), the next time the app starts.
    static func clearFirestoreLater() { UserDefaults.standard.set(true, forKey: clearKey) }

    private static var callable: Functions?

    /// The backend's callable functions (Android repo's firebase/functions), on the emulators when asked.
    static var functions: Functions {
        if let callable { return callable }
        let f = Functions.functions(region: "europe-west1")
        if usingEmulatorsNow { f.useEmulator(withHost: "127.0.0.1", port: functionsPort) }
        callable = f
        return f
    }

    private nonisolated static func signedIn(_ u: User) -> SignedIn? {
        u.isAnonymous ? nil : SignedIn(uid: u.uid, name: u.displayName ?? "", email: u.email ?? "")
    }
}

/// Release builds: App Attest on real devices.
final class AttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? { AppAttestProvider(app: app) }
}

extension UIApplication {
    /// The view controller on top, to present Google's sign-in from.
    static var topController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// Whether the phone has a network, for the sync status.
@MainActor @Observable
final class Connectivity {
    private(set) var online = true
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var changed: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let on = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.online != on else { return }
                self.online = on
                self.changed?(on)
            }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity"))
    }
}
