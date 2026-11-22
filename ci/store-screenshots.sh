#!/usr/bin/env bash
# The App Store's screenshots, made in the iOS Simulator at the sizes Apple asks for: an iPhone
# 6.9" (iPhone Pro Max) and an iPad 13" (iPad Pro 13-inch). Into fastlane/screenshots/en-US/, which
# fastlane deliver uploads (the other languages show the English ones).
#
#   ci/store-screenshots.sh build/dd/Build/Products/Debug-iphonesimulator/VITranslator.app
set -uo pipefail
APP="$1"
OUT="fastlane/screenshots/en-US"
BID=app.vitranslator.phone
rm -rf "$OUT"
mkdir -p "$OUT"

boot() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b > /dev/null
  xcrun simctl status_bar "$1" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true
  xcrun simctl install "$1" "$APP"
}

shot() {
  local udid="$1" name="$2" wait="$3"
  shift 3
  xcrun simctl terminate "$udid" "$BID" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BID" "$@" > /dev/null
  sleep "$wait"
  xcrun simctl io "$udid" screenshot "$OUT/$name.png" > /dev/null && echo "  $name.png"
}

for dev in "iPhone 17 Pro Max" "iPad Pro 13"; do
  UDID="$(python3 ci/pick-sim.py "$dev")" || UDID=""
  if [ -z "$UDID" ]; then
    # (an older runner: the largest of its kind)
    UDID="$(python3 ci/pick-sim.py "${dev%% *}")"
  fi
  tag=$([ "${dev%% *}" = iPhone ] && echo iphone || echo ipad)
  echo "== $dev ($UDID)"
  boot "$UDID"
  shot "$UDID" "${tag}_1_play" 25 -vitMode play -vitConsole ps5 -vitUiLang en -vitDemoText "Where were you last night?"
  shot "$UDID" "${tag}_2_areas" 6 -vitMode setup -vitTab areas
  shot "$UDID" "${tag}_3_source" 6 -vitMode setup -vitTab source -vitConsole ps5 -vitPs5Steps YES
  shot "$UDID" "${tag}_4_show" 6 -vitMode setup -vitTab show
  shot "$UDID" "${tag}_5_translator" 6 -vitMode setup -vitTab translator
  shot "$UDID" "${tag}_6_arabic" 25 -vitMode play -vitUiLang ar -vitDemoText "Where were you last night?"
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
done
ls -la "$OUT"
python3 - "$OUT" <<'PY'
import struct, sys, os
for f in sorted(os.listdir(sys.argv[1])):
    with open(os.path.join(sys.argv[1], f), "rb") as h:
        h.read(16); w, ht = struct.unpack(">II", h.read(8))
    print(f, w, "x", ht)
PY
