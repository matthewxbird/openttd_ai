// main.nut
// Entry point for the AI. OpenTTD instantiates MvBAI and calls Start().
// Scan -> rank -> try to build the top route -> sleep -> repeat.
// Built routes are remembered in `state`; failed pairs go on the blacklist.

require("src/logger.nut");
require("src/money.nut");
require("src/railtype.nut");
require("src/scoring.nut");
require("src/candidates.nut");
require("src/cargo_scan.nut");
require("src/station_builder.nut");
require("src/terminus.nut");
require("src/depot_builder.nut");
require("src/aystar.nut");
require("src/rail_pf.nut");
require("src/track_builder.nut");
require("src/signals.nut");
require("src/trains.nut");
require("src/route.nut");
require("src/state.nut");
require("src/autoreplace.nut");
require("src/maintenance.nut");
require("src/planner.nut");
require("src/junction_builder.nut");

class MvBAI extends AIController {
    state        = null;
    railtype     = null;
    auto_replace = null;

    // DEBUG: stamp one flat double-track T-junction at boot so its geometry can
    // be screenshotted/verified in isolation, before wiring junctions into live
    // routing. Set false for normal play.
    static DEBUG_JUNCTION = true;

    function Start();
    function Save();
    function Load(version, data);
    function TryBuildRoute(candidate);
    function _FailRoute(candidate, route, new_src, new_dst);
    function _DebugStampJunction();
}

