# SpendWise iOS: handoff (updated 27 Oct 2026)

## Status (27 Oct): done, all green
Run 40491927009 passed everything: Core 135 tests, 11 UI flows, 55 backend checks, 120 screenshots.
It added default categories (Groceries, Gifts, Car, Miscellaneous), the item library fed by every
category (Prices tab with category chips, one-time catch-up), and generic names instead of real
stores/brands/places in hints, sample data and prompts. Repo is **private**. Screenshots per run
in `screenshots/` (gitignored). The Android agent got the same tasks (prompt in the 27 Oct chat):
its strings feed scripts/convert_strings.py; iOS overrides qa_example/ai_instructions_quick_hint
until Android changes them. For a new CI round: public, push, watch, private again.

## 2 Nov task (account switching, welcome, Sign in with Apple)
- **Sections 1–2 ported** (2 Nov), from Android ffb69da (account switching: `Cloud.otherAccount` /
  `answer` / `signOut(removeLists:)`, prefs `sync.data_owner`, Core `DataOwner`, `SyncStore.hasData/wipe`,
  `App/OtherAccount.swift`) and a1c3c9d (welcome: language page first, sign-in page with Apple above
  Google, no tester page). Strings come from Android's **committed** HEAD, never its working copy:
  `git -C ~/Documents/Dev/MyShoppingList archive HEAD app/src/main/res | tar -x -C <tmp>` then
  `python3 scripts/convert_strings.py <tmp>/app/src/main/res App/Resources scripts/ios-strings.json`.
  The Android session (dev-53) waits to hear the iOS CI is green to update its FEATURES §10.2 bullet.
- **Section 3, Sign in with Apple: done in the app** (2 Nov). `App/Cloud/AppleSignIn.swift`
  (AppleAuthorizer, Apple's standard button: the UIKit `ASAuthorizationAppleIDButton`, because the tap
  first shows "Your data in the cloud"; SwiftUI's `SignInWithAppleButton` starts Apple's sheet at once),
  `Cloud.signInWithApple()` (nonce, `OAuthProvider.appleCredential`, the first-time name becomes the
  display name), Delete account revokes Apple's token first (`revokeApple`: re-authenticate with Apple,
  `revokeToken(withAuthorizationCode:)`; on failure nothing is deleted). Core `AppleNonce`, `SHA256`,
  `AccountName` (no name / relay email fallbacks) with tests. Settings: Apple's button above Google's.
  The welcome's sign-in page comes with section 2. Rules, `test_rules.py` (66/66) and
  `grant_premium.py` changed in MyShoppingList (200e22b), **rules not deployed**.
- **Real Apple sign-in can only be tried on a real iPhone or TestFlight**, after the console steps
  below (not in the simulator CI uses, not on Appetize).

### Console checklist (the owner does these)
- [ ] **Apple Developer → Certificates, IDs & Profiles → Identifiers → `com.unes.spendwise`:** tick
      **Sign in with Apple** ("Enable as a primary App ID"), Save. Profiles made after this include it.
- [ ] **Apple Developer → Keys → +:** name "SpendWise Sign in with Apple", tick **Sign in with Apple** →
      Configure → primary App ID `com.unes.spendwise` → Register. Download `AuthKey_<KEYID>.p8` (only
      once; keep it private, not in any repo). Note the **Key ID** (10 characters, on the key's page)
      and your **Team ID** (10 characters, top right / Membership details).
- [ ] **Firebase console → spendwise-unes → Authentication → Sign-in method → Add new provider →
      Apple → Enable.** Services ID: leave empty for now (the Android web flow needs one later,
      FEATURES.md §10.2). Under **OAuth code flow configuration**: Apple team ID = your Team ID,
      Key ID = the key's ID, Private key = the whole contents of the .p8 file. Save. (These are what
      token revocation on Delete account uses.)
- [ ] **Firestore rules:** review MyShoppingList 200e22b, then (when you say so)
      `cd ~/Documents/Dev/MyShoppingList/firebase && firebase deploy --only firestore:rules`.
- Xcode capability: done in the repo (`App/SpendWise.entitlements`: `com.apple.developer.applesignin`).

## Commits
Everything is committed and pushed.
Commit author: `git -c user.email=younes.masri.97@gmail.com commit`, trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never the burner email.

## What the task is
User asked (26 Oct): port the Android app SpendWise (`~/Documents/Dev/MyShoppingList`, Android
head `46142d3`) to iOS, test it via the GitHub pipeline with lots of tests and screenshots, and
look at them. Follow the `android-to-ios` skill (`~/.claude/skills/android-to-ios`). Final report:
what was seen in logs/screenshots (show some), verified vs not, then the elapsed-time line.

## Layout (see README.md, PLAN.md)
- `Core/` SwiftPM `SpendWiseCore`: SQLite wrapper (`CSQLite` systemLibrary on Linux), Room v10
  schema + DAO SQL (`Database.swift`, `Stats.swift`), `ShoppingRepository`, `Backup` (same JSON),
  `Money` (Java-style rounding), `QuickAdd` (parsers, FollowUp, PackHint, NameSuggestions,
  Allowance, AiPayload), `Analysis`, `SyncSchema`/`Sync` (merge, store, family codes),
  `ItemInsights`, `ReceiptText`, `JSON`, `CoreText`. Tests: `swift test --package-path Core`
  after `. ~/.local/swift/env.sh` (132 pass).
- `App/`: SwiftUI screens; `AppModel` (@Observable, revision counter, prefs), `Router`,
  `Strings.swift` (in-app language, `L()`/`P()` Android-style plurals `key#one`…), `Cloud/`
  (Cloud = account/plan/family, AiGateway, CloudSync, BackendTest), `DemoMode`/`DemoData`
  (launch args `-SpendWiseDemo YES -SpendWiseScreen <name>`), `TestDriver` (`-SpendWiseTest <role>`).
- `UITests/` XCUITest (11 flows). `firebase/` Android rules+functions for CI emulators only (no
  .firebaserc). `scripts/`: convert_strings.py + ios-strings.json, screenshots.sh,
  backend-test.sh, backend_check.py, fake-gemini.cjs (NODE_OPTIONS preload stubbing Gemini).
- Firebase: iOS app registered in spendwise-unes (`1:517582004920:ios:db48257d69fa67c2c88a4d`,
  bundle `com.unes.spendwise`), GoogleService-Info.plist committed. Emulator ports 9196/8196/5196.
- Android bugs found (in PLAN.md): `and_separator` spaces trimmed; hardcoded "Lists" header.
- Skill updated with lessons (architecture/environment/pitfalls).

## Time
Elapsed so far: 2 h 30 min (start 1793000416). Keep adding; end replies with
"This response: … · Total: …".
