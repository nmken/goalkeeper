# GoalKeeper 1.1 plan audit (2026-09-01)

Audit of the "GoalKeeper 1.1 — self-updater + four feature requests" plan against the actual source
(`app/index.html` 1209 lines, `shell/main.m` 170 lines, `build.sh`, `create_dmg.sh`). No code changed.

## Verdict

The plan is sound and its architecture claims are accurate. It is NOT ready to execute as written:
there are 4 blocking gaps (theme system missing entirely, native shell will be frozen after 1.1 without
future-proofing hooks, no shell/HTML compatibility check, the "protect my data" ask is only half met),
plus a set of correctness fixes. Apply the list below, then execute.

Verified true: ObjC + WKWebView, bridge name `bridge`, `persist()` after every mutation, `curMonth`
computed once at line 631, `rollover()` at 650, `renderLadder` at 763, `saveDeal` at 1007, no
`WKUIDelegate` (so `alert`/`confirm` are silent), no git repo, no `.gitignore`, `gh` authed as `nmken`,
`nmken/goalkeeper` is free, `goalkeeper-ui` launch config exists.

---

## A. Blocking additions (plan is incomplete without these)

### A1. New Step 8 — Theme picker (dark / blue / green, not just pink-lavender)
The current UI hardcodes the palette: 29× `rgba(139,92,246,…)`, 4× `#8B5CF6`, pink ring gradient
`#ff8fd0`, pink checkbox tick `#ff6fb5`, pink post-it gradient `#ffe4f2→#ffd2e8`, three pink/purple
body radial gradients, pink blob `.b2`, `html { color-scheme: light }`, and the native window
background is hardcoded lavender in `main.m` (`colorWithCalibratedRed:0.83 green:0.83 blue:1.0`).

Required:
- Refactor every color to CSS custom properties on `:root`: `--accent`, `--accent-rgb` (for the
  rgba() glows), `--accent-2` (the second gradient stop, currently pink), `--bg-a/--bg-b/--bg-c`
  (the three background gradients), `--blob-1/2/3`, `--postit-a/--postit-b`, `--tick`, `--ink`,
  `--ink-dim`, `--glass`, `--glass-border`, `--sheet-bg`, `--input-bg`, `--me-color` (`#c07a00`),
  `--selection`, `--placeholder`, scrollbar thumb colors. SVG strokes that are inline literals
  (`#8B5CF6` in `#monthCaret`, hero underlines, ring gradient stops, `#ff6fb5` tick) must switch to
  `var(--accent)` / `currentColor` or be rendered from JS with the theme value.
- Keep "ink" drawing colors that read as pen/marker (`--marker-red`, tally `#40366b`, cash green,
  coin gold) but give dark theme lighter variants where they sit on dark glass.
- Themes: `lavender` (current, default), `blue`, `green`, `dark` (dark glass: `--glass`
  ≈ rgba(255,255,255,0.08), `--ink` light, `color-scheme: dark`, dimmer glows). Applied via
  `<html data-theme="…">`. Store in `state.theme`; persisted with everything else; applied before
  first paint on boot to avoid a flash.
- Settings sheet: a row of 4 swatch circles labeled "Look", live-preview on click, saved with Save,
  reverted on Cancel.
- Native hook NOW (shell change, must ship in the 1.1 DMG): bridge message `{type:'windowBg', r,g,b}`
  so JS sets the NSWindow background to the theme's base color. Without it the dark theme flashes
  lavender on every launch and the theme can never be fully fixed by an HTML-only update.
- Confetti palette reads from the active theme (accent, accent-2, gold, white) instead of the
  hardcoded lavender/pink list in Step 4.
- Run `/themed-ui-chrome` after: scrollbars and `color-scheme` must follow the theme.
- Verification: screenshot all four themes in the browser pass; check every sheet, popover, flags,
  post-it, chart labels and the `me` leaderboard name for contrast in dark.