function MvBAI::Start() {
    // Name the company so it is identifiable in the player list.
    if (!AICompany.SetName("MvB AI")) {
        local i = 2;
        while (!AICompany.SetName("MvB AI #" + i)) i++;
    }

    Log.Info(Log.PHASE_BOOT, "MvB AI starting. Hello, OpenTTD!");

    Money.TakeMaxLoan();
    this.railtype     = Railtype.PickAndSet();
    this.state        = State();
    this.auto_replace = AutoReplace();

    // Trains built from here on service when reliability drops 25%.
    Trains.ConfigureServicing();

    if (MvBAI.DEBUG_JUNCTION) this._DebugStampJunction();

    Log.Info(Log.PHASE_BOOT, "Boot complete. Entering scan/build loop.");

    while (true) {
        // 0. Health pass: check existing lines + trains before building more.
        //    Reports cargo waiting + station ratings, flags stuck trains, and
        //    tops up busy routes with another train.
        Maintenance.Tick(this.state, this.railtype);

        // 1. Scan + rank.
        local cands  = CargoScan.Scan();
        // INDUSTRY-CHAIN BIAS: if a candidate's producer is an industry we ALREADY
        // supply (it's the accepter of one of our routes), boost it - hauling the
        // product onward to the next chain stage (raw -> processed -> goods) is
        // where the big money is. This makes the AI complete chains it started.
        foreach (c in cands) {
            if (this.state.SuppliesIndustry(c.producer)) {
                c.score = Scoring.ChainBoost(c.score);
            }
        }
        local ranked = Candidates.Rank(cands, this.state.blacklist);
        CargoScan.LogPerCargoBest(ranked);
        CargoScan.LogTop(ranked, 5);

        // 2. Try to build the best candidate we haven't already built.
        //    But DON'T start a new line while another is still on probation -
        //    we verify each line actually earns before pouring money into the
        //    next one (no more building broken lines and moving on).
        local built_one = false;
        local holding   = false;
        if (this.state.HasProbation()) {
            // Don't idle: plan ahead while the new line proves itself.
            holding = true;
            Log.Info(Log.PHASE_RANK,
                "A route is on probation; planning ahead instead of building this tick.");
            Planner.LookAhead(this.state, ranked, this.railtype);
        } else if (Maintenance.NeedsMoreCapacity(this.state)) {
            // Scale up existing lines (more trains / longer trains, done by the
            // health pass) until they carry all their cargo, BEFORE spending on
            // a brand new route - and plan the next route meanwhile.
            holding = true;
            Log.Info(Log.PHASE_RANK,
                "Existing route has a backlog with room to grow; scaling it, planning ahead.");
            Planner.LookAhead(this.state, ranked, this.railtype);
        } else
        foreach (c in ranked) {
            if (this.state.HasRoute(c.cargo, c.producer, c.accepter)) continue;
            // One route per producer (ANY industry - mine, forest, oil well,
            // farm, factory...): if this producer already feeds a line, don't
            // start a second (less profitable) one from it - scale the existing
            // route instead. Bringing OTHER producers to the same accepter is
            // still allowed (different producer => not skipped here).
            if (this.state.ProducerServed(c.producer)) continue;
            if (c.score <= 0) {
                Log.Info(Log.PHASE_RANK, "Top remaining candidate has non-positive ROI; idle.");
                break;
            }
            // Affordability: require the FULL estimate plus a margin for
            // overruns the estimate under-counts (terraforming, bridges) and
            // an operating buffer. Don't sink the whole bank into one
            // ambitious line early game. If this candidate is too dear, skip
            // it and try a cheaper one further down the ranking - do NOT break
            // (the list is sorted by ROI, not cost, so the priciest route is
            // often on top and would otherwise block everything).
            // Full up-front cost = track + the initial fleet of trains/wagons,
            // plus a margin for under-counted overruns. Including the fleet stops
            // us laying track and then running dry before buying the trains.
            local est    = Scoring.BuildCostEstimate(c.distance)
                         + Scoring.FleetCostEstimate(Trains.PickNumTrains(c.production, Maintenance.MAX_TRAINS));
            local needed = est + est / 3;   // ~1.3x for overruns + operating buffer
            if (!Money.HasFunds(needed)) {
                Log.Info(Log.PHASE_MONEY,
                    "Skip " + AICargo.GetCargoLabel(c.cargo) + " dist=" + c.distance
                    + " (need ~" + needed + ", have " + Money.Cash() + ")");
                continue;
            }
            if (this.TryBuildRoute(c)) {
                built_one = true;
                break;
            }
        }

        // 3. Yearly engine roster review.
        this.auto_replace.Tick(this.railtype, this.state);

        // 4. Surplus loan repay if cash is healthy.
        Money.RepaySurplusIfAny();

        Log.Info(Log.PHASE_LOOP,
            "Tick done. Routes=" + this.state.CountRoutes()
            + " Blacklist=" + this.state.blacklist.Size()
            + " Cash=" + Money.Cash());
        // Sleep: short after a build (keep momentum); short while HOLDING so
        // scaling + probation checks + planning iterate quickly (no long idle
        // pause); longer only when genuinely idle with nothing to do.
        this.Sleep(built_one ? 500 : (holding ? 300 : 2220));
    }
}

