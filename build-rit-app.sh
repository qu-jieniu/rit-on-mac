#!/usr/bin/env bash
# Build a Mac-distributable RIT.app (+ RIT.dmg) on a macOS host.
#
# Inputs (alongside this script):
#   ./http.sys                       — patched http.sys PE (built on Linux)
#   ./wine-host-matches-star-wildcard.patch  — the 1-line Wine patch (reference)
#
# Output:
#   ./out/RIT.app
#   ./out/RIT.dmg
#
# Requires (install once):
#   brew install --cask --no-quarantine gcenx/wine/wineskin
#
# Optional (recommended): Developer ID Application cert in your login keychain
# for codesign, and an Apple ID with app-specific password for notarization.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
WRAPPER_NAME="RIT.app"
WRAPPER="$OUT/$WRAPPER_NAME"
ENGINE="${WS_ENGINE:-WS11WineCX64Bit24.0.0}"   # override if you bumped engines
CLIENT_URL="${CLIENT_URL:-http://rit.306w.ca/client/Client.application}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Run this on macOS. (We can build the http.sys patch on Linux, but the .app wrapper is Mac-only.)" >&2
    exit 1
fi

WSY="/Applications/Wineskin Winery.app"
if [[ ! -d "$WSY" ]]; then
    echo "Wineskin Winery not found at $WSY"
    echo "Install with:  brew install --cask --no-quarantine gcenx/wine/wineskin"
    exit 1
fi

if [[ ! -f "$HERE/http.sys" ]]; then
    echo "Missing $HERE/http.sys (the patched driver)." >&2
    exit 1
fi

mkdir -p "$OUT"
rm -rf "$WRAPPER"

echo "==> Creating wrapper with engine $ENGINE"
"$WSY/Contents/Resources/Wineskin Winery" \
    --create-wrapper "$WRAPPER" --engine "$ENGINE"

# The wrapper's Wineskin.app helper drives configuration.
WS="$WRAPPER/Contents/Resources/Wineskin.app/Contents/MacOS/Wineskin"
PFX="$WRAPPER/Contents/Resources/drive_c"

echo "==> Installing .NET Framework 4.8 (this takes 5-10 minutes)"
"$WS" --winetricks -q dotnet48

echo "==> Downloading RIT Client.application"
curl -fsSL "$CLIENT_URL" -o "$PFX/Client.application"

echo "==> Dropping in patched http.sys (fixes Wine's * wildcard bug)"
cp "$HERE/http.sys" "$PFX/windows/system32/drivers/http.sys"

echo "==> Setting RIT as the default executable"
"$WS" --set-exe "C:\\Client.application"

echo "==> Hiding Wineskin's debug logs window on launch"
"$WS" --set-cmd-line ""

# Clean exit. Without these, Wine background processes (wineserver, winedevice,
# http.sys driver host, rpcss, plugplay) keep running after the user closes RIT
# and the Dock icon won't go away. Quit-wrapper-mode makes Wineskin watch the
# main exe and kill the bottle when it exits; the post-run hook is a backstop.
"$WS" --set-quit-wrapper-mode 1
"$WS" --set-post-run "wineserver -k"

# Codesigning. Three modes, in order of preference:
#   1. Real Developer ID (CODESIGN_IDENTITY env set) — no Gatekeeper prompts, can notarize
#   2. Ad-hoc sign (no env set, default below) — won't fix Gatekeeper, but stops
#      "app is damaged" errors on M-chip Macs after any bundle modification
#   3. Skip entirely (SKIP_CODESIGN=1) — bundle ships unsigned
if [[ "${SKIP_CODESIGN:-}" != "1" ]]; then
    IDENTITY="${CODESIGN_IDENTITY:--}"   # '-' means ad-hoc
    echo "==> Codesigning (identity: ${IDENTITY})"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$WRAPPER"
fi

echo "==> Building DMG"
DMG="$OUT/RIT.dmg"
rm -f "$DMG"
hdiutil create -volname "RIT" -srcfolder "$WRAPPER" -ov -format UDZO "$DMG"

# Optional notarization. Set NOTARY_PROFILE in env (a `xcrun notarytool store-credentials` profile name).
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting for notarization"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "Done."
echo "  Wrapper: $WRAPPER"
echo "  DMG:     $DMG"
