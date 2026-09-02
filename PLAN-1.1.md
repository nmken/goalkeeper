# GoalKeeper 1.1 — self-updater, themes, and four feature requests (revised plan, 2026-09-01)

Revision of the original 1.1 plan with the findings of `PLAN-AUDIT-1.1.md` merged in. This is the
execution document; the audit stays as the rationale.

## Context

After a month of daily use, the app's user (~25 deals on her install) asked for: confetti when a goal
is hit, a way to start a new month, a way to export/protect her data, and a buyer name on each sale.
Nathan added: a theme picker (dark, blue, green instead of the pink/lavender), and the question of
whether the installed app can receive updates without the DMG dance.

**Update question:** the installed 1.0 has no update mechanism, so *this* release ships as a DMG one
last time. Data lives in `~/Library/Application Support/GoalKeeper/`, outside the bundle, so
reinstalling never touches it. 1.1 adds a self-updater (GitHub Releases feed, downloads `index.html`
+ listed assets, shows an "update ready" chip). Because the native shell freezes after this DMG,
1.1 also ships every native hook a future UI-only update could plausibly need (Step 2).

Decisions confirmed: updater fed from a **public GitHub repo**; manual **"Close out {Month}"** plus a
fix for the auto-rollover; **JSON backup export + import**, plus **automatic rotating backups**;
**four themes** (lavender = current, blue, green, dark).

Architecture (verified 2026-09-01): `shell/main.m` (ObjC, clang, no Xcode project, not sandboxed,
ad-hoc signed) hosts a WKWebView loading single-file `app/index.html` (1209 lines). Bridge =
`WKScriptMessageHandler` named `bridge`; JS `persist()` runs after every mutation so reloading the
WebView is always safe. No `WKUIDelegate`, so `alert`/`confirm` are silent no-ops: **every
confirmation is an in-page `.overlay` sheet.** Build `./build.sh`, package `./create_dmg.sh`.
`swiftc` is broken on this machine — stay in ObjC. Today is 2026-09-01; this Mac's `data.json` is
unrelated test data (August board) and must never reach her install.

Key line refs in `app/index.html`: `curMonth` 631, `rollover()` 650, `renderLadder` 763, FAB open
handler ~987, `saveDeal` 1007, ladder edit handler ~1053, `saveSet` ~1105, goals click ~1138,
`loadState` boot ~1160, `inTopbarControls` 1198.

---

## Step 0 — Git + GitHub + housekeeping

- `git init`; `.gitignore`: `build/`, `*.dmg`, `.DS_Store`, `app/starter-data.json`. **Commit**
  `app/fonts/*.woff2` (build.sh fetches only when missing; the bundle must ship them).
- **Delete `make-dmg.sh`** (superseded by `create_dmg.sh`; two scripts writing different paths is a
  trap). Update README build section to `./build.sh` → `./create_dmg.sh`.
- **Neutralize personal defaults** in `freshBoard()` before the public push: closers become
  `Closer 1..4` style placeholders (or empty) and generic goals; real names live only in her
  `data.json`. Do the same review for any comments/strings naming real people.
- `create_dmg.sh`: starter-data bundling becomes **opt-in** (`--starter`). Default packs no
  `starter-data.json`. The 1.1 DMG ships without starter data.
- Initial commit of the 1.0 state, tag `v1.0`.
- `gh repo create nmken/goalkeeper --public --source=. --push` (`nmken/goalkeeper` verified free).
- Update memory `goalkeeper-app-architecture`: repo URL, `create_dmg.sh` (not make-dmg), release flow.
- **`/checkpoint`** here.

## Step 1 — Versioning

- `app/index.html`: `<meta name="gk-version" content="1.1">` in `<head>` (byte-exact literal, double
  quotes, no extra attributes — `build.sh`, `release.sh`, and the native validator all match it
  textually). JS const `APP_VERSION` read from the meta. Shown small in the Settings footer ("v1.1").
