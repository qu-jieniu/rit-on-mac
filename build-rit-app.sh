#!/usr/bin/env bash
# Build RIT.app + RIT.dmg on a macOS host, without Wineskin/Sikarugir.
#
# What this script does:
#   1. Downloads a vanilla Gcenx wine build (Mac x86_64 binaries)
#   2. Creates a fresh wine prefix, installs .NET 4.8 via winetricks
#   3. Downloads RIT's Client.application
#   4. Drops in the patched http.sys
#   5. Assembles a self-contained RIT.app:
#        - Contents/MacOS/RIT       (shell-script launcher)
#        - Contents/Resources/wine  (the wine engine, bundled)
#        - Contents/Resources/prefix (the WINEPREFIX)
#        - Contents/Info.plist
#   6. Optionally codesigns (ad-hoc by default; Developer ID if env vars set)
#   7. Builds RIT.dmg
#
# Inputs (env, optional):
#   WINE_URL            direct URL to a wine engine .tar.xz. Default: latest GPTK
#                       (Apple's Game Porting Toolkit — arm64-native, no Rosetta).
#                       For Intel Macs / fallback, point at one of the Gcenx
#                       macOS_Wine_builds wine-staging-NN-osx64.tar.xz URLs.
#   CLIENT_URL          where to fetch Client.application; default is rit.306w.ca
#   CODESIGN_IDENTITY   "Developer ID Application: …" — set for real signing
#   SKIP_CODESIGN       set =1 to skip codesign entirely
#   NOTARY_PROFILE      a `xcrun notarytool store-credentials` profile name — set to notarize
#
# Outputs:
#   ./out/RIT.app
#   ./out/RIT.dmg

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
WORK="$HERE/.work"
WRAPPER="$OUT/RIT.app"
DMG="$OUT/RIT.dmg"
CLIENT_URL="${CLIENT_URL:-http://rit.306w.ca/client/Client.application}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "build-rit-app.sh must run on macOS." >&2
    exit 1
fi

if [[ ! -f "$HERE/http.sys" ]]; then
    echo "Missing $HERE/http.sys (patched Wine HTTP driver)." >&2
    exit 1
fi

mkdir -p "$OUT" "$WORK"

