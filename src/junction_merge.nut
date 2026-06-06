// src/junction_merge.nut
// AUTO-FORK JUNCTION (fork a new producer's spur onto an existing trunk).
//
// STATUS: WIRED behind MvBAI.USE_JUNCTION (OFF on main). Self-contained increment:
// builds the source station, forks the spur onto an existing DOUBLE-TRACK trunk,
// stamps the turnout, depot + one train -> shared consumer station, registers a
// capacity-safe route (spur-only `touched`; trunk gets a junction_deps refcount so
// its lifecycle won't tear the trunk out from under the spur's train).
// NEXT (visual-debug loop, then bench):
//   - validate junctions FORM correctly in-game (turnout geometry is the hard part);
//   - the shared CONSUMER STATION is still a 2-platform reversing terminus - a 2nd
//     converging line can collide at its single throat. Through-station / junction
//     throat at the consumer is the remaining capacity piece;
//   - scale the spur past one train (double-track the spur) once the throat is safe.
// Gated OFF until visual-validated + bench-positive (piecemeal junction levers all
// regressed; this only pays as the whole double-track-trunk + safe-throat stack).
//
// When a NEW source feeds a consumer we ALREADY serve, instead of (a) reusing
// the consumer's single-throat station (the 2nd line collides - the in-game bug)
// or (b) building a wholly separate duplicate station+line (measured -8%, wasteful
// duplicate infra), we MERGE: pathfind the new source's line to JOIN the existing
// route's trunk at a fork, stamp the turnout there, and share the consumer
// station. This is how dense networks are built (one trunk fed by many spurs).
//
// HOW (build the fork load-points at the turnout):
//   1. Find an existing rail route to the same accepter; its `path_out` is the
//      trunk (producer..consumer tile order).
//   2. Build the new source's station + a lead-in stub.
//   3. Pathfind from the stub to ANY trunk tile near the consumer (multi-goal):
//      the search reaches the closest trunk tile = the fork point.
//   4. Build the path; at the fork tile, the connecting diagonal piece IS the
//      turnout (points) joining the spur into the trunk.
//   5. PBS-signal the spur + fork; share the existing consumer station; run a
//      train source -> consumer over the merged trunk.
//
// CAVEAT (measured): the shared trunk must have CAPACITY (double-track + signals)
// or the merged traffic deadlocks (Phase 10.2 own-track reuse was -7% on single
// track). Step 1 builds the junction GEOMETRY (visible in-game); capacity is the
// next step. Gated behind MvBAI.USE_JUNCTION so it's off until it pays.

class JunctionMerge {

    static TRUNK_TAIL = 12;   // consider this many trunk tiles nearest the consumer
                              // as candidate fork points

    // Find an existing BUILT/probation RAIL route delivering to `accepter`, whose
    // trunk (path_out) we can fork onto. Returns the route or null.
    // CAPACITY GATE: only a DOUBLE-TRACK trunk (single_track == false) can absorb
    // a forked spur's extra train without deadlocking (measured: merging onto a
    // single-track corridor deadlocks, -7%). Single-track trunks are skipped here
    // so the caller falls back to a normal (separate) build.
    static function _ExistingTrunkTo(state, accepter) {
        foreach (_, r in state.routes) {
            if (("air" in r) && r.air) continue;
            if (("road" in r) && r.road) continue;
            if (r.accepter != accepter) continue;
            if (r.path_out == null || r.path_out.len() < 4) continue;
            if (r.dst_station == null) continue;
            if (("single_track" in r) && r.single_track) continue;   // need a double-track trunk
            if (r.status == "condemning") continue;                  // don't fork onto a dying line
            return r;
        }
        return null;
    }

    // The trunk tiles nearest the consumer = the tail of path_out (producer..
    // consumer order, so the last tiles are at the consumer end). Returns an
    // array of [tile, prev] goal pairs (prev = the next tile toward the consumer,
    // so a join faces consumer-ward).
    static function _TrunkGoals(path_out) {
        local n = path_out.len();
        local start = n - JunctionMerge.TRUNK_TAIL;
        if (start < 1) start = 1;
        local goals = [];
        // Skip the last couple (right at the station throat) - join out on the
        // open trunk, not in the station mouth.
        for (local i = start; i < n - 2; i++) {
            goals.push([path_out[i], path_out[i + 1]]);
        }
        return goals;
    }

