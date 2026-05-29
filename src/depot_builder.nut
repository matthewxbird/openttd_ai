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

    static SKIP_NEAR_STATION = 3;  // don't put a depot in the station throat
    static MAX_DEPOTS = 2;         // per track (called for out AND back tracks)
    static SPACING    = 16;        // tiles between consecutive depots (spread out)

    // path: a track tile array (out track src->dst, OR back track dst->src).
    // Builds depots on the OUTER (left-of-travel) side of THIS track. The right
    // side can't be used - the other track of the double-track pair runs there.
    // Call once for the out track and once for the back track so depots end up
    // on both running lines, on their outer flanks. `label` tags the log.
    // Returns an array of depot tile indices, or null if none built.
    static function New(path, label = "track") {
        if (path == null || path.len() < DepotBuilder.SKIP_NEAR_STATION + 3) {
            Log.Warn(Log.PHASE_DEPOT, "[" + label + "] path too short for a depot.");
            return null;
        }

        local depots   = [];
        local last_idx = -DepotBuilder.SPACING;

        for (local i = DepotBuilder.SKIP_NEAR_STATION;
                i < path.len() - 1 && depots.len() < DepotBuilder.MAX_DEPOTS; i++) {
            if (i - last_idx < DepotBuilder.SPACING) continue;  // keep them spread out

            // Always the LEFT (outer) side - right side is the partner track.
            local depot_tile = DepotBuilder._TryBuildAt(path, i, false);
            if (depot_tile != null) {
                depots.push(depot_tile);
                last_idx = i;
            }
        }

        // Pragmatic fallback: if the spaced pass found nothing (rough terrain),
        // scan EVERY tile and grab the first workable depot spot - one depot is
        // far better than abandoning the whole route.
        if (depots.len() == 0) {
            for (local i = DepotBuilder.SKIP_NEAR_STATION; i < path.len() - 1; i++) {
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

    // Try to build one depot at a BEND of the line at index i, and ENFORCE that
    // it is actually accessible: after building we verify (in test mode) that
    // the depot->mainline rail really exists AND the mainline still runs
    // through. If not, the depot is torn down and the line restored - we NEVER
    // keep an inaccessible depot. Returns the depot tile, or null.
    //
    //   a --d1--> b      d1 = a->b, d2 = b->c (perpendicular: a bend).
    //             |       Try depot = b - d2 first: depot->b->c is a STRAIGHT
    //   D? c  D?          run (best, guaranteed smooth). Else depot = b + d1:
    //                     depot->b->c curves with the line's own bend.
    static function _TryBuildAt(path, i, want_right, allow_terraform = false) {
        if (i < 1 || i + 1 >= path.len()) return null;
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        local d1 = b - a;
        local d2 = c - b;
        local mx = AIMap.GetMapSizeX();
        if (!DepotBuilder._IsUnitStep(d1, mx) || !DepotBuilder._IsUnitStep(d2, mx)) return null;
        if (d1 == d2 || d1 == -d2) return null;   // need a bend, not a straight

        // Candidate depot tiles: straight-exit (b-d2) preferred, then curve (b+d1).
        foreach (depot in [b - d2, b + d1]) {
            if (!AIMap.IsValidTile(depot) || !AITile.IsBuildable(depot)) continue;
            if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) {
                if (!allow_terraform) continue;
                AITile.LevelTiles(depot, depot);
                if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) continue;
            }

            DepotBuilder._ClearSignals(b, d2);

            // Dry-run.
            local test_ok;
            {
                local tm = AITestMode();
                test_ok = AIRail.BuildRailDepot(depot, b) && AIRail.BuildRail(depot, b, c);
            }
            if (!test_ok) continue;

            // Build for real.
            if (!AIRail.BuildRailDepot(depot, b)) continue;
            if (!AIRail.BuildRail(depot, b, c)) { AITile.DemolishTile(depot); continue; }
            local enter = AIRail.BuildRail(a, b, depot);   // best-effort entry

            // ENFORCE accessibility: the depot->mainline link AND the through
            // line must both actually exist now. _RailExists confirms a piece is
            // already built (not just buildable).
            local exit_ok = DepotBuilder._RailExists(depot, b, c);
            local main_ok = DepotBuilder._RailExists(a, b, c);
            if (!exit_ok || !main_ok) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot at " + depot + " not accessible (exit=" + exit_ok
                    + " main=" + main_ok + "); removing and trying elsewhere.");
                AIRail.RemoveRail(depot, b, c);
                AIRail.RemoveRail(a, b, depot);
                AITile.DemolishTile(depot);
                AIRail.BuildRail(a, b, c);   // make sure the line is intact
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Depot at " + depot + " (bend at " + b + ", verified accessible, enter="
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
