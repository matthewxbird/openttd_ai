// src/rail2_route.nut
// Phase 11 rail rewrite: build a rail route on captured SmartTerminus
// stations (StationDT, from Captures.WronstonThroat - verified throat geometry)
// with a DOUBLE-TRACK main + DISTANCE-SCALED fleet (no 2-train deadlock cap).
//
// v1: stations fixed orientation (main east). Connect src.main_a -> dst.main_a
// (out) and dst.main_b -> src.main_b (back); reuse the robust reroute pathfinder.
// Gated behind MvBAI.USE_RAIL2.

class Rail2 {
    static BASE_TRAINS = 3;
    static MAX_TRAINS  = 12;
    static function FleetSize(distance, production) {
        local byDist = Rail2.BASE_TRAINS + distance / 12;
        local byProd = 1 + production / 40;
        local n = byDist < byProd ? byDist : byProd;
        if (n < 1) n = 1;
        if (n > Rail2.MAX_TRAINS) n = Rail2.MAX_TRAINS;
        return n;
    }

    // Which station SPEC rail2 builds. 2-platform crossover opener (small/cheap) -
    // the user's "don't build too big too early". Swap to StationDT.Spec3() for the
    // high-throughput 3-platform bridged terminus.
    static function Spec() { return StationDT.Spec2(); }

    // Site a station near `industry`, throat/main facing `partner_tile`. Returns rec.
    // is_source: producer station (must PRODUCE the cargo) vs accepter (must ACCEPT).
    static function SiteStation(industry_id, partner_tile, cargo, is_source, join_id = null) {
        local spec = Rail2.Spec();
        local loc = AIIndustry.GetLocation(industry_id);
        local ix = AIMap.GetTileX(loc);
        local iy = AIMap.GetTileY(loc);
        // Throat faces the partner ONLY. The main exits in the throat direction, so a
        // 90-deg rotation can point the main at WATER / away from the partner and never
        // connect (measured: 90-deg rotations -> 1 loop + 14 main-fails, faces water).
        // Keep best-COVERAGE origin scoring (the "other side" win) at the facing k.
        local base_k = StationDT.DirToward(loc, partner_tile);
        local ks = [base_k];
        local cands = [];
        for (local dy = -8; dy <= 2; dy++)
            for (local dx = -8; dx <= 2; dx++)
                cands.push([ix + dx, iy + dy]);
        cands.sort(function(a, b) : (ix, iy) {
            local da = (a[0] + 2 - ix) * (a[0] + 2 - ix) + (a[1] + 2 - iy) * (a[1] + 2 - iy);
            local db = (b[0] + 2 - ix) * (b[0] + 2 - ix) + (b[1] + 2 - iy) * (b[1] + 2 - iy);
            return da - db;
        });
        // Pass 1: among ALL rotations + origins, pick the one whose platforms COVER
        // the industry BEST (most platform tiles in coverage). Coverage dominates;
        // ties prefer the partner-facing rotation (cleanest main connect). This lets
        // a 90-deg-rotated or other-side placement win when it serves the industry
        // better (e.g. reaching two adjacent industries).
        // Pick the origin whose platforms actually PRODUCE/ACCEPT the cargo best
        // (real GetCargoProduction/Acceptance, not distance-to-centre). NO non-
        // covering fallback - an out-of-coverage station serves nothing ("Accepts:
        // Nothing"), so skip the route rather than build a useless station.
        local best = null; local best_val = -1;
        foreach (k in ks) {
            foreach (c in cands) {
                if (!StationDT.CanBuild(c[0], c[1], k, spec, join_id)) continue;
                local cs = StationDT.CoverScore(c[0], c[1], k, cargo, is_source, spec);
                if (cs == 0) continue;                       // must really serve it
                local val = cs * 2 + (k == base_k ? 1 : 0);  // coverage first, tie->facing
                if (val > best_val) { best_val = val; best = [c[0], c[1], k]; }
            }
        }
        if (best != null) {
            local st = StationDT.Build(best[0], best[1], best[2], cargo, is_source, spec, join_id);
            if (st != null) return st;
        }
        return null;
    }

    static MAIN_CHUNKS = 2000;  // match TrackBuilder.MAX_CHUNKS (reach for hard routes;
                                // afforded by the TileModel AVOID+BRIDGE search-space cut).
    // Advance ONE straight tile out of a throat (lay that piece) and return the
    // [new_tile, new_prev] to pathfind from/to. Pushing the pathfinder's start (and
    // goal) one tile past the throat forces a STRAIGHT exit, so the first/last curve
    // can't land right on the throat (the recurring kink at every station). Best-
    // effort: if the next tile is off-map or the straight piece won't lay (blocked /
    // water / foreign rail), fall back to the throat tile itself - no change there.
    static function _LeadOut(tile, prev) {
        local step = tile - prev;
        local lead = tile + step;
        if (!AIMap.IsValidTile(lead) || AIMap.DistanceManhattan(tile, lead) != 1) return [tile, prev];
        if (AIRail.BuildRail(prev, tile, lead)
                || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) {
            return [lead, tile];
        }
        return [tile, prev];
    }

