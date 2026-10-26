# SpendWise for iOS

The iPhone version of SpendWise (`~/Documents/Dev/MyShoppingList`, package `com.corner.spendwise`):
shopping lists, prices and spending, with AI quick add, receipts and reports, and Premium sync and
families on the same Firebase project (`spendwise-unes`), so an iPhone and an Android phone share
one account.

- `Core/`: Swift package, Foundation and SQLite only, tested on Linux
  (`. ~/.local/swift/env.sh && swift test --package-path Core`). The same SQLite schema, queries
  and sync triggers as the Android Room database, backups in the same JSON, the AI's answers read
  the same way.
- `App/`: SwiftUI (iOS 17). `App/Cloud/` holds Firebase (account, plan, sync, families, AI).
- `UITests/`: XCUITest flows run on CI.
- `firebase/`: the Android repo's rules and functions, for the CI emulators only (no `.firebaserc`;
  never deploy from here).
- `scripts/`: strings from Android (`convert_strings.py` + `ios-strings.json`), screenshots, the
  backend test (`backend-test.sh`, `backend_check.py`, `fake-gemini.cjs`).
- `.github/workflows/ios.yml`: builds, tests and photographs the app on GitHub's macOS runners.

See `PLAN.md` for what's ported and how iOS differs, and `docs/TESTING.md` for trying it on Appetize.io.
