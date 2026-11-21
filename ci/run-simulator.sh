#!/usr/bin/env bash
# Runs the built app in the iOS Simulator, as an iPhone and as an iPad, for CI: screenshots of
# Play and of each Setup tab (English, then Arabic), and an end-to-end check of the TV side: a
# stand-in TV (ci/fake_tv.py) is connected with its code, the app reads a game-like picture it
# draws itself (-vitDemoText) with Vision and the core, and the TV must get the lines on its page.
#
#   ci/run-simulator.sh build/dd/Build/Products/Debug-iphonesimulator/VITranslator.app out
set -uo pipefail
APP="$1"
OUT="$2"
BID=app.vitranslator.phone
mkdir -p "$OUT"

pick() { python3 ci/pick-sim.py "$1"; }

boot() {
  local udid="$1"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 2>/dev/null || true
  xcrun simctl install "$udid" "$APP"
}

shot() {
  local udid="$1" name="$2" wait="$3"
  shift 3
  xcrun simctl terminate "$udid" "$BID" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BID" "$@" > /dev/null
  sleep "$wait"
  xcrun simctl io "$udid" screenshot "$OUT/$name.png" > /dev/null && echo "  $name.png"
}

PHONE="$(pick iPhone)"
PAD="$(pick iPad)"
echo "== iPhone $PHONE, iPad $PAD"
boot "$PHONE"

echo "== the TV side: a stand-in TV, connected with its code, gets the lines the app reads"
python3 ci/fake_tv.py --code 123456 --timeout 300 --want-lines 0 --out "$OUT/fake-tv.json" > "$OUT/fake-tv.log" 2>&1 &
TV=$!
sleep 2
# (the TV's address as on a home network: the core connects TVs on the LAN, here the Mac's own)
LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 127.0.0.1)"
echo "TV at $LAN:8792"
xcrun simctl launch "$PHONE" "$BID" -vitConsole ps5 -vitMode play -vitUiLang en \
  -vitPairTv "$LAN:8792" -vitPairCode 123456 -vitDemoText "Where were you last night?" > /dev/null
# (the first run downloads the reviewed translations and loads Vision's model)
for i in $(seq 1 60); do
  kill -0 "$TV" 2>/dev/null || break
  sleep 5
done
xcrun simctl io "$PHONE" screenshot "$OUT/iphone-play-demo.png" > /dev/null
kill "$TV" 2>/dev/null
wait "$TV"
TV_RESULT=$?
cat "$OUT/fake-tv.log" | tail -n 30
echo "fake TV result: $TV_RESULT"

echo "== screenshots"
for tab in source show snapshot translator profile areas pages; do
  shot "$PHONE" "iphone-setup-$tab" 5 -vitMode setup -vitTab "$tab" -vitConsole ps5 -vitPs5Steps YES
done
shot "$PHONE" "iphone-setup-source-xbox" 5 -vitMode setup -vitTab source -vitConsole xbox
shot "$PHONE" "iphone-play" 5 -vitMode play -vitConsole ps5
shot "$PHONE" "iphone-ar-play" 6 -vitMode play -vitUiLang ar
shot "$PHONE" "iphone-ar-setup-source" 5 -vitMode setup -vitTab source -vitConsole ps5 -vitPs5Steps YES
xcrun simctl spawn "$PHONE" log show --last 15m --style compact --predicate 'process == "VITranslator"' > "$OUT/iphone.log" 2>/dev/null || true
echo "== what the core made of the demo picture"
grep "VIT-CI" "$OUT/iphone.log" | cut -c1-400 | tail -n 8
# the subtitle was read with Vision and handled by the core: its memory saw it (a hit or a miss)
READ_OK=1
grep "VIT-CI read=" "$OUT/iphone.log" | grep -qE '"(hits|misses)":[1-9]' && READ_OK=0
echo "demo subtitle read by the core: $([ $READ_OK -eq 0 ] && echo yes || echo NO)"
xcrun simctl shutdown "$PHONE" 2>/dev/null || true

if [ -n "$PAD" ]; then
  boot "$PAD"
  shot "$PAD" "ipad-play-demo" 30 -vitMode play -vitConsole ps5 -vitUiLang en -vitDemoText "Where were you last night?"
  shot "$PAD" "ipad-setup-source" 5 -vitMode setup -vitTab source -vitConsole ps5 -vitPs5Steps YES
  shot "$PAD" "ipad-setup-areas" 5 -vitMode setup -vitTab areas
  shot "$PAD" "ipad-ar-play" 6 -vitMode play -vitUiLang ar
  xcrun simctl shutdown "$PAD" 2>/dev/null || true
fi
[ "$TV_RESULT" -eq 0 ] && [ "$READ_OK" -eq 0 ]