// Try to build the full route described by `c`.
// Reuses an existing station if we already serve that industry.
// Adds pair to blacklist on any failure.
function MvBAI::TryBuildRoute(c) {
    local cargo_label = AICargo.GetCargoLabel(c.cargo);
    local acc_is_town = ("acc_is_town" in c) ? c.acc_is_town : false;
    Log.Info(Log.PHASE_RANK,
        "Attempting " + cargo_label
        + " " + AIIndustry.GetName(c.producer)
        + " -> " + Route.AccepterName(c)
        + " (dist=" + c.distance + ", profit/yr=" + c.score + ")");

    local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production, acc_is_town);

    // Each station's throat is oriented to face the OTHER end, so the main line
    // runs straight toward its partner (no wrap-around loop).
    local producer_tile = AIIndustry.GetLocation(c.producer);
    local accepter_tile = acc_is_town
        ? AITown.GetLocation(c.accepter)
        : AIIndustry.GetLocation(c.accepter);

    // Track which stations WE build this attempt, so we can clean them up if
    // the route is abandoned (reused stations are left alone).
    local new_src = false;
    local new_dst = false;

    // Source station: reuse if we have one at this producer.
    route.src_station = this.state.FindExistingStation(c.producer, true);
    if (route.src_station == null) {
        route.src_station = StationBuilder.BuildAt(c.producer, c.cargo, true, accepter_tile);
        new_src = true;
    } else {
        Log.Info(Log.PHASE_STATION, "Reusing existing source station id=" + route.src_station.station_id);
    }
    if (route.src_station == null) {
        return this._FailRoute(c, route, false, false);
    }

    // Dest station (a town for end-chain cargo, else an industry).
    route.dst_station = this.state.FindExistingStation(c.accepter, false, acc_is_town);
    if (route.dst_station == null) {
        route.dst_station = acc_is_town
            ? StationBuilder.BuildAtTown(c.accepter, c.cargo, producer_tile)
            : StationBuilder.BuildAt(c.accepter, c.cargo, false, producer_tile);
        new_dst = true;
    } else {
        Log.Info(Log.PHASE_STATION, "Reusing existing dest station id=" + route.dst_station.station_id);
    }
    if (route.dst_station == null) {
        return this._FailRoute(c, route, new_src, new_dst);
    }

    // Track: two passes for double track. BuildDoubleTracks reads each
    // station's per-platform approach tiles, lays a straight lead-in out of
    // each platform (so no tight turn at the throat), then pathfinds. The
    // out-track uses platform 0 at both ends, the back-track platform 1.
    local tracks = TrackBuilder.BuildDoubleTracks(
        route.src_station, route.dst_station);
    route.path_out  = tracks.out;
    route.path_back = tracks.back;
    route.touched   <- tracks.touched;   // every tile rail was laid on (for cleanup)
    // BOTH tracks are required. With only the out track, a train reaches the
    // destination and then has no way home (the back platform is unconnected
    // and signals are one-way) - it strands. Fail the route instead.
    if (route.path_out == null || route.path_back == null) {
        Log.Err(Log.PHASE_TRACK, "Incomplete double track (out or back missing); abandoning route.");
        return this._FailRoute(c, route, new_src, new_dst);
    }

    // Validate the freshly built track is CONTINUOUS end-to-end and repair any
    // gaps (e.g. a tunnel/bridge that failed to build) BEFORE we spend money on
    // crossovers, depots, signals and a train. A broken line that can't be
    // repaired is abandoned now rather than stranding a train later.
    local out_ok  = TrackBuilder.ValidateAndRepair(route.path_out,  "out");
    local back_ok = TrackBuilder.ValidateAndRepair(route.path_back, "back");
    if (!out_ok || !back_ok) {
        Log.Err(Log.PHASE_TRACK, "Track failed validation and could not be repaired; abandoning route.");
        return this._FailRoute(c, route, new_src, new_dst);
    }

    // Throat crossover at each terminus so a train can arrive on the out
    // track and depart on the back track (it reverses in the platform).
    Terminus.BuildBothEnds(route.src_station, route.dst_station);

    // Spur depots on the OUTER side of BOTH running lines (out and back), so a
    // train can reach one whichever track it is on. Build these BEFORE signals:
    // a depot junction adds track to a mainline tile, and a signal sitting on
    // that tile blocks the join. With bare track the junctions go in cleanly.
    local depots = [];
    local d_out  = DepotBuilder.New(route.path_out,  "out");
    local d_back = DepotBuilder.New(route.path_back, "back");
    if (d_out  != null) foreach (t in d_out)  depots.push(t);
    if (d_back != null) foreach (t in d_back) depots.push(t);
    if (depots.len() == 0) {
        Log.Err(Log.PHASE_DEPOT, "No depot could be built; abandoning route.");
        return this._FailRoute(c, route, new_src, new_dst);
    }
    route.depot_tiles = depots;
    route.depot_tile  = depots[0];   // primary: where trains are built

    // Signals on both tracks (back track may be null on very awkward terrain).
    Signals.PlaceAlong(route.path_out,  true,  "out");
    if (route.path_back != null) {
        Signals.PlaceAlong(route.path_back, true, "back");
    }

    // Trains.
    local engine = Trains.PickEngine(c.cargo, this.railtype);
    local wagon  = Trains.PickWagon(c.cargo, this.railtype);
    if (engine == -1 || wagon == -1) {
        Log.Err(Log.PHASE_TRAIN, "Cannot dispatch: missing engine/wagon.");
        return this._FailRoute(c, route, new_src, new_dst);
    }
    // Start with a FLEET sized to the producer's output (big producers get more
    // trains from day one), each train filled to the platform / engine power.
    // The periodic capacity review tops this up or lengthens trains later.
    local n          = Trains.PickNumWagons(c.distance, c.production);
    local num_trains = Trains.PickNumTrains(c.production, Maintenance.MAX_TRAINS);
    route.trains = [];
    for (local k = 0; k < num_trains; k++) {
        local id = Trains.BuildTrain(route.depot_tile, engine, wagon, c.cargo, n);
        if (id == -1) break;   // out of cash / depot - stop here
        if (!Trains.DispatchTrain(id, route.src_station.tile, route.dst_station.tile)) break;
        route.trains.push(id);
    }
    if (route.trains.len() == 0) {
        return this._FailRoute(c, route, new_src, new_dst);
    }
    route.train_id = route.trains[0];
    Log.Info(Log.PHASE_TRAIN,
        "Initial fleet: " + route.trains.len() + " train(s) for production " + c.production + "/mo.");
    // Not "built" yet - the line is on PROBATION until a train proves it works
    // by completing a round trip (or turning a profit). Maintenance promotes it
    // to "built", or condemns and tears it down if it never earns / gets stuck.
    route.status = "probation";
    this.state.AddRoute(route);
    Log.Info(Log.PHASE_RANK,
        "Route built; on PROBATION until it earns. Total routes: " + this.state.CountRoutes());
    return true;
}

