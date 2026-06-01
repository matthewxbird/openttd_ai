# MvB AI — Profitability & Competitiveness Plan

Goal: make MvB AI a top-tier, aggressively profitable competitor that out-earns
and out-expands rival companies on the same map — and, critically, **stays
solvent under competition**. This plan is grounded in (a) a measured honest
verdict from our own headless benchmark and (b) a deep study of how a leading
multi-modal NoAI wins. We are **learning from it, not copying it** — several
places below note where our design should be *cleaner / more robust* than the
reference.

---

## Honest verdict (measured, not guessed)

Our parallel benchmark (`tools/run_bench.ps1`, 5 seeds, 12 game-years, 1v1) gave:

```
WIN-RATE vs reference: 0/5 = 0%
seed 1  LOSS  reference=54.4M  MvB=52.6k
seed 2  LOSS  reference=47.8M  MvB=1
seed 3  LOSS  reference=54.0M  MvB=1
seed 4  LOSS  reference=56.9M  MvB=1
seed 5  LOSS  reference=30.8M  MvB=74.4k
```

Two facts dominate:

1. **We bankrupt under competition.** On 3/5 seeds we ended at company value = 1
   (broke), even though the *same seeds solo* reached ~0.5–1.1M. A competitor
   grabbing prime industries/space first, plus our own money mismanagement,
   tips us into a debt spiral. **A bankrupt company cannot win — solvency is
   prerequisite #1, ahead of everything else.**
2. **Even solvent, we earn ~1000× too little.** Best case ~74k vs ~30–57M. That
   gap is network *scale*: one transport mode, thin single-pair routes, empty
   return legs, no early-cash play, slow expansion.

### Root causes (ranked by impact on the result)

1. **No money discipline.** We `TakeMaxLoan()` at boot and never give it back,
   so we bleed interest from day one; we never contract when cash-stressed; we
   commit to builds without reasoning about total spending power. → bankruptcy.
2. **Single mode (rail) + fragile builder.** No air (the fastest early cash),
   no road (cheap feeders/short hauls); our double-track builder fails on hard
   terrain and wastes money.
3. **Per-pair, rail-only scoring.** We estimate each producer→accepter pair in
   isolation; we don't compare modes, and we don't rank on a fast global value
   surface, so we pick weak targets and expand slowly.
4. **Thin network.** No backhaul (empty return legs), no demand-driven feeder /
   supply routes to grow chain throughput, no future-production sizing.

---

## What we've already built (assets to keep)

- **Headless measurement loop** — `tools/openttd.Dockerfile` (OpenTTD 15.3,
  null driver), `tools/run_match.ps1`, and the parallel `tools/run_bench.ps1`
  (win-rate across seeds). This is a genuine edge: we can tune *with data*.
- **Pure-math unit tests** (`tools/run_tests.ps1`, dockerized Squirrel, 68
  passing) for scoring / estimator / strategy / engine / retirement decisions.
- **Strict route lifecycle** — probation → built, teardown + blacklist, protect
  shared stations, free pre-flight pathfind before spending.
- **Estimator** (`src/estimator.nut`) — pre-build fleet simulation → annual
  profit / ROI / income-per-vehicle / income-per-building-time.
- **Adaptive profit model** (`src/strategy.nut`) — roi / buildtime / pervehicle.
- **Engine economics** — power-to-weight-aware loco choice.
- **Town authority** (statues) and **route retirement** (drop chronic losers).

These stay. The plan below adds the missing pillars on top of them.

---

## How a top-tier multi-modal NoAI wins (deep study findings)

Mechanisms observed in the reference, with the *principle* we take from each:

1. **Usable-money accounting + borrow-on-demand.**
   `usable = bankBalance + (maxLoan − currentLoan)` — it reasons about total
   spending power, not just cash. It borrows the *minimum* needed for the next
   build (`SetMinimumLoanAmount(loan + need − balance + buffer)`) and repays to
   zero whenever the balance allows. → never pays idle interest.
   **Principle:** model usable money; borrow minimally, just-in-time; repay fast.

