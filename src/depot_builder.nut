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

        if (depots.len() == 0) {
            Log.Warn(Log.PHASE_DEPOT, "[" + label + "] no flat spot found for a depot.");
            return null;
        }
        Log.Info(Log.PHASE_DEPOT,
            "[" + label + "] built " + depots.len() + " depot(s) on the outer side.");
        return depots;
    }

    // Try to build one depot off the mainline at path index i.
    // want_right: build on the RIGHT of travel if true, else the LEFT.
    // Returns the depot tile, or null if this spot isn't usable.
    //
    // Single-corner turnout: the depot sits ONE tile off the line and joins it
    // through a 3-way junction on tile b - the straight mainline a-c plus a
    // single curve to the depot. A train enters and leaves with ONE gentle
    // curve; there is no parallel siding and so NO staircase of perpendicular
    // corners (which jams long trains).
    //
    //      depot           depot = b + p (one tile to the side)
    //       |  \           b carries: straight a--c, plus the curve to depot
    //   a ==b== c          ENTER: a -> b -> depot   (one curve)
    //                      EXIT : depot -> b -> c   (one curve, with the flow)
    static function _TryBuildAt(path, i, want_right) {
        // Need THREE collinear, single-step mainline tiles (a,b,c).
        if (i < 1 || i + 1 >= path.len()) return null;
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        local d = b - a;
        if (c - b != d) return null;
        if (d != 1 && d != -1 && d != AIMap.GetMapSizeX() && d != -AIMap.GetMapSizeX()) return null;

        local p     = want_right ? RailPathFinder._RightOffset(d) : -RailPathFinder._RightOffset(d);
        local depot = b + p;

        // Flat, level ground only (reject sloped sites before spending money).
        local base_h = AITile.GetMaxHeight(b);
        if (!DepotBuilder._SiteIsFlat([depot], base_h, true))  return null;
        if (!DepotBuilder._SiteIsFlat([c],     base_h, false)) return null;

        // Clear signals on the mainline tile we join, so the junction can be
        // added (no-op when depots are built before signals, the usual case).
        DepotBuilder._ClearSignals(b, d);

        // Dry-run the whole build in test mode (no money, nothing placed).
        {
            local tm = AITestMode();
            if (!AIRail.BuildRailDepot(depot, b))  return null;
            if (!AIRail.BuildRail(depot, b, c))    return null;  // exit curve (mandatory)
        }

        // Build for real.
        if (!AIRail.BuildRailDepot(depot, b)) return null;
        if (!AIRail.BuildRail(depot, b, c)) {                    // exit curve, with flow
            AITile.DemolishTile(depot);
            return null;
        }
        local enter = AIRail.BuildRail(a, b, depot);             // entry curve (best-effort)

        Log.Info(Log.PHASE_DEPOT,
            "Depot at " + depot + " (" + (p == RailPathFinder._RightOffset(d) ? "right" : "left")
            + " of line, junction at " + b + ", enter=" + (enter ? "yes" : "no") + ")");
        return depot;
    }

    // True if every tile in `tiles` is flat at `height`. `must_be_buildable`
    // also requires open land (for the new siding tiles); the mainline tiles
    // already carry our rail so we only check their height/slope.
    static function _SiteIsFlat(tiles, height, must_be_buildable) {
        foreach (t in tiles) {
            if (!AIMap.IsValidTile(t)) return false;
            if (must_be_buildable && !AITile.IsBuildable(t)) return false;
            if (AITile.GetSlope(t) != AITile.SLOPE_FLAT) return false;
            if (AITile.GetMaxHeight(t) != height) return false;
        }
        return true;
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
