#!/bin/zsh
# Screenshots of every main surface against the scripted preview service.
#
#   scripts/duo-screenshots.sh <out-dir> [device-udid]
#
# Build first (xcodebuild … -derivedDataPath build/DerivedData build). Uses
# simctl rather than XCTest because XCTest screenshots of an unfolded iPhone Duo
# come back black. Captures every internal display and keeps the non-black one,
# so it works folded or unfolded.
set -u
out=$1
dev=${2:-$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone Duo/ {print $2; exit}')}
[ -n "$dev" ] || { echo "No booted iPhone Duo; pass a device UDID." >&2; exit 1; }
mkdir -p "$out"
app=build/DerivedData/Build/Products/Debug-iphonesimulator/Gian.app
xcrun simctl install "$dev" "$app" || exit 1
original_appearance=$(xcrun simctl ui "$dev" appearance)
displays=($(xcrun simctl io "$dev" enumerate 2>/dev/null | awk '/UUID:/ {uuid=$2} /Display class: 0/ {print uuid}'))
shot() {
  local name=$1 best="" bestsize=0 size
  for d in $displays; do
    xcrun simctl io "$dev" screenshot --display="$d" "/tmp/gian-shot-$d.png" >/dev/null 2>&1 || continue
    size=$(stat -f%z "/tmp/gian-shot-$d.png")
    if [ "$size" -gt "$bestsize" ]; then best="/tmp/gian-shot-$d.png"; bestsize=$size; fi
  done
  [ -n "$best" ] && cp "$best" "$out/$name.png" && echo "$out/$name.png" || echo "FAILED $name"
}
for appearance in Light Dark; do
  xcrun simctl ui "$dev" appearance ${appearance:l}
  xcrun simctl terminate "$dev" dev.gian.ios >/dev/null 2>&1
  xcrun simctl launch "$dev" dev.gian.ios -previewScript fullDirectory -gian.appearance $appearance >/dev/null
  sleep 6
  shot "setup-${appearance:l}"
  for dest in home repos chat newChat settings; do
    xcrun simctl terminate "$dev" dev.gian.ios >/dev/null 2>&1
    xcrun simctl launch "$dev" dev.gian.ios -previewScript fullDirectory -previewReady \
      -previewDestination $dest -gian.appearance $appearance >/dev/null
    sleep 16
    shot "$dest-${appearance:l}"
  done
done
xcrun simctl terminate "$dev" dev.gian.ios >/dev/null 2>&1
# Leave the device as found: -gian.appearance ends up in the app's defaults.
# Through the simulator's cfprefsd (full container path): editing the plist
# directly leaves the cached value in place.
prefs="$(xcrun simctl get_app_container "$dev" dev.gian.ios data)/Library/Preferences/dev.gian.ios"
xcrun simctl spawn "$dev" defaults delete "$prefs" gian.appearance >/dev/null 2>&1
xcrun simctl ui "$dev" appearance "$original_appearance"