### A2. Future-proof the native shell before it freezes
The whole point of 1.1 is "never ship a DMG again". Anything native that a future UI could need must
be in this shell. Add to Step 2/6:
- `windowBg` bridge message (A1).
- `revealDataFolder` (opens `~/Library/Application Support/GoalKeeper` in Finder) — also add as a
  File menu item.
- `openURL {url}` (https only) for a future "what's new" link.
- Generic `assets` support in the updater: `version.json` gets `"assets": ["fonts/x.woff2", …]`
  (relative to feed, downloaded into `App Support/app/`, each with a `sha256`). Today the updater
  only copies the two fonts from the bundle, so a future UI update that adds a font, image, or
  sound could never load it. Decide this now; it cannot be added later without a DMG.
- Native shell injects `window.__shell = { version: "<CFBundleShortVersionString>", features:
  ["export","import","update","windowBg","revealDataFolder","assets"] }` via `WKUserScript` at
  document start. JS gates UI on `__shell.features` so an updated HTML running in an older shell
  hides what the shell can't do instead of posting messages that are silently dropped.

### A3. Shell ↔ HTML compatibility gate
`version.json` must carry `"minShell": "1.1"`. Native compares against its own bundle version and
refuses to install an HTML that needs a newer shell (log + no chip, or a chip that says "needs the
new installer" and links the DMG). Without this, a future 1.4 HTML that relies on a 1.2 shell
message installs "successfully" and half-works on her machine.

### A4. "Protect the data" is only half addressed
Manual export requires her to remember. `data.json.bak` is only ever one save old. Add (native, so
it must be in 1.1):
- Rotating automatic backups: on the first `save` of each calendar day, copy `data.json` to
  `App Support/GoalKeeper/backups/data-YYYY-MM-DD.json`; keep the last 30.
- On every archive (auto or manual close-out) also write `backups/closeout-YYYY-MM.json` containing
  the full state, not just the month snapshot.
- Close-out confirm sheet gets an "Export a backup first" secondary button.
- Import restore sheet lists `backups/` files? No — keep it to the file picker, but the File menu's
  "Reveal data folder" makes the backups discoverable.

---

## B. Correctness fixes to the plan as written

### B1. Auto-rollover while a sheet is open (Step 5)
`rollover()` on `focus`/60 s interval can replace `state.deals` while `editing = {kind:'deal', idx}`
is live in the deal sheet; the subsequent save writes into `state.deals[idx]` of the new board
(undefined → throws). Guard: skip the timed/focus rollover while any `.overlay.show` exists and
retry on the next tick; `closeSheets()` should trigger a rollover check.

### B2. Archived snapshots lose their settings
`rollover()` snapshots only `deals/bonuses/closers/goals`. `renderHero`/`renderLadder` render
archived months with the *current* `state.goalDeals`/`minDeals`, and `renderLeader` with the current
`state.rep`. Once she edits settings, history renders wrong (ring at wrong goal, "GOAL!!" flag on the
wrong row). `archiveAndReset()` must snapshot `rep, pct, minDeals, goalDeals` too, and the renderers
must read them from `board()` with fallback to `state` for old snapshots.

### B3. Buyer name must be escaped and given room
- Render with `esc(e.who)` (the ladder is built with `innerHTML`; an apostrophe or `<` in a name
  must not break the row).
- The ladder column is 236 px; a row with checkbox + `$4,500` + flag + name is tight. Prefer the name
  on a dim second line under the amount (`.lrow` becomes `flex-wrap` with `.who` at `flex-basis:100%`)
  rather than ellipsis at 5 characters. Decide in the browser pass, not in the abstract.
- Add a `<datalist>` of previously used names (this month + history) so repeat buyers autocomplete.
- Trim, cap at 40 chars, store `undefined` (not `""`) when empty so old and new deals look the same.

### B4. Confetti trigger ordering and reduced-motion
- Fire after `closeSheets(); renderAll();` in `saveDeal()`, not before — otherwise it plays under the
  sheet overlay (`z-index` 10) and the blurred backdrop.
- When the crossing happens via the leaderboard "me" row it already routes through `$('fab').click()`
  → `saveDeal`, so no extra trigger is needed (confirm in test).
- `prefers-reduced-motion`: don't silently skip; show a 1-frame static burst or a "🎉 GOAL!" toast so
  she still gets the moment if macOS Reduce Motion is on.
- Cap particles (≈180 big / 90 medium / 40 small) and stop the rAF loop when the tab is hidden.

### B5. Update-ready chip vs. window drag
`inTopbarControls` (line 1198) lists `.monthbtn, .iconbtn, .backchip, .monthpop`. The new chip must
be added there or clicking it starts a native window drag instead of applying the update.

### B6. Updater must also check periodically, not only at launch
She leaves the app open for weeks (that is the whole rollover bug). Add an `NSTimer` check every
6 h plus a check on `applicationDidBecomeActive:` throttled to once per hour. Otherwise the update
never reaches an app that is never quit.

### B7. Replace the size/marker validation with a hash
`version.json` gets `"sha256": "…"` for the HTML (and each asset). Native verifies with CommonCrypto
before install. This directly solves the raw.githubusercontent 5-minute stale-cache mismatch the plan
warns about, replaces the "≥ 20 KB" heuristic, and detects truncated downloads. Keep the exact
`gk-version` meta check as well. `release.sh` computes the hashes.

### B8. Runtime-broken HTML passes the sanity ping
The `didFinishNavigation` ping (`document.title` + `typeof __loadedB64`) only catches syntax errors.
A runtime throw in `renderAll()` leaves a blank board forever. Better: JS posts `{type:'ready'}` after
the first successful `renderAll()`; native starts a 10 s timer on load and, if `ready` doesn't arrive
while running the App Support copy, discards it and reloads bundled. Also add an app-menu item
"Reset to Built-in Version" (deletes `App Support/app/`) as a manual escape hatch.

### B9. Publish via GitHub Releases, not raw main
Use `https://github.com/nmken/goalkeeper/releases/latest/download/version.json` (and the HTML as a
release asset next to it). Assets in one release are published atomically, so `version.json` and
`index.html` can't disagree the way raw + cache can. `release.sh` does `gh release create v<ver>
app/index.html app/version.json`. `NSURLSession` follows the 302 by default. Keep the raw URL only as
the dev/override path.

### B10. Close-out discoverability
Her complaint was "no option to start a new month". Buried in Settings it stays hidden. Put
"Close out August →" as the last row of the month popover (the month name is where she'll look) AND
in Settings. Same confirm sheet.

### B11. Manual close-out clock caveat
After a manual close-out the board is ahead of the calendar; `tsForWeek` anchors new deals to
`state.month` (correct) but `weekOf(Date.now())` preselects the *calendar's* week chip. Preselect
w1 when `state.month > currentMonth()`.

### B12. Import shape
`Object.assign(defaults, freshBoard(), imported)` — also validate that each deal has numeric
`amt`/`comm`/`ts` and drop malformed entries; validate `theme` is a known key; call `rollover()`
only if the imported month is older than the calendar (the plan says this; make it explicit in code
comments so the `<` guard from B1 is reused).

---

## C. Housekeeping the plan gets wrong or leaves loose

- C1. **Delete `make-dmg.sh`**, don't "leave it". Two DMG scripts writing to different paths
  (`build/GoalKeeper.dmg` vs `./GoalKeeper.dmg`) is a trap; README and the memory file both still
  point at the stale one. Update README and the `goalkeeper-app-architecture` memory in Step 0.
- C2. `create_dmg.sh` bundles **this Mac's live `data.json`** as `starter-data.json` (currently an
  August board, rep "Aya", 15 deals, last modified Aug 23). Make starter bundling opt-in
  (`--starter` flag) so the 1.1 DMG doesn't ship a stale personal board. Her install ignores it
  (board not pristine), but it's still baked into a file you're sending around.
- C3. Public repo privacy: `freshBoard()` hardcodes real coworker first names (Aya, Emma, Gabe,
  Isaiah) and the goals. Neutralize the defaults in the repo (or move them to `starter-data.json`,
  which is git-ignored) before the first public push.
- C4. `.gitignore`: `build/`, `*.dmg`, `.DS_Store`, `app/starter-data.json`. **Commit**
  `app/fonts/*.woff2` (build.sh only fetches when missing; the updater needs them in the bundle).
- C5. `build.sh` currently uses a quoted heredoc (`<<'PLIST'`) — the plan's note to unquote it is
  correct; also fail hard if the meta regex doesn't match.
- C6. `release.sh` should refuse to run with a dirty tree, and verify `minShell` ≤ bundle version
  and that `sha256` in `version.json` matches the file before tagging.
- C7. Memory says `./make-dmg.sh`; plan Step 0 says update memory with the repo URL — do both.
- C8. Today is 2026-09-01. This Mac's `data.json` still says `2026-08` (rolls on next launch). Her
  installed 1.0 will auto-roll to September the next time she *relaunches*; if she never quits, it
  stays on August — that is likely the exact symptom she reported. Say so in the release note to her.

---

## D. Things already right — no change

- Data location survives reinstall; old deals without `who` render fine.
- Bridge, `persist()`-after-mutation, and the in-page-sheet-instead-of-`confirm()` rule.
- Version single-source-of-truth via the HTML meta; `NSNumericSearch` comparison.
- Launch selection (bundle ≥ App Support → discard), fonts copied at install, updates never touch
  the bundle (Gatekeeper approval stays valid).
- `data.json.pre-import` before an import; `NSSavePanel`/`NSOpenPanel` as window sheets.
- Confetti with no library (file:// has no CDN); crossing check only on the add path.
- Verification plan (browser pass → native → local updater feed → GitHub → corrupt copy) and the
  checkpoint after Step 0 and after landing.

## E. Execution order recommendation

0 git/GitHub (+C1–C4, C7) → 1 versioning → 8 themes (A1, do it early: it touches every color the
later features render) → 3 buyer name → 4 confetti → 5 new month (+B1, B2, B10, B11) → 6
export/import (+A4, B12) → 2 updater (+A2, A3, B5–B9) → 7 release tooling → ship DMG.
Checkpoint after 0, after 8, after 6, after 2.

---

## F. Preserving her existing data on the 1.0 → 1.1 install (added 2026-09-01)

Context: her install has ~25 deals; this Mac's data.json is unrelated test data and must never reach hers.

- Reinstall is safe by design: `data.json` lives in `~/Library/Application Support/GoalKeeper/`, outside
  the bundle. Dragging the new app over the old one never touches it. On first launch the boot code
  reads her file (25 deals → not "pristine") and ignores any bundled starter board. If the calendar has
  moved on, August is archived into history + `archives/archive-2026-08.json`, not dropped.
- **Trap to close:** `create_dmg.sh` bundles this Mac's `data.json` as `starter-data.json`. If her
  `data.json` ever fails to parse at launch, `loadState` sees `saved == null`, adopts the starter
  board, and `persist()`s it — overwriting her file and rotating the corrupt copy into `data.json.bak`
  (last good backup lost). Fixes: (1) ship the 1.1 DMG **without** starter data (C2, make it opt-in);
  (2) in the boot branch, never adopt starter when `existed` is true but `saved` is null — treat it
  like the existing "unreadable, don't persist" branch.
- **Pre-upgrade backup (native, 1.1 shell):** on first launch of a new bundle version (store the last
  seen version in `App Support/GoalKeeper/shell-version.txt`), copy `data.json` →
  `backups/pre-upgrade-<version>.json` before the WebView loads.
- **Install text for this one DMG:** add "Before dragging the new app: Finder → Go → Go to Folder →
  `~/Library/Application Support/GoalKeeper` → duplicate that folder" (1.0 has no export yet).
- She must right-click → Open once more: new binary = new ad-hoc signature.
