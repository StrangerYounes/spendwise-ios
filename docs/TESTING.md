# Trying SpendWise for iOS on Appetize.io

Upload `SpendWise-simulator.zip` (from the CI run's artifacts) to appetize.io and choose iOS. Each
session starts empty and resets after a few minutes; there's no camera, microphone or Google
account there.

**Sample data:** Settings → tap "SpendWise 1.0" at the bottom 7 times → Developer appears. (On
Appetize the app talks to the real Firebase project; AI needs the App Check token in "Before you
start" below.)

## Before you start (one time, for the AI on Appetize)
Debug builds prove themselves to the backend with an App Check **debug token**. To let the
Appetize build reach the AI:
1. Firebase console → spendwise-unes → App Check → Apps → **SpendWise iOS** → ⋮ → Manage debug
   tokens → Add debug token → generate one (a UUID), save.
2. GitHub → spendwise-ios → Settings → Secrets and variables → Actions → New repository secret
   `APP_CHECK_DEBUG_TOKEN` with that UUID. The next CI build carries it (never committed).
Without it, everything else works; quick add says the AI didn't accept this copy of the app.

## What to check, by feature
Each line: where, what to do, what you should see. Android's behaviour is the reference.

### First run (welcome and guide)
- Fresh start → three pages, then **Your currency** and the local rate. "العربية" at the top
  switches the whole app to Arabic at once (right to left, Western digits); "English" switches back.
- **Make my first list** → Home says "Make your first list"; the New list button pulses.
  New list → name it → the list opens with "Add your first item"; add one → a card explains ticking
  and Finish shopping (Got it). Leaving the list ends the guide.
- **I've used SpendWise before** → Settings.

### Home
- "Spent in <month>" card (opens Insights), the quick-add bar, search (results show items with
  their list), Active / Completed, list cards with category, date, store, progress, total.
- ⋮ on a card: Edit (name, category) and Delete (asks first).
- Top: receipt icon (Free: sparkle, opens Upgrade), Insights, ⋮ (Categories, Stores, Items,
  Settings).

### A list
- Tick items: they move to In cart; the card's total and progress follow. ✕ removes with **Undo**
  for about 10 s. Everything in the cart → "Everything's in the cart · Finish".
- Add item: the sheet stays open; Enter adds and clears for the next; suggestions show times bought
  and last price, "Cheaper at …" when another store was cheaper. It closes only with ✕.
- Price boxes: type `89500÷3` with the + − × ÷ keys under the box → "= 29833.33"; leaving the box
  puts the result in it.
- Tap an item: the editor (estimated and paid price, note, store, In cart, Delete).
- Title tap renames; ⋮: Reorder (arrows), Reopen (completed lists), Clear all items. Store chip:
  "Where are you shopping?" with New store. Photo icon: attach a photo; tap to view, ✕ removes.

### Items, item insights, Insights
- Items → All items (category filter, sort A–Z / Most bought / Recent) → an item → its insights
  (tiles, price chart by date, purchases, Rename everywhere; onto an existing name it combines).
- Grocery prices tab: library items with per-store prices; Edit, Delete, Merge, add one with +.
- Insights: KPIs, bars per month (tap a bar), category donut (tap a slice or row: it opens to the
  lists behind it; a list opens), stores, biggest purchases, top items, date filter (calendar icon).

### Quick add and receipts (AI)
- The bar or the mic: first use asks **Use the AI?** (Not now does nothing). Type "filled gas for
  40 and milk at Spinneys" → review cards (Bought / To buy, category, store, date, list) → Save.
- Receipt from gallery (Premium): up to three photos, a note, Read receipt → review; "Ask for
  changes…" under it ("remove the coffee"); lira prices convert at the saved rate (Change / Don't
  convert); a price about 3× the last one shows "Pack of 3?".
- Free: the receipt tile has a PREMIUM badge and opens Upgrade.
- Allowance chip next to the title ("88 left"), tap it for the sentence.

### AI reports
- Insights → Ask AI about your spending: presets or a question → the preview says what will be sent
  → Write report → the report (facts, summary, sections, tips); saved below; delete from its page.

### Settings
- Theme, currency (common or Other…), local currency rate (commas are thousands: 89,500), language.
- AI features: Use the AI switch (on asks again), allowances, Your instructions for the AI (See the
  base prompt).
- Your data: Back up (Everything / Item library only → saves a JSON file; an Android backup file
  restores here and vice versa), Restore from backup.
- Sync across devices: Sign in with Google (not possible on Appetize: no Google account), Family.
- About: Privacy policy and Deleting your account open younes.app/spendwise; Contact writes to
  hello@younes.app.

## What CI already checked (each run)
- 132 Core tests (Linux and macOS).
- Screenshots of every screen above, English and Arabic, light and dark.
- UI tests that tap through: new list → items → tick → finish; undo; quick add review and save;
  currency; language switch; Arabic Home; guide; Insights categories; Free receipt → Upgrade;
  rename; sums in price boxes.
- Backend end to end on the Firebase emulators with Android's rules and functions (Gemini stubbed):
  anonymous account, Free allowance, quick add counted, receipt refused on Free, receipt + note +
  own instructions + follow-up on Premium (counted as the backend's charges() says), report request
  and report, base prompts; two simulators on one account: a list made on one reaches the other,
  a tick there and a price change here both survive, a delete reaches both, nothing left waiting.

## Not testable without a real iPhone
Voice notes and spoken follow-ups (no microphone in the simulator), the camera, Google sign-in,
App Attest (release builds), uploads finishing in the background.
