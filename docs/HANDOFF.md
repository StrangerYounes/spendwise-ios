# SpendWise iOS: handoff (26 Oct 2026, written before a context compaction)

## FIRST (27 Oct): check run 40332146549, then finish
State on 26 Oct evening: the app builds; run 6 (40325996166) passed every backend check (55/55:
AI, allowances, receipts + note + own instructions + follow-up, reports, two-phone sync) and every
UI test but one (Insights category, a test-scrolling problem). Run 7 (40332146549) carries that
test fix but was CANCELLED (the handoff push cancelled it via the workflow concurrency group, and that push's run was cancelled too): rerun it with `gh run rerun 40332146549 -R StrangerYounes/spendwise-ios` after making the repo public. Repo is **private** now.
1. `gh run view 40332146549 -R StrangerYounes/spendwise-ios --json conclusion,jobs`. If the UI test
   still fails: make the repo public (`-f visibility=public`), fix, push, watch, then private again.
2. When green: `gh run download <id> -R StrangerYounes/spendwise-ios -n screenshots` into
   `~/Documents/Dev/SpendWise-iOS-builds/2026-10-27-run-<id>/` and copy the PNGs to
   `screenshots/<date>-run-<id>/app/` in this repo (the user asked for every CI run's shots there;
   gitignored). Run 3 and run 4 are already there. Review new shots (contact sheets).
3. Make sure the repo is private, then give the user the final report: what was verified (Core
   132 tests; 12 UI flows; 55 backend checks; 120 screenshots EN/AR light + dark reviewed), what
   was fixed along the way, Android bugs found (PLAN.md: and_separator, qa_heard spaces, the
   anonymous sign-in race, hardcoded "Lists"), and what needs a real iPhone (docs/TESTING.md).
   Offer to report the Android bugs/fix them in the Android repo.

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
- `UITests/` XCUITest (12 flows). `firebase/` Android rules+functions for CI emulators only (no
  .firebaserc). `scripts/`: convert_strings.py + ios-strings.json, screenshots.sh,
  backend-test.sh, backend_check.py, fake-gemini.cjs (NODE_OPTIONS preload stubbing Gemini).
- Firebase: iOS app registered in spendwise-unes (`1:517582004920:ios:db48257d69fa67c2c88a4d`,
  bundle `com.unes.spendwise`), GoogleService-Info.plist committed. Emulator ports 9196/8196/5196.
- Android bugs found (in PLAN.md): `and_separator` spaces trimmed; hardcoded "Lists" header.
- Skill updated with lessons (architecture/environment/pitfalls).

## Time
Elapsed so far: 2 h 30 min (start 1793000416). Keep adding; end replies with
"This response: … · Total: …".
