#!/usr/bin/env bash
# CI: the app against the Firebase emulators (Auth 9196, Firestore 8196, Functions 5196 with a
# stubbed Gemini, see fake-gemini.cjs). Each role writes Documents/test-report.json in the app's
# container; backend_check.py checks the reports and Firestore's copy.
#
#   scripts/backend-test.sh <SpendWise.app> <udid> <second udid> <out dir>
set -uo pipefail
APP="$1"; UDID="$2"; UDID2="$3"; OUT="$4"
BUNDLE=com.unes.spendwise
mkdir -p "$OUT"
# macOS has no `timeout`; a hung simctl call must not hang the job
limit() { s=$1; shift; perl -e 'alarm shift; exec @ARGV or die' "$s" "$@"; }

for u in "$UDID" "$UDID2"; do
  limit 120 xcrun simctl boot "$u" 2>/dev/null || true
  limit 300 xcrun simctl bootstatus "$u" -b > /dev/null || true
  limit 120 xcrun simctl install "$u" "$APP"
done

# role udid seconds [fresh]
run_role() {
  local role="$1" udid="$2" seconds="$3" fresh="${4:-}"
  local container report
  echo "== $role on $udid"
  limit 30 xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  container=$(limit 30 xcrun simctl get_app_container "$udid" "$BUNDLE" data)
  report="$container/Documents/test-report.json"
  rm -f "$report"
  local args=(-AppleLanguages "(en)" -AppleLocale en_US -SpendWiseTest "$role" -debug_use_emulators YES)
  [ -n "$fresh" ] && args+=(-SpendWiseFresh YES)
  limit 60 xcrun simctl launch "$udid" "$BUNDLE" "${args[@]}" > /dev/null || { sleep 5; limit 60 xcrun simctl launch "$udid" "$BUNDLE" "${args[@]}" > /dev/null; }
  local waited=0
  while [ $waited -lt "$seconds" ]; do
    if [ -f "$report" ] && grep -q '"done" : true' "$report"; then break; fi
    sleep 3; waited=$((waited + 3))
  done
  cp "$report" "$OUT/$role.json" 2>/dev/null || echo "{\"role\": \"$role\", \"steps\": [], \"done\": false}" > "$OUT/$role.json"
  limit 30 xcrun simctl io "$udid" screenshot --type=png "$OUT/$role.png" > /dev/null 2>&1 || true
  limit 30 xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  grep -E '"name"|"ok"|"detail"' "$OUT/$role.json" | paste - - - | sed 's/^ *//' || true
}

run_role ai "$UDID" 300 fresh
python3 scripts/backend_check.py prepare
run_role owner "$UDID" 240 fresh
run_role member "$UDID2" 300 fresh
run_role owner2 "$UDID" 240
python3 scripts/backend_check.py check "$OUT" | tee "$OUT/check.txt"
exit "${PIPESTATUS[0]}"
