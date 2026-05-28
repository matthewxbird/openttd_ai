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
    static function _TryBuildAt(path, i) {
        local mx = AIMap.GetMapSizeX();
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];

        // Need three collinear, single-step tiles (a straight run).
        local d = b - a;
        if (c - b != d) return null;
        if (d != 1 && d != -1 && d != mx && d != -mx) return null;

        // Perpendicular offsets to either side of the mainline at b.
        local perps = (d == 1 || d == -1) ? [mx, -mx] : [1, -1];

        foreach (p in perps) {
            local depot_tile = b + p;
            if (!AIMap.IsValidTile(depot_tile)) continue;
            if (!AITile.IsBuildable(depot_tile)) continue;

            // Depot faces the mainline tile b (adjacent).
            if (!AIRail.BuildRailDepot(depot_tile, b)) continue;

            // Turnout: link the depot into the mainline on tile b. Connect it
            // to BOTH directions (from a, and from c) so a train can leave the
            // depot whichever way the line flows - otherwise it could only exit
            // backwards against the one-way signals and stall. At least the
            // first (upstream) link must succeed.
            local link_a = AIRail.BuildRail(a, b, depot_tile);
            local link_c = AIRail.BuildRail(c, b, depot_tile);
            if (!link_a && !link_c) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot turnout failed at " + b + ": "
                    + AIError.GetLastErrorString() + " — removing orphan depot.");
                AITile.DemolishTile(depot_tile);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Spur depot built at " + depot_tile + " off mainline tile " + b);
            return depot_tile;
        }
        return null;
    }
}
