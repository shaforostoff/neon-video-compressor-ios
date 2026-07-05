#!/usr/bin/env bash
#
# package.sh — build an unsigned Release IPA, optimized for size.
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
ICON="$ROOT/Neon Video Compressor/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# --- Optional: shrink the app icon before the asset catalog is compiled. ---
# actool decodes every catalog image to a raw ARGB bitmap and re-compresses it
# with lzfse inside Assets.car, so the source file's *format* (PNG/WebP/HEIC) and
# any *lossless* optimizer make no difference to the shipped size — only the
# icon's colour entropy does. pngquant (lossy palette reduction) lowers that
# entropy and roughly halves the icon's footprint in the .car (~350 KB off the
# IPA). We quantize a throwaway copy and always restore the pristine source
# afterwards (explicitly, and via an EXIT trap), so the committed icon is never
# degraded. Skipped automatically when pngquant isn't installed.
ICON_BAK=""
restore_icon() {
  if [ -n "$ICON_BAK" ] && [ -f "$ICON_BAK" ]; then mv -f "$ICON_BAK" "$ICON"; fi
  ICON_BAK=""
}
trap restore_icon EXIT

if [ -f "$ICON" ] && command -v pngquant >/dev/null 2>&1; then
  echo "==> pngquant: shrinking app icon for this build"
  ICON_BAK="$(mktemp)"
  cp "$ICON" "$ICON_BAK"
  pngquant --force --strip --output "$ICON" -- "$ICON_BAK" \
    || { echo "    (pngquant couldn't hit quality — shipping full-colour icon)"; cp "$ICON_BAK" "$ICON"; }
elif [ -f "$ICON" ]; then
  echo "==> pngquant not installed — full-colour icon (brew install pngquant to shave ~350 KB)"
fi

xcodebuild \
  -project "Neon Video Compressor.xcodeproj" \
  -scheme "Neon Video Compressor" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  clean build

restore_icon   # actool has consumed the icon; put the pristine source back now

# Xcode 15's INFOPLIST_KEY_* synthesis doesn't recognize UIFileSharingEnabled,
# so it's patched in directly here — needed to browse the app's Documents
# folder (e.g. tvc_debug.log) from the Files app.
PLIST="build/Build/Products/Release-iphoneos/Neon Video Compressor.app/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :UIFileSharingEnabled true" "$PLIST"

# UIBackgroundModes=[audio] powers the "keep converting when locked" toggle
# (silent-audio keep-alive). The synthesized Info.plist can't express it, so add
# it here (freshly regenerated each build, so a plain Add is safe).
/usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string audio" "$PLIST"

cd build/Build/Products/Release-iphoneos

rm -rf Payload && mkdir Payload
cp -R "Neon Video Compressor.app" Payload/

# Strip the symbol table from the shipped binary. A plain `xcodebuild build`
# (as opposed to archive/install) leaves DEPLOYMENT_POSTPROCESSING=NO, so the
# ~2 MB debug symbol table is never removed despite STRIP_INSTALLED_PRODUCT=YES.
# The IPA is unsigned (AltStore re-signs on install), so stripping here is safe;
# we only lose crash symbolication, which sideloaded builds don't use anyway.
strip "Payload/Neon Video Compressor.app/Neon Video Compressor"

zip -9 -qr "Neon Video Compressor.ipa" Payload
mv -f "Neon Video Compressor.ipa" "$ROOT/"


cd "$ROOT"
echo "==> Built Neon Video Compressor.ipa ($(ls -l "Neon Video Compressor.ipa" | awk '{print $5}') bytes)"