// Abandon a half-built route: blacklist the pair and CLEAN UP everything we
// built for it this attempt (track, depots, and any stations WE created), so
// failed attempts don't leave an orphaned mess that piles up on retries.
// Reused (pre-existing) stations are left untouched. Returns false (for the
// caller to return directly).
function MvBAI::_FailRoute(c, route, new_src, new_dst) {
    this.state.blacklist.Add(c.cargo, c.producer, c.accepter);

    // PROTECT anything belonging to ANOTHER route. The failing route isn't in
    // state yet, so every station already in state belongs to a different line.
    // Build a set of their station ids and a zone of tiles around each (the
    // platform, throat, approach) - we must NEVER demolish a shared station or
    // its connecting track while backtracking.
    local prot_ids   = {};   // station_id -> true
    local prot_tiles = {};   // tile -> true
    foreach (_, r in this.state.routes) {
        foreach (st in [r.src_station, r.dst_station]) {
            if (st == null) continue;
            prot_ids[st.station_id] <- true;
            _MarkTileZone(prot_tiles, st.tile, StationBuilder.PLATFORM_LENGTH + 6);
        }
    }

    // Helper: demolish a tile only if it's safe (not a station tile, not in a
    // protected zone belonging to another route).
    local safe_demolish = function(t) : (prot_tiles) {
        if (!AIMap.IsValidTile(t)) return;
        if (AIRail.IsRailStationTile(t)) return;          // never a station
        if (t in prot_tiles) return;                      // shared/other-route area
        AITile.DemolishTile(t);
    };

    if (route.depot_tiles != null) {
        foreach (d in route.depot_tiles) safe_demolish(d);
    }
    // Demolish tiles rail was laid on this attempt (lead-in stubs, partial track
    // from failed pathfinds) - but skip anything protected above.
    if (("touched" in route) && route.touched != null) {
        foreach (t in route.touched) safe_demolish(t);
    }
    foreach (path in [route.path_out, route.path_back]) {
        if (path == null) continue;
        foreach (t in path) safe_demolish(t);
    }
    // Only remove a station WE built this attempt AND that no other route uses.
    if (new_src && route.src_station != null && !(route.src_station.station_id in prot_ids)) {
        StationBuilder.Remove(route.src_station);
    }
    if (new_dst && route.dst_station != null && !(route.dst_station.station_id in prot_ids)) {
        StationBuilder.Remove(route.dst_station);
    }

    Log.Warn(Log.PHASE_RANK, "Route abandoned and cleaned up: " + AICargo.GetCargoLabel(c.cargo)
        + " " + AIIndustry.GetName(c.producer) + " -> " + Route.AccepterName(c));
    return false;
}

