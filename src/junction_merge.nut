// src/junction_merge.nut
// AUTO-FORK JUNCTION (AAHOG CombineByFork, replicated algorithmically).
//
// STATUS: SCAFFOLD - NOT YET WIRED into main (intentionally). This is step 1 of
// the "full junction stack". The pathfind-to-trunk + spur build + turnout geometry
// are here; STILL TODO before wiring + benching:
//   - depot for the spur + train dispatch + orders (source -> shared consumer);
//   - add the route to state + a junction-aware lifecycle (condemn must not
//     demolish the SHARED trunk/consumer station another route uses);
//   - CAPACITY: the shared trunk must be double-track + PBS-signalled at the fork,
//     or the merged traffic DEADLOCKS (measured: single-track sharing -7%). This
//     is the hard part and the reason it's gated off until it pays.
// Wire behind a flag, smoke that junctions FORM in-game (visual), then bench.
//
// When a NEW source feeds a consumer we ALREADY serve, instead of (a) reusing
// the consumer's single-throat station (the 2nd line collides - the in-game bug)
// or (b) building a wholly separate duplicate station+line (measured -8%, wasteful
// duplicate infra), we MERGE: pathfind the new source's line to JOIN the existing
// route's trunk at a fork, stamp the turnout there, and share the consumer
// station. This is how AAHOG builds dense networks (one trunk fed by many spurs).
//
// HOW (mirrors AAHOG's BuildRailloadPoints):
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
    static function _ExistingTrunkTo(state, accepter) {
        foreach (_, r in state.routes) {
            if (("air" in r) && r.air) continue;
            if (("road" in r) && r.road) continue;
            if (r.accepter != accepter) continue;
            if (r.path_out == null || r.path_out.len() < 4) continue;
            if (r.dst_station == null) continue;
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
    // already serve) onto the existing trunk. Returns true on success.
    static function TryMerge(state, c) {
        local existing = JunctionMerge._ExistingTrunkTo(state, c.accepter);
        if (existing == null) return false;   // no trunk to join; caller builds normally

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
            // Cleanup: remove the consecutive spur pieces we laid (skip the trunk
            // tile at the end - never demolish the existing route's track).
            for (local i = 0; i + 1 < tiles.len() - 1; i++) {
                AIRail.RemoveRail(tiles[i], tiles[i + 1], tiles[i + 2 < tiles.len() ? i + 2 : i + 1]);
            }
            StationBuilder.Remove(src_st);
            return false;
        }

        // Signal the spur (one-way PBS toward the trunk).
        Signals.PlaceAlong(tiles, true, "junction-spur");

        // Share the consumer station; run a train source -> consumer.
        local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production, false);
        route.src_station = src_st;
        route.dst_station = existing.dst_station;   // SHARED consumer station
        route.path_out    = tiles;
        route.single_track = true;   // spur is single-track for now (one train)
        route.junction    <- true;
        route.status      = "probation";
        route.probation_date = AIDate.GetCurrentDate();

        Log.Info(Log.PHASE_TRACK, "[junction] merged spur " + AIIndustry.GetName(c.producer)
            + " onto trunk -> " + Route.AccepterName(c) + " (shared station "
            + existing.dst_station.station_id + ").");
        return route;
    }
}
