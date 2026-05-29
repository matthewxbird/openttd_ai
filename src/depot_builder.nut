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

    // Try to build one depot SIDING off the mainline at path index i.
    // prefer_right: try the right side of travel first (we alternate sides for
    // even coverage); otherwise the left side first.
    // Returns the depot tile, or null if this spot isn't usable.
    //
    // The depot sits on a short siding that runs PARALLEL to the mainline, so
    // every turn is a single 45-degree curve - never a 90-degree dead corner
    // (which strands trains). Flow a -> b -> c -> e along the out track;
    // the siding hangs off the side `p`:
    //
    //   a ===== b ===== c ===== e      mainline (one-way, flow ->)
    //            \             /
    //   depot == sb ===== sc          siding parallel to the line
    //
    //   - ENTER: a -> b -> sb -> depot   (diverge at b, gentle curve)
    //   - EXIT : depot -> sb -> sc -> c -> e   (merge at c, gentle curves)
    //
    // Both moves run WITH the one-way flow, so a built train can leave and a
    // running train can pull in for servicing, with no sharp turn anywhere.
    static function _TryBuildAt(path, i, prefer_right) {
        // Need FOUR collinear, single-step mainline tiles (a,b,c,e).
        if (i + 2 >= path.len()) return null;
        local a = path[i - 1];
        local b = path[i];
        local c = path[i + 1];
        local e = path[i + 2];

        local d = b - a;
        if (c - b != d || e - c != d) return null;
        if (d != 1 && d != -1 && d != AIMap.GetMapSizeX() && d != -AIMap.GetMapSizeX()) return null;

        local right = RailPathFinder._RightOffset(d);
        local order = prefer_right ? [right, -right] : [-right, right];

        foreach (p in order) {
            local sb    = b + p;       // beside b
            local sc    = c + p;       // beside c (sb + d)
            local depot = sb + p;      // one more tile out, beside the siding
            foreach (t in [sb, sc, depot]) {
                if (!AIMap.IsValidTile(t) || !AITile.IsBuildable(t)) { sb = null; break; }
            }
            if (sb == null) continue;

            if (!AIRail.BuildRailDepot(depot, sb)) continue;

            // Build the siding. The straight + merge/diverge corners are the
            // must-haves; the upstream diverge (enter) is best-effort.
            local ok = true;
            ok = ok && AIRail.BuildRail(depot, sb, sc);  // sb: depot -> sc (curve)
            ok = ok && AIRail.BuildRail(sb, sc, c);      // sc: sb -> c     (curve)
            ok = ok && AIRail.BuildRail(sc, c, e);       // c : merge with flow
            // ENTER (best-effort): diverge at b, then run straight into the
            // depot along the siding. Needs BOTH the b corner and the sb
            // straight; if either fails the depot is still usable exit-only.
            local link_enter = AIRail.BuildRail(a, b, sb)
                            && AIRail.BuildRail(b, sb, depot);

            if (!ok) {
                Log.Warn(Log.PHASE_DEPOT,
                    "Depot siding failed near " + b + ": "
                    + AIError.GetLastErrorString() + " — removing partial build.");
                AITile.DemolishTile(depot);
                AIRail.RemoveRail(depot, sb, sc);
                AIRail.RemoveRail(sb, sc, c);
                AIRail.RemoveRail(sc, c, e);
                AIRail.RemoveRail(a, b, sb);
                AIRail.RemoveRail(b, sb, depot);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Depot siding at " + depot + " ("
                + (p == right ? "right" : "left") + " of line, merge at " + c
                + ", enter=" + (link_enter ? "yes" : "no") + ")");
            return depot;
        }
        return null;
    }
}
