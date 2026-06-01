# MvB AI — Profitability & Competitiveness Plan

Goal: make MvB AI a top-tier, aggressively profitable competitor that out-earns
and out-expands rival companies on the same map. This plan is derived from
studying how the strongest open-source NoAI competitors win, and lays out the
gaps in our current design plus a phased roadmap to close them.

The headline weaknesses, in order of competitive impact:

1. **Single transport mode (rail only).** We never use road, ship, or air.
   We forfeit the fastest early-money plays and can't serve routes where rail
   is uneconomic.
2. **Static, crude profit scoring.** We rank on `AnnualProfit × distance` using
   hard-coded per-tile cost constants. We never simulate the *actual* engine
   set, capacity, running cost, or build time of a candidate before committing.
3. **No adaptive strategy.** We always optimise the same thing. Strong AIs
   switch their objective by game phase (grow capital → grow throughput → grow
   per-vehicle yield as the vehicle cap approaches).
4. **Shallow engine selection.** "Best speed×power/cost" loco + "highest
   capacity" wagon. No weight/slope/acceleration model, no railtype comparison,
   no proper double-heading economics.
5. **No feeder / transfer networks, no backhaul.** Every route is one isolated
   producer→accepter pair with empty return legs.
6. **No town authority management.** We never build statues / fund local
   actions to lift station ratings, so we leave cargo (and money) on the table.
7. **Junction templating not wired into routing.** We can't share corridors, so
   the map fills with redundant parallel lines and we hit space limits.

---

## How the strongest competitors are built (reference findings)

Studied a mature multi-modal NoAI. Key architecture:

- **Adaptive profit model.** Each turn it picks ONE objective:
  - `roiBase` — when cash-poor or during inflation: maximise return on
    investment (grow the bank fastest).
  - `buildingTimeBase` — when there's lots of vehicle headroom: maximise
    income per unit of *building time* (throughput; build as fast as possible).
  - `vehicleProfitBase` — when near the vehicle cap: maximise income per
    *vehicle* (squeeze the most out of each scarce vehicle slot).
  A single `GetValue(roi, incomePerBuildingTime, incomePerVehicle)` selector
  feeds the candidate ranking, so the *same* candidate list is re-ranked for the
  current phase.

- **A real Estimator.** Before building anything it computes, per candidate:
  income, running cost, building cost, building time (a function of distance and
  infrastructure), days per trip, vehicles-per-route, capacity, and from those
  derives ROI / income-per-building-time / income-per-vehicle. It simulates the
  actual engine set (loco+wagon combo, count, refit, double-head) using live
  `AIEngine` data, weight, slopes, and acceleration — not constants.

- **Massive candidate generation.** It enumerates cargo×place pairs across the
  whole map (capped by a time budget), PLUS transfer candidates, meet-place
  candidates, and return-route pairs, then ranks the lot and builds top-down
  until money or the time budget runs out.

- **Feeder / transfer / backhaul networks.** Routes feed each other (a short
  road feeder into a rail trunk), and return legs carry cargo back
  (bidirectional routes) instead of running empty.

- **Multi-modal.** Rail, road, tram, ship, aircraft — picks the cheapest
  profitable mode per candidate. Aircraft give explosive early cash; road gives
  cheap feeders and short hauls; ships handle water gaps.

- **Capacity / overflow management.** Detects overflowing stations and
  under-served demand, then adds vehicles, lengthens trains, or builds
  additional producing/accepting routes to balance the network.

- **Town authority management.** Builds statues and funds local actions to lift
  ratings where it matters.

---

## Current MvB AI architecture (baseline)

- `main.nut` loop: maintenance tick → `CargoScan.Scan` → chain-boost → rank →
  build best affordable candidate → autoreplace → repay loan → sleep. Gated on
  probation (verify a line earns before building the next) and capacity (scale
  existing before building new).
- `scoring.nut`: `AnnualProfit` from production×payment, minus amortised
  `BuildCostEstimate` (constant per-tile costs); `DistanceWeighted`,
  `ChainBoost`, `ClusterBoost`.
- `cargo_scan.nut`: scores producer→accepter (+town accepter) pairs;
  `MIN_DISTANCE=40`.
- `trains.nut`: `PickEngine` (speed×power/cost), `PickWagon` (capacity),
  `PickNumTrains` (production/120), double-head when underpowered.
