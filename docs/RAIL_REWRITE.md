# Rail-layer clean rewrite (Phase 11 keystone)

Goal: bust the ~3M local optimum toward AAHOG's ~44M. The gap is **fleet size**
(see PLAN.md Phase 11): AAHOG runs hundreds of vehicles via **drive-through
multi-platform stations** (no reversing deadlock) + **distance-scaled per-route
train counts** (cap = game limit 500). We cap at 2 trains/route because our
**reversing terminus deadlocks** past 2. Rewriting the rail BUILDER to AAHOG's
station model removes that cap. Keep the rest (candidates, estimator, money,
lifecycle) — only the builder is capped.

Branch: `feat/rail-rewrite`. Build incrementally, smoke + bench each piece.
Topology needs the user's GUI visual-debug loop (headless blind-builds failed 10/10).

## AAHOG station model (reverse-engineered, `_aaahogex_ref/station.nut`)

A rail station is a rectangle defined by 4 numbers (class `RailStation` @2702,
base `HgStation` @1647):
- `platformTile`  — top-left corner tile of the station rectangle.
- `platformNum`   — number of PARALLEL platforms (the rectangle's width).
- `platformLength`— length of each platform (the rectangle's depth).
- `GetPlatformRailTrack()` — orientation: `AIRail.RAILTRACK_NW_SE` or `NE_SW`.

**One call builds the whole block** (`BuildStation` @2720):
```
AIRail.BuildRailStation(platformTile, railTrack, platformNum, platformLength, joinStation)
// or BuildNewGRFRailStation(..., cargo, industryType, industryType, 500, isSource)
```
`joinStation` = `AIStation.STATION_NEW` or an existing station id to merge into one
logical station (this is how multiple platforms/lines share one station id).

**Connection tiles, BOTH ends** (`GetPlatformConnectionTiles` @2824): for each
platform i, the tile just BEFORE the platform and just AFTER it:
```
NW_SE: (x+i, y-1) and (x+i, y+platformLength)
NE_SW: (x-1, y+i) and (x+platformLength, y+i)
```
A **drive-through** station wires approach track at BOTH ends (enter one, exit the
other). A terminus wires only one end. AAHOG default `isRoRo = !IsTransfer()`
(`trainroute.nut:857`) → drive-through for normal routes.

Station factory classes (`station.nut`): `SrcRailStationFactory` (@1518),
`DestRailStationFactory` (@1560, **platformNum default 3**), `TransferStationFactory`
(@1582), `TerminalStationFactory` (@1601). Concrete stations: `SmartStation` (@3735,
the flexible drive-through), `DestRailStation` (@4057), `SrcRailStation` (@4612),
`TransferStation` (@3484), `SimpleRailStation` (@5226). READ THESE NEXT for the
throat/approach geometry + signal pattern before laying track.

Per-route fleet (`trainroute.nut:1286`):
```
maxTrains = engineSet.maxVehicles                       // base from engine/wagon
maxTrains = maxTrains * (pathDistance+addl) / pathDistance  // scale by distance
```
Capped only by `vehicle.max_trains` (game setting, default 500). Add trains until
the route's `maxTrains` or cargo backlog says stop.

## Target architecture (new modules)

Keep: `cargo_scan`, `candidates`, `estimator`, `scoring`, `money`, `strategy`,
`state`, `route` (record), `maintenance` lifecycle (adapt caps), `air`, `road`.

Rewrite/replace (rail builder only):
1. **`station_model`** — RailStation record {cornerTile, num, length, axis, id}
   + `BuildDriveThrough(corner, num, length, axis, cargo, joinId)` (one
   BuildRailStation call) + `ConnectionTiles(end)` (both-ends approach tiles)
   + `Place(industryOrTown, axisToward, num, length)` siting search.
2. **`rail_builder2`** — given two drive-through stations, lay a **double-track
   main** (out + back) connecting one end of src to one end of dst and the other
   ends back (a loop), reusing the existing `rail_pf` A* pathfinder. Signal as a
   one-way PBS through-route. No reversing.
3. **`fleet`** — distance-scaled `maxTrains`; build/dispatch N trains with
   through-orders (load@src → unload@dst → back, no reverse); top up to cap on
   backlog.
4. **caps** — `Maintenance.MAX_TRAINS` becomes per-route distance-scaled (drive-
   through routes only); keep the flat-2 cap ONLY for any legacy reversing route.

Wire behind a flag (`USE_RAIL2`) OFF on main; flip for smoke/bench; keep the old
builder until rail2 beats it.

## Forced order (each bench-gated)

1. Drive-through station builds + ONE through-train runs a loop (no reverse). SMOKE:
   junctions/station form, train completes a round trip, 0 deadlock.
2. Distance-scaled fleet: N trains per route on the double-track loop. BENCH vs
   baseline — expect the first real value lift (more vehicles).
3. Junctions/shared trunks (port from `feat/auto-junction`, now trunks are
   double-track + drive-through dst = safe throat).
4. Dynamic profit model (roi→buildingTime→perVehicle) + breadth/transfers.

Do NOT reorder — caps can't rise before the station is deadlock-free (measured).

## KEY: drive-through stations are BAKED THROAT TEMPLATES (not algorithmic)

`SmartStation` (`station.nut:3735`) is hand-crafted geometry. `GetRails()` returns
a fixed list of 3-tile rail segments (`[[dx,dy],[dx,dy],[dx,dy]]` in a station-local
coord system via `At(x,y)`, rotated by `stationDirection`) that forms the THROAT:
the platforms (cols 0,1[,2]) merge upward through ~6 rows of rail into a single
ARRIVAL line and a single DEPARTURE line, plus a depot. ASCII (from source):
```
 6   D I     D=departure  I=arrival (the two main-line connection points)
 5 A B
 4 r r
 3 r r r     <- throat: platforms fan into arrival/departure
 2 r B r
 1 r r r
 0 s s       <- platforms (s), cols 0..platformNum-1
   0 1 2
```
Exposed tiles: `GetArrivalsTiles()`, `GetDeparturesTiles()` (+ `*DangerTiles` for
signal placement). AAHOG **stamps the throat** at the platform site, then the
MAIN-LINE pathfinder only connects departure→(other station)arrival and back.

=> **Our rewrite uses the SAME approach and our EXISTING tooling**: bake the
drive-through throat as a `junction_builder` StampList template (transcribe
AAHOG's `GetRails()` directly, OR capture a hand-built one in-game via the
`junction-builder` skill — the user's GUI loop). `station_model` then = {stamp
throat template (rotated) at src + dst; expose arrival/departure tiles; pathfind
the double-track main between them; signal one-way PBS; dispatch N no-reverse
trains}. This is why prior bolt-on RoRo loops failed — the throat must be a
proper baked merge, like SmartStation, not a tacked-on return loop.

## Status log

- 2026-06-05 (cont.): IMPLEMENTED + smoke-tested headless. State:
  - `src/station_dt.nut` (StationDT): faithful AAHOG SmartStation port. **Builds
    4/4 directions, 16/16 throat rails, fail=0** after adding `AITile.LevelTiles`
    (the throat bridge needs equal-height heads - `ERR_BRIDGE_HEADS_NOT_ON_SAME_HEIGHT`)
    + obstacle-clearing before throat rails. `CanBuild` rejects relief>2.
  - `src/rail2_route.nut` (Rail2): sites two StationDT terminals, builds the
    double-track main via the EXISTING robust `TrackBuilder._RunPathfinder`
    (reroute-on-UNKNOWN; a naive single pathfind failed mid-path), distance-scaled
    fleet (`FleetSize`). **Builds a full route: "Reham Coal Mine->Ginnley Power
    Station, trains=5, dist=74"** - proves the fleet-scale thesis is BUILDABLE
    (5 trains on one route, vs the old 2-train cap).
  - `main.nut`: `USE_RAIL2` flag (OFF), `DEBUG_DT` boot smoke (OFF). Wired into the
    rail dispatch branch.
  - **BLOCKER (needs GUI visual-debug):** the 5-train route's trains **stall in the
    throat within ~44 days, never reach dst (reachedDst=false, STUCK=4)** -> the
    maintenance lifecycle condemns it. The throat connectivity / signal direction /
    depot-flow is semantically wrong somewhere I can't see headless. Suspects:
    (a) num==2 has no throat depot, so the depot (built mid-out-main by
    DepotBuilder) spawns trains facing the wrong way into one-way-PBS main - they
    can't reach the source platform to load; (b) a throat segment / signal is mis-
    rotated so arrival->platform->departure isn't a valid through-path. num==3 (depot
    in throat) sites too rarely (bigger footprint) to test - 0 routes in a 256 smoke.
  - **NEXT (visual loop):** flip `USE_RAIL2=true`, run a GUI game, find a rail2
    SmartTerminus, WATCH where the 5 trains jam (leaving source? in the throat? at
    the depot?). Fix the throat/signal/depot from what you see. Then re-bench. Until
    then rail2 is OFF on the branch; main is untouched (bit-identical to baseline).
    This is the documented headless wall (10/10 topology builds failed blind).

- 2026-06-05: branch + design captured. Read RailStation base + SmartStation:
  drive-through = baked throat template (GetRails) + main-line pathfind. NEXT:
  transcribe AAHOG SmartStation throat into a junction_builder StampList template
  (or capture via GUI skill), implement `station_model` to stamp it + expose
  arrival/departure tiles. Then main-line pathfind + no-reverse dispatch (forced
  order step 1). Existing `junction_builder.nut` StampList is the template engine.
