#!/usr/bin/env bash
#
# rebuild-n-package.sh — fast iteration build for C++/app-source changes.
#
# Unlike package.sh (which does a size-optimized `clean build` + strip for a
# shippable IPA), this does an *incremental* build: xcodebuild recompiles only
# the sources you touched (e.g. Engine/Transcoder.cpp) and relinks, so turnaround
# is seconds instead of a full clean rebuild.
#
# It also intentionally does NOT strip the shipped binary and preserves the
# dSYM, so crash reports (.ips) can still be symbolicated with:
#   atos -o "build/Build/Products/Release-iphoneos/Neon Video Compressor.app.dSYM/Contents/Resources/DWARF/Neon Video Compressor" \
#        -arch arm64 -l <loadAddr> <addr>
#
# Output: ./Neon Video Compressor.ipa  (unsigned; AltStore/your sideloader re-signs)
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

APP="Neon Video Compressor"
PRODUCTS="build/Build/Products/Release-iphoneos"

# Incremental build. No `clean`, so only changed translation units recompile.
# DEBUG_INFORMATION_FORMAT=dwarf-with-dsym guarantees the .dSYM is (re)generated
# for symbolication even on incremental builds.
xcodebuild \
  -project "$APP.xcodeproj" \
  -scheme "$APP" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  build

# Same UIFileSharingEnabled patch as package.sh, so the app's Documents folder
# (tvc_debug.log, transcoded output) stays browsable from the Files app.
PLIST="$PRODUCTS/$APP.app/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :UIFileSharingEnabled true" "$PLIST"

cd "$PRODUCTS"

rm -rf Payload && mkdir Payload
cp -R "$APP.app" Payload/

# NOTE: deliberately NOT stripping — keep symbols in the shipped binary so crash
# frames in our C++ resolve directly (the dSYM alongside also works). Use
# package.sh for the lean, stripped, shippable IPA.

zip -9 -qr "$APP.ipa" Payload
mv -f "$APP.ipa" "$ROOT/"

cd "$ROOT"
echo "==> Built $APP.ipa ($(ls -l "$APP.ipa" | awk '{print $5}') bytes)"
echo "==> dSYM: $PRODUCTS/$APP.app.dSYM"
