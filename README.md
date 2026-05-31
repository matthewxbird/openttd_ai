# MvB AI — an OpenTTD NoAI script

A learning-project AI for OpenTTD. It scans the map for the most
profitable producer→accepter cargo pair (by ROI across **all** cargoes,
not just coal), builds a double-track rail line with stations + depot
between them, dispatches a train, then loops to add more routes as
funds allow.

Heavy in-game logging at every phase so you can watch it think in the
AI Debug window.

---

## Manual install (Windows)

1. **Locate OpenTTD's content directory.** Default on Windows:
   ```
   %USERPROFILE%\Documents\OpenTTD\
   ```
   Open it in Explorer with `Win+R` → `%USERPROFILE%\Documents\OpenTTD\`.

2. **Create the AI subfolder** if it doesn't exist:
   ```
   %USERPROFILE%\Documents\OpenTTD\ai\MvB_AI\
   ```

3. **Copy the AI files into it.** Copy these from this repo into the
   `MvB_AI` folder above:
   - `info.nut`
   - `main.nut`
   - the entire `src\` folder

   Final layout in OpenTTD content dir:
   ```
   ai\MvB_AI\
     info.nut
     main.nut
     src\
       logger.nut
       money.nut
       railtype.nut
       scoring.nut
       candidates.nut
       cargo_scan.nut
       station_builder.nut
       depot_builder.nut
       track_builder.nut
       signals.nut
       trains.nut
       route.nut
       state.nut
       autoreplace.nut
       aystar.nut
       rail_pf.nut
   ```

   **For development**, symlink instead of copying so edits flow through.
   Run an admin command prompt and:
   ```
   mklink /J "%USERPROFILE%\Documents\OpenTTD\ai\MvB_AI" "C:\dev\openttd_ai"
   ```

4. **No library install needed.** The pathfinder is fully custom (`src/aystar.nut`
   + `src/rail_pf.nut`), adapted from
   [AAAHogEx](https://github.com/rei-artist/AAAHogEx). No online content
   download required.

---

## Assign it to a company

1. Main menu → New Game.
2. Click **"AI/Game Script Settings"** (or "AI Settings" depending on
   OpenTTD version).
3. Add a slot → pick **"MvB AI"** from the dropdown.
4. Start a new game. Recommended for first try: temperate climate,
   ~256×256, fairly flat terrain.

---

## Watch the AI think

This is the fun part. The AI logs at every phase (`[BOOT]`, `[SCAN]`,
`[RANK]`, `[STATION]`, `[TRACK]`, `[SIGNAL]`, `[TRAIN]`, `[MONEY]`,
`[REPLACE]`, `[LOOP]`) so you can see exactly what it's doing.

### Open the AI Debug window

- Toolbar → click the **cog/wrench icon** → **"AI/Game Script Debug"**.
- Or use the keyboard shortcut **`Ctrl+Alt+D`** (configurable).
- Use the company dropdown at the top of the window to select MvB AI.
- Logs stream live as the AI runs.

### Bump verbosity in the console

- Open the in-game console with the **backtick** key (`` ` `` — to the
  left of `1` on US/UK keyboards).
- Type:
  ```
  debug_level script=3
  ```
- Higher numbers = more verbose. `5` is the max.

### Pause + step

- In the AI Debug window, use the **"Break on:"** field to halt when
  the AI logs a string containing the given text.
- **"Continue"** resumes execution.
- This is the closest thing to a breakpoint while iterating on the AI.

### What you should see

Roughly, in order:

```
[BOOT]    MvB AI starting. Hello, OpenTTD!
[MONEY]   Loan set to max: 500000
[BOOT]    Rail type chosen (id=..., max_speed=...)
[SCAN]    Cargoes detected: 12
[SCAN]    COAL: 14 producers, 3 accepters
[RANK]    #1 COAL | Coal Mine -> Power Station | dist=84 | ROI=0.42
[RANK]    Attempting COAL Coal Mine -> Power Station (dist=84, ROI=0.42)
[STATION] Built source station id=... at tile=...
[STATION] Built dest station id=... at tile=...
[TRACK]   [out] pathfinder iter=250
[TRACK]   [out] path found, length=92
[TRACK]   [out] built rail=88 bridges=2 tunnels=0
[SIGNAL]  [out] placed 22 PBS one-way signals
[TRAIN]   Engine pick: ... (speed=... power=... cost=...)
[TRAIN]   Train built id=... wagons=3
[TRAIN]   Train ... dispatched.
[LOOP]    Tick done. Routes=1 Blacklist=0 Cash=...
```

If you see `[Err]` lines, something gave up — most often the pathfinder
ran out of budget on a terrible map. The pair is added to the
blacklist and the AI tries the next candidate.

---

## Running tests

The pure modules (`scoring`, `estimator`, `strategy`, `candidates`,
`money.ShouldRepay`) are covered by Squirrel unit tests.

**Recommended (no host install): Docker.** A tiny image builds a Squirrel
interpreter from source, so nothing needs to be on PATH:

```
./tools/run_tests.ps1            # builds the image on first run, then runs tests
./tools/run_tests.ps1 -Rebuild   # force-rebuild the interpreter image
```

Under the hood: `tools/squirrel.Dockerfile` compiles `sq`, and the suite runs
with the repo mounted at `/work` (`docker run --rm -v "${PWD}:/work" mvb-sq
tests/run_all.nut`).

**Alternative: native `sq.exe`.** Build/get Squirrel 3.x, put `sq.exe` on PATH,
then from repo root: `sq.exe tests/run_all.nut`.

Expected output ends with:
```
passed: <N>
failed: 0
ALL TESTS PASSED
```

> Note: the upstream Squirrel master treats `base` as a fully reserved keyword
> (stricter than OpenTTD's bundled Squirrel). Avoid `base` as a local variable
> name in pure modules so they parse under both.

---

## What works in v1

- Multi-cargo scan, ROI ranking across all (producer, accepter) pairs.
- Double-track rail between picked pair.
- Station + depot + PBS one-way signals.
- Engine + wagon pick by cost-effectiveness, distance-sized trains.
- Loop: keep adding routes as cash allows.
- Reuse stations at industries we already serve.
- Yearly autoreplace via AIGroup.
- Max loan on boot, surplus repaid when cash is healthy.

## Not in v1 (planned)

- Save/Load (currently stubbed — restarted game forgets state).
- Multi-train per route.
- Road / aircraft / ship support.
- Smarter station orientation (currently tries two cardinal layouts).
- Parallel double-track that hugs the first track (currently both
  tracks pathfind independently).

---

## References

- **OpenTTD AI API**: <https://docs.openttd.org/ai-api/>
- **Pathfinder.Rail library** (search OpenTTD content download list).
- The AI Debug window and `debug_level script=N` console command are
  your best friends while iterating.
