import FirebaseAuth
import FirebaseFunctions
import Foundation
import Observation
import SpendWiseCore

/// The only thing in the app that talks to the AI (Android util/AiGateway.kt): it calls the `ai`
/// Cloud Function, which holds the Gemini key, writes the prompts and counts each account's
/// allowance. The app sends only what a request needs; the account never reaches the AI.
///
/// Phones that aren't signed in get an anonymous Firebase account the first time they use the AI,
/// so their allowance can be counted; it never shows as signed in and can't sync.
@MainActor @Observable
final class AiGateway {
    /// The last known allowance per feature (empty until refreshAllowances or a request answers).
    private(set) var allowances: [AiFeature: Allowance] = [:]
    /// Bumped on every change, so a refresh that a request overtook doesn't put older counts back.
    @ObservationIgnored private var allowanceVersion = 0
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var cloud: Cloud?
    @ObservationIgnored private var countsFor: String?

    #if DEBUG
    /// Demo mode and tests: answers instead of the backend, by feature.
    @ObservationIgnored var demoAnswer: ((AiFeature, JSON) async throws -> String)?
    #endif

    func attach(model: AppModel, cloud: Cloud) {
        self.model = model
        self.cloud = cloud
    }

    /// The counts belong to an account: another one (signing in or out, a new anonymous one) starts afresh.
    func accountChanged(_ uid: String?) {
        if uid != countsFor {
            allowances = [:]
            countsFor = uid
            Task { await refreshAllowances() }
        }
    }

    func languageChanged() {}

    /// The last count, unless it's from an earlier day or week (then nothing rather than a guess).
    func current(_ f: AiFeature) -> Allowance? { allowances[f].flatMap { $0.isCurrent() ? $0 : nil } }

    /// For tests and screenshots.
    func setAllowance(_ f: AiFeature, _ a: Allowance) { allowances[f] = a; allowanceVersion += 1 }

    private var tzOffsetMin: Int { TimeZone.current.secondsFromGMT() / 60 }

    private var debugTier: Any {
        guard let cloud, cloud.planSwitchable else { return NSNull() }
        return cloud.tier == .premium ? "premium" : "free"
    }

    private var lang: String { Lang.isArabic ? "ar" : "en" }

    /// Asks the backend how much of each feature is used (nothing goes to the AI). Only once the
    /// person agreed to the AI, since it may make the anonymous account. Failures keep the last answer.
    func refreshAllowances() async {
        guard let model, model.consentGranted, Cloud.configured else { return }
        do {
            try await ensureAccount()
            let asked = Auth.auth().currentUser?.uid
            let version = allowanceVersion
            let callable = Cloud.functions.httpsCallable("aiAllowance")
            callable.timeoutInterval = 20
            let data: [String: Any] = ["tzOffsetMin": tzOffsetMin, "debugTier": debugTier, "lang": lang]
            let result = try await callable.call(data)
            guard let features = (result.data as? [String: Any])?["features"] as? [String: Any] else { return }
            // Not if the account changed while asking
            guard asked == Auth.auth().currentUser?.uid else { return }
            // Nor if a request brought newer counts meanwhile
            guard version == allowanceVersion else { return }
            var next: [AiFeature: Allowance] = [:]
            for f in AiFeature.allCases { if let a = Allowance.from(features[f.id]) { next[f] = a } }
            allowances = next
        } catch {
            print("SpendWise: allowance refresh failed: \(error)")
        }
    }

    /// Sends one request and returns the model's JSON text. [payload] holds the feature's own fields.
    func generate(_ feature: AiFeature, _ payload: JSON) async throws -> String {
        // The screens ask first; this is the backstop, before even an anonymous account is made
        guard let model, model.consentGranted else { throw AiError(L("ai_consent_off")) }
        #if DEBUG
        if let demoAnswer { return try await demoAnswer(feature, payload) }
        #endif
        guard Cloud.configured else { throw AiError(L("ai_offline"), retryable: true) }
        try await ensureAccount()
        var data = payload.foundation as? [String: Any] ?? [:]
        data["feature"] = feature.id
        data["tzOffsetMin"] = tzOffsetMin
        data["debugTier"] = debugTier
        // The person's own additions to this feature's prompt
        data["instructions"] = model.instructions(for: feature) ?? NSNull()
        // The backend's messages come back in the app's language
        data["lang"] = lang
        let result: HTTPSCallableResult
        do {
            let callable = Cloud.functions.httpsCallable("ai")
            callable.timeoutInterval = feature.timeout
            result = try await callable.call(data)
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain {
                let code = FunctionsErrorCode(rawValue: ns.code)
                print("SpendWise: \(feature.id) failed: \(ns.code)")
                // Out of allowance: show it as used up until the next refresh says otherwise
                if code == .resourceExhausted, var a = allowances[feature] {
                    a.used = a.limit ?? a.used
                    allowances[feature] = a
                    allowanceVersion += 1
                }
                throw AiError(message(for: ns), retryable: code.map { [FunctionsErrorCode.unavailable, .deadlineExceeded, .internal].contains($0) } ?? false)
            }
            print("SpendWise: \(feature.id) failed: \(error)")
            throw AiError(L("ai_offline"), retryable: true)
        }
        guard let map = result.data as? [String: Any] else { throw AiError(L("ai_empty"), retryable: true) }
        if let a = Allowance.from(map["allowance"]) { allowances[feature] = a; allowanceVersion += 1 }
        // Everything the request used: a receipt's note counts as a quick add, a follow-up is a quick add
        if let all = map["allowances"] as? [String: Any] {
            for (id, value) in all {
                if let f = AiFeature(rawValue: id), let a = Allowance.from(value) { allowances[f] = a; allowanceVersion += 1 }
            }
        }
        guard let json = map["json"] as? String else { throw AiError(L("ai_empty"), retryable: true) }
        return json
    }