// Mark every tile within `r` of `center` in `set` (a protected zone).
function _MarkTileZone(set, center, r) {
    local cx = AIMap.GetTileX(center);
    local cy = AIMap.GetTileY(center);
    local mx = AIMap.GetMapSizeX();
    local my = AIMap.GetMapSizeY();
    for (local dy = -r; dy <= r; dy++) {
        local y = cy + dy;
        if (y < 0 || y >= my) continue;
        for (local dx = -r; dx <= r; dx++) {
            local x = cx + dx;
            if (x < 0 || x >= mx) continue;
            set[AIMap.GetTileIndex(x, y)] <- true;
        }
    }
}

// DEBUG: build one flat double-track T-junction on a terraformed patch near the
// map centre, so its geometry can be inspected. Builds a short double-track
// main + a branch leg, then stamps JunctionBuilder.BuildFlatDoubleT to tie them.
function MvBAI::_DebugStampJunction() {
    local mx = AIMap.GetMapSizeX();
    local d  = 1;    // main runs along +x
    local p  = mx;   // tracks/branch separated along +y
    local base = AIMap.GetTileIndex(AIMap.GetMapSizeX() / 2, AIMap.GetMapSizeY() / 2);

    // Flatten a generous rectangle so all pieces sit at one height.
    local bx = AIMap.GetTileX(base);
    local by = AIMap.GetTileY(base);
    local c1 = AIMap.GetTileIndex(bx - 1, by - 4);
    local c2 = AIMap.GetTileIndex(bx + 10, by + 3);
    AITile.LevelTiles(c1, c2);

    // Main double-track: track 0 on row `base`, track 1 on row base+p.
    // Lay straight rail for 9 tiles on each.
    for (local k = 1; k <= 7; k++) {
        AIRail.BuildRail(base + (k - 1) * d, base + k * d, base + (k + 1) * d);
        AIRail.BuildRail(base + p + (k - 1) * d, base + p + k * d, base + p + (k + 1) * d);
    }

    // Junction at the 4th tile of track 0.
    local j0 = base + 4 * d;
    local c0 = j0 + d;

    // DOUBLE-TRACK branch leg approaching from the -p side: two columns, one
    // under j0, one under c0, each running a few tiles out.
    for (local s = 2; s <= 3; s++) {
        AIRail.BuildRail(j0 - (s - 1) * p, j0 - s * p, j0 - (s + 1) * p);
        AIRail.BuildRail(c0 - (s - 1) * p, c0 - s * p, c0 - (s + 1) * p);
    }

    local ok = JunctionBuilder.BuildFlatDoubleT(j0, d, p);
    Log.Info(Log.PHASE_BOOT,
        "[debug] flat double-track T at tile (" + AIMap.GetTileX(j0) + "," + AIMap.GetTileY(j0)
        + ") built=" + ok + " - screenshot to verify geometry.");
}

// Save/Load are stubbed in v1.
function MvBAI::Save() { return {}; }
function MvBAI::Load(version, data) { }
