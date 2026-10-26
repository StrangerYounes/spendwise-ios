#!/usr/bin/env bash
# Installs a simulator build of the app and photographs its main screens, in English and Arabic,
# light and dark. Runs on a Mac (or a macOS CI runner) with Xcode:
#
#   BUNDLE=com.unes.myapp DEMO=MyApp SCREENS="home contact settings" DARK="home" \
#     scripts/screenshots.sh build/Build/Products/Debug-iphonesimulator/MyApp.app <simulator-udid> screenshots
#
# The app's debug build reads -MyAppDemo YES -MyAppScreen <name> (see templates/DemoMode.swift.example)
# to load sample data and open a screen by itself, so no tapping is needed. LANGS="en ar" by default.
set -euo pipefail

APP="$1"
UDID="$2"
OUT="${3:-screenshots}"
BUNDLE="${BUNDLE:?set BUNDLE, e.g. com.unes.myapp}"
DEMO="${DEMO:?set DEMO, the launch-arg prefix, e.g. MyApp (reads -MyAppDemo -MyAppScreen)}"
SCREENS="${SCREENS:-onboarding home settings}"   # every screen DemoMode knows
DARK="${DARK:-home}"             # also shot in dark mode

mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

shoot() { # language appearance screen
  local lang="$1" look="$2" screen="$3"
  xcrun simctl ui "$UDID" appearance "$look"
  local locale=en_US
  [ "$lang" = ar ] && locale=ar_LB
  local file="$OUT/${lang}_${look}_${screen}.png" try
  # A launch now and then shows only the empty background when the shot is taken (a blank frame
  # is ~90 KB, a real screen 100 KB+): relaunch and wait longer
  for try in 1 2 3; do
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE" \
      -AppleLanguages "($lang)" -AppleLocale "$locale" \
      -"${DEMO}Demo" YES -"${DEMO}Screen" "$screen" >/dev/null
    sleep $(( ${WAIT:-4} * try ))
    xcrun simctl io "$UDID" screenshot --type=png "$file" >/dev/null
    [ "$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")" -ge "${MIN_BYTES:-95000}" ] && break
    echo "  (blank, retrying $lang $look $screen)"
  done
  echo "  $lang $look $screen"
}

for lang in ${LANGS:-en ar}; do
  for screen in $SCREENS; do shoot "$lang" light "$screen"; done
  for screen in $DARK; do shoot "$lang" dark "$screen"; done
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
echo "Screenshots in $OUT"