    /// The backend's own messages (marked `shown`) are written for people; Firebase's generic ones aren't.
    private func message(for e: NSError) -> String {
        let details = e.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        let own = (details?["shown"] as? Bool == true && !e.localizedDescription.isEmpty) ? e.localizedDescription : nil
        switch FunctionsErrorCode(rawValue: e.code) {
        case .permissionDenied?, .resourceExhausted?, .failedPrecondition?, .aborted?: return own ?? L("ai_cant_take")
        // The backend's checks on what the app sent: written for developers, and a bug in the app
        case .invalidArgument?: return L("ai_invalid")
        case .unauthenticated?: return own ?? L("ai_unauth")
        case .deadlineExceeded?: return own ?? L("ai_slow")
        case .unavailable?: return own ?? L("ai_offline")
        default: return own ?? L("ai_down")
        }
    }

    @ObservationIgnored private var accountTask: Task<Void, Error>?

    /// One account check at a time, shared by everyone asking (allowances, a request).
    private func ensureAccount() async throws {
        if let running = accountTask { return try await running.value }
        let task = Task { try await self.checkAccount() }
        accountTask = task
        defer { accountTask = nil }
        try await task.value
    }

    @ObservationIgnored private var signingIn = false

    /// Before signing in: an anonymous sign-in under way finishes first, and none starts until
    /// [signInEnded], so none can land after (and replace) the new sign-in.
    func signInStarting() async {
        signingIn = true
        _ = try? await accountTask?.value
    }

    func signInEnded() { signingIn = false }

    /// Makes sure there's an account whose sign-in still works: an anonymous one is replaced, a
    /// Google one has to sign in again.
    private func checkAccount() async throws {
        let auth = Auth.auth()
        if let user = auth.currentUser {
            do {
                _ = try await user.getIDToken()
                return
            } catch {
                let ns = error as NSError
                if ns.domain == AuthErrorDomain && ns.code == AuthErrorCode.networkError.rawValue { throw AiError(L("ai_offline"), retryable: true) }
                print("SpendWise: sign-in no longer valid: \(error)")
                if !user.isAnonymous { throw AiError(L("ai_signin_expired")) }
                try? auth.signOut()
            }
        }
        // A sign-in is under way: its account will do (allowances wait for the next refresh)
        if signingIn { throw AiError(L("ai_offline"), retryable: true) }
        do {
            _ = try await auth.signInAnonymously()
        } catch {
            print("SpendWise: anonymous sign-in failed: \(error)")
            throw AiError(L("ai_offline"), retryable: true)
        }
    }

    /// The base prompts as the backend writes them, keyed by feature id. Nothing of the person's is
    /// sent, so this needs neither consent nor an account.
    func basePrompts() async throws -> [String: String] {
        #if DEBUG
        if DemoMode.isOn { return DemoData.basePrompts }
        #endif
        guard Cloud.configured else { throw AiError(L("ai_offline"), retryable: true) }
        do {
            let callable = Cloud.functions.httpsCallable("aiPrompts")
            callable.timeoutInterval = 20
            let result = try await callable.call()
            guard let prompts = (result.data as? [String: Any])?["prompts"] as? [String: Any] else { throw AiError(L("ai_empty"), retryable: true) }
            return prompts.compactMapValues { $0 as? String }
        } catch let e as AiError {
            throw e
        } catch {
            print("SpendWise: prompts failed: \(error)")
            throw AiError(L("ai_offline"), retryable: true)
        }
    }
}