- `build.sh`: extract `VER` from the meta (fail hard if absent); **unquote the plist heredoc** so
  `$VER` fills `CFBundleVersion` + `CFBundleShortVersionString`; add
  `NSAppTransportSecurity → NSAllowsLocalNetworking = true` (localhost dev feed only). Keep
  `codesign` last. Do not copy `version.json` into the bundle.
- New `app/version.json`:
  ```json
  { "version": "1.1", "minShell": "1.1", "html": "index.html", "sha256": "<hex>",
    "assets": [], "notes": "…" }
  ```
  `html`/`assets[].path` resolve relative to the feed URL. `assets` entries are
  `{ "path": "fonts/X.woff2", "sha256": "<hex>" }`. `release.sh` fills the hashes.

## Step 2 — Native shell: updater + every future hook (`shell/main.m`)

Detailed design in "Updater design" below. Summary of what the 1.1 shell must contain, because it
cannot change again without a DMG:

**Bridge JS→native:** existing `save`, `load`, `drag`, `zoomWindow`, `archive`; new `export
{data, filename}`, `import {}`, `applyUpdate {}`, `checkUpdate {}`, `ready {}`, `windowBg {r,g,b}`,
`revealDataFolder {}`, `openURL {url}` (https only), `resetToBundled {}`.

**Native→JS** (main-thread `runJS:` helper, args JSON-escaped via `jsString:`, all guarded
`window.X && window.X(...)`): `__updateReady(version, notes)`, `__updateStatus('checking'|'uptodate'|
'error'|'needsInstaller')`, `__importedB64(b64)`, `__exportDone(ok)`, `__menu(cmd)`.

**Shell capability injection:** a `WKUserScript` at document start sets
`window.__shell = { version: "<CFBundleShortVersionString>", features: ["export","import","update",
"windowBg","revealDataFolder","openURL","assets","ready","resetToBundled"] }`. JS gates UI on
`__shell.features` so a newer HTML in an older shell hides what the shell can't do.

**Backups (native):**
- On the first `save` of each calendar day copy `data.json` → `backups/data-YYYY-MM-DD.json`; keep
  the newest 30.
- On every `archive` message also write `backups/closeout-YYYY-MM.json` = full `data.json`.
- **Pre-upgrade backup:** on launch, compare bundle version with `App Support/shell-version.txt`; if
  different (or absent), copy `data.json` → `backups/pre-upgrade-<bundleVersion>.json`, then write
  the file. Runs before the WebView loads.
- `data.json` → `data.json.pre-import` before the import panel opens.

**Menus:** File menu: Export Backup… (⇧⌘E), Import Backup… (⇧⌘I), separator, Reveal Data Folder.
App menu: About GoalKeeper (shows shell + UI version), Check for Updates…, Reset to Built-in Version.
Each calls `window.__menu('export'|'import'|'checkUpdate'|'reveal'|'reset')` so JS owns the logic
and browser fallbacks stay identical (reset and reveal may be handled natively directly).

**Window background:** `windowBg` sets `self.window.backgroundColor`; default stays lavender until
JS sends the theme color at boot.

**Periodic checks:** update check on launch (parallel with page load), on
`applicationDidBecomeActive:` throttled to once per hour, and on an `NSTimer` every 6 h. She never
quits the app.

Link `-framework UniformTypeIdentifiers`; `#import <CommonCrypto/CommonDigest.h>` for SHA-256.

## Step 3 — Buyer name on each sale (`app/index.html`)

- Data model: `deals[].who` (string, optional). Stored trimmed, capped at 40 chars, **omitted**
  (not `""`) when empty so old and new deals look identical. Snapshots/exports carry it automatically.
- Deal sheet: `Bought by` text field `#dealWho` between commission and week, with a `<datalist>` of
  distinct names from the live month + history. Clear it in the FAB open handler, populate in the
  ladder edit handler, read in `saveDeal()` for add and edit paths.
