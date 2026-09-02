#!/bin/bash
# create_dmg.sh — packs build/GoalKeeper.app into a compressed, drag-to-Applications DMG.
# Usage: ./create_dmg.sh            # plain installer (default, safe for existing installs)
#        ./create_dmg.sh --starter  # also bundle THIS Mac's live board as starter data for a
#                                   # brand-new install (never use for an app going to an existing user)
set -euo pipefail

APP_NAME="GoalKeeper"
APP_PATH="build/GoalKeeper.app"
DMG_NAME="GoalKeeper.dmg"
WITH_STARTER=0
[ "${1:-}" = "--starter" ] && WITH_STARTER=1

cd "$(dirname "$0")"
STAGING_DIR="$(mktemp -d /tmp/dmg-staging-XXXXXX)"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT
fail() { echo "❌ ERROR: $1" >&2; exit 1; }

[ -d "$APP_PATH" ] || fail "App bundle not found at '$APP_PATH'. Build it first (./build.sh)."
[ -x "$APP_PATH/Contents/MacOS/$APP_NAME" ] || fail "'$APP_PATH' doesn't look like a valid .app bundle."
VER=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

echo "📦 Packing $APP_NAME $VER into $DMG_NAME ..."
cp -R "$APP_PATH" "$STAGING_DIR/" || fail "Could not copy the .app into the staging folder."
ln -s /Applications "$STAGING_DIR/Applications" || fail "Could not create the /Applications symlink."

if [ "$WITH_STARTER" = 1 ]; then
  LIVE_DATA="$HOME/Library/Application Support/$APP_NAME/data.json"
  [ -s "$LIVE_DATA" ] || fail "--starter given but no live data at '$LIVE_DATA'."
  echo "   • bundling this Mac's board as starter data (--starter)"
  cp "$LIVE_DATA" "$STAGING_DIR/$(basename "$APP_PATH")/Contents/Resources/app/starter-data.json" \
    || fail "Could not bundle the starter data."
  codesign --force -s - "$STAGING_DIR/$(basename "$APP_PATH")" 2>/dev/null \
    || fail "Could not re-sign the app after adding starter data."
fi

cat > "$STAGING_DIR/How to install.txt" <<'TXT'
UPGRADING FROM AN OLDER GOALKEEPER? Do this first (one-time safety copy of your data):
   Finder -> Go -> Go to Folder... -> paste:  ~/Library/Application Support/GoalKeeper
   Right-click that "GoalKeeper" folder -> Duplicate. Done. (Your data is never touched by
   installing, this is just a belt-and-braces backup. Newer versions back up automatically.)

1. Drag GoalKeeper onto the Applications folder icon (choose Replace if asked).
2. First launch of a new version - macOS warns because the app isn't notarized with Apple:
   • Right-click GoalKeeper in Applications and choose "Open".
   • If macOS only offers "Move to Trash / Done" (macOS 15 Sequoia and newer):
     open System Settings -> Privacy & Security, scroll down, and click
     "Open Anyway" next to GoalKeeper. Needed once per version.
That's it - your data saves automatically, each month archives itself, and from now on
new versions arrive inside the app (a small "update ready" chip at the top).
TXT

rm -f "$DMG_NAME"
echo "   • creating compressed image"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_NAME" >/dev/null \
  || fail "hdiutil failed to create the DMG."
SIZE=$(du -h "$DMG_NAME" | cut -f1 | tr -d ' ')
echo "✅ SUCCESS: $(pwd)/$DMG_NAME (${SIZE}) is ready to share."