    static function _BuildMain(from_tile, from_prev, to_tile, to_prev, is_outward, guide, label) {
        // Start/end the pathfind one straight tile OUTSIDE each throat (see _LeadOut)
        // so no curve forms right at the station exit/entry. The pathfinder seed
        // includes the prev tile and the goal appends its prev, so the throat tiles
        // stay on the path - we only shift where the free curve search may begin.
        local s = Rail2._LeadOut(from_tile, from_prev);
        local g = Rail2._LeadOut(to_tile, to_prev);
        // repair=true: terraform slope/clear failures minimally and lay the rail,
        // instead of leaving a gap. Important for the PARALLEL back-track, which is
        // side-constrained and often can't reroute around a one-tile slope.
        local tiles = TrackBuilder._RunPathfinder(s[0], s[1], g[0], g[1], is_outward, guide, label, Rail2.MAIN_CHUNKS, true);
        if (tiles == null) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] " + label + " build failed.");
            return null;
        }
        Signals.PlaceAlong(tiles, true, label);
        return tiles;
    }

    static function TryBuild(state, c, railtype) {
        // PRE-FLIGHT (free, test-mode): confirm a rail path even EXISTS before
        // building two expensive levelled SmartTerminus stations. Without this an
        // unreachable route (e.g. across water) builds both stations, then the main
        // pathfind grinds 600 chunks and fails -> ~half the starting budget wasted.
        local acc_is_town = ("acc_is_town" in c && c.acc_is_town);
        if (!acc_is_town && !TrackBuilder.CanReach(c.producer, c.accepter)) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] preflight: no path "
                + AIIndustry.GetName(c.producer) + " -> " + Route.AccepterName(c)
                + "; skipping (nothing built).");
            return false;
        }
        Money.EnsureFunds(220000);   // 2 captured stations (level+throat) + main + fleet
        local prod_tile = AIIndustry.GetLocation(c.producer);
        local acc_tile  = ("acc_is_town" in c && c.acc_is_town)
            ? AITown.GetLocation(c.accepter) : AIIndustry.GetLocation(c.accepter);
        local src = Rail2.SiteStation(c.producer, acc_tile, c.cargo, true);
        if (src == null) { Log.Warn(Log.PHASE_STATION, "[rail2] no src site"); return false; }
        // If this accepter is ALREADY served by a rail2 station, JOIN the new dst to
        // it (one logical station id, separate platform-lines) instead of building a
        // 3rd standalone station crammed at the same consumer. Fall back to a new
        // station if it can't physically join (too far to merge).
        local join_id = null;
        foreach (_, r in state.routes) {
            if (("rail2" in r) && r.rail2 && r.accepter == c.accepter
                && r.dst_station != null && ("station_id" in r.dst_station)) {
                join_id = r.dst_station.station_id; break;
            }
        }
        local dst = (join_id != null)
            ? Rail2.SiteStation(c.accepter, prod_tile, c.cargo, false, join_id) : null;
        if (dst == null) dst = Rail2.SiteStation(c.accepter, prod_tile, c.cargo, false);  // new station
        if (dst == null) {
            Log.Warn(Log.PHASE_STATION, "[rail2] no dst site");
            StationDT.Demolish(src);
            return false;
        }

        // ROLLBACK (transactional build cleanup): from here on, ANY
        // failure demolishes everything this attempt built - both stations AND all
        // main track laid below - so a failed route leaves nothing behind. Without
        // this, every "main build failed; abandoning" leaked orphaned track: sunk
        // cost + a maintenance drain with no asset value (the borrow-and-burn that
        // floored company value at 1). Protect every OTHER route's station zone so
        // cleanup never demolishes a working line.
        local prot = {};
        local mx = AIMap.GetMapSizeX();
        foreach (_, r in state.routes) {
            foreach (st in [("src_station" in r) ? r.src_station : null,
                            ("dst_station" in r) ? r.dst_station : null]) {
                if (st == null || !("tile" in st)) continue;
                for (local dy = -8; dy <= 8; dy++)
                    for (local dx = -8; dx <= 8; dx++) {
                        local t = st.tile + dx + dy * mx;
                        if (AIMap.IsValidTile(t)) prot[t] <- true;
                    }
            }
        }
        TrackBuilder._touched.clear();   // from here, _touched = THIS route's main track
        local depot_holder = [null];     // fallback depot tile (for cleanup), if any
        local Rollback = function() : (src, dst, prot, depot_holder) {
            TrackBuilder.SafeDemolishTouched(TrackBuilder._touched, prot);
            if (depot_holder[0] != null) AITile.DemolishTile(depot_holder[0]);
            StationDT.Demolish(src);
            StationDT.Demolish(dst);
            return false;
        };

        // Double-track main. Per the captured throat's SIGNAL directions: main_a
        // (row dy1, west-facing presignals) = ARRIVAL track; main_b (row dy2,
        // east-facing PBS) = DEPARTURE track - at BOTH identical ends. So:
        //   out  : src.main_b (depart) -> dst.main_a (arrive)
        //   back : dst.main_b (depart) -> src.main_a (arrive)
        // OUT track: isOutward=true, no guide. BACK track: isOutward=FALSE + the out
        // track as guide -> the pathfinder's parallel side-bias threads it ALONGSIDE
        // the out track (clean double-track, no weave/whacky-loop) and never crosses it.
        local out_main = Rail2._BuildMain(src.main_b, src.main_b_prev, dst.main_a, dst.main_a_prev, true, [], "rail2-out");
        local back_main = null;
        if (out_main != null) {
            // Try the CLEAN PARALLEL back-track first (isOutward=false + out as guide
            // -> side-bias threads it alongside, no weave). If that can't thread
            // (terrain/water the side-bias can't follow), FALL BACK to an INDEPENDENT
            // pathfind (may weave, but connects) so the route isn't lost to a back-leg
            // the strict parallel couldn't solve.
            back_main = Rail2._BuildMain(dst.main_b, dst.main_b_prev, src.main_a, src.main_a_prev, false, out_main, "rail2-back");
            if (back_main == null) {
                Log.Warn(Log.PHASE_TRACK, "[rail2] parallel back-track failed; retrying independent.");
                back_main = Rail2._BuildMain(dst.main_b, dst.main_b_prev, src.main_a, src.main_a_prev, false, [], "rail2-back2");
            }
        }
        if (out_main == null || back_main == null) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] main build failed; abandoning.");
            return Rollback();
        }

        // Depot: the src station has one baked into its throat (dead-end siding off
        // the dy3 line). Fall back to a back-main depot only if it didn't build.
        local depot = ("depot" in src) ? src.depot : null;
        if (depot == null) {
            local d = DepotBuilder.New(back_main, "rail2-depot");
            if (d != null && d.len() > 0) { depot = d[0]; depot_holder[0] = depot; }
        }
        if (depot == null) {
            Log.Warn(Log.PHASE_DEPOT, "[rail2] no depot; abandoning.");
            return Rollback();
        }

        local engine = Trains.PickEngine(c.cargo, railtype);
        local wagon  = Trains.PickWagon(c.cargo, railtype);
        if (engine == -1 || wagon == -1) { Log.Warn(Log.PHASE_TRAIN, "[rail2] no engine/wagon"); return Rollback(); }
        local nwag = Trains.PickNumWagons(c.distance, c.production);
        local nfleet = Rail2.FleetSize(c.distance, c.production);
        // The rail2 SmartTerminus platform is Spec().len tiles - SHORTER than the
        // legacy default - so size every train to it or it overhangs the platform.
        local plat_tiles = Rail2.Spec().len;
        local trains = [];
        for (local k = 0; k < nfleet; k++) {
            local id = Trains.BuildTrain(depot, engine, wagon, c.cargo, nwag, plat_tiles);
            if (id == -1) break;
            if (!Trains.DispatchTrain(id, src.platform_tile, dst.platform_tile, false)) break;
            trains.push(id);
        }
        if (trains.len() == 0) { Log.Warn(Log.PHASE_TRAIN, "[rail2] no trains dispatched"); return Rollback(); }

        local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production,
            ("acc_is_town" in c) ? c.acc_is_town : false);
        route.src_station = src;
        route.dst_station = dst;
        route.path_out  = out_main;
        route.path_back = back_main;
        // Record the main track tiles so a later condemn/teardown cleans them too.
        route.touched <- [];
        foreach (t in TrackBuilder._touched) route.touched.push(t);
        route.depot_tiles = [depot];
        route.depot_tile  = depot;
        route.trains   = trains;
        route.train_id = trains[0];
        route.max_trains = Rail2.MAX_TRAINS;
        route.plat_tiles <- plat_tiles;   // so later lengthening fits this platform too
        route.backhaul <- false;
        route.rail2    <- true;
        route.status   = "probation";
        route.probation_date = AIDate.GetCurrentDate();
        state.AddRoute(route);
        Log.Info(Log.PHASE_RANK, "[rail2] route built " + AIIndustry.GetName(c.producer)
            + " -> " + Route.AccepterName(c) + " trains=" + trains.len() + " dist=" + c.distance);
        return true;
    }
}
