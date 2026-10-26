# SpendWise iOS port

Ported 26 Oct 2026 from Android `46142d3` (25 Oct). Feature reference: the Android repo's
`docs/FEATURES.md`; this file says what the iPhone does differently and why.

## What's ported
Everything in FEATURES.md §2–§6: Home, lists (Add items, item editor, undo, store, photos, reorder,
Finish/Reopen, sums in price boxes, sheets that close only with ✕), Items and the item library
(rename/merge), item insights, Insights (bars, category donut with its lists, date filter),
categories and stores (rename/merge), Settings (theme, currency, local rate, language, backup and
restore, AI consent and allowances, your instructions for the AI, About), the first-run welcome and
guide, Upgrade, AI quick add (typed or voice), receipts (up to three photos, a note, follow-ups,
pack hints, conversions, on-device fallback), AI reports, account (Google sign-in, sign out, delete
account), sync (field-level merge, offline, joining an account with data), families (start, invite,
join, remove, leave, close).

## Data formats kept identical
- The database: Room's version-10 schema, queries and sync triggers, in SQLite (`Core/Database.swift`,
  `SyncSchema.swift`). Bundle id `com.unes.spendwise`.
- Backups: the same JSON (version 3), version-1 files import (`Core/Backup.swift`, tested with the
  Android fixture `backup_v1.json`).
- Firestore: `users/{uid}/{table}/{uid}` and `spaces/{id}/…` with `_t`, `_deleted`, `_by`;
  `entitlements`, `invites`. The AI backend (`ai`, `aiAllowance`, `aiPrompts`) gets the same payloads.
- Settings keys follow Android's prefs (`app_language`, `ai_consent.granted`, `onboarding.step`…).

## iOS differences (platform-forced)
| Android | iOS |
|---|---|
| Play Integrity App Check | App Attest (release), App Check debug provider (debug builds; token from the CI secret `APP_CHECK_DEBUG_TOKEN`, to register in the console) |
| Credential Manager Google sign-in | GoogleSignIn-iOS. **App Store rule 4.8:** a release with Google sign-in also needs Sign in with Apple (to do before release) |
| Per-app language (system) | In-app switch (Settings, welcome) loads that language's strings at once; iOS Settings → SpendWise → Language also works |
| MediaRecorder AAC/ADTS | AVAudioRecorder AAC in an ADTS `.aac` file (the backend sends it as audio/aac) |
| Gallery multi-pick sorted by date taken | PhotosPicker, in the order picked (no photo-library permission asked) |
| ML Kit on-device text | Vision text recognition, then the same row parser (`ReceiptText`) |
| WorkManager background upload | Uploads finish in a short background task when leaving the app; the rest go up on the next open |
| Crashlytics | Not added yet (needs dSYM upload); planned with the release setup |
| Price box: + − × ÷ insert at the cursor | They're added at the end of the box (SwiftUI on iOS 17 has no cursor position) |
| Play Billing (none yet) | No App Store subscription yet either; Upgrade says it's coming |

## Android bugs found while porting
1. `and_separator` is `" and "` in strings.xml (Arabic `" و "`), but Android trims the spaces, so
   the AI report preview reads "Looks at: spendingandprice trends". Fix: ` and ` as done
   for `each_suffix`. iOS has the spaced text (`scripts/ios-strings.json`). Same for `qa_heard`
   (`Heard: “%1$s”. ` loses its trailing space): quick add shows `Heard: “hello”.No purchases found…`.
2. Home's search results show a fixed English "Lists" header (no string resource), also in Arabic.
   iOS shows «القوائم» in Arabic.

## Testing
- Core: 132 tests on Linux and macOS (the Android unit and instrumented tests ported, plus the
  database, stats, repository and sync-store tests).
- CI: screenshots of every screen in English and Arabic (light, and dark for the main ones), UI
  tests that tap through the app, and the backend end to end on the Firebase emulators with
  Android's real rules and functions (Gemini stubbed): AI quick add, receipts, follow-ups, own
  instructions, allowances and reports; two simulators sharing one account.
