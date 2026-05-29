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

            local depot_tile = DepotBuilder._TryBuildAt(path, i);
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
    // Returns the depot tile, or null if this spot isn't usable.
    //
    // Layout (flow a -> b -> c along the out track):
    //
    //        depot
    //          |          s1 is one tile off the line, depot one MORE tile off,
    //         s1          so the depot sits clear of the running line (a real
    //          \          spur, not a tap ON the main line).
    //   a == b == c       the merge on b is a single corner s1 -> c, aligned
    //                     WITH the one-way flow, so a train built in the depot
    //                     leaves depot -> s1 -> b -> c WITH traffic (it could
    //                     never exit against the one-way signals).
    static function _TryBuildAt(path, i) {
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        // Need three collinear, single-step tiles (a straight run).
        local d = b - a;
        if (c - b != d) return null;
        local mx = AIMap.GetMapSizeX();
        if (d != 1 && d != -1 && d != mx && d != -mx) return null;

        // Spur goes to the LEFT of travel; the back track runs on the RIGHT
        // (left-hand running), so the left side is clear. Try left first, then
        // right as a fallback.
        local right = RailPathFinder._RightOffset(d);
        foreach (p in [-right, right]) {
            local s1    = b + p;     // one tile off the line
            local depot = s1 + p;    // two tiles off the line
            if (!AIMap.IsValidTile(s1) || !AIMap.IsValidTile(depot)) continue;
            if (!AITile.IsBuildable(s1) || !AITile.IsBuildable(depot)) continue;

            // Depot faces s1 (adjacent); s1 then runs straight back to b.
            if (!AIRail.BuildRailDepot(depot, s1)) continue;

            // s1: straight piece b -- s1 -- depot (collinear, perpendicular run).
            local link_s1 = AIRail.BuildRail(b, s1, depot);
            // b: corner merging the spur into the line WITH the flow (s1 -> c).
            local link_b  = AIRail.BuildRail(s1, b, c);

            if (!link_s1 || !link_b) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot spur link failed near " + b + ": "
                    + AIError.GetLastErrorString() + " — removing orphan depot.");
                AITile.DemolishTile(depot);
                AIRail.RemoveRail(b, s1, depot);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Spur depot built at " + depot + " (2 tiles off line, exit with flow at " + b + ")");
            return depot;
        }
        return null;
    }
}