2. **Emergency contraction.** When usable money goes negative / cash is tight,
   it *sells vehicles idle in depots, stops unprofitable vehicles, and shrinks
   road/air fleets* before they sink the company.
   **Principle:** under stress, shed losers — don't ride them into bankruptcy.

3. **Disciplined build pacing.** It builds candidates top-down by value, but
   before each build checks `buildingCost + vehiclePrice ≤ usable`, waits for
   funds if short, and *stops the whole pass* when the next candidate's value
   drops below a threshold (or money/time runs out).
   **Principle:** never overcommit; spend only when the next thing clears a value
   bar and is affordable.

4. **Precomputed value surface → global multi-modal ranking.** For every cargo it
   precomputes `Estimate(vehicleType, cargo, distanceBucket, stdProduction)` →
   a `value`, across **all modes and distance buckets**. Candidates are then
   matched to real places and ranked globally (roi phase: by value; throughput
   phase: by value × production), choosing the **best mode per cargo/distance**.
   **Principle:** rank the whole map at once on a fast value surface; let the
   mode fall out of the economics, not a hard-coded "rail only".

5. **Multi-modal, mode chosen by economics.** Air (pax/mail) = explosive early
   ROI with tiny infrastructure and *no track to misbuild*; road = cheap short
   hauls + feeders; rail = high-volume trunks; water = gaps. Each gated by
   per-mode feasibility (airport noise/size, coast, road reuse).
   **Principle:** aircraft first for early capital; then road feeders + rail
   trunks; pick whichever mode wins the estimate for each candidate.

6. **Native bidirectional / backhaul.** When both endpoints produce *and* accept
   the cargo, it runs the route loaded both ways.
   **Principle:** detect mutual cargo and load the return leg.

7. **Demand-driven chain building.** It actively builds *supply/feeder* routes to
   satisfy a processing industry's input demand, lifting the whole chain's
   throughput (and the volume we deliver).
   **Principle:** grow production by feeding the industries we already serve.

8. **Future/expected production sizing.** It sizes routes for *expected* (often
   growing) production, not just last month's figure.
   **Principle:** build for where the industry is going.

---

## Where MvB AI will be *better* (not a clone)

- **Data-driven tuning.** Our `run_bench` win-rate harness lets us tune every
  constant against real outcomes across seeds — measure, don't guess. The
  reference hand-tunes opaque magic numbers; we'll regression-test ours.
- **Test-backed pure economics.** Money discipline, value ranking, and emergency
  rules are pure functions with unit tests — fewer silent regressions.
- **Stricter pre-commit validation.** We already pre-flight pathfinding and run
  a strict probation lifecycle; extending the same "validate before you spend"
  rule to *money* (Phase 0) should waste even less than the reference.
- **Simplicity where it pays.** We won't chase every mode/mod at once; we'll add
  the highest-EV modes (air, road) cleanly and keep the rail core robust.

---

## Roadmap (re-prioritized by the measured verdict)

Ordered by **expected competitive gain ÷ risk**, with *solvency first* because a
bankrupt company scores zero. Each phase ships independently, keeps the strict
route lifecycle, gets unit tests for pure parts, and is verified with
`run_bench` before moving on.

### Phase 0 — Solvency & money discipline *(NEW — top priority, low risk)*

The single change most likely to move us off 0%: stop bankrupting ourselves.

- **Usable-money model:** `Usable = cash + (maxLoan − loan)`. Replace
  `Money.HasFunds(cash ≥ x)` with affordability against *usable*.
- **Borrow on demand, repay fast:** drop `TakeMaxLoan()` at boot. Borrow the
  minimum needed for the next build just-in-time; repay toward zero whenever
  `cash − buffer > loan`.
- **Emergency contraction:** when usable < 0 (or cash < buffer), sell trains
  idle in depots and condemn the worst-performing route until solvent.
  (Builds on the existing retirement logic.)
- **Pre-commit affordability:** before any build, require
  `buildCost + initialFleetCost ≤ usable`; otherwise skip to a cheaper candidate
  or wait — never start a build we can't finish.

