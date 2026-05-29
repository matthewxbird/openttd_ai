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
    static MAX_DEPOTS = 3;         // be generous: several depots per line
    static SPACING    = 8;         // min tiles between consecutive depots

    // path: out-track tile array (src -> dst), as returned by TrackBuilder.
    // Builds up to MAX_DEPOTS spur depots spaced along the mainline so a train
    // can always reach one nearby without a long detour, and always off the
    // running line (a spur) so it never blocks through traffic.
    // Returns an array of depot tile indices (>= 1), or null if none built.
    static function New(path) {
        if (path == null || path.len() < DepotBuilder.SKIP_NEAR_STATION + 3) {
            Log.Warn(Log.PHASE_DEPOT, "Path too short for a spur depot.");
            return null;
        }

        local depots  = [];
        local last_idx = -DepotBuilder.SPACING;  // allow the first candidate

        for (local i = DepotBuilder.SKIP_NEAR_STATION; i < path.len() - 2; i++) {
            if (i - last_idx < DepotBuilder.SPACING) continue;  // keep them spread out

            // Alternate sides: even depots on the left of travel, odd on the
            // right, so depots are evenly spread on BOTH sides of the mainline.
            local prefer_right = (depots.len() % 2) == 1;
            local depot_tile = DepotBuilder._TryBuildAt(path, i, prefer_right);
            if (depot_tile != null) {
                depots.push(depot_tile);
                last_idx = i;
                if (depots.len() >= DepotBuilder.MAX_DEPOTS) break;
            }
        }

        if (depots.len() == 0) {
            Log.Warn(Log.PHASE_DEPOT, "No straight run found for a spur depot.");
            return null;
        }
        Log.Info(Log.PHASE_DEPOT, "Built " + depots.len() + " spur depot(s) along the line.");
        return depots;
    }

    // Try to build one spur depot off the mainline at path index i.
    // prefer_right: try the right side of travel first (for even spacing on
    // both sides); otherwise the left side first.
    // Returns the depot tile, or null if this spot isn't usable.
    //
    // Layout (flow a -> b -> c along the out track; depot 2 tiles off):
    //
    //            depot
    //              |        s1 sits one tile off the line, the depot one MORE
    //             s1        tile off, so the depot is clear of the running line.
    //            /  \
    //   a ===== b ===== c   b is a 3-way junction: the straight mainline a-c
    //                       PLUS a diverge corner (a -> s1) for ENTERING and a
    //                       merge corner (s1 -> c) for EXITING. Both are aligned
    //                       WITH the one-way flow, so a train can drive into the
    //                       depot from upstream and back out downstream without
    //                       ever fighting the signals.
    static function _TryBuildAt(path, i, prefer_right) {
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        // Need three collinear, single-step tiles (a straight run).
        local d = b - a;
        if (c - b != d) return null;
        if (d != 1 && d != -1 && d != AIMap.GetMapSizeX() && d != -AIMap.GetMapSizeX()) return null;

        // Side offsets. Right of travel is where the back track runs, so the
        // left is usually clearer; but we alternate sides for even coverage.
        local right = RailPathFinder._RightOffset(d);
        local order = prefer_right ? [right, -right] : [-right, right];

        foreach (p in order) {
            local s1    = b + p;     // one tile off the line
            local depot = s1 + p;    // two tiles off the line
            if (!AIMap.IsValidTile(s1) || !AIMap.IsValidTile(depot)) continue;
            if (!AITile.IsBuildable(s1) || !AITile.IsBuildable(depot)) continue;

            // Depot faces s1 (adjacent); s1 then runs straight back to b.
            if (!AIRail.BuildRailDepot(depot, s1)) continue;

            // s1: straight piece b -- s1 -- depot (collinear perpendicular run).
            local link_s1   = AIRail.BuildRail(b, s1, depot);
            // b: merge corner s1 -> c (EXIT with flow). This is the must-have:
            // without it a train built in the depot cannot leave with traffic.
            local link_exit = AIRail.BuildRail(s1, b, c);
            // b: diverge corner a -> s1 (ENTER with flow). Best-effort; lets a
            // running train pull in for servicing/autoreplace. Failing it still
            // leaves a usable exit-only depot.
            local link_enter = AIRail.BuildRail(a, b, s1);

            if (!link_s1 || !link_exit) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot spur link failed near " + b + ": "
                    + AIError.GetLastErrorString() + " — removing orphan depot.");
                AITile.DemolishTile(depot);
                AIRail.RemoveRail(b, s1, depot);
                AIRail.RemoveRail(a, b, s1);
                AIRail.RemoveRail(s1, b, c);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Spur depot at " + depot + " (2 tiles "
                + (p == right ? "right" : "left") + " of line, junction at " + b
                + ", enter=" + (link_enter ? "yes" : "no") + ")");
            return depot;
        }
        return null;
    }
}
