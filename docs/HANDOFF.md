# SpendWise iOS: handoff (26 Oct 2026, written before a context compaction)

## FIRST: wait for the CI run in progress
- Run 40293780477 failed on one error (Core public inits, fixed in commit after edeb7f2). Now wait for run **40318289215**.
  At handoff: core job green (132 tests Linux + macOS), the ios job was in **"Build for the
  simulator (app and UI tests)"** (first build with Firebase SPM, slow).
- Wait for it, don't poll in the foreground. Background wait, e.g.:
  `until s=$(gh run view <run-id> -R StrangerYounes/spendwise-ios --json jobs -q '.jobs[]|select(.name=="ios")|.steps[]|select(.name|startswith("Build for"))|.status') && [ "$s" = completed ]; do sleep 30; done`
  (run_in_background). Two background watchers were already running for it (bp6q842n6 for the
  build step, bhwp4kt4s = `gh run watch` writing scratchpad `run1.txt`); after compaction just
  start a fresh wait.
- On a failed build: `gh run view <run-id> -R StrangerYounes/spendwise-ios --log-failed | grep -E "error:" | sed 's/^.*Z //' | sort -u`,
  fix all errors (read `~/.claude/skills/android-to-ios/references/pitfalls.md`), commit, push
  (repo is **public** now, keep it public while iterating), watch the new run.
- On success: download artifacts to `~/Documents/Dev/SpendWise-iOS-builds/2026-10-26-run-<id>/`
  (`gh run download <id> -R StrangerYounes/spendwise-ios`), make contact sheets with
  `python3 <scratchpad>/sheets.py <dir> <out> 6 0.3 [filter]` (script in the session scratchpad;
  recreate if gone: PIL, 6 shots per sheet at 0.3 scale, filename labels) and **Read every
  screenshot** (EN/AR light, dark set). Check UI test results (`tests` artifact: ui-tests.log) and
  backend test (`tests/backend-test/check.txt`, `*.json`, `emulators.log`). Fix real bugs, rerun.
- When testing is done: `gh api -X PATCH repos/StrangerYounes/spendwise-ios -f visibility=private -q .visibility`.

## Uncommitted local changes (commit + push with the next fix)
- `App/AccountSection.swift`, `App/Cloud/Cloud.swift`: Developer section gets "Show Premium
  screens" (debug, `plan.preview_premium`) and "Load sample data" (DemoData.load).
- `App/Cloud/BackendTest.swift`: sync roles call `cloud.setDebugTier(.premium)` first (on the
  emulators the plan comes from the debug switch; without it sync never starts).
- `docs/TESTING.md` (Appetize guide, new), this file.
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
Elapsed so far: 2 h 8 min (start 1793000416). Keep adding; end replies with
"This response: … · Total: …".