- Ladder row (`renderLadder`): render `esc(e.who)` (row is `innerHTML`). Layout decision made in the
  browser pass: prefer a dim second line under the row (`.lrow` gets `flex-wrap:wrap`, `.who` at
  `flex-basis:100%; padding-left:32px; font-size:14px; color:var(--ink-dim)`) over a 5-character
  ellipsis in the 236 px column. `$4,500` stays right-aligned; keep the existing `flag` behavior.
  `title="Sarah · $4,500"` on the row.

## Step 4 — Confetti

- Pure JS canvas, no library (`file://`, no CDN). One lazily created fixed full-screen
  `<canvas id="confetti">`, `pointer-events:none; z-index:50`. Rectangles + a few circles; colors from
  the **active theme** (`--accent`, `--accent-2`, gold `#f2cf6b`, white). Gravity, drag, spin, fade;
  rAF loop stops itself when empty and pauses while `document.hidden`. Particle caps: big 180,
  medium 90, small 40.
- API: `confetti({ power:'small'|'medium'|'big', x, y })`.
- Reduced motion: no silent skip — show a one-frame static burst plus a "🎉 GOAL!" toast.
- Triggers (live board only, never while viewing history), **fired after** `persist(); closeSheets();
  renderAll();` so it plays above the closed sheet:
  - **Big** (~2.5 s): `saveDeal()` add path when `deals.length` crosses `state.goalDeals`
    (prev < goal ≤ new). Leaderboard "me" row taps already route through `$('fab').click()` →
    `saveDeal`, so no extra trigger (verify).
  - **Medium**: same crossing for `state.minDeals`.
  - **Small** from the checkbox: goals post-it when a goal toggles to done.
- Crossing check only on the add path (not edit/delete/right-click undo).

## Step 5 — New month

- **Fix auto-rollover for an app left open:** replace the `curMonth` const with `currentMonth()`;
  `freshBoard()` and `rollover()` call it. Roll only when `state.month < currentMonth()` (string
  compare on `YYYY-MM`), never when the board is *ahead* of the calendar. Call `rollover()` (then
  `renderAll()` if it rolled) on `visibilitychange`→visible, window `focus`, and a 60 s interval.
- **Guard:** skip the timed/focus rollover while any `.overlay.show` exists (an open deal sheet holds
  `editing.idx` into the old board); `closeSheets()` re-runs the check.
