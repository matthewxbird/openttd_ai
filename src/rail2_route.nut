// src/rail2_route.nut
// Phase 11 rail-layer rewrite: build a full rail route on AAHOG-style
// SmartTerminus stations (StationDT) with a DOUBLE-TRACK main connecting the
// separated throats, and a DISTANCE-SCALED fleet (no 2-train deadlock cap).
//
// Topology (per end, terminus with separated/bridged throat):
//   producer ── src StationDT ──out-main──▶ dst StationDT ── accepter
//                    ▲                            │
//                    └───────── back-main ◀───────┘
// out-main:  src.departure[0]  ->  dst.arrival[0]
// back-main: dst.departure[0]  ->  src.arrival[0]
// Trains reverse INSIDE each terminus (auto), but arrival & departure are on
// separate bridged throat tracks so they never conflict -> many trains, no
// deadlock. Fleet scales with distance (AAHOG trainroute.nut:1286).
//
// Gated behind MvBAI.USE_RAIL2 (OFF on main). Reuses RailPathFinder /
// TrackBuilder._BuildPath / Signals / DepotBuilder / Trains.

class Rail2 {
    static NUM   = 2;     // platforms per terminus. (num==3 adds a throat depot but
                          // its bigger footprint sites too rarely - 0 routes in a
                          // 256 smoke; revisit once siting/levelling is stronger.)
    static LEN   = 5;     // platform length
    static SEARCH_RADIUS = 6;

    // Per-route train cap, scaled by distance (AAHOG formula, distance-proportional),
    // bounded so an early single route doesn't buy 50 trains before proving out.
    static BASE_TRAINS = 3;
    static MAX_TRAINS  = 12;
    static function FleetSize(distance, production) {
        // ~1 train per 12 tiles of round trip, clamped, also bounded by production.
        local byDist = Rail2.BASE_TRAINS + distance / 12;
        local byProd = 1 + production / 40;
        local n = byDist < byProd ? byDist : byProd;
        if (n < 1) n = 1;
        if (n > Rail2.MAX_TRAINS) n = Rail2.MAX_TRAINS;
        return n;
    }

    // Map a from->to world direction to the StationDT dir whose THROAT (local +y)
    // points from the platforms toward `toward`. We want the throat (and main
    // line) to fan out toward the partner industry.
    //   DIR_SE: +y = +Y    DIR_NW: +y = -Y
    //   DIR_SW: +y = +X    DIR_NE: +y = -X
    static function _DirToward(self_tile, toward) {
        local dx = AIMap.GetTileX(toward) - AIMap.GetTileX(self_tile);
        local dy = AIMap.GetTileY(toward) - AIMap.GetTileY(self_tile);
        if (abs(dx) >= abs(dy)) {
            return dx >= 0 ? StationDT.DIR_SW : StationDT.DIR_NE;   // +X / -X
        }
        return dy >= 0 ? StationDT.DIR_SE : StationDT.DIR_NW;       // +Y / -Y
    }

    // Site + build a StationDT near an industry, throat facing the partner.
    // Returns the station record or null.
    static function SiteStation(industry_id, is_source, partner_tile, cargo) {
        local self_tile = AIIndustry.GetLocation(industry_id);
        local tiles = is_source
            ? AITileList_IndustryProducing(industry_id, Rail2.SEARCH_RADIUS)
            : AITileList_IndustryAccepting(industry_id, Rail2.SEARCH_RADIUS);
        if (tiles.IsEmpty()) return null;
        tiles.Valuate(AIMap.DistanceManhattan, self_tile);
        tiles.Sort(AIList.SORT_BY_VALUE, true);   // nearest first

        local dir = Rail2._DirToward(self_tile, partner_tile);
        // Try the partner-facing dir first, then the opposite as fallback.
        local opp = { [StationDT.DIR_SE] = StationDT.DIR_NW, [StationDT.DIR_NW] = StationDT.DIR_SE,
                      [StationDT.DIR_SW] = StationDT.DIR_NE, [StationDT.DIR_NE] = StationDT.DIR_SW };
        foreach (d in [dir, opp[dir]]) {
            foreach (tile, _ in tiles) {
                if (!StationDT.CanBuild(tile, d, Rail2.NUM, Rail2.LEN)) continue;
                local st = StationDT.Build(tile, d, Rail2.NUM, Rail2.LEN, cargo, is_source);
                if (st != null) return st;
            }
        }
        return null;
    }

