#!/bin/bash
# release.sh — ship a GoalKeeper version.
#   UI-only change: edit app/index.html, bump <meta name="gk-version"> AND "version" in app/version.json, run this.
#   The installed app polls the GitHub Release feed and updates itself; only native (shell/main.m) changes need a new DMG install.
set -euo pipefail
cd "$(dirname "$0")"
fail() { echo "❌ $1" >&2; exit 1; }

# 1. clean tree
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty — commit or stash first"

# 2. versions agree
META='<meta name="gk-version" content="'
VER=$(grep -o "${META}[^\"]*\">" app/index.html | sed -E 's/.*content="([^"]*)".*/\1/')
[ -n "$VER" ] || fail "no gk-version meta in app/index.html"
[ "$(grep -c "${META}" app/index.html)" = 1 ] || fail "gk-version meta must appear exactly once"
JV=$(python3 -c 'import json;print(json.load(open("app/version.json"))["version"])')
[ "$VER" = "$JV" ] || fail "HTML meta version $VER != version.json version $JV"
MIN=$(python3 -c 'import json;print(json.load(open("app/version.json")).get("minShell","0"))')
python3 - "$MIN" "$VER" <<'PY' || fail "minShell > version"
import sys
k=lambda v:[int(x) for x in v.split('.')]
sys.exit(0 if k(sys.argv[1])<=k(sys.argv[2]) else 1)
PY
grep -q '<title>GoalKeeper</title>' app/index.html || fail "HTML lost its <title>"
grep -q 'window.__loadedB64' app/index.html || fail "HTML lost the bridge loader"
git tag -l "v$VER" | grep -q . && fail "tag v$VER already exists — bump the version"

# 3. hashes into version.json (html + listed assets); assets upload flat, so url = basename
python3 - <<'PY'
import json,hashlib,os
j=json.load(open("app/version.json"))
sha=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
j["html"]="index.html"; j["sha256"]=sha("app/index.html")
for a in j.get("assets",[]):
    p=os.path.join("app",a["path"]); a["sha256"]=sha(p); a["url"]=os.path.basename(a["path"])
json.dump(j,open("app/version.json","w"),indent=2); open("app/version.json","a").write("\n")
print("version.json:",json.dumps(j,indent=1))
PY

# 4. build + package
./build.sh
./create_dmg.sh
BV=$(defaults read "$(pwd)/build/GoalKeeper.app/Contents/Info.plist" CFBundleShortVersionString)
[ "$BV" = "$VER" ] || fail "built bundle says $BV, expected $VER"

# 5. commit, tag, push, release
git add app/version.json
git commit -qm "Release v$VER" || true
git tag -a "v$VER" -m "v$VER"
git push origin HEAD "v$VER"
ASSETS=(app/index.html app/version.json GoalKeeper.dmg)
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
for p in $(python3 -c 'import json;[print(a["path"]) for a in json.load(open("app/version.json")).get("assets",[])]'); do
  cp "app/$p" "$STAGE/$(basename "$p")"; ASSETS+=("$STAGE/$(basename "$p")")
done
NOTES=$(python3 -c 'import json;print(json.load(open("app/version.json")).get("notes",""))')
gh release create "v$VER" "${ASSETS[@]}" --title "GoalKeeper $VER" --notes "$NOTES"
echo "✅ released v$VER — installed apps pick it up on their next check (launch / hourly on focus / 6h)."
echo "   feed: https://github.com/nmken/goalkeeper/releases/latest/download/version.json"