**Done when:** no seed in a 1v1 `run_bench` ends bankrupt (value = 1); we end
solvent on all seeds even when out-expanded. *(This alone won't win, but it
turns guaranteed losses into live games.)*

### Phase 1 — Value surface + global multi-modal ranking *(high leverage)*

- Precompute `Estimator.Estimate(mode, cargo, distanceBucket, stdProduction)` →
  value, for each cargo across distance buckets (extend the estimator to all
  modes as they land). Cache per scan.
- Rank ALL candidates globally on that surface (roi phase: value; buildtime:
  value × expected production), choosing the best *mode* per cargo/distance.
- Replace the current per-pair rail-only scan path with this surface lookup.

**Done when:** the scan ranks dozens of cross-mode candidates by value in one
pass; logged top-N shows the chosen mode per candidate.

### Phase 2 — Aircraft (early-cash engine) *(explosive ROI, low rail-risk)*

Air sidesteps our fragile track builder entirely — 2 airports + planes + orders.

- `src/air.nut`: airport siting (town pax/mail), plane selection, orders; reuse
  `Estimator.Compute` for the economics (it's mode-agnostic).
- Add `VT_AIR` candidates to the value surface; an air route lifecycle that
  skips rail-only maintenance.

**Done when:** in the opening years the AI seeds a few high-ROI air routes that
fund rapid expansion; `run_bench` company value in year ~5 jumps materially.

### Phase 3 — Road mode + feeders *(unlocks short hauls + network density)*

- `src/road/`: road pathfinder, drive-through stops, depots; `VT_ROAD` in the
  value surface; choose road when it beats rail for short/low-volume cargo.
- Feeders that transfer into rail/air trunks (`OF_TRANSFER`).

**Done when:** the AI builds profitable road routes and road→rail feeders, and
picks road when it's the cheaper profitable mode.

### Phase 4 — Network effects: backhaul + demand-driven chains *(high gain)*

- **Backhaul:** detect endpoints that mutually produce+accept a cargo; load both
  legs. Start with same-cargo (no refit), then refit-aware where wagons allow.
- **Demand-driven supply routes:** for a processing industry we serve, build
  feeder routes to meet its *input* demand → grows chain throughput and our
  delivered volume. Use expected/future production for sizing.

**Done when:** bidirectional routes appear where geography allows and chain
output (hence our income) grows over a match.

### Phase 5 — Town authority (DONE) & growth

Statues implemented. TODO: fund growth actions where it lifts accepted cargo;
avoid low-rating towns.

### Phase 6 — Junction integration & corridor sharing *(late-game space)*

Wire `junction_builder` templates into routing (test-mode validated, fall back
to grade-separated crossing; banned near stations) so routes share trunks
instead of laying redundant parallel track. Station templates for clean throats.

### Phase 7 — Continuous capacity / overflow tuning

Sharpen `maintenance.nut`: overflow-trend detection → +trains / longer trains /
split routes; periodic rebalance. (Route retirement already in.)

---

## Implemented so far (status)

- **Estimator** (Phase-1 fleet sim) — done; feeds ranking.
- **Adaptive profit model** (`strategy.nut`) — done; ROI mode drops distance
  weighting (turned a bankrupt solo seed into ~0.5M).
- **Engine economics** — power-to-weight loco metric — done (partial Phase 3 of
  the old plan; railtype upgrades still TODO).
- **Town authority** (statues) — done.
- **Route retirement** (drop chronic losers) — done.
- **Routing hygiene** — crash fix, game-time probation, free pre-flight
  pathfind, concurrent probation, proximity round-trip detection — done.

The above are necessary hygiene but did **not** move the 1v1 result off 0% —
confirming the verdict: **solvency (Phase 0) + scale (multi-modal, Phases 1–4)**
are the levers that matter next.

---

## Validation discipline

- Pure-math additions get dockerized `sq.exe` unit tests (`tools/run_tests.ps1`).
- Every phase measured with `tools/run_bench.ps1` (parallel, multi-seed) — track
  **1v1 win-rate** and per-seed solvency, not just solo value.
- Keep the strict route lifecycle; never demolish a station serving another line.
- Commit module-by-module, push after each.
