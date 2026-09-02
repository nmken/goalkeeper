# GoalKeeper

Your whiteboard, as a tiny Mac app: deal counter, commission tracker, tally-mark leaderboard, and monthly goals.

## Build & install

```bash
./build.sh        # → build/GoalKeeper.app
./create_dmg.sh   # → ./GoalKeeper.dmg (drag to Applications); add --starter to bundle this Mac's board
```

First launch of the installed app: **right-click → Open** (it's ad-hoc signed, not notarized). Only needed once.

Data lives in `~/Library/Application Support/GoalKeeper/data.json`. Past months are archived there automatically on rollover.

## Use

- **+** bubble (or tap your leaderboard row) — log a deal; commission auto-fills from your standard % (editable per deal)
- **+ bonus** chip — add weekend bonuses etc.
- **Leaderboard** — tap a closer +1, right-click −1 (right-click your own row undoes your last deal)
- **Goals post-it** — tap the box to check off, click text to edit, hover ✕ to remove
- **⚙** — commission %, monthly minimum/goal deals, your name, closer names
