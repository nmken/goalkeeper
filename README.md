# GoalKeeper

Your whiteboard, as a tiny Mac app: deal counter, commission tracker, tally-mark leaderboard, monthly goals, confetti when you hit them.

## Build & install

```bash
./build.sh        # → build/GoalKeeper.app (clang + Cocoa/WebKit, no Xcode project needed)
./create_dmg.sh   # → ./GoalKeeper.dmg (drag to Applications); add --starter to bundle this Mac's board for a brand-new user
```

First launch of each new build: **right-click → Open** (ad-hoc signed, not notarized). On macOS 15+, if only "Move to Trash" is offered, use System Settings → Privacy & Security → **Open Anyway**.

Data lives in `~/Library/Application Support/GoalKeeper/`:
- `data.json` — the live board (+ `data.json.bak`, previous good write)
- `archives/` — one file per closed month
- `backups/` — automatic: first save of each day (30 kept), every close-out, before every app upgrade, before every import
- `app/` — an updated UI downloaded by the in-app updater (only present when newer than the bundled one)

Reinstalling or updating never touches any of it.

## Shipping updates

The app has two halves: the native shell (`shell/main.m`) and the UI (`app/index.html`, one self-contained file). The installed app polls a GitHub Release feed and downloads a newer UI by itself.

**UI-only change (the normal case):**
1. Edit `app/index.html`.
2. Bump `<meta name="gk-version" content="X.Y">` in the HTML **and** `"version"` in `app/version.json` to the same value.
3. Commit, then `./release.sh` — it verifies versions, fills in the SHA-256, builds, packages, tags `vX.Y`, pushes, and publishes a GitHub Release with `index.html`, `version.json` and the DMG.
4. Her app shows "✨ vX.Y ready — tap to update" on its next check (launch, hourly when focused, every 6 h).

**Native change (`shell/main.m`, `build.sh` plist):** bump the version the same way, run `./release.sh`, and send her the DMG — the shell can't replace itself. If a UI needs a newer shell, set `minShell` in `version.json`; older shells then say "needs a fresh install" instead of updating.

Dev overrides for testing the updater: env `GK_UPDATE_URL=http://localhost:PORT/version.json` (Terminal launches) or a one-line `~/Library/Application Support/GoalKeeper/update-url.txt` (Finder launches — delete it afterwards). `GK_NO_UPDATE=1` disables checks.

Browser preview of the UI (no native bridge, localStorage instead): `python3 -m http.server 8737 --directory app`.

## Use

- **+** bubble (or tap your leaderboard row) — log a deal; commission auto-fills from your % (editable per deal); optional **Bought by** name
- **+ bonus** chip — weekend bonuses etc.
- **Leaderboard** — tap a closer +1, right-click −1 (right-click your own row undoes your last deal)
- **Goals post-it** — tap the box to check off (confetti!), click text to edit, hover ✕ to remove
- **Month name** — history of past months; **Close out {Month} →** archives now and starts the next month
- **⚙** — commission %, minimum/goal deals, your name, closers, **Look** (lavender / blue / green / dark), **Export / Import backup**, close-out
- **File menu** — Export Backup… (⇧⌘E), Import Backup… (⇧⌘I), Reveal Data Folder; **GoalKeeper menu** — Check for Updates…, Reset to Built-in Version
