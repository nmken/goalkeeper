#!/bin/bash
# Builds GoalKeeper.app — no Xcode project needed, just the CLT toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/GoalKeeper.app
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

# ---- 0. version (single source of truth: the gk-version meta in app/index.html) ----
VER=$(sed -n 's/.*<meta name="gk-version" content="\([^"]*\)">.*/\1/p' app/index.html | head -1)
if [ -z "$VER" ]; then
  echo 'build.sh: no <meta name="gk-version" content="..."> in app/index.html' >&2
  exit 1
fi
echo "version ${VER}"

# ---- 1. fonts (downloaded once, then cached in the repo) ----
mkdir -p app/fonts
fetch_font() {
  local family="$1" out="$2"
  [ -s "$out" ] && return 0
  echo "fetching font: $family"
  local css url
  css=$(curl -fsSL -A "$UA" "https://fonts.googleapis.com/css2?family=${family}&display=swap")
  url=$(echo "$css" | grep -o 'https://[^)]*\.woff2' | tail -1)
  curl -fsSL "$url" -o "$out"
}
fetch_font "Kalam:wght@700" app/fonts/Kalam-Bold.woff2
fetch_font "Patrick+Hand" app/fonts/PatrickHand-Regular.woff2

# ---- 2. icon ----
mkdir -p build
if [ ! -s build/AppIcon.icns ]; then
  echo "rendering icon"
  clang -fobjc-arc -framework Cocoa icon/makeicon.m -o build/makeicon
  build/makeicon build/icon_1024.png
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    dbl=$((sz * 2))
    sips -z $dbl $dbl build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

# ---- 3. compile shell ----
echo "compiling"
clang -fobjc-arc -O2 -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers shell/main.m -o build/GoalKeeper-bin

# ---- 4. assemble .app ----
echo "assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/app"
cp build/GoalKeeper-bin "$APP/Contents/MacOS/GoalKeeper"
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp app/index.html "$APP/Contents/Resources/app/"
cp -R app/fonts "$APP/Contents/Resources/app/fonts"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GoalKeeper</string>
  <key>CFBundleDisplayName</key><string>GoalKeeper</string>
  <key>CFBundleIdentifier</key><string>com.nathan.goalkeeper</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleExecutable</key><string>GoalKeeper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# ---- 5. ad-hoc sign ----
codesign --force --deep -s - "$APP"
echo "done → ${APP}"