- `track_builder.nut` + `rail_pf.nut`: custom A* double-track builder.
- `maintenance.nut`: probation/condemn lifecycle, capacity scaling.
- `junction_builder.nut`: scan→template→rotate (NOT wired into routing yet).
- Rail only. Picks one railtype at boot. No transfers, no backhaul, no towns.

---

## Roadmap

Phased so each phase is independently shippable and measurably improves results,
ordered by **expected competitive gain ÷ implementation risk**. Every phase must
keep the existing strict-validation lifecycle (probation, teardown+blacklist of
broken lines, protect shared stations).

### Phase 1 — Estimator: simulate before building *(highest leverage, low risk)* — IMPLEMENTED (pending in-game verification)

Status: `src/estimator.nut` added (`EngineSet` fleet sim + pure `Compute`
metrics); wired into `cargo_scan` ranking; metrics logged in the top-N output;
`tests/test_estimator.nut` added. Needs the unit suite run (`sq.exe`) and in-game
confirmation that logged estimates track realised profit (~30%), then tune
`TILES_PER_DAY_PER_KMH` / `RAIL_DIST_FACTOR` / `TERMINAL_DAYS`.


Replace constant-based scoring with a real pre-build estimate. This makes every
later decision (which route, which mode, how many vehicles) sharply better.

