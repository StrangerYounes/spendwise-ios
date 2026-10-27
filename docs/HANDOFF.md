# SpendWise iOS: handoff (updated 27 Oct 2026)

## Status (27 Oct): done, all green
Run 40491927009 passed everything: Core 135 tests, 11 UI flows, 55 backend checks, 120 screenshots.
It added default categories (Groceries, Gifts, Car, Miscellaneous), the item library fed by every
category (Prices tab with category chips, one-time catch-up), and generic names instead of real
stores/brands/places in hints, sample data and prompts. Repo is **private**. Screenshots per run
in `screenshots/` (gitignored). The Android agent got the same tasks (prompt in the 27 Oct chat):
its strings feed scripts/convert_strings.py; iOS overrides qa_example/ai_instructions_quick_hint
until Android changes them. For a new CI round: public, push, watch, private again.

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
