// main.nut
// Entry point for the AI. OpenTTD instantiates MvBAI and calls Start().
// Scan -> rank -> try to build the top route -> sleep -> repeat.
// Built routes are remembered in `state`; failed pairs go on the blacklist.

require("src/logger.nut");
require("src/map_dump.nut");
require("src/money.nut");
require("src/railtype.nut");
require("src/scoring.nut");
require("src/build_diag.nut");
require("src/estimator.nut");
require("src/air.nut");
require("src/road.nut");
require("src/backhaul.nut");
require("src/strategy.nut");
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
require("src/town_authority.nut");
require("src/planner.nut");
require("src/junction_builder.nut");

class MvBAI extends AIController {
    state        = null;
    railtype     = null;
    auto_replace = null;

    // DEBUG: stamp one flat double-track T-junction at boot so its geometry can
    // be screenshotted/verified in isolation, before wiring junctions into live
    // routing. Set false for normal play.
    // How many routes may be on probation at once before we stop starting new
    // ones (lets the company keep expanding instead of freezing on one line).
    static MAX_CONCURRENT_PROBATION = 4;

    static DEBUG_JUNCTION = false;

    // DEBUG: set true and fill the region to SCAN a hand-built junction into a
    // [scan] descriptor in the AI Debug log. Build your ideal junction in-game,
    // read its bounding tile coords (land-info tool shows X,Y), put them here,
    // reload - the AI dumps the layout. Paste the [scan] lines back to bake a
    // template. (x1,y1) = top-left (min X, min Y), (x2,y2) = bottom-right.
    static DEBUG_SCAN  = false;
    static SCAN_X1 = 150;
    static SCAN_Y1 = 122;
    static SCAN_X2 = 186;
    static SCAN_Y2 = 158;

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

    // Borrow on demand (Phase 0), not a max loan at boot - holding idle loan
    // bleeds interest and depresses company value (value counts -loan) for no
    // reason. We raise the loan just-in-time before each build instead.
    this.railtype     = Railtype.PickAndSet();
    this.state        = State();
    this.auto_replace = AutoReplace();

    // Trains built from here on service when reliability drops 25%.
    Trains.ConfigureServicing();

    if (MvBAI.DEBUG_JUNCTION) this._DebugStampJunction();
    if (MvBAI.DEBUG_SCAN) {
        JunctionBuilder.ScanToLog(MvBAI.SCAN_X1, MvBAI.SCAN_Y1, MvBAI.SCAN_X2, MvBAI.SCAN_Y2);
    }

    Log.Info(Log.PHASE_BOOT, "Boot complete. Entering scan/build loop.");

    // Persisted across iterations so the loop spends its ticks BUILDING from a
    // cached ranking rather than re-scanning the whole map every tick. AAHOG
    // works continuously and uses its full opcode budget each tick; long Sleep()
    // idles waste game-time we should spend expanding. We therefore: (a) run the
    // health pass on its own spaced cadence, (b) re-scan only periodically and
    // reuse the ranking between scans, (c) build with a tiny sleep so routes go
    // up back-to-back.
    local ranked     = [];
    local last_scan  = -1000000;
    local last_maint = -1000000;
    local SCAN_INTERVAL  = 250;   // ticks between full map re-scans
    local MAINT_INTERVAL = 900;   // ticks between health passes (stuck/probation
                                  // heuristics compare positions across calls -
                                  // must stay spaced, else a train paused at a
                                  // signal reads as "stuck")

