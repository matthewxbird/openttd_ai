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

## Game-phase strategy (EARLY → MID → LATE) *(NEW — primary doctrine)*

**Why this exists:** our old opener built **double-track, two-pair "dual lines"
from turn one**. They cost too much, take too long to lay, and stall the company
before it has any income — slow start, thin map presence, easy to out-expand.
We replace it with a phase-aware doctrine: start cheap and wide, upgrade only
what proves itself, optimise only at the end. The phase is selected from game
age + company state (cash, usable money, # of healthy built routes), not a fixed
clock.

### EARLY — land-grab for cash (single-track, one-train lines)

Goal: **plant as many cheap, profitable lines as fast as possible** to claim map
space and throw off early cash. Speed and footprint beat per-line efficiency.

- **Single-track, one-train, two-way PBS** is the *default* build, not a salvage
  fallback. One out-track, one reversing train, simple terminus stations.
- **Cheap, high-ROI pairs:** short/medium hauls with quick payback; rank by
  income-per-building-time so we lay the next line sooner. Avoid expensive
  terrain crossings — skip a candidate rather than spend big to cross water.
- **Spread out / claim space:** prefer candidates that stake new ground (new
  towns/industries, away from existing lines) so rivals can't box us in. Map
  presence is a strategic asset, not just income.
- **Money discipline (Phase 0):** borrow just-in-time per line, repay fast; never
  start a line we can't finish. Many small affordable bets, not one big one.

**Exit to MID when:** ~6 healthy single-track lines are built and profitable
(and cash/usable money is comfortably positive).

### MID — upgrade the winners + grow towns

Goal: **stop laying new cheap track; deepen the proven lines and start growing
the demand side.** Compounding, not land-grab.

- **Upgrade earners to double-track + multi-platform stations:** take the
  half-dozen+ profitable single-track lines and convert them to double-track with
  multi-platform (RoRo / through) stations so the train cap can rise past the
  single reversing train. (This is where the throughput ceiling lifts — see the
  reversing-terminus deadlock note.) Upgrade by profitability rank; leave
  marginal lines single-track.
- **Move goods & created resources into towns:** prioritise routes that deliver
  *processed* cargo (goods, food, etc.) and raw production **into towns** —
  delivering accepted cargo grows the town.
- **Grow towns deliberately:** town authority actions (statues already done →
  fund growth where it lifts accepted cargo), so the towns we serve get bigger
  and accept/produce more, compounding the upgraded lines.

**Exit to LATE when:** the core upgraded network is saturating (overflow trends,
high station ratings) and cash is strong.

### LATE — extreme optimisation + huge compound routes

Goal: **squeeze maximum value from a mature network.**

- **Huge compound routes:** multi-stop / multi-cargo trunks, backhaul on every
  leg, demand-driven feeder chains into the trunks. Maximise loaded vehicle-km.
- **Corridor sharing & junctions:** route new traffic onto shared trunks via
  `junction_builder` templates instead of redundant parallel track; clean
  station throats.
- **Continuous capacity tuning:** overflow-trend → +trains / longer trains /
  split routes; periodic rebalance; retire chronic losers.

This doctrine **reorders the roadmap**: Phase 0 (solvency) underpins EARLY; the
single-track-default + land-grab is the EARLY deliverable; double-track upgrade +
town growth (Phases 4–5) become the MID deliverable; backhaul/compound routes +
junction sharing + capacity tuning (Phases 4,6,7) become LATE. Multi-modal
(air/road, Phases 2–3) slots into EARLY (air = fastest early cash) and MID (road
feeders).

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

**Mapping to the game-phase doctrine above:**
- **EARLY (land-grab):** Phase 0 (solvency) + single-track-default land-grab
  builder + Phase 2 (air for fastest early cash).
- **MID (upgrade + grow):** double-track/multi-platform upgrade of proven lines,
  Phase 3 (road feeders), Phase 4 (move goods/resources into towns), Phase 5
  (town growth), Phase 9 (passenger network + bus/mail feeders → grow towns).
  Short road lines (≤~25 tiles) from Phase 9 also seed the EARLY land-grab.
- **LATE (optimise + compound):** Phase 4 (backhaul/compound), Phase 6 (junction
  corridor sharing), Phase 7 (capacity tuning).
- **All phases (competitive only):** Phase 8 (foreign-track-aware building +
  build-failure debuggability) — applies the moment a rival shares the map,
  which is every 1v1 turn; without it the land-grab itself breaks on rival track.

The single-track-default opener and the EARLY→MID→LATE phase selector are the
**new top-priority build items** (they replace the dual-track opener); they ride
on top of the Phase 0 money model.

**EARLY land-grab — IMPLEMENTED (commit 6b452b8).** `Strategy.GamePhase` (EARLY
until 6 proven routes, then MID) + `EarlySingleTrack` build cheap one-train
single-track lines in EARLY, gated to cramped maps (≤128 dim): measured solo
128x128 +19% (cheap, collision-free, dodges the reversing-terminus deadlock),
while spacious maps keep double-track throughput (blanket single-track sank 256
−13%). MID/LATE distinct build paths still TODO.

**MEASURED: the throughput ceiling is the reversing-terminus deadlock, and it
gates every "more capacity" idea.** Three approaches to lift per-route throughput
were all built + benched and all REGRESSED vs the 973,579 best:
- *Production-gated* (build double up front for high-output routes): 818,879
  — 128 sank 960k→648k. Double-track + 2 trains on cramped maps deadlocks.
- *Distance-gated* single-track: 777,411 — same distance helps 128, hurts 256.
- *Demand-driven single→double in-place upgrade* (build back track + re-signal +
  add 2nd train when a single line's lone full train can't clear its backlog):
  867,991 — never fired on the poor seed (cash-gated), and where it did fire on
  256 it deadlocked the converted routes (seed4 944k→445k). Implemented
  (`Maintenance._UpgradeSingleToDouble`, `TrackBuilder.BuildBackTrack`,
  `Signals.RemoveAlong`) then reverted; re-add once the deadlock is gone.
  **Re-add requirement:** recall ALL of the line's trains to a depot and wait
  until every one is parked BEFORE laying the back track or changing any signal —
  never edit track/signals while a train is on the line (it can crash or stall on
  a half-converted layout). Convert only when the line is clear. Then, once the
  line IS upgraded, check each parked train's orders, fix them if the new
  double-track layout needs different routing, and re-send the trains out.

**=> The real unlock is the reversing-terminus deadlock itself.** Our stations are
dead-end terminuses; a train drives in, reverses, and leaves over a shared throat
crossover — with 2+ trains that throat deadlocks (hence MAX_TRAINS=2 and why
single-track-1-train wins cramped maps). Fixing it (RoRo / drive-through stations,
or a deadlock-proof throat) lets MAX_TRAINS rise AND makes the demand upgrade pay.
This is now the top solo lever (was Phase 6/7; promote it).

### Phase 0 — Solvency & money discipline *(IMPLEMENTED — commit d24084a)*

DONE: dropped boot `TakeMaxLoan`; `Money.Usable = cash + (maxLoan−loan)`;
`EnsureFunds(need)` borrows just-in-time before a committed build;
`RepayDownToBuffer()` repays the loan down to an 80k operating buffer each tick;
`HasFunds` gates on `Usable`. Pure `RepayAmount`/`BorrowTarget` unit-tested.
**Measured solo: overall 873,603 → 973,579 (+11.4%; +20.7% vs the original
baseline).** 128 +37.8% (idle-loan interest was a big cramped-map drag). Buffer
swept: 80k optimal (50k=831k, 150k=766k — non-monotonic/chaotic). TODO remaining:
emergency contraction (sell idle/condemn worst when usable<0) — not yet needed
solo (no bankruptcies), revisit for 1v1.

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

### Phase 2 — Aircraft (early-cash engine) *(IMPLEMENTED — commits d66a8db, e49b778)*

Air sidesteps our fragile track builder entirely — 2 airports + planes + orders.

DONE: `src/air.nut` — airport siting (search near town centre, noise-aware,
test-build before commit), plane selection (cap×speed/runcost, big-plane gated
to big-airport availability), town↔town **passenger** candidate generation,
and a THIN air lifecycle (`Air.MaintainRoute` / `Air.CheckCondemning`: prune
dead planes, add on backlog, condemn a dud — no track/stuck/deadlock logic).
`Estimator.UnitEconomics(VT_AIR,…)` prices air on the shared value surface;
air candidates rank ALONGSIDE rail in the main loop; rail `Maintenance` /
`NeedsMoreCapacity` / `State.FindExistingStation` skip `air=true` routes.

**BIGGEST LEVER SO FAR. Measured solo, 5 seeds × {128,256}, 12y:**
```
                     128         256          overall
main baseline        901,937     1,283,232    1,092,584
+ air (shuttle)      1,399,792   4,148,650    2,774,221   (+154%)
```
Key tuning: **continuous-shuttle orders** (AppendOrder flag = literal `0`, NOT
OF_FULL_LOAD_ANY) beat full-load by +75% — full-load idled planes topping off
on thin pairs (few trips/yr); shuttle = many trips/yr, revenue scales with
trips. Native backhaul (both towns produce pax). 256 gains most (long hops).
Untested levers: MAIL cargo, MAX_PLANES (5), MAX_TOWNS (12), distance window.

**Done when:** ✅ company value jumps materially (achieved: +154% solo).

### Phase 3 — Road mode + feeders *(IMPLEMENTED — commit 9f1bea4)*

DONE: `src/road.nut` — compact road A* (reuses AyStar; routes over flat/dry
land + existing road, avoids water, never builds on foreign property),
drive-through stops, road depot, road vehicles with continuous-shuttle orders,
thin lifecycle (`Road.MaintainRoute`/`CheckCondemning`). `Estimator` VT_ROAD
unit economics (cheap infra) so road wins SHORT, low-volume hauls. Town↔town
short-hop bus candidates rank on the shared value surface with rail + air.
Feeders into trunks = Phase 9. Original spec below.

### Phase 3 (orig) — Road mode + feeders *(unlocks short hauls + network density)*

- `src/road/`: road pathfinder, drive-through stops, depots; `VT_ROAD` in the
  value surface; choose road when it beats rail for short/low-volume cargo.
- Feeders that transfer into rail/air trunks (`OF_TRANSFER`).

**Done when:** the AI builds profitable road routes and road→rail feeders, and
picks road when it's the cheaper profitable mode.

### Phase 4 — Network effects: backhaul + demand-driven chains *(IMPLEMENTED (backhaul) — commit ed0a36d)*

DONE (both halves): (1) rail same-cargo **backhaul** (`src/backhaul.nut`) — when
both endpoints mutually produce+accept the cargo, the train loads the return leg
too (~doubling revenue); air/road already shuttle loaded both ways. (2)
**demand-driven supply chains** — `State.HaulsFrom` + `Scoring.SupplyBoost` (×3)
boost any candidate delivering the INPUT cargo INTO an industry whose OUTPUT we
already haul; supplying its inputs grows its production, so our line out of it
carries more (the mirror of the forward ChainBoost; AAHOG's
SearchAndBuildToMeetSrcDemand mechanism). TODO (minor): refit-aware multi-cargo
backhaul. Original spec below.

### Phase 4 (orig) — Network effects: backhaul + demand-driven chains *(high gain)*

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

### Phase 6 — Junction integration & corridor sharing *(LATE — DEFERRED, low EV)*

`junction_builder.nut` exists (scan/stamp/rotate templates) but is NOT yet
wired into live routing. Deferred: high-risk to wire blind (could break the
rail builder that still carries value) and LOW EV now that AIR is the dominant
earner — corridor sharing matters only once rail trunks are dense. Revisit with
bench data after the multi-modal stack is tuned.

### Phase 7 — Continuous capacity / overflow tuning *(SUBSTANTIALLY DONE)*

`maintenance.nut` already: adds a train on source backlog, lengthens
under-length trains, retires chronic losers; air/road scale vehicles on
waiting cargo (own lifecycles). Remaining (optional): overflow-TREND detection
(vs instantaneous), periodic rebalance, route splitting — tune with bench data.

### Phase 8 — Foreign-track-aware building & track-build debuggability *(IMPLEMENTED — commit 4fee1a9 + follow-ups)*

DONE: ownership-aware pathfinding (`rail_pf.nut`: foreign rail priced as a
near-wall `_cost_foreign_rail`, neighbour guard skips flat joins onto non-own
tiles so paths detour or grade-separate), graceful avoid-set **detour/reroute**
(`track_builder._RunPathfinder`, MAX_REBUILD attempts) + repair-pass terraform,
structured **build-failure reports** wired into the builder (`build_diag.nut`,
classifies ERR_UNKNOWN from tile facts — owner/rail/water/station/buildable),
owner-annotated ASCII map dump, and foreign-safe cleanup (`_FailRoute` never
demolishes non-owned rail). Classifier + cross-cost are unit-tested.
Remaining (optional debug polish, not built): PF trace-mode, scripted 1v1
foreign-corridor regression scenario.

Original spec below.



**Problem (measured behaviour):** our pathfinder (`src/rail_pf.nut`) costs and
*joins* any tile where `AIRail.IsRailTile()` is true, but it does **not** check
tile ownership. In a 1v1 / multi-company game a rival's rail is interleaved with
ours and the map's, so the pathfinder happily routes a path onto/through foreign
track; the builder (`src/track_builder.nut`) then fails the piece with
`ERR_OWNED_BY_ANOTHER_COMPANY` (and we cannot demolish or build on it). Today we
just `Log.Warn` the failed piece and the whole line build stalls or aborts —
this is a major reason builds break down once an opponent is on the map.

**Robust foreign-track handling:**

- **Ownership-aware pathfinding.** In the neighbour/cost step, classify every
  rail tile by `AITile.GetOwner` / `AIRail.GetOwner` relative to `COMPANY_SELF`:
  - *Own* rail → joinable/shareable as today.
  - *Foreign* rail → **impassable** by default (do not route onto it). Only allow
    a clean grade-separated crossing (bridge/tunnel over/under) at a heavy cost,
    never a flat join or a build *on* the foreign tile.
  - *Town/road* level-crossing rules unchanged.
- **Foreign-aware crossing cost.** Replace the single `_cost_crossing_rail` with
  distinct costs: cheap for our own corridor, expensive-but-legal for a
  grade-separated jump over foreign track, ∞ (forbidden) for a flat join to
  foreign track. This pushes paths *around* rivals when feasible, *over* them
  when not.
- **Builder pre-check + graceful detour.** Before laying each piece, verify the
  tile is buildable by us (clear / own); if a piece comes back
  `ERR_OWNED_BY_ANOTHER_COMPANY` / `ERR_AREA_NOT_CLEAR` due to foreign property,
  trigger a **local re-route** around the offending tile rather than aborting the
  whole line. Cap retries, then fall back to single-track salvage / abandon
  cleanly (never orphan, per the condemn rules).
- **Don't touch what isn't ours.** Cleanup/teardown must never demolish or count
  foreign tiles (extend the existing `_Touch` discipline to skip non-owned rail).

**Track-build debuggability (we must be able to see *why* a build failed):**

- **Structured build-failure report.** On any build abort, emit a single
  structured log line: phase, route label, failing tile + coords, the exact
  `AIError.GetLastErrorString()`, tile owner, and the pathfinder cost class of
  that tile. (Today the error is logged but not the *ownership/cost context* that
  explains it.)
- **Annotated map dump.** Extend `src/map_dump.nut` to colour/mark tiles by
  owner (self / each rival / town / unowned) and overlay the attempted path and
  the failing tile, so the ASCII dump on failure shows *where the rival track
  blocked us*. (Headless can't screenshot — this is our eyes.)
- **Pathfinder trace mode.** A debug flag that logs the top-N expanded nodes with
  their cost breakdown (terrain / crossing / foreign penalty) for a failed
  search, so we can tell "no route" from "route existed but priced wrong".
- **Regression tests.** Pure-math `sq.exe` tests for the ownership classifier and
  the foreign-aware cost function; a scripted 1v1 `run_bench` scenario that puts a
  rival line across our best corridor and asserts we still build (detour or
  grade-separated) rather than abort.

**Done when:** in 1v1, lines that previously aborted in mixed-ownership terrain
now complete (detour or grade-separated crossing) or fail *cleanly* to single
-track salvage; every build abort produces a structured, owner-annotated
diagnostic; the foreign-track classifier and cost function are unit-tested.

### Phase 9 — Passenger network & town growth *(IMPLEMENTED — commit 79f0cc3)*

DONE: PAX + MAIL as first-class **air** cargo (a town may hub one pax + one
mail air route, reusing its airport); intra-town **bus feeders**
(`Road.BuildFeeder`) that TRANSFER town-centre pax into a proven airport
station (joined drive-through stop), extending the trunk catchment — feeders
are never profit-retired (fare credits the trunk). Short-haul road bus rule
lands via Phase 3. Town growth = Phase 5 statues. Original spec below.

### Phase 9 (orig) — Passenger network & town growth (bus/truck feeders) *(NEW — MID-game growth engine)*

**Why:** towns grow when a nearby station has a good rating and we *transport*
their passengers/mail and *deliver* accepted cargo (goods, food) — see the
[Towns](https://wiki.openttd.org/en/Manual/Towns) manual. A bigger town produces
more passengers/mail and accepts more cargo, compounding every line that serves
it. Passengers are also a large, always-available cargo we currently ignore.

**Feeder pattern (the core mechanic).** A town's passengers sit in its *centre*,
but a high-capacity train station usually can't go there. So run cheap **bus
feeders inside the town** that pick up passengers and **transfer**
(`OF_TRANSFER`, paid on final delivery not at the transfer) them to a train (or
air) station on the town edge; the trunk vehicle then hauls them the long
distance for the big payment — see
[Feeder service](https://wiki.openttd.org/en/Manual/Feeder%20service). Same
pattern for mail and for moving *goods/food into the town centre* to grow it.

- **Passenger/mail as first-class cargo.** Add town pax/mail pairs to the value
  surface (Phase 1). Origin = town centre catchment; destination = another town
  (pax) or anywhere accepting mail.
- **Intra-town bus feeders.** `src/road/` bus stops in the town centre + a depot;
  short loop that transfers into the trunk station. Size the feeder fleet to the
  trunk's throughput, not the other way round.
- **Trunk leg picks the winning mode.** Bus/air/rail for the long leg falls out of
  the value-surface estimate per distance bucket.
- **Grow towns we serve.** Tie into Phase 5: prioritise delivering accepted cargo
  (goods/food/pax) *into* served towns, keep station rating high, and fund
  growth/authority actions where they lift accepted cargo — so served towns
  enlarge over the match.

**Short-haul mode rule (bus/truck instead of train).** For short routes —
roughly **≤ 20–30 tiles** — a single train + its track/stations is overkill and
slow to pay back. Make the value surface / mode selector prefer **road (bus for
pax/mail, truck for freight)** under that distance threshold (and for
low-volume cargo), reserving rail for longer, higher-volume trunks. The exact
threshold is a tunable constant, swept with `run_bench`. This also feeds the
EARLY land-grab: cheap short road lines plant fast and claim space with almost no
build risk.

**Done when:** the AI runs bus/mail feeders that transfer into longer trunks,
serves and visibly grows towns over a match (rising population / accepted cargo),
and chooses road over rail for sub-~25-tile / low-volume candidates.

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
- **Orphan/deadlock recovery** (commit 1c69c27) — solo seeds were going bankrupt
  (value=1) with NO opponent: a route scaled to MAX_TRAINS deadlocks the
  reversing terminus, the built-route stuck handler never acted, and the eventual
  2-year-loss condemn gave up on the deadlocked trains and demolished the depots,
  ORPHANING still-running trains into a debt spiral. Fix: condemn a built route
  after 3 stuck passes; never orphan in condemnation (keep depots, reverse stuck
  trains, sell as they park, finish only when empty). Solo mean 284k -> 314k,
  bankruptcy eliminated. The reversing-terminus deadlock itself (the throughput
  ceiling, ~540k) is the next lever.
- **Multi-size benchmarking + map-dump diagnostics** (commit 4db1705) -
  run_bench `-MapSizes`, run_match `-MapSize`; src/map_dump.nut renders the
  terrain/route layout as an ASCII grid in the log on track-build failure and
  on stuck-train condemn (headless can't screenshot). Exposed the back-track
  failure leak below.
- **Single-track salvage** (commit b36b1f6) - when only the back track fails to
  build (parallel track can't get a 2nd water/terrain crossing), run the route
  on the out track alone with ONE reversing train (two-way PBS, capped at 1
  train) instead of abandoning the built out track + stations. BIGGEST lever so
  far: solo mean @256 jumped to ~817k with TWO seeds over 1,000,000; 128x128
  bankruptcies eliminated. Overall mean (128+256) ~572k.
- **Single-track crash fix** (commit 409cc1d) - the integrity check dereferenced
  a null back-track path on single-track routes ("index '0' does not exist"),
  killing the whole AI; existing routes then coasted, silently inflating some
  benchmark seeds. Fixed (null-safe FindGap / ValidateAndRepair). Matches are
  DETERMINISTIC, so each measurement is exact.
- **Train cap = 2** (commits 52bf476, 8c99691) - the reversing-terminus deadlock
  was the dominant value destroyer (routes scaling to 3-4 trains deadlock ->
  condemn -> ~200k lost each). Sweep of MAX_TRAINS (overall solo mean): 4=460k,
  3=491k, 2=806k, 1=699k. **MAX_TRAINS=2 hits the 1,000,000 solo goal @256
  (mean 1.028M; seed4 1.6M, seed1 1.32M).** 128 mean ~585k (a later lever).
  Root cap is still the terminus; RoRo through-stations would let the cap rise.
  **Under the new doctrine this cap is the EARLY single-track ceiling** (1–2
  reversing trains per cheap land-grab line); the MID double-track + multi-platform
  upgrade is exactly what lifts the cap on the proven lines, and LATE compound
  routes raise it further.

## Milestone: solo 1M reached (256 maps) -> 1v1 vs AAHOG begins

Per the goal, solo benchmarking continued until ~1M company value; reached on
256x256 (mean just over 1M) at MAX_TRAINS=2. Now benchmarking 1v1 vs AAAHogEx
(C:\dev\_aaahogex_ref). AAHOG is multi-modal and very strong, so the initial 1v1
gap is expected to be large; this sets the real competitive baseline. Remaining
solo levers (128-map scale, terminus rework, money discipline / build pacing)
feed back into the 1v1 fight.

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
