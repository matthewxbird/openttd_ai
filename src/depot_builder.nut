// src/depot_builder.nut
// Build a rail depot on a SPUR off the mainline, not at a station end.
//
// Why a spur: a depot placed at the end of a station platform forces
// trains to reverse into it and blocks the platform for through traffic.
// Instead we find a straight 3-tile run on the already-built out-track,
// build the depot one tile to the side, and add a single connecting rail
// piece (a turnout) on the mainline tile. Through-trains run straight past
// it untouched; only a train explicitly sent to the depot branches off.
//
//   ... a == b == c ...        mainline (straight run)
//            \
//           depot              spur, connected by a rail piece on b
//
// No depot order is added to trains, so the mainline is never disrupted;
// the depot only exists for building/servicing/autoreplace.

class DepotBuilder {

    static SKIP_NEAR_STATION = 6;  // keep depots well clear of BOTH station throats
    static MAX_DEPOTS = 2;         // per track (called for out AND back tracks)
    static SPACING    = 16;        // tiles between consecutive depots (spread out)

    // path: a track tile array (out track src->dst, OR back track dst->src).
    // Builds depots on the OUTER (left-of-travel) side of THIS track. The right
    // side can't be used - the other track of the double-track pair runs there.
    // Call once for the out track and once for the back track so depots end up
    // on both running lines, on their outer flanks. `label` tags the log.
    // spacing    = tiles between consecutive depots on this track (null = default).
    // max_depots = cap for this track (null = default). Pass a length-scaled count
    //   + the desired spacing to spread servicing depots ALONG a long line (~1 per
    //   `spacing` tiles) instead of just one.
    // Returns an array of depot tile indices, or null if none built.
    static function New(path, label = "track", spacing = null, max_depots = null) {
        local sp  = (spacing == null) ? DepotBuilder.SPACING : spacing;
        local cap = (max_depots == null) ? DepotBuilder.MAX_DEPOTS : max_depots;
        // Depots live only in the MIDDLE of the line - skip SKIP_NEAR_STATION
        // tiles at BOTH ends so no junction is built near a station throat.
        if (path == null || path.len() < 2 * DepotBuilder.SKIP_NEAR_STATION + 3) {
            Log.Warn(Log.PHASE_DEPOT, "[" + label + "] path too short for a depot.");
            return null;
        }
        local lo = DepotBuilder.SKIP_NEAR_STATION;
        local hi = path.len() - 1 - DepotBuilder.SKIP_NEAR_STATION;

        local depots   = [];
        local last_idx = -sp;

        for (local i = lo; i < hi && depots.len() < cap; i++) {
            if (i - last_idx < sp) continue;  // keep them spread out

            // Always the LEFT (outer) side - right side is the partner track.
            local depot_tile = DepotBuilder._TryBuildAt(path, i, false);
            if (depot_tile != null) {
                depots.push(depot_tile);
                last_idx = i;
            }
        }

        // Pragmatic fallback: if the spaced pass found nothing (rough terrain),
        // scan EVERY middle tile and grab the first workable depot spot - one
        // depot is far better than abandoning the whole route. Still kept clear
        // of both station throats.
        if (depots.len() == 0) {
            for (local i = lo; i < hi; i++) {
                local depot_tile = DepotBuilder._TryBuildAt(path, i, false, true);  // allow terraform
                if (depot_tile != null) { depots.push(depot_tile); break; }
            }
        }

        if (depots.len() == 0) {
            Log.Warn(Log.PHASE_DEPOT, "[" + label + "] no spot found for a depot.");
            return null;
        }
        Log.Info(Log.PHASE_DEPOT,
            "[" + label + "] built " + depots.len() + " depot(s) on the outer side.");
        return depots;
    }

