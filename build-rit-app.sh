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
PKG="$OUT/RIT.pkg"
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
# Drop into the prefix...
cp "$HERE/http.sys" "$PREFIX/drive_c/windows/system32/drivers/http.sys"
# ...AND into the wine engine's fakedll source. Without this, the launcher's
# `wineboot --update` (which runs when dosdevices is missing — i.e., always
# on first launch since we strip dosdevices at build time) re-copies the
# engine's stock http.sys over our patched one and the fix is gone.
for arch in x86_64-windows i386-windows; do
    ENGINE_HTTPSYS="$WINE_DIR/lib/wine/$arch/http.sys"
    if [[ -f "$ENGINE_HTTPSYS" ]]; then
        cp "$HERE/http.sys" "$ENGINE_HTTPSYS"
        echo "    patched engine $arch/http.sys"
    fi
done
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

# Launcher — Mach-O binary compiled from launcher.m (Objective-C / Cocoa).
# Lets macOS treat us as a proper .app: hides the launcher's own Dock entry,
# spawns wine64 in its own process group (clean shutdown), and gives the
# Dock entry the RIT icon via CFBundleIconFile.
echo "==> Compiling launcher.m"
clang -framework Cocoa -arch arm64 -arch x86_64 \
      -mmacosx-version-min=14.0 \
      -o "$WRAPPER/Contents/MacOS/RIT" \
      "$HERE/launcher.m"
chmod +x "$WRAPPER/Contents/MacOS/RIT"

# Generate RIT.icns from the iconset (PNGs checked into the repo at
# RIT.iconset/). iconutil is built into macOS.
echo "==> Compiling icon"
iconutil --convert icns "$HERE/RIT.iconset" -o "$WRAPPER/Contents/Resources/RIT.icns"

# Info.plist. Note CFBundleIconFile + LSMinimumSystemVersion = 14 (Sonoma,
# GPTK's floor). NSPrincipalClass is set so wine's NSApp inherits our bundle
# context and shows the .icns in Dock.
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
    <key>CFBundleIconFile</key>       <string>RIT</string>
    <key>LSMinimumSystemVersion</key> <string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOPLIST

# ---------- 5. Codesign ----------
if [[ "${SKIP_CODESIGN:-}" != "1" ]]; then
    IDENTITY="${CODESIGN_IDENTITY:--}"   # '-' means ad-hoc
    echo "==> Codesigning bundle (identity: $IDENTITY)"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$WRAPPER"
fi

# ---------- 6. Installer package (.pkg) ----------
# Staging: an installer expects a tree mirroring the destination layout.
echo "==> Building $PKG"
PKG_ROOT="$WORK/pkg-root"
PKG_SCRIPTS="$WORK/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"
cp -R "$WRAPPER" "$PKG_ROOT/Applications/"

# Preinstall:
#   1. Hard-stop on macOS Ventura or older (GPTK requires Sonoma 14+).
#   2. Kill any running RIT/wine processes so we don't try to overwrite
#      open files.
#   3. Remove the previous /Applications/RIT.app entirely so each install
#      starts from a clean bundle (no leftover ClickOnce cache, no stale
#      registry, no API key from a previous version).
cat > "$PKG_SCRIPTS/preinstall" <<'PREINST'
#!/bin/bash
set -e

# 1. macOS version gate.
MAJOR=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 14 ]; then
    /usr/bin/osascript -e 'display alert "macOS update required" message "RIT requires macOS Sonoma (14) or later. Open System Settings → General → Software Update and update first." as critical' >/dev/null 2>&1 || true
    exit 1
fi

# 2. Kill any running RIT/wine processes (otherwise the rm below races with
#    open file handles and the install partially fails).
/usr/bin/pkill -9 -f 'RIT\.app/Contents/Resources/wine|Client\.exe|wineserver|wine64-preloader' 2>/dev/null || true
/bin/sleep 1

# 3. Wipe the previous install. Fresh every time — every student boots from
#    the same baked-in state, no leftover settings or ClickOnce cache.
/bin/rm -rf /Applications/RIT.app

exit 0
PREINST
chmod +x "$PKG_SCRIPTS/preinstall"

# Postinstall: strip Gatekeeper quarantine, chown to the user (Wine refuses
# to use a prefix not owned by the running user), and install Rosetta 2 on
# Apple Silicon if it's not already there. All three need root, which the
# .pkg flow gives us for free.
cat > "$PKG_SCRIPTS/postinstall" <<'POSTINST'
#!/bin/bash
APP="/Applications/RIT.app"

# 1. Strip quarantine recursively from every file in the bundle, including
#    the engine + prefix DLLs (which inherit quarantine from the downloaded .pkg).
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/usr/bin/find "$APP" -exec /usr/bin/xattr -d com.apple.quarantine {} \; 2>/dev/null
# Also clear Gatekeeper's "where did this come from" extended attribute.
/usr/bin/find "$APP" -exec /usr/bin/xattr -d com.apple.metadata:kMDItemWhereFroms {} \; 2>/dev/null

# 2. Chown the bundle to the console user (the one who logged in / triggered
#    the install). Wine's wineserver explicitly rejects prefixes not owned by
#    the running UID. Default install puts everything as root:wheel.
CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console)
CONSOLE_GROUP=$(/usr/bin/id -gn "$CONSOLE_USER" 2>/dev/null || echo staff)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    /usr/sbin/chown -R "${CONSOLE_USER}:${CONSOLE_GROUP}" "$APP"
fi

# 3. On Apple Silicon, install Rosetta 2 if missing.
if [ "$(/usr/bin/uname -m)" = "arm64" ] && ! /usr/bin/pgrep -q oahd 2>/dev/null; then
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license || true
fi
exit 0
POSTINST
chmod +x "$PKG_SCRIPTS/postinstall"

# Build a component package (no choices, just install RIT.app).
COMPONENT_PKG="$WORK/RIT-component.pkg"
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier com.rotman.rit \
    --version "1.0" \
    --install-location / \
    --scripts "$PKG_SCRIPTS" \
    "$COMPONENT_PKG"

# Wrap into a product/distribution archive so we can attach the welcome /
# license screens later if desired.
rm -f "$PKG"
productbuild --package "$COMPONENT_PKG" "$PKG"

# Optional Developer ID Installer signing. Set INSTALLER_IDENTITY in env, e.g.
#   export INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    SIGNED="$WORK/RIT-signed.pkg"
    productsign --sign "$INSTALLER_IDENTITY" "$PKG" "$SIGNED"
    mv "$SIGNED" "$PKG"
fi

# ---------- 7. Notarize ----------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting $PKG for notarization (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
fi

echo
echo "Built:"
echo "  $WRAPPER"
echo "  $PKG  ($(du -sh "$PKG" | cut -f1))"