    while (true) {
        local now = AIController.GetTick();

        // 0. Health pass on its OWN cadence (decoupled from the fast build loop).
        if (now - last_maint >= MAINT_INTERVAL) {
            Maintenance.Tick(this.state, this.railtype);
            last_maint = now;
        }

        // 1. Scan + rank periodically; REUSE the ranking between scans so ticks
        //    go to building, not rescanning an unchanged map. The scan runs each
        //    candidate (rail/air/road) through the estimator value surface.
        if (now - last_scan >= SCAN_INTERVAL || ranked.len() == 0) {
            local cands = CargoScan.Scan(this.railtype);
            // MULTI-MODAL: air + road candidates rank ALONGSIDE rail on the
            // shared value surface (best mode per cargo/distance falls out).
            foreach (ac in Air.ScanCandidates(this.railtype)) cands.append(ac);
            foreach (rc in Road.ScanCandidates(this.railtype)) cands.append(rc);
            // ADAPTIVE PROFIT MODEL: pick the objective from company state, then
            // re-score by it. INDUSTRY-CHAIN BIAS: boost hauling the output of an
            // industry we already supply (complete the chain we started).
            local mode = Strategy.DecideFromGame();
            Strategy.Apply(cands, mode);
            foreach (c in cands) {
                if (this.state.SuppliesIndustry(c.producer)) c.score = Scoring.ChainBoost(c.score);
            }
            ranked = Candidates.Rank(cands, this.state.blacklist);
            CargoScan.LogPerCargoBest(ranked);
            CargoScan.LogTop(ranked, 5);
            last_scan = now;
        }

        // GAME-PHASE DOCTRINE: EARLY land-grab builds cheap single-track lines;
        // MID/LATE build double track. Cheap to recompute each tick.
        local phase = Strategy.GamePhaseFromGame(this.state);

        // 2. Try to build the best candidate we haven't already built.
        //    But DON'T start a new line while another is still on probation -
        //    we verify each line actually earns before pouring money into the
        //    next one (no more building broken lines and moving on).
        local built_one = false;
        local holding   = false;
        // Allow a few routes to prove concurrently. Freezing ALL expansion on a
        // single probation line let one slow/broken route stop the whole company
        // from growing (we'd build one line and idle for the rest of the game).
        // We still throttle - we don't build unboundedly while nothing has been
        // verified - but we keep expanding up to MAX_CONCURRENT_PROBATION.
        if (this.state.CountProbation() >= MvBAI.MAX_CONCURRENT_PROBATION) {
            // Don't idle: plan ahead while the new lines prove themselves.
            holding = true;
            Log.Info(Log.PHASE_RANK,
                this.state.CountProbation() + " route(s) on probation (cap "
                + MvBAI.MAX_CONCURRENT_PROBATION + "); planning ahead instead of building.");
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
            if (c.score <= 0) {
                Log.Info(Log.PHASE_RANK, "Top remaining candidate has non-positive ROI; idle.");
                break;
            }
            // AIR candidate (Phase 2): own affordability + builder, then continue
            // to the next candidate on success/failure (no rail path).
            if (("air" in c) && c.air) {
                // One air route per (source town, cargo): a town may hub BOTH a
                // pax and a mail route (reusing its airport), but not duplicate
                // the same cargo (bounds airport terminal congestion).
                local dup = false;
                foreach (_, r in this.state.routes) {
                    if (("air" in r) && r.air && r.producer == c.producer && r.cargo == c.cargo) { dup = true; break; }
                }
                if (dup) continue;
                local plane = Air.PlaneSet(c.cargo);
                local need  = 2 * Air.AIRPORT_COST_EST
                            + (plane != null ? plane.price : 50000);
                need += need / 3;
                if (!Money.HasFunds(need)) {
                    Log.Info(Log.PHASE_MONEY, "Skip AIR (need ~" + need + ", have " + Money.Cash() + ")");
                    continue;
                }
                Money.EnsureFunds(need);
                if (Air.TryBuild(this.state, c)) { built_one = true; break; }
                continue;
            }
            // ROAD candidate (Phase 3): own affordability + builder.
            if (("road" in c) && c.road) {
                if (this.state.ProducerServed(c.producer)) continue;
                local rveh = Road.VehicleSet(c.cargo);
                local rneed = c.distance * 400 + 2 * 4000 + 2000
                            + (rveh != null ? rveh.price : 20000);
                rneed += rneed / 3;
                if (!Money.HasFunds(rneed)) continue;
                Money.EnsureFunds(rneed);
                if (Road.TryBuild(this.state, c)) { built_one = true; break; }
                continue;
            }
            // One route per producer (ANY industry - mine, forest, oil well,
            // farm, factory...): if this producer already feeds a line, don't
            // start a second (less profitable) one from it - scale the existing
            // route instead. Bringing OTHER producers to the same accepter is
            // still allowed (different producer => not skipped here).
            if (this.state.ProducerServed(c.producer)) continue;
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
            // EARLY land-grab: build single-track + ONE train when the route's
            // production only justifies one train (cheap, fast, collision-free,
            // dodges the terminus deadlock; claims space) - on ANY map size. Only
            // the few genuinely high-throughput routes (>=2 trains' worth of
            // output) get double-track, which is the only layout that can run a
            // 2nd train without a head-on collision.
            local trains_needed = ("est_num_trains" in c)
                ? c.est_num_trains
                : Trains.PickNumTrains(c.production, Maintenance.MAX_TRAINS);
            local single_only = Strategy.EarlySingleTrack(phase, trains_needed);
            local ntrains     = single_only ? 1 : Trains.PickNumTrains(c.production, Maintenance.MAX_TRAINS);
            local est    = Scoring.BuildCostEstimate(c.distance, single_only)
                         + Scoring.FleetCostEstimate(ntrains);
            local needed = est + est / 3;   // ~1.3x for overruns + operating buffer
            if (!Money.HasFunds(needed)) {
                Log.Info(Log.PHASE_MONEY,
                    "Skip " + AICargo.GetCargoLabel(c.cargo) + " dist=" + c.distance
                    + " (need ~" + needed + ", have " + Money.Cash() + ")");
                continue;
            }
            // Decided to build this one: borrow just enough to cover it now, so
            // incremental spends (stations, track, fleet) never run dry midway.
            Money.EnsureFunds(needed);
            if (this.TryBuildRoute(c, single_only)) {
                built_one = true;
                break;
            }
        }

        // 3. Yearly engine roster review.
        this.auto_replace.Tick(this.railtype, this.state);

        // 4. Repay the loan down to our operating buffer (cuts interest + lifts
        //    company value, which counts -loan).
        Money.RepayDownToBuffer();

        // 4b. Town authority: build a statue in each town we deliver into (once,
        //     when affordable) - a permanent local-rating boost so our stations
        //     there accept more cargo.
        TownAuthority.Tick(this.state);

        Log.Info(Log.PHASE_LOOP,
            "Tick done. Routes=" + this.state.CountRoutes()
            + " Blacklist=" + this.state.blacklist.Size()
            + " Cash=" + Money.Cash());
        // Tiny sleep: keep working every tick (build itself suspends the AI per
        // command, so we don't burn a whole tick). After a build, immediately try
        // the next (Sleep 1) so routes go up back-to-back; while HOLDING, a short
        // wait; when idle (nothing affordable/buildable), wait toward the next
        // re-scan rather than a long dead idle.
        this.Sleep(built_one ? 1 : (holding ? 20 : 50));
    }
}

