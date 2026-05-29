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

    // Try to build one depot at an ELBOW (diagonal bend) of the line at index i.
    // Returns the depot tile, or null if this spot isn't usable.
    //
    // We attach ONLY at a bend, never on a straight run. On a straight run the
    // only spur is perpendicular - a hard 90-degree join that traps trains. At a
    // bend the line already turns, so a depot placed "straight ahead" of the
    // incoming leg exits through a curve of the SAME gentleness as the line's
    // own bend - no sharp 90-degree join.
    //
    //   a --d1--> b           d1 = a->b, d2 = b->c (perpendicular: a bend)
    //             |  \         depot D = b + d1 (straight on past the bend)
    //             c   D        EXIT : D -> b -> c  (curve, same bend as a->b->c)
    static function _TryBuildAt(path, i, want_right, allow_terraform = false) {
        if (i < 1 || i + 1 >= path.len()) return null;
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        local d1 = b - a;   // incoming leg direction
        local d2 = c - b;   // outgoing leg direction
        local mx = AIMap.GetMapSizeX();
        // Both legs must be single orthogonal steps, and PERPENDICULAR (a bend).
        if (!DepotBuilder._IsUnitStep(d1, mx) || !DepotBuilder._IsUnitStep(d2, mx)) return null;
        if (d1 == d2 || d1 == -d2) return null;   // straight or reversal, not a bend

        local depot = b + d1;   // straight on past the bend
        if (!AIMap.IsValidTile(depot) || !AITile.IsBuildable(depot)) return null;
        if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) {
            if (!allow_terraform) return null;
            AITile.LevelTiles(depot, depot);
            if (AITile.GetSlope(depot) != AITile.SLOPE_FLAT) return null;
        }

        // Clear signals on the bend tile so the junction can be added.
        DepotBuilder._ClearSignals(b, d2);

        // Dry-run in test mode (no money) before building.
        {
            local tm = AITestMode();
            if (!AIRail.BuildRailDepot(depot, b))  return null;
            if (!AIRail.BuildRail(depot, b, c))    return null;  // exit curve (mandatory)
        }

        if (!AIRail.BuildRailDepot(depot, b)) return null;
        if (!AIRail.BuildRail(depot, b, c)) {                    // exit curve -> c, with flow
            AITile.DemolishTile(depot);
            return null;
        }
        local enter = AIRail.BuildRail(a, b, depot);             // entry straight (best-effort)

        Log.Info(Log.PHASE_DEPOT,
            "Depot at " + depot + " (bend at " + b + ", enter=" + (enter ? "yes" : "no") + ")");
        return depot;
    }

    static function _IsUnitStep(d, mx) {
        return d == 1 || d == -1 || d == mx || d == -mx;
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