    // Try to build a merged spur from candidate `c` (new source -> consumer we
    // already serve) onto the existing DOUBLE-TRACK trunk. Self-contained: builds
    // the source station, forks the spur onto the trunk, stamps the turnout,
    // depot + one train -> shared consumer station, registers a capacity-safe
    // route. Returns true on success, false to let the caller build normally.
    static function TryMerge(state, c, railtype) {
        local existing = JunctionMerge._ExistingTrunkTo(state, c.accepter);
        if (existing == null) return false;   // no double-track trunk to join; caller builds normally

        // Source station for the new producer (its own; faces the consumer).
        local acc_tile = AIIndustry.GetLocation(c.accepter);
        local src_st = StationBuilder.BuildAt(c.producer, c.cargo, true, acc_tile, false);
        if (src_st == null) return false;

        // Lead-in stub out of the source's out platform.
        local src_h = AITile.GetMaxHeight(src_st.enter_tile);
        local lead  = TrackBuilder._BuildLeadIn(src_st.enter_tile, src_st.front_tile, src_h);
        if (lead == null) { StationBuilder.Remove(src_st); return false; }

        // Pathfind the spur to JOIN the trunk (any tail tile = goal).
        local goals = JunctionMerge._TrunkGoals(existing.path_out);
        if (goals.len() == 0) { StationBuilder.Remove(src_st); return false; }

        local pf = RailPathFinder();
        pf.isOutward = true;
        pf.InitializePath([[lead.tip, lead.prev]], goals, []);
        local tiles = pf.FindPath(TrackBuilder.MAX_CHUNKS, null);
        if (tiles == null || tiles.len() < 2) {
            Log.Warn(Log.PHASE_TRACK, "[junction] spur pathfind failed to reach trunk; abandoning.");
            StationBuilder.Remove(src_st);
            return false;
        }

        // Build the spur. The last tile is a trunk tile; building rail into it
        // forms the turnout (points). _BuildPath lays each consecutive piece.
        TrackBuilder._BuildPath(tiles, "junction-spur");
        local gap = TrackBuilder.FindGap(tiles);
        if (gap != -1) {
            Log.Warn(Log.PHASE_TRACK, "[junction] spur has a build gap at " + gap + "; abandoning.");
            JunctionMerge._RemoveSpur(tiles);   // skip the trunk tile - never demolish existing track
            StationBuilder.Remove(src_st);
            return false;
        }

        // Signal the spur (one-way PBS toward the trunk).
        Signals.PlaceAlong(tiles, true, "junction-spur");

        // Depot on the spur (so the spur's own train can be built/serviced without
        // reaching back into the trunk's depots).
        local depots = DepotBuilder.New(tiles, "junction-spur");
        if (depots == null || depots.len() == 0) {
            Log.Warn(Log.PHASE_DEPOT, "[junction] no spur depot; abandoning merge.");
            JunctionMerge._RemoveSpur(tiles);
            StationBuilder.Remove(src_st);
            return false;
        }

        // One train: spur -> SHARED consumer station. (Single train on the spur
        // for now; the trunk is double-track so the merged train runs the trunk
        // without meeting the trunk's own train head-on. Scaling the spur past one
        // train needs the spur itself double-tracked - a later increment.)
        local engine = Trains.PickEngine(c.cargo, railtype);
        local wagon  = Trains.PickWagon(c.cargo, railtype);
        if (engine == -1 || wagon == -1) {
            Log.Warn(Log.PHASE_TRAIN, "[junction] no engine/wagon; abandoning merge.");
            JunctionMerge._RemoveSpur(tiles);
            StationBuilder.Remove(src_st);
            return false;
        }
        local nwag = Trains.PickNumWagons(c.distance, c.production);
        local tid  = Trains.BuildTrain(depots[0], engine, wagon, c.cargo, nwag);
        if (tid == -1
            || !Trains.DispatchTrain(tid, src_st.tile, existing.dst_station.tile, false)) {
            Log.Warn(Log.PHASE_TRAIN, "[junction] train build/dispatch failed; abandoning merge.");
            JunctionMerge._RemoveSpur(tiles);
            StationBuilder.Remove(src_st);
            return false;
        }

        // Register a capacity-SAFE route. `touched` = the spur pieces ONLY (NOT the
        // final trunk tile), so this route's own teardown can never demolish the
        // shared trunk. The shared consumer station + trunk path_out belong to
        // `existing` (already in state) and are protected by the normal
        // other-route protection during any condemn.
        local touched = [];
        for (local i = 0; i + 1 < tiles.len(); i++) touched.push(tiles[i]);  // skip trunk tile

        local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production, false);
        route.src_station  = src_st;
        route.dst_station  = existing.dst_station;   // SHARED consumer station
        route.path_out     = tiles;
        route.path_back    = null;
        route.single_track = true;     // spur runs one train (collision-free)
        route.depot_tiles  = depots;
        route.depot_tile   = depots[0];
        route.trains       = [tid];
        route.train_id     = tid;
        route.backhaul     <- false;
        route.max_trains   = 1;
        route.touched      <- touched;
        route.junction     <- true;                  // forked spur, shares trunk+station
        route.trunk_key    <- Route.Key(existing.cargo, existing.producer, existing.accepter);
        route.status       = "probation";
        route.probation_date = AIDate.GetCurrentDate();

        // Mark the trunk as having a dependent spur: its lifecycle MUST NOT condemn
        // /demolish the trunk while a junction route runs over it (would orphan the
        // spur's train). Maintenance reads junction_deps to refuse trunk teardown.
        existing.junction_deps <- (("junction_deps" in existing) ? existing.junction_deps : 0) + 1;

        state.AddRoute(route);
        Log.Info(Log.PHASE_TRACK, "[junction] merged spur " + AIIndustry.GetName(c.producer)
            + " onto trunk -> " + Route.AccepterName(c) + " (shared station "
            + existing.dst_station.station_id + ", trunk now has "
            + existing.junction_deps + " spur(s)).");
        return true;
    }

    // Remove ONLY the spur pieces we just laid (never the final trunk tile).
    static function _RemoveSpur(tiles) {
        for (local i = 0; i + 1 < tiles.len() - 1; i++) {
            AIRail.RemoveRail(tiles[i], tiles[i + 1],
                tiles[i + 2 < tiles.len() ? i + 2 : i + 1]);
        }
    }
}