    // Try to build one depot on a STRAIGHT run of the line at index i.
    // RULE: depots are NEVER placed on a diagonal/bend - only where three tiles
    // are collinear (a, b, c in one straight line). On a straight run the depot
    // taps off with a single clean curve; tapping a diagonal produces the
    // S-bend / hard corner that traps trains.
    //
    //   a == b == c     straight run (a, b, c collinear)
    //        |          depot perpendicular at b +/- p
    //      depot        EXIT: depot -> b -> c   ENTER: a -> b -> depot
    //
    // After building we ENFORCE accessibility: the depot->line link AND the
    // through line must actually exist (test-mode ALREADY_BUILT), else the depot
    // is torn down, the line restored, and we try the other side / next spot.
    static function _TryBuildAt(path, i, want_right, allow_terraform = false) {
        // Need straight rail for at least ONE tile beyond each side of the
        // junction, i.e. a 5-tile straight window centred on b
        // (i-2 .. i+2 all collinear). This gives the train a straight approach
        // and a straight exit so it can't get stuck on a curve next to the depot.
        if (i < 2 || i + 2 >= path.len()) return null;
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        local d  = b - a;
        local mx = AIMap.GetMapSizeX();
        if (!DepotBuilder._IsUnitStep(d, mx)) return null;
        if (a - path[i - 2] != d) return null;   // straight 1 tile before a
        if (c - b != d) return null;             // b -> c straight
        if (path[i + 2] - c != d) return null;   // straight 1 tile after c

        local right = RailPathFinder._RightOffset(d);
        // Try both sides; the requested side first.
        local order = want_right ? [right, -right] : [-right, right];

        foreach (p in order) {
            local depot = b + p;
            if (!AIMap.IsValidTile(depot) || !AITile.IsBuildable(depot)) continue;
            if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) {
                if (!allow_terraform) continue;
                AITile.LevelTiles(depot, depot);
                if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) continue;
            }

            DepotBuilder._ClearSignals(b, d);

            local test_ok;
            {
                local tm = AITestMode();
                test_ok = AIRail.BuildRailDepot(depot, b) && AIRail.BuildRail(depot, b, c);
            }
            if (!test_ok) continue;

            if (!AIRail.BuildRailDepot(depot, b)) continue;
            if (!AIRail.BuildRail(depot, b, c)) { AITile.DemolishTile(depot); continue; }
            local enter = AIRail.BuildRail(a, b, depot);   // best-effort entry

            local exit_ok = DepotBuilder._RailExists(depot, b, c);
            local main_ok = DepotBuilder._RailExists(a, b, c);
            if (!exit_ok || !main_ok) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot at " + depot + " not accessible (exit=" + exit_ok
                    + " main=" + main_ok + "); removing.");
                AIRail.RemoveRail(depot, b, c);
                AIRail.RemoveRail(a, b, depot);
                AITile.DemolishTile(depot);
                AIRail.BuildRail(a, b, c);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Depot at " + depot + " (straight run at " + b + ", verified, enter="
                + (enter ? "yes" : "no") + ")");
            return depot;
        }
        return null;
    }

    static function _IsUnitStep(d, mx) {
        return d == 1 || d == -1 || d == mx || d == -mx;
    }

    // True if a rail piece connecting from->tile->to ALREADY exists. Uses a
    // test-mode BuildRail: if it would build (returns true) the piece is
    // missing; if it fails with ERR_ALREADY_BUILT the connection is present.
    static function _RailExists(from, tile, to) {
        local tm = AITestMode();
        if (AIRail.BuildRail(from, tile, to)) return false;     // would build = missing
        return AIError.GetLastError() == AIError.ERR_ALREADY_BUILT;
    }

    // Remove any signal on `tile` facing along the line (either direction), so
    // a junction can be added to the tile. No-op if there is no signal.
    static function _ClearSignals(tile, d) {
        foreach (front in [tile + d, tile - d]) {
            if (!AIMap.IsValidTile(front)) continue;
            if (AIRail.GetSignalType(tile, front) != AIRail.SIGNALTYPE_NONE) {
                AIRail.RemoveSignal(tile, front);
            }
        }
    }

}
