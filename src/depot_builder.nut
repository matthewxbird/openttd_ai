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

    static SKIP_NEAR_STATION = 3;  // don't put the depot in the station throat

    // path: out-track tile array (src -> dst), as returned by TrackBuilder.
    // Returns the depot tile index, or null if no spot was found.
    static function New(path) {
        if (path == null || path.len() < DepotBuilder.SKIP_NEAR_STATION + 3) {
            Log.Warn(Log.PHASE_DEPOT, "Path too short for a spur depot.");
            return null;
        }

        local mx = AIMap.GetMapSizeX();

        for (local i = DepotBuilder.SKIP_NEAR_STATION; i < path.len() - 2; i++) {
            local a = path[i - 1];
            local b = path[i];
            local c = path[i + 1];

            // Need three collinear, single-step tiles (a straight run).
            local d = b - a;
            if (c - b != d) continue;
            if (d != 1 && d != -1 && d != mx && d != -mx) continue;

            // Perpendicular offsets to either side of the mainline at b.
            local perps = (d == 1 || d == -1) ? [mx, -mx] : [1, -1];

            foreach (p in perps) {
                local depot_tile = b + p;
                if (!AIMap.IsValidTile(depot_tile)) continue;
                if (!AITile.IsBuildable(depot_tile)) continue;

                // Depot faces the mainline tile b (must be adjacent — it is).
                if (!AIRail.BuildRailDepot(depot_tile, b)) continue;

                // Add the turnout: a rail piece on b linking the mainline
                // (coming from a) into the depot tile.
                if (!AIRail.BuildRail(a, b, depot_tile)) {
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
        }

        Log.Warn(Log.PHASE_DEPOT, "No straight run found for a spur depot.");
        return null;
    }
}
