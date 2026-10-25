#!/bin/sh
# Takes store screenshots on a simulator: runs integration_test/screenshots_test.dart
# and captures the screen whenever it asks.
#   tool/screenshots.sh <simulator udid> <output dir> [flutter test --dart-define=... args]
set -eu
udid=$1 out=$2
shift 2
app=org.minstrelplayer.minstrel
mkdir -p "$out"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# The classic status bar: 9:41, full battery and signal.
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

flutter test integration_test/screenshots_test.dart -d "$udid" "$@" &
test_pid=$!

docs=""
while kill -0 $test_pid 2>/dev/null; do
  if [ -z "$docs" ]; then
    data=$(xcrun simctl get_app_container "$udid" $app data 2>/dev/null || true)
    [ -n "$data" ] && docs="$data/Documents"
  fi
  if [ -n "$docs" ] && [ -f "$docs/shot-request" ]; then
    name=$(cat "$docs/shot-request")
    rm -f "$docs/shot-request"
    xcrun simctl io "$udid" screenshot --type=png "$out/$name.png" >/dev/null 2>&1
    echo "captured $out/$name.png"
    touch "$docs/shot-done"
  fi
  sleep 0.3
done
wait $test_pid