# ---------- 1. Wine engine ----------
# Default: Apple's Game Porting Toolkit. It's arm64-native, so no Rosetta is
# needed (and Wine on Rosetta hits "unsupported privilege level: 0" errors
# during heavy operations like winetricks dotnet48). Override WINE_URL to
# pick a different engine (e.g., wine-staging for Intel-only builds).
if [[ -z "${WINE_URL:-}" ]]; then
    echo "==> Locating latest Game Porting Toolkit release"
    WINE_URL=$(curl -fsSL \
        ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/Gcenx/game-porting-toolkit/releases?per_page=5" \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
for rel in data:
    for asset in rel.get('assets', []):
        if asset['name'].endswith('.tar.xz') and 'game-porting-toolkit' in asset['name'].lower():
            print(asset['browser_download_url']); sys.exit(0)
")
    [[ -n "$WINE_URL" ]] || { echo "Couldn't find a GPTK release"; exit 1; }
fi
echo "    engine URL: $WINE_URL"

ASSET="$(basename "$WINE_URL")"
WINE_TARBALL="$WORK/$ASSET"
if [[ ! -f "$WINE_TARBALL" ]]; then
    echo "==> Downloading $ASSET"
    curl -fsSL \
        -H "Accept: application/octet-stream" \
        ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
        "$WINE_URL" -o "$WINE_TARBALL"
fi

WINE_DIR="$WORK/wine"
if [[ ! -x "$WINE_DIR/bin/wine" ]]; then
    rm -rf "$WINE_DIR"
    echo "==> Extracting wine engine"
    # Gcenx ships wine as a full .app bundle. Find the engine subdir inside it
    # ("X.app/Contents/Resources/wine") and lift it to $WINE_DIR.
    EX="$WORK/extract"
    rm -rf "$EX"; mkdir -p "$EX"
    tar -xJf "$WINE_TARBALL" -C "$EX"
    INNER=$(find "$EX" -type d -path '*Contents/Resources/wine' -maxdepth 5 | head -1)
    [[ -n "$INNER" ]] || { echo "Couldn't locate wine engine inside tarball:"; tar -tJf "$WINE_TARBALL" | head -5; exit 1; }
    mv "$INNER" "$WINE_DIR"
    rm -rf "$EX"
fi
xattr -dr com.apple.quarantine "$WINE_DIR" 2>/dev/null || true

# Wine 9+ unified the wine/wine64 binary; older builds had separate wine64.
if   [[ -x "$WINE_DIR/bin/wine" ]];   then WINE="$WINE_DIR/bin/wine"
elif [[ -x "$WINE_DIR/bin/wine64" ]]; then WINE="$WINE_DIR/bin/wine64"
else echo "no wine binary in $WINE_DIR/bin"; ls "$WINE_DIR/bin" || true; exit 1; fi
WINESERVER="$WINE_DIR/bin/wineserver"
[[ -x "$WINESERVER" ]] || { echo "wineserver missing from $WINE_DIR/bin"; exit 1; }
echo "    wine: $WINE"

# ---------- 2. Wine prefix ----------
PREFIX="$WORK/prefix"
if [[ -f "$PREFIX/.dotnet48-installed" ]]; then
    echo "==> Reusing existing prefix at $PREFIX"
else
    echo "==> Building fresh prefix at $PREFIX (this includes .NET 4.8 — ~10 min)"
    rm -rf "$PREFIX"
    export WINEPREFIX="$PREFIX"
    export WINEARCH=win64
    export WINEDEBUG=-all

    "$WINE" wineboot --init
    "$WINESERVER" -w

    # winetricks: download from upstream if not on PATH
    if ! command -v winetricks >/dev/null 2>&1; then
        echo "==> Fetching winetricks"
        curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
             -o "$WORK/winetricks"
        chmod +x "$WORK/winetricks"
        WINETRICKS="$WORK/winetricks"
    else
        WINETRICKS="$(command -v winetricks)"
    fi

    # winetricks expects a `wine` binary on PATH; GPTK only ships `wine64`.
    # Honor winetricks' WINE env var to point it directly at our binary.
    WINE="$WINE" WINESERVER="$WINESERVER" PATH="$WINE_DIR/bin:$PATH" \
        "$WINETRICKS" -q --force dotnet48
    touch "$PREFIX/.dotnet48-installed"
fi

# ---------- 3. Client.application + patched http.sys ----------
CLIENT_APP="$PREFIX/drive_c/Client.application"
if [[ ! -f "$CLIENT_APP" ]]; then
    echo "==> Downloading $CLIENT_URL"
    curl -fsSL "$CLIENT_URL" -o "$CLIENT_APP"
fi

echo "==> Installing patched http.sys"
cp "$HERE/http.sys" "$PREFIX/drive_c/windows/system32/drivers/http.sys"
md5_pref=$(md5 -q "$PREFIX/drive_c/windows/system32/drivers/http.sys")
md5_src=$( md5 -q "$HERE/http.sys")
[[ "$md5_pref" = "$md5_src" ]] || { echo "http.sys deploy mismatch"; exit 1; }

# ---------- 4. Assemble RIT.app ----------
echo "==> Assembling $WRAPPER"
rm -rf "$WRAPPER"
mkdir -p "$WRAPPER/Contents/MacOS" "$WRAPPER/Contents/Resources"

cp -R "$WINE_DIR"  "$WRAPPER/Contents/Resources/wine"
cp -R "$PREFIX"    "$WRAPPER/Contents/Resources/prefix"

# Strip the dosdevices links — wine recreates them on first run, and they
# may otherwise point at the builder's home directory.
rm -rf "$WRAPPER/Contents/Resources/prefix/dosdevices"

# ---------- 4a. Slim the bundle ----------
# Three safe trims, no behavioral change:
#   - strip debug symbols off Wine binaries
#   - remove Wine Mono (unused — winetricks installed Microsoft .NET 4.8 instead)
#   - remove Wine Gecko (unused — RIT has no WebBrowser controls)
#     ^ moderate risk if RIT ever pops an embedded-HTML dialog. Remove this
#       line if you hit any "Wine wants to install Gecko" prompt at runtime.
echo "==> Slimming bundle"
WRAPPER_WINE="$WRAPPER/Contents/Resources/wine"
WRAPPER_PFX="$WRAPPER/Contents/Resources/prefix"

# Strip debug symbols from all Wine binaries
find "$WRAPPER_WINE/bin" -type f -perm +111 -exec strip -S {} \; 2>/dev/null || true
find "$WRAPPER_WINE/lib" -type f \( -name '*.dylib' -o -name '*.so' \) \
     -exec strip -S {} \; 2>/dev/null || true

# Wine Mono lives in two places: the bundled engine and the populated prefix
rm -rf "$WRAPPER_WINE/share/wine/mono" \
       "$WRAPPER_PFX/drive_c/windows/Microsoft.NET/assembly/Wine-Mono" 2>/dev/null || true

# Wine Gecko — KEEP. Removing it breaks .NET 4.8 ClickOnce launchers like
# RIT's Client.application with "This application could not be started"
# at first launch; the trust-prompt UI loads mshtml.dll from Gecko.
# (Saves ~80 MB if removed; not worth the broken install.)

# Wine's bundled docs/man/info pages are pointless in a shipped bundle
rm -rf "$WRAPPER_WINE/share/man" "$WRAPPER_WINE/share/info" "$WRAPPER_WINE/share/doc" 2>/dev/null || true

echo "    bundle size after slim: $(du -sh "$WRAPPER" | cut -f1)"

# Launcher.
cat > "$WRAPPER/Contents/MacOS/RIT" <<'EOSH'
#!/bin/bash
# RIT.app launcher — sets up the bundled wine environment and runs Client.application.
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_RES="$HERE/../Resources"
export WINEPREFIX="$APP_RES/prefix"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export PATH="$APP_RES/wine/bin:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$APP_RES/wine/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
# Wine 9+ has a unified `wine` binary; older builds split into wine/wine64.
if   [ -x "$APP_RES/wine/bin/wine" ];   then WINEBIN="$APP_RES/wine/bin/wine"
elif [ -x "$APP_RES/wine/bin/wine64" ]; then WINEBIN="$APP_RES/wine/bin/wine64"
else echo "No wine binary in $APP_RES/wine/bin" >&2; exit 1; fi
# Recreate dosdevices if we stripped them at build time.
[ -d "$WINEPREFIX/dosdevices" ] || "$APP_RES/wine/bin/wineboot" --update
trap '"$APP_RES/wine/bin/wineserver" -k 2>/dev/null || true' EXIT
exec "$WINEBIN" start /unix "$WINEPREFIX/drive_c/Client.application"
EOSH
chmod +x "$WRAPPER/Contents/MacOS/RIT"

# Info.plist.
cat > "$WRAPPER/Contents/Info.plist" <<'EOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>     <string>RIT</string>
    <key>CFBundleIdentifier</key>     <string>com.rotman.rit</string>
    <key>CFBundleName</key>           <string>RIT</string>
    <key>CFBundleDisplayName</key>    <string>Rotman Interactive Trader</string>
    <key>CFBundleVersion</key>        <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>CFBundleSignature</key>      <string>????</string>
    <key>LSMinimumSystemVersion</key> <string>10.15</string>
    <key>LSArchitecturePriority</key> <array><string>x86_64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
</dict>
</plist>
EOPLIST

# ---------- 5. Codesign ----------
if [[ "${SKIP_CODESIGN:-}" != "1" ]]; then
    IDENTITY="${CODESIGN_IDENTITY:--}"   # '-' means ad-hoc
    echo "==> Codesigning bundle (identity: $IDENTITY)"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$WRAPPER"
fi

# ---------- 6. DMG ----------
echo "==> Building $DMG (bzip2-compressed)"
rm -f "$DMG"
# UDBZ (bzip2) typically yields a 10-20% smaller DMG than UDZO (zlib) at the
# cost of slower decompression — acceptable for a one-shot install.
hdiutil create -volname "RIT" -srcfolder "$WRAPPER" -ov -format UDBZ "$DMG"

# ---------- 7. Notarize ----------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting $DMG for notarization (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "Built:"
echo "  $WRAPPER"
echo "  $DMG  ($(du -sh "$DMG" | cut -f1))"