- New `src/estimator.nut` computing, for a `(cargo, src, dst, distance,
  production)` candidate:
  - **Engine set**: reuse/extend `Trains.PickEngine`/`PickWagon` to return a
    full set — loco(s), wagon, wagon count to fill the platform, double-head
    decision — and its real capacity from `AIEngine.GetCapacity`.
  - **Trip days**: `distance / effectiveSpeed` (effective speed derated for
    acceleration on the route's slopes; start with a flat derate, refine later).
  - **Income/trip**: `capacity × AICargo.GetCargoIncome(cargo, distance, days)`.
  - **Running cost/year**: `Σ AIEngine.GetRunningCost` across the fleet.
  - **Build cost**: keep `BuildCostEstimate` but calibrate constants against
    `AIRail.GetBuildCost` / `AIBridge` / station / depot real costs.
  - **Vehicles per route**: `ceil(production / trips-per-month-per-train)`.
  - Derive **roi**, **incomePerBuildingTime**, **incomePerVehicle**.
- Calibrate the cost constants in `scoring.nut` against live `GetBuildCost`
  calls at boot (store inflated values) instead of magic numbers.
- Tests in `tests/` (pure-math parts) the same way `scoring` is tested.

**Done when:** ranking uses estimator output; logged estimates roughly match
realised profit on built routes (within ~30%).

### Phase 2 — Adaptive profit model *(high leverage, low risk)* — IMPLEMENTED (pending in-game verification)

Status: `src/strategy.nut` added. `Strategy.Decide(cash, vehicles, cap)` picks
`roi` / `buildtime` / `pervehicle` each tick (poor→roi, headroom→buildtime,
near-cap→pervehicle); `Strategy.Apply` re-scores every candidate by the chosen
estimator metric, keeping cluster + distance weighting consistent. Wired into
the main loop before ranking, mode logged per tick. `tests/test_strategy.nut`
covers mode thresholds, metric selection, and sign-preserving re-scoring.

Remaining: run the unit suite; confirm in-game that the logged mode switches as
cash/vehicle-count grow and that early routes are high-ROI. Tune `RICH_CASH`
and the headroom/busy fractions.

### Phase 3 — Deeper engine economics + railtype upgrades *(medium)* — PARTIALLY IMPLEMENTED

Status: `Trains.PickEngine` now ranks by `Trains.EngineValue` = effective
speed (rated, capped by power/weight sustainable speed) ÷ running cost, instead
of `speed*power/cost`. Favours fast, adequately-powered, cheap-to-run locos;
double-heading still covers raw power shortfalls. Pure + unit-tested
(`tests/test_trains.nut`). STILL TODO: per-railtype route comparison and
in-service railtype upgrades; refit-aware wagon choice.

- Improve `PickEngine`: model train **weight** (loco + loaded wagons), use
  `AIEngine.GetPower` vs weight on the route's **max slope** to predict real
  speed; pick the loco that maximises *income per running cost* at that speed,
  not raw speed×power.
- Compare **railtypes**: estimate the best route on each available railtype
  (faster track can pay for itself) and pick the winner; upgrade existing lines
  when a markedly better railtype unlocks and ROI justifies it.
- Refit-aware wagon choice; articulated/multiple-unit handling.

**Done when:** chosen engines beat the current heuristic on income/vehicle in
side-by-side route logs.

### Phase 4 — Network effects: backhaul + feeders + more candidates *(high gain, medium risk)*

- **Backhaul / bidirectional**: when src and dst each produce a cargo the other
  accepts, run loaded both ways (huge income/vehicle gain). Detect via
  `Place`/industry cargo maps; extend `Route` + ordering to load at both ends.
- **More candidates**: widen `CargoScan` to enumerate more cargo×place pairs
  under a per-tick time budget (resume-style generator), so we always have a
  deep ranked list rather than a handful.
- **Feeders (after road, Phase 6)**: short feeders gathering cargo into a trunk
  station. Defer the build until road exists; design the route model now to
  allow transfer orders (`OF_TRANSFER`).

**Done when:** bidirectional routes appear where geography allows and measurably
raise income per vehicle; candidate list depth > a few dozen.

### Phase 5 — Town authority management *(medium gain, low risk)* — IMPLEMENTED

Status: `src/town_authority.nut` added. `TownAuthority.Tick(state)` runs each
loop: for every route delivering into a town, build a **statue** there once when
affordable (permanent local-rating boost -> station accepts more cargo). Pure
decision `ShouldBuildStatue` is unit-tested (`tests/test_town_authority.nut`).
STILL TODO: fund other local actions; avoid dumping into low-rating towns.

- For town-accepting routes (goods/food/pax/mail), build a **statue** and **fund
  local actions** when affordable to lift the station rating and accepted
  fraction. (`AITown.PerformTownAction`.)
- Prefer towns where our rating is already decent; avoid dumping into low-rating
  towns.

**Done when:** town delivery routes show higher accepted-cargo fractions after
the authority actions.

### Phase 6 — Second transport mode: ROAD *(high gain, higher risk)*

Road is the cheapest second mode and unlocks feeders + short hauls rail can't
serve economically. Biggest single expansion of where we can make money.

- `src/road/` builder: road pathfinder (or reuse A* with road cost), bus/truck
  stations, drive-through stops, depots.
- Extend the estimator + candidate gen to consider `VT_ROAD` per candidate and
  pick the cheaper profitable mode.
- Feeders into rail trunks (ties off Phase 4).

**Done when:** the AI builds profitable road routes and road feeders, and chooses
road over rail when it's cheaper for short/low-volume cargo.

### Phase 7 — AIR (and later SHIP) *(explosive early cash, contained risk)*

- Aircraft: city-pair pax/mail. Very high early ROI, minimal infrastructure —
  ideal `roiBase`-phase play. Airport placement + estimator support for `VT_AIR`.
- Ships last (most situational): water-gap cargo, docks, buoys.

**Done when:** in the opening years the AI seeds a couple of high-ROI air routes
that fund rapid rail/road expansion.

### Phase 8 — Junction integration & corridor sharing *(efficiency / late-game space)*

- Wire `junction_builder` templates into routing: when a new route would parallel
  an existing corridor, tie into it with a validated stamped junction (test-mode
  first, fall back to grade-separated crossing), keeping the
  `JUNCTION_STATION_GUARD` ban near stations.
- Station templates (the deferred `docs/JUNCTIONS_TODO.md` item) for clean,
  regression-free throats.

**Done when:** routes share trunk corridors instead of laying redundant parallel
track, and the map stays buildable late game.

### Phase 9 — Capacity / overflow tuning *(continuous)*

- Sharpen `maintenance.nut`: detect station overflow (cargo waiting trending up)
  and under-served demand; respond with +trains / longer trains / split routes.
- Periodic network rebalance pass; retire chronically unprofitable routes.

---

## Sequencing rationale

- **Phases 1–2 first**: they multiply the value of *everything* else for little
  risk — better estimates and the right objective per phase. Do these before
  adding modes, or we'd just expand a poorly-ranked search.
- **Phase 3–5**: deepen rail economics and squeeze existing routes.
- **Phases 6–7**: add modes — the largest source of new profitable
  opportunities, but the most build effort, so they come after the brain is good.
- **Phases 8–9**: efficiency and late-game scaling.

## Test / validation discipline

- Pure-math additions get `sq.exe` unit tests in `tests/` (as `scoring` does).
- Every phase verified in-game with heavy logging before moving on.
- Keep the strict route lifecycle: probation → built, or teardown + blacklist;
  never demolish a station serving another line.
- Commit module-by-module, push after each.