// Try to build the full route described by `c`.
// Reuses an existing station if we already serve that industry.
// Adds pair to blacklist on any failure.
function MvBAI::TryBuildRoute(c, single_only = false) {
    local cargo_label = AICargo.GetCargoLabel(c.cargo);
    // single_only (EARLY land-grab, short haul): build this line single-track
    // (out track only, one reversing train) on purpose - cheaper + faster than
    // double track, so we plant more lines and claim more map space. MID/LATE
    // and long hauls build full double track.
    local acc_is_town = ("acc_is_town" in c) ? c.acc_is_town : false;
    Log.Info(Log.PHASE_RANK,
        "Attempting " + cargo_label
        + " " + AIIndustry.GetName(c.producer)
        + " -> " + Route.AccepterName(c)
        + " (dist=" + c.distance + ", profit/yr=" + c.score + ")");

    local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production, acc_is_town);

    // PRE-FLIGHT (free): for an industry->industry route, confirm a rail path
    // even EXISTS before we spend a penny on stations/track. The dominant money
    // leak was building two stations + lead-in stubs for a route the pathfinder
    // then couldn't connect ("open set empty") - repeated on long routes it
    // bankrupted us. If unreachable, blacklist now with nothing built.
    if (!acc_is_town && !TrackBuilder.CanReach(c.producer, c.accepter)) {
        Log.Warn(Log.PHASE_TRACK,
            "Pre-flight: no rail path " + AIIndustry.GetName(c.producer)
            + " -> " + Route.AccepterName(c) + "; skipping (nothing built).");
        return this._FailRoute(c, route, false, false);
    }

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
        route.src_station, route.dst_station, single_only);
    route.path_out  = tracks.out;
    route.path_back = tracks.back;
    // every tile rail was laid on (for cleanup); guard the key so a builder that
    // bailed early (and omitted it) can never crash the whole AI here.
    route.touched   <- ("touched" in tracks) ? tracks.touched : [];
    // The OUT track is mandatory. If even it failed there's nothing to run.
    if (route.path_out == null) {
        Log.Err(Log.PHASE_TRACK, "Out track missing; abandoning route.");
        return this._FailRoute(c, route, new_src, new_dst);
    }
    // SINGLE-TRACK SALVAGE: when only the back track failed (common where the
    // out track had to bridge water / thread tight terrain - the parallel back
    // track can't get a second crossing), don't throw away the built out track +
    // two stations. Run the route on the out track ALONE with exactly ONE train
    // that reverses at each terminus. One train can never meet an opposing train,
    // so single track is collision-free; we just signal it two-way and cap it at
    // one train. This converts a wasted build (the dominant 128x128 bankruptcy
    // cause) into a working, if lower-capacity, route.
    route.single_track = (route.path_back == null);

    // Validate the freshly built track is CONTINUOUS end-to-end and repair any
    // gaps (e.g. a tunnel/bridge that failed to build) BEFORE we spend money on
    // crossovers, depots, signals and a train. A broken line that can't be
    // repaired is abandoned now rather than stranding a train later.
    local out_ok  = TrackBuilder.ValidateAndRepair(route.path_out,  "out");
    local back_ok = route.single_track
        ? true
        : TrackBuilder.ValidateAndRepair(route.path_back, "back");
    if (!out_ok || !back_ok) {
        Log.Err(Log.PHASE_TRACK, "Track failed validation and could not be repaired; abandoning route.");
        return this._FailRoute(c, route, new_src, new_dst);
    }
    if (route.single_track) {
        Log.Warn(Log.PHASE_TRACK,
            "Back track unavailable; running this route SINGLE-TRACK with one train.");
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

    // Signals. Double track: one-way PBS per rail. Single track: two-way PBS on
    // the out track so the lone reversing train passes in BOTH directions.
    if (route.single_track) {
        Signals.PlaceAlong(route.path_out, true, "out", false);  // two-way PBS
    } else {
        Signals.PlaceAlong(route.path_out,  true,  "out");
        if (route.path_back != null) {
            Signals.PlaceAlong(route.path_back, true, "back");
        }
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
    // Single-track routes run exactly ONE train (a second would collide head-on);
    // double-track routes get a fleet sized to the producer's output.
    local num_trains = route.single_track
        ? 1
        : Trains.PickNumTrains(c.production, Maintenance.MAX_TRAINS);
    // BACKHAUL (Phase 4): if both endpoints mutually produce+accept this cargo,
    // load the return leg too. Stored on the route so added trains inherit it.
    route.backhaul <- Backhaul.Mutual(c.cargo, c.producer, c.accepter, acc_is_town);
    if (route.backhaul) {
        Log.Info(Log.PHASE_TRAIN, "Backhaul: both ends mutual; loading return leg.");
    }
    route.trains = [];
    for (local k = 0; k < num_trains; k++) {
        local id = Trains.BuildTrain(route.depot_tile, engine, wagon, c.cargo, n);
        if (id == -1) break;   // out of cash / depot - stop here
        if (!Trains.DispatchTrain(id, route.src_station.tile, route.dst_station.tile, route.backhaul)) break;
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

    // BUILD-FAILURE DIAGNOSTICS (our eyes in a headless match). Emit a structured
    // summary + an owner-annotated corridor map with the attempted path overlaid
    // and the breaking tile marked, BEFORE we demolish anything. This is how we
    // tell "no route" from "rival blocked us" from "priced wrong" from the log.
    {
        local acc_is_town = ("acc_is_town" in c) ? c.acc_is_town : false;
        local src_tile = AIIndustry.GetLocation(c.producer);
        local dst_tile = acc_is_town ? AITown.GetLocation(c.accepter) : AIIndustry.GetLocation(c.accepter);
        local path     = ("path_out" in route && route.path_out != null) ? route.path_out : null;
        local fail     = -1;
        if (path != null) {
            local gap = TrackBuilder.FindGap(path);    // first discontinuity, if any
            if (gap != -1 && gap < path.len()) fail = path[gap];
        }
        local stage = (route.src_station == null) ? "src-station"
                    : (route.dst_station == null) ? "dst-station"
                    : (path == null)              ? "out-track-pathfind"
                    : (fail != -1)                ? "out-track-gap"
                    : "post-track";
        Log.Err(Log.PHASE_TRACK,
            "[buildfail] RAIL " + AICargo.GetCargoLabel(c.cargo)
            + " " + AIIndustry.GetName(c.producer) + " -> " + Route.AccepterName(c)
            + " dist=" + c.distance + " stage=" + stage
            + " src=(" + AIMap.GetTileX(src_tile) + "," + AIMap.GetTileY(src_tile) + ")"
            + " dst=(" + AIMap.GetTileX(dst_tile) + "," + AIMap.GetTileY(dst_tile) + ")"
            + " pathlen=" + (path != null ? path.len() : 0));
        if (fail != -1) BuildDiag.Report(fail, "buildfail", stage);   // owner/error/cause of the break
        MapDump.RouteFail(src_tile, dst_tile, path, fail, "buildfail");
    }

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
        // NEVER touch a rival's property (Phase 8): a foreign rail/station tile
        // isn't ours to demolish (the call would fail anyway), and we must not
        // count it as cleaned. Only demolish rail that is ours / unowned ground.
        if (AIRail.IsRailTile(t) && !AICompany.IsMine(AITile.GetOwner(t))) return;
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

    // Flatten a generous square covering both arms of the cross.
    local bx = AIMap.GetTileX(base);
    local by = AIMap.GetTileY(base);
    AITile.LevelTiles(AIMap.GetTileIndex(bx - 2, by - 2),
                      AIMap.GetTileIndex(bx + 12, by + 8));

    // Stamp the captured junction at all 4 rotations, spaced apart, to verify
    // the rotation logic (track bits + offsets + signals).
    for (local k = 0; k < 4; k++) {
        local ox = bx + 2 + k * 16;     // 16 tiles apart along x
        local oy = by + 2;
        AITile.LevelTiles(AIMap.GetTileIndex(ox - 1, oy - 1),
                          AIMap.GetTileIndex(ox + 13, oy + 13));
        local origin = AIMap.GetTileIndex(ox, oy);
        JunctionBuilder.StampList(origin, JunctionBuilder.Rotate(JunctionBuilder.Template1(), k));
        Log.Info(Log.PHASE_BOOT,
            "[debug] junction rot=" + k + " at (" + ox + "," + oy + ")");
    }
}

// Save/Load are stubbed in v1.
function MvBAI::Save() { return {}; }
function MvBAI::Load(version, data) { }
