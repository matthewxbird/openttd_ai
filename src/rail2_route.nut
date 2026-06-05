// src/rail2_route.nut
// Phase 11 rail rewrite: build a rail route on AAHOG-captured SmartTerminus
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

    // Site a station near `industry`, throat/main facing `partner_tile`. Returns rec.
    static function SiteStation(industry_id, partner_tile, cargo) {
        local loc = AIIndustry.GetLocation(industry_id);
        local ix = AIMap.GetTileX(loc);
        local iy = AIMap.GetTileY(loc);
        // Throat faces the partner (rotations verified to stamp clean). This puts
        // src.throat -> dst and dst.throat -> src so the double main connects short
        // and the return leg can complete.
        local k  = StationDT.DirToward(loc, partner_tile);
        local cands = [];
        for (local dy = -8; dy <= 2; dy++)
            for (local dx = -8; dx <= 2; dx++)
                cands.push([ix + dx, iy + dy]);
        cands.sort(function(a, b) : (ix, iy) {
            local da = (a[0] + 2 - ix) * (a[0] + 2 - ix) + (a[1] + 2 - iy) * (a[1] + 2 - iy);
            local db = (b[0] + 2 - ix) * (b[0] + 2 - ix) + (b[1] + 2 - iy) * (b[1] + 2 - iy);
            return da - db;
        });
        foreach (c in cands) {
            if (!StationDT.CanBuild(c[0], c[1], k)) continue;
            local st = StationDT.Build(c[0], c[1], k, cargo, true);
            if (st != null) return st;
        }
        return null;
    }

    static MAIN_CHUNKS = 250;   // fail-fast: the throat main-exit makes long hauls
                                // explode the A* open-set; cap chunks so a hard
                                // connect gives up quick instead of grinding to 600.
    static function _BuildMain(from_tile, from_prev, to_tile, to_prev, guide, label) {
        local tiles = TrackBuilder._RunPathfinder(from_tile, from_prev, to_tile, to_prev, true, guide, label, Rail2.MAIN_CHUNKS);
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
        local src = Rail2.SiteStation(c.producer, acc_tile, c.cargo);
        if (src == null) { Log.Warn(Log.PHASE_STATION, "[rail2] no src site"); return false; }
        local dst = Rail2.SiteStation(c.accepter, prod_tile, c.cargo);
        if (dst == null) {
            Log.Warn(Log.PHASE_STATION, "[rail2] no dst site");
            StationDT.Demolish(src);
            return false;
        }

        // Double-track main. Per the captured throat's SIGNAL directions: main_a
        // (row dy1, west-facing presignals) = ARRIVAL track; main_b (row dy2,
        // east-facing PBS) = DEPARTURE track - at BOTH identical ends. So:
        //   out  : src.main_b (depart) -> dst.main_a (arrive)
        //   back : dst.main_b (depart) -> src.main_a (arrive)
        local out_main = Rail2._BuildMain(src.main_b, src.main_b_prev, dst.main_a, dst.main_a_prev, [], "rail2-out");
        local back_main = (out_main == null) ? null
            : Rail2._BuildMain(dst.main_b, dst.main_b_prev, src.main_a, src.main_a_prev, [], "rail2-back");
        if (out_main == null || back_main == null) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] main build failed; abandoning.");
            StationDT.Demolish(src); StationDT.Demolish(dst);
            return false;
        }

        // Depot on the back-main near the source (fresh train -> source -> load first).
        local depot = null;
        local d = DepotBuilder.New(back_main, "rail2-depot");
        if (d != null && d.len() > 0) depot = d[0];
        if (depot == null) {
            Log.Warn(Log.PHASE_DEPOT, "[rail2] no depot; abandoning.");
            StationDT.Demolish(src); StationDT.Demolish(dst);
            return false;
        }

        local engine = Trains.PickEngine(c.cargo, railtype);
        local wagon  = Trains.PickWagon(c.cargo, railtype);
        if (engine == -1 || wagon == -1) { Log.Warn(Log.PHASE_TRAIN, "[rail2] no engine/wagon"); return false; }
        local nwag = Trains.PickNumWagons(c.distance, c.production);
        local nfleet = Rail2.FleetSize(c.distance, c.production);
        local trains = [];
        for (local k = 0; k < nfleet; k++) {
            local id = Trains.BuildTrain(depot, engine, wagon, c.cargo, nwag);
            if (id == -1) break;
            if (!Trains.DispatchTrain(id, src.platform_tile, dst.platform_tile, false)) break;
            trains.push(id);
        }
        if (trains.len() == 0) { Log.Warn(Log.PHASE_TRAIN, "[rail2] no trains dispatched"); return false; }

        local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production,
            ("acc_is_town" in c) ? c.acc_is_town : false);
        route.src_station = src;
        route.dst_station = dst;
        route.path_out  = out_main;
        route.path_back = back_main;
        route.depot_tiles = [depot];
        route.depot_tile  = depot;
        route.trains   = trains;
        route.train_id = trains[0];
        route.max_trains = Rail2.MAX_TRAINS;
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
