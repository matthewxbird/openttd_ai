# MvB AI — a multi-modal OpenTTD NoAI script

A competitive AI for OpenTTD. It scans the whole map and ranks every
candidate route — **across rail, air and road** — on a shared
economic *value surface* (per-mode, per-cargo, per-distance estimates),
then builds whichever mode wins for each opportunity:

- **Aircraft** — town↔town passenger & mail shuttles. Fastest early cash,
  no track to misbuild, no terminus deadlock; the biggest single earner.
- **Rail** — high-volume industry trunks (single- or double-track chosen
  per route), with **backhaul** (loaded return legs) where geography allows.
- **Road** — cheap short-haul bus/truck routes + **intra-town bus feeders**
  that transfer passengers into airport trunks (extends catchment).

It runs strict money discipline (borrow just-in-time, repay to a buffer),
a route lifecycle (probation → built → condemn/retire), and is hardened for
**competition**: ownership-aware pathfinding that routes around / over rival
track, and structured build-failure diagnostics (it can't screenshot, so it
explains failures and dumps an annotated ASCII map).

Heavy in-game logging at every phase so you can watch it think in the
AI Debug window. See `PLAN.md` for the full design + measured benchmarks.

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
     src\        (copy the whole folder - estimator, air, road, backhaul,
                  cargo_scan, scoring, strategy, money, candidates, route,
                  state, station_builder, depot_builder, terminus, signals,
                  track_builder, rail_pf, aystar, trains, railtype, autoreplace,
                  maintenance, planner, town_authority, junction_builder,
                  build_diag, map_dump, logger ...)
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

## What works now

- **Multi-modal value surface** — every candidate (rail / air / road) ranked
  together by estimated annual profit; the winning mode falls out of the
  economics per cargo & distance (`src/estimator.nut`).
- **Aircraft** (`src/air.nut`) — town↔town pax + mail; largest-airport-that-fits
  siting, airport-size plane scaling, continuous-shuttle orders, thin lifecycle.
- **Rail** — single- or double-track per route (cheapest layout that works),
  PBS signals, single-track salvage, **backhaul** loaded return legs
  (`src/backhaul.nut`), spur depots, capacity scaling, route retirement.
- **Road** (`src/road.nut`) — compact road A*, drive-through stops, short-haul
  bus/truck routes, and **intra-town bus feeders** transferring into airports.
- **Money discipline** (`src/money.nut`) — borrow just-in-time per build, repay
  the loan down to an operating buffer; affordability gates on usable money.
- **Competition hardening** (Phase 8) — ownership-aware pathfinding (routes
  around / grade-separates over rival track, never builds on foreign tiles) and
  structured build-failure diagnostics + owner-annotated ASCII map dumps
  (`src/build_diag.nut`, `src/map_dump.nut`).
- **Lifecycle** — probation → built → condemn/retire; never orphans vehicles.
- Town authority statues; yearly autoreplace.

## Measured (solo, headless benchmark)

Aircraft was the biggest lever: solo company value **1.09M → 2.77M (+154%)**
on the 5-seed × {128,256} suite. See `PLAN.md` and `tools/run_bench.ps1`.

## Not yet

- Save/Load (stubbed — a restarted game forgets state).
- Ships / water gaps.
- Junction-template corridor sharing wired into live routing (Phase 6, deferred).
- Refit-aware multi-cargo backhaul; demand-driven supply chains.

---

## References

- **OpenTTD AI API**: <https://docs.openttd.org/ai-api/>
- **Pathfinder.Rail library** (search OpenTTD content download list).
- The AI Debug window and `debug_level script=N` console command are
  your best friends while iterating.
