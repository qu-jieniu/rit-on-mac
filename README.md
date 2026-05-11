# rit-on-mac

A patched-Wine bundle that makes **Rotman Interactive Trader (RIT)** and its
local REST API work cleanly on Apple Silicon (M-series) Macs.

RIT is a Windows-only WinForms application used in finance courses and trading
competitions at the Rotman School of Management. This repo ships the smallest
change needed to make it (and its local API on `http://localhost:9999/v1/`)
actually work under Wine — a one-line patch to Wine's `http.sys` driver.

## For students / end users

Grab the latest `RIT.dmg` from [Releases](https://github.com/qu-jieniu/rit-on-mac/releases),
drag `RIT.app` into `/Applications`, double-click. RIT launches, ClickOnce
installer runs, login screen appears. The local REST API at
`http://localhost:9999/v1/...` is live as soon as you tick "Enable API" in
RIT's Options dialog.

If macOS Gatekeeper complains about an "unidentified developer", either:
- Right-click `RIT.app` → **Open** → confirm (one time), or
- Open Terminal and run: `sudo xattr -dr com.apple.quarantine /Applications/RIT.app`

(See the signing section below for the Developer-ID path that removes this prompt entirely.)

## Why this exists

RIT's local REST API uses .NET `HttpListener` and registers
`http://*:9999/v1/`. Stock Wine only recognizes `+` as a wildcard host;
`*` (the "weak" wildcard Microsoft introduced) falls through to a literal
character match that never wins against a normal `Host:` header. The result:
TCP connects, http.sys parses the request, queues it for user-mode delivery —
and waits forever, because no URL group matches. The student sees a hang on
every API call.

The fix is one character in `dlls/http.sys/http.c`:

```diff
-    if (url->url[7] == '+')
+    if (url->url[7] == '+' || url->url[7] == '*')
```

See [`wine-host-matches-star-wildcard.patch`](wine-host-matches-star-wildcard.patch).

The compiled output, `http.sys`, is a Windows PE32+ DLL — it runs unmodified
inside any current Wine engine on macOS (Gcenx wine-crossover, Whisky's GPTK
wine, CrossOver bottles, WineskinServer WS11 engines). We swap that single
file into the bottle and everything Just Works.

## For maintainers — building the DMG

### Option 1: GitHub Actions (recommended, zero-Mac)

Push to this repo, go to **Actions → Build RIT.dmg → Run workflow**. About 10
minutes later, download the `RIT-<sha>` artifact from the run page. Releases
also auto-attach the DMG.

### Option 2: Build locally on a Mac

```sh
# One-time install
brew install --cask --no-quarantine gcenx/wine/wineskin

# Build
./build-rit-app.sh
# → out/RIT.app and out/RIT.dmg
```

`build-rit-app.sh` automates the Wineskin Winery flow: creates the wrapper,
installs .NET Framework 4.8 via winetricks, downloads RIT's
`Client.application`, **drops in the patched `http.sys`**, configures clean
exit (`--quit-wrapper-mode 1` + `wineserver -k` post-run hook), and builds the
compressed DMG.

### Signing

The script supports three signing modes:

| Mode | Env vars | What users see |
|---|---|---|
| **Apple Developer ID + notarize** | `CODESIGN_IDENTITY` + `NOTARY_PROFILE` | No Gatekeeper prompts. Pay Apple $99/yr. |
| **Ad-hoc** (default) | _none_ | "Unidentified developer" prompt; users do `xattr -dr` or right-click → Open |
| **Unsigned** | `SKIP_CODESIGN=1` | Same prompt as ad-hoc, plus risk of "app is damaged" on tampered bundles |

There is no honest free alternative to Apple Developer ID for Gatekeeper
trust. Self-signed and homebrew CA certs do **not** establish trust on macOS
13/14/15. The only real options without paying are the ad-hoc + `xattr` flow,
or MDM-pushed policy exceptions on university-managed Macs.

## Rebuilding `http.sys` for a different Wine version

The shipped `http.sys` was built against upstream `wine-10.0`. The driver
ABI is stable across recent Wine versions; if your engine ever needs a
different build, the rebuild is straightforward:

```sh
git clone --depth 1 --branch wine-10.0 https://gitlab.winehq.org/wine/wine.git
cd wine
git apply ../wine-host-matches-star-wildcard.patch
./configure --without-x --without-freetype --disable-tests --enable-archs=i386,x86_64
make -j dlls/http.sys/x86_64-windows/http.sys
# Output: dlls/http.sys/x86_64-windows/http.sys
```

The build needs `mingw-w64`, `gcc-multilib`, `bison`, `flex`. On Ubuntu / Debian:

```sh
sudo apt install build-essential bison flex gcc-multilib g++-multilib \
                 gcc-mingw-w64 g++-mingw-w64 mingw-w64-tools
```

## Upstreaming

The patch is small enough to be an obvious WineHQ fix. Once accepted into Wine
upstream, future Wine releases on macOS will work out of the box and this repo
becomes maintenance-only (just updating the bundle for new RIT releases).

## License

The `http.sys` binary in this repo is derived from Wine source code and is
licensed **LGPL-2.1-or-later** (same as Wine). The build script and
documentation in this repo are LGPL-2.1-or-later as a convenient overall
license. See [`COPYING.LIB`](https://gitlab.winehq.org/wine/wine/-/raw/master/COPYING.LIB)
in the Wine repository for the LGPL text.

RIT itself is a proprietary product of the Rotman School of Management. This
repo distributes only the Wine engine glue; users acquire `Client.application`
from Rotman's distribution.