- **Shared `archiveAndReset(newMonth)`** used by auto and manual paths: snapshot **`month, deals,
  bonuses, closers, goals, rep, pct, minDeals, goalDeals`** (renderers read these from `board()` with
  fallback to `state` for old snapshots — fixes history rendering with today's settings), push to
  `history`, post `archive`, then new board with goals unchecked and closers at 0.
- **Manual close-out**, two entry points, same confirm sheet `#closeoutOverlay` ("Archive August and
  start September? August stays in the month history."): (1) last row of the month popover
  "Close out August →"; (2) danger-styled button in Settings. Confirm sheet has a secondary
  "Export a backup first" button (runs Step 6 export, sheet stays open).
- After a manual close-out the board can be one month ahead; the `<` guard prevents re-archiving.
  When `state.month > currentMonth()`, the deal/bonus sheets preselect week 1 instead of the
  calendar's week.
- Month popover already lists history; no change beyond the close-out row.

## Step 6 — Export backup / import restore

- Settings sheet: `Export backup…` and `Import backup…` (ghost style) above Save/Cancel, plus the
  version footer. Buttons hidden unless `__shell.features` includes them (browser fallback always on).
- Export: `{ app:'GoalKeeper', version: APP_VERSION, exportedAt: ISO, data: state }` →
  `{type:'export', data, filename:'GoalKeeper-backup-YYYY-MM-DD.json'}`; native `NSSavePanel`
  (`allowedContentTypes = @[UTTypeJSON]`, `beginSheetModalForWindow:`). Browser fallback: Blob +
  `<a download>`.
- Import: `{type:'import'}` → native `NSOpenPanel` (json, 50 MB cap) → `__importedB64(b64)`. JS
  accepts the wrapped shape or a raw `data.json`; validates `deals`/`history` arrays, `month`
  string, each deal has numeric `amt`/`comm`/`ts` (malformed entries dropped), `theme` is a known
  key; shows `#importOverlay` with a summary ("August 2026 · 14 deals · 2 archived months · Sarah")
  before replacing state: `state = Object.assign(defaults, freshBoard(), imported); viewing = null;
  rollover(); applyTheme(); persist(); renderAll()`. Invalid file → same sheet with an error line,
  state untouched. Browser fallback: `<input type=file>`.

## Step 7 — Boot hardening (data preservation)

- In `loadState` boot: when `existed` is true but `saved` is null (file present, unparseable),
  **never adopt starter data and never persist** — extend the existing read-only branch. Starter
  data is adopted only when no data file exists at all or the saved board is pristine *and parsed*.
- JS posts `{type:'ready'}` after the first successful `renderAll()` (see updater fallback).
- `applyTheme()` runs before first paint (from the `load` callback, and from a `localStorage`/inline
  hint so the browser build doesn't flash).

## Step 8 — Theme picker

- Refactor every color to `:root` custom properties: `--accent`, `--accent-rgb`, `--accent-2`
  (second gradient stop, currently pink `#ff8fd0`), `--bg-a/--bg-b/--bg-c` (body radial gradients),
  `--bg-base` (linear base), `--blob-1/2/3`, `--postit-a/--postit-b`, `--tick` (`#ff6fb5`),
  `--ink`, `--ink-dim`, `--glass`, `--glass-border`, `--sheet-bg`, `--input-bg`, `--input-border`,
  `--me-color` (`#c07a00`), `--selection`, `--placeholder`, `--scroll-thumb`. Replace all 29
  `rgba(139,92,246,…)` with `rgba(var(--accent-rgb), …)`. Inline SVG literals (`#8B5CF6` in
  `#monthCaret` and hero underlines, ring gradient stops, tick color, `#7a5cd6` chart labels) become
  `var(--accent)` / `currentColor` or are emitted from JS with the theme value.
- Keep pen/marker "ink" colors (`--marker-red`, tally `#40366b`, cash green, coin gold) but define
  lighter dark-theme variants where they sit on dark glass.
- Themes on `<html data-theme>`: `lavender` (default = today's look), `blue`, `green`, `dark`
  (`--glass` ≈ rgba(255,255,255,0.08), light ink, `color-scheme: dark`, dimmer glows, dark scrollbar
  thumb). `state.theme` persisted; `applyTheme()` sets the attribute, `color-scheme`, and posts
  `windowBg` with the theme's base color.
- Settings: a "Look" row of four swatch circles, live preview on click, committed on Save, reverted on
  Cancel/Escape/backdrop click.
- Run `/themed-ui-chrome` afterwards for scrollbars, selects, inputs.

## Step 9 — Release tooling + ship

- `release.sh`: refuse a dirty tree; assert HTML meta version == `version.json` version and
  `minShell` ≤ bundle version; compute `sha256` for `index.html` and each listed asset into
  `version.json`; `./build.sh`; `./create_dmg.sh`; commit; tag `v<version>`; push;
  `gh release create v<version> app/index.html app/version.json <assets…> GoalKeeper.dmg`.
- Feed URL = `https://github.com/nmken/goalkeeper/releases/latest/download/version.json` (assets in
  one release are published atomically; no raw-cache mismatch). Raw URL remains only as a dev
  override.
- README: build/package/release flow; "UI-only update" recipe (edit HTML → bump meta +
  `version.json` → `./release.sh` → her app updates itself); "native change ⇒ DMG".
- DMG install text adds: "Before dragging the new app: Finder → Go → Go to Folder →
  `~/Library/Application Support/GoalKeeper` → duplicate that folder (one-time safety for this
  upgrade)." Plus the right-click → Open note (new binary = new ad-hoc signature).
- Release note to her: September may still show August in 1.0 until relaunch; 1.1 fixes that.
- Ship 1.1 as a DMG (no starter data). Her `data.json` is untouched; old deals without `who` render
  fine.
- **`/checkpoint`** after the plan lands verified.

---

## Files touched

| File | Change |
|---|---|
| `app/index.html` | version meta; theme variables + picker; buyer field + ladder; confetti; `currentMonth()`, rollover guards, `archiveAndReset`, close-out sheet + popover row; export/import UI + validation; update chip; `__shell` gating; `ready`; `applyTheme` |
| `shell/main.m` | updater (launch selection, periodic checks, download + sha256 validate + assets, install, applyUpdate, ready-timeout + nav-fail fallback, resetToBundled); export/import panels; backups (daily, closeout, pre-upgrade, pre-import); `windowBg`; `revealDataFolder`; `openURL`; `__shell` user script; menus |
| `build.sh` | version from meta into Info.plist; ATS local networking; new frameworks |
| `create_dmg.sh` | starter data opt-in; updated install text |
| `app/version.json`, `release.sh`, `.gitignore` | new |
| `README.md`, memory file | updated |
| `make-dmg.sh` | deleted |

## Execution order + checkpoints

0 git/housekeeping → checkpoint → 1 versioning → 8 themes (early: every later feature renders with
theme vars) → checkpoint → 3 buyer name → 4 confetti → 5 new month → 6 export/import → 7 boot
hardening → checkpoint → 2 shell (updater + hooks + backups) → checkpoint → 9 release → ship.

## Verification

1. **Browser pass** (`preview_start` with `goalkeeper-ui`: `python3 -m http.server 8737 --directory
   app`): all four themes screenshotted (board, every sheet, popover, post-it, flags, `me` row
   contrast in dark); buyer name saves/edits/renders/escapes (`O'Brien <x>`) and autocompletes;
   confetti at min, at goal, on goal checkbox, not on edit/delete/undo, plays above the closed sheet;
   close-out from popover and from Settings archives and the popover shows the archived month with
   the new month live, and archived months render with their own goal/min settings after changing
   Settings; export downloads JSON, import restores after confirm, bad JSON rejected with a message.
2. **Rollover while open**: set `state.month` to `2026-08` in devtools, trigger `focus` → rolls to
   September, August in history. Repeat with the deal sheet open → no roll until the sheet closes.
   Set `state.month` to `2026-10` → no roll.
3. **Native build**: `./build.sh`; launch `build/GoalKeeper.app` with a copy of a data.json in
   place; `backups/pre-upgrade-1.1.json` appears; export opens a Save panel and writes a valid file;
   import round-trips; `data.json.pre-import` exists; daily backup written on first save; dark theme
   sets the window background (no lavender flash on relaunch); Reveal Data Folder opens Finder.
4. **Data-preservation**: launch with an unparseable `data.json` present → app does not overwrite it,
   `data.json.bak` untouched, no starter adopted.
5. **Updater end to end, locally first** (see test plan below): local 1.2 feed → chip → click → new UI
   with fonts → relaunch still 1.2 → bundle 1.3 discards the App Support copy → corrupt-copy
   variants (no meta / unreadable / script block deleted / runtime throw in `renderAll`) each fall
   back to bundled (the last one via the `ready` timeout) → sha256 mismatch, version mismatch, 404,
   `minShell` too high (chip says installer needed) each write nothing → Wi-Fi off is silent →
   Reset to Built-in Version works → one real check against the GitHub Releases URL after pushing.
6. Run `/themed-ui-chrome` and `/checkpoint` at the marked points.

---

## Updater design (native, `shell/main.m`)

**App Support layout** (`~/Library/Application Support/GoalKeeper/`): existing `data.json`,
`data.json.bak`, `archives/` untouched. New: `app/index.html` + `app/fonts/*.woff2` + any listed
assets (present only when newer than the bundle), `backups/`, `data.json.pre-import`,
`shell-version.txt`, optional `update-url.txt` (one-line dev override of the feed URL).

**Feed**: `#define GK_FEED_URL "https://github.com/nmken/goalkeeper/releases/latest/download/version.json"`;
overridden by env `GK_UPDATE_URL`, then `update-url.txt`; `GK_NO_UPDATE=1` skips. Versions compared
with `[a compare:b options:NSNumericSearch]`.

**Launch selection `loadAppHTML`**: write pre-upgrade backup if the bundle version changed. Read
`gk-version` from the App Support copy via regex; if missing, or bundle version ≥ it, delete
`App Support/app/` and load the bundled file (read access = bundle `app/`). Otherwise load the App
Support copy with `allowingReadAccessToURL:` = `App Support/app/`. Adopt `WKNavigationDelegate`:
`didFailProvisionalNavigation`/`didFailNavigation` while on the App Support copy → discard and reload
bundled. On any load start a 10 s timer; if `{type:'ready'}` has not arrived when it fires and the
App Support copy is running → discard and reload bundled (catches runtime throws the old title ping
missed). `pageReady = YES` on `ready`; announce any pending update then.
`webViewWebContentProcessDidTerminate` → reload.

**Check + install `checkForUpdates:`** (launch, activate ≤1/h, 6 h timer, manual): ephemeral
`NSURLSession`, `ReloadIgnoringLocalAndRemoteCacheData`, 15 s timeout, redirects followed. Require
HTTP 200 and a dict with string `version`, `html`, `sha256`, optional `minShell`, optional `assets`
array. If `minShell` > bundle version → `__updateStatus('needsInstaller')` (manual) and stop. If
remote ≤ max(bundle, App Support copy) → done (`uptodate` if manual; if a newer copy than the running
page is already on disk, announce it). Else resolve `html` and each asset relative to the feed
(https only; http allowed only when the feed itself is http), download each with
`downloadTaskWithURL:` into a staging dir under App Support (move synchronously inside the handler).
Validate the HTML: SHA-256 equals `sha256`, valid UTF-8, contains `<title>GoalKeeper</title>`, the
exact `gk-version` meta for the feed version, and `window.__loadedB64`; validate each asset's hash.
Then build `app.new/` = bundled fonts + downloaded assets + HTML (`NSDataWritingAtomic`), swap
`app/` ← `app.new/`. Any failure: NSLog, clean staging, return without touching `app/`. Success:
store `pendingUpdate`, `__updateReady` on main once `pageReady`. `applyUpdate` (JS calls `persist()`
first) → `loadAppHTML`. `resetToBundled` → delete `App Support/app/` → `loadAppHTML`.

**Update chip (JS)**: `✨ v1.2 ready — tap to update` in the top bar; add `.updatechip` to
`inTopbarControls` so clicking it does not start a window drag. Hidden while viewing history? No —
always visible when pending.

**Export/Import panels**: script messages arrive on the main thread. `NSSavePanel`/`NSOpenPanel`
with `allowedContentTypes = @[UTTypeJSON]`, `beginSheetModalForWindow:`. Import caps at 50 MB,
base64s to JS.

**Pitfalls**: GitHub Releases "latest" is a 302 — follow it; keep the sha256 check regardless.
Env-var overrides only reach Terminal launches; use `update-url.txt` for Finder launches and remove
it after testing. Updates never write inside the bundle, so Gatekeeper's one-time approval is never
invalidated. Never bundle starter data in a DMG meant for an existing install.

**Updater test plan (local, before GitHub)**: copy `app/` to the scratchpad, bump the copy's meta to
1.2 with a visible change, write `version.json` with `version 1.2`, `minShell 1.1`, real `sha256`,
`assets` listing the two fonts with hashes; serve with `python3 -m http.server`; launch from Terminal
with `GK_UPDATE_URL=http://localhost:PORT/version.json` → chip → click → new UI with hand-drawn fonts
→ relaunch from Finder still 1.2. Rebuild with bundled 1.3 → App Support copy discarded. Then the
corrupt-copy variants (no meta / unreadable / script block deleted / runtime throw) each fall back.
Then sha mismatch, version mismatch, 404, and `minShell 9.0` each write nothing (the last shows the
installer chip on a manual check). Then Wi-Fi off is silent. Finally one real check against the
GitHub Releases URL after `./release.sh`.