    // Lay a single main-line track from one throat tile to another, using the
    // existing ROBUST pathfind+build+reroute (handles mid-path UNKNOWN/90-turn by
    // detouring - a naive single pathfind fails on any one bad tile). `guide` =
    // the out-track tiles to parallel (for the back track), or [] for the out.
    // Returns the tile list or null.
    static function _BuildMain(from_tile, from_prev, to_tile, to_prev, guide, label) {
        local tiles = TrackBuilder._RunPathfinder(
            from_tile, from_prev, to_tile, to_prev, true, guide, label);
        if (tiles == null) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] " + label + " build failed (reroutes exhausted).");
            return null;
        }
        Signals.PlaceAlong(tiles, true, label);   // one-way PBS along the main
        return tiles;
    }

    // Build the whole route. Returns true on success.
    static function TryBuild(state, c, railtype) {
        // Ensure a budget that covers TWO levelled SmartTerminus stations + the
        // double-track main + a distance-scaled fleet, so siting doesn't drain
        // cash mid-build (was: 49 ERR_NOT_ENOUGH_CASH on platform builds).
        Money.EnsureFunds(180000);
        local prod_tile = AIIndustry.GetLocation(c.producer);
        local acc_tile  = ("acc_is_town" in c && c.acc_is_town)
            ? AITown.GetLocation(c.accepter) : AIIndustry.GetLocation(c.accepter);

        local src = Rail2.SiteStation(c.producer, true, acc_tile, c.cargo);
        if (src == null) { Log.Warn(Log.PHASE_STATION, "[rail2] no src site"); return false; }
        local dst = Rail2.SiteStation(c.accepter, false, prod_tile, c.cargo);
        if (dst == null) {
            Log.Warn(Log.PHASE_STATION, "[rail2] no dst site");
            StationDT._Demolish(src.platform_tile, src.origin, src.dir, src.num, src.len);
            return false;
        }

        // Double-track main: out (src.departure -> dst.arrival), back (dst.departure
        // -> src.arrival). The back track parallels the out track (passed as guide).
        local out_main = Rail2._BuildMain(
            src.departure_tiles[0], src.departure_tiles[1],
            dst.arrival_tiles[0],   dst.arrival_tiles[1], [], "rail2-out");
        local back_main = (out_main == null) ? null : Rail2._BuildMain(
            dst.departure_tiles[0], dst.departure_tiles[1],
            src.arrival_tiles[0],   src.arrival_tiles[1], out_main, "rail2-back");
        if (out_main == null || back_main == null) {
            Log.Warn(Log.PHASE_TRACK, "[rail2] main build failed; abandoning.");
            StationDT._Demolish(src.platform_tile, src.origin, src.dir, src.num, src.len);
            StationDT._Demolish(dst.platform_tile, dst.origin, dst.dir, dst.num, dst.len);
            return false;
        }

        // Depot: use a station depot if present (num==3), else build one on the out-main.
        local depot = (src.depot != null) ? src.depot : null;
        if (depot == null) {
            local d = DepotBuilder.New(out_main, "rail2-depot");
            if (d != null && d.len() > 0) depot = d[0];
        }
        if (depot == null) {
            Log.Warn(Log.PHASE_DEPOT, "[rail2] no depot; abandoning.");
            StationDT._Demolish(src.platform_tile, src.origin, src.dir, src.num, src.len);
            StationDT._Demolish(dst.platform_tile, dst.origin, dst.dir, dst.num, dst.len);
            return false;
        }

        // Fleet: distance-scaled, dispatched src -> dst (full load) -> back.
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
        if (trains.len() == 0) {
            Log.Warn(Log.PHASE_TRAIN, "[rail2] no trains dispatched; abandoning.");
            return false;
        }

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
            + " -> " + Route.AccepterName(c) + " trains=" + trains.len()
            + " dist=" + c.distance);
        return true;
    }
}
