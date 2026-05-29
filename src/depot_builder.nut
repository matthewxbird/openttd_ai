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

        // The siding wants flat, level ground. Require the whole footprint
        // (mainline b,c,e plus siding sb,sc,depot) to be FLAT and at the same
        // height. This rejects sloped sites up front so we never pay for a
        // depot+rails that then fail half-built on a slope.
        local base_h = AITile.GetMaxHeight(b);

        foreach (p in order) {
            local sb    = b + p;       // beside b
            local sc    = c + p;       // beside c (sb + d)
            local depot = sb + p;      // one more tile out, beside the siding

            if (!DepotBuilder._SiteIsFlat([sb, sc, depot], base_h, true)) continue;
            if (!DepotBuilder._SiteIsFlat([c, e], base_h, false)) continue;

            // Clear any signals sitting on the mainline tiles we are about to
            // join (b, c, e). A signal on a tile blocks adding the junction
            // track. Normally depots are built before signals so there are
            // none, but a reused line or a second route may already be signed.
            // Do this BEFORE the test so the dry-run sees joinable bare track.
            DepotBuilder._ClearSignals(b, d);
            DepotBuilder._ClearSignals(c, d);
            DepotBuilder._ClearSignals(e, d);

            // Validate the ENTIRE build in test mode first - no money spent,
            // nothing placed. Only if it all passes do we build for real.
            {
                local tm = AITestMode();
                if (!DepotBuilder._LaySiding(a, b, c, e, sb, sc, depot).ok) {
                    continue;   // can't build here; try the other side
                }
            }   // test mode ends here

            // Build for real (we already know it succeeds).
            local r = DepotBuilder._LaySiding(a, b, c, e, sb, sc, depot);
            if (!r.ok) {
                // Should not happen after a passing test, but stay safe.
                AITile.DemolishTile(depot);
                continue;
            }

            Log.Info(Log.PHASE_DEPOT,
                "Depot siding at " + depot + " ("
                + (p == right ? "right" : "left") + " of line, merge at " + c
                + ", enter=" + (r.enter ? "yes" : "no") + ")");
            return depot;
        }
        return null;
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

    // Lay (or test-lay) the whole siding. Returns { ok, enter }.
    //   ok    = the mandatory exit path built (depot + merge curves)
    //   enter = the optional upstream diverge built too
    static function _LaySiding(a, b, c, e, sb, sc, depot) {
        if (!AIRail.BuildRailDepot(depot, sb)) return { ok = false, enter = false };
        local ok = AIRail.BuildRail(depot, sb, sc)   // sb: depot -> sc (curve)
                && AIRail.BuildRail(sb, sc, c)        // sc: sb -> c     (curve)
                && AIRail.BuildRail(sc, c, e);        // c : merge with flow
        local enter = AIRail.BuildRail(a, b, sb)      // b : diverge in
                   && AIRail.BuildRail(b, sb, depot); // sb: straight to depot
        return { ok = ok, enter = enter };
    }
}
