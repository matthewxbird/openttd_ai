// src/station_dt.nut
// SMART TERMINUS (Phase 11) - built from REAL captured throat geometry. Now
// PARAMETERIZED on a SPEC so multiple station sizes coexist:
//   Spec2() - 2-platform crossover opener (Captures.TwoPlatThroat); cheap/small.
//   Spec3() - 3-platform bridged merge (Captures.WronstonThroat); high throughput.
// A spec is a plain table (Squirrel statics can't be reassigned at runtime, so it
// is passed as a param, not stored on a static). Capture frame (k=0 = main +X):
//   platforms run along X at rows plat_c1.y..plat_c2.y; the throat is stamped for
//   dx in [throat_min..throat_max]; the double main connects at main_a (ARRIVAL)
//   and main_b (DEPARTURE). Rotation k*90 CW faces the throat/main at the partner.

class StationDT {

    // 2-platform opener: 2 tracks + a crossover turnout at dx4 + exit at dx5.
    static function Spec2() {
        return {
            num = 2, len = 4, foot_w = 6, foot_h = 2,
            throat_min = 4, throat_max = 5,
            plat_c1 = [0, 0], plat_c2 = [3, 1],
            main_a = [5, 1], main_a_prev = [4, 1],   // row1 = ARRIVAL (signal faces in)
            main_b = [5, 0], main_b_prev = [4, 0],   // row0 = DEPARTURE (signal faces out)
            depot = null, depot_front = null,        // none captured; rail2 uses back-main
            throat = Captures.TwoPlatThroat(),
        };
    }
    // 3-platform bridged merge (Wronston), trailing trim at dx13.
    static function Spec3() {
        return {
            num = 3, len = 6, foot_w = 14, foot_h = 4,
            throat_min = 6, throat_max = 13,
            plat_c1 = [0, 1], plat_c2 = [5, 3],
            main_a = [13, 1], main_a_prev = [12, 1],
            main_b = [13, 2], main_b_prev = [12, 2],
            depot = [12, 3], depot_front = [11, 3],
            throat = Captures.WronstonThroat(),
        };
    }

    // Rotate a point (x,y) by k*90 CW within the spec's foot_w x foot_h grid.
    static function _Rot(x, y, k, spec) {
        local w = spec.foot_w; local h = spec.foot_h;
        local px = x; local py = y;
        for (local i = 0; i < (k % 4); i++) {
            local nx = h - 1 - py; local ny = px;
            px = nx; py = ny;
            local t = w; w = h; h = t;
        }
        return [px, py];
    }
    static function _FootDims(k, spec) {
        return (k % 2 == 0) ? [spec.foot_w, spec.foot_h] : [spec.foot_h, spec.foot_w];
    }
    static function _Tile(ox, oy, pt) { return AIMap.GetTileIndex(ox + pt[0], oy + pt[1]); }
    static function _Foot(ox, oy, k, spec) {
        local d = StationDT._FootDims(k, spec);
        return [AIMap.GetTileIndex(ox, oy), AIMap.GetTileIndex(ox + d[0] - 1, oy + d[1] - 1)];
    }

    // BuildRailStation params for rotation k: {corner_pt, dir, num, len}.
    static function _PlatformParams(k, spec) {
        local r1 = StationDT._Rot(spec.plat_c1[0], spec.plat_c1[1], k, spec);
        local r2 = StationDT._Rot(spec.plat_c2[0], spec.plat_c2[1], k, spec);
        local cx = r1[0] < r2[0] ? r1[0] : r2[0];
        local cy = r1[1] < r2[1] ? r1[1] : r2[1];
        local dir = (k % 2 == 0) ? AIRail.RAILTRACK_NE_SW : AIRail.RAILTRACK_NW_SE;
        return { corner = [cx, cy], dir = dir, num = spec.num, len = spec.len };
    }

    static function CanBuild(ox, oy, k, spec, join_id = null) {
        local jid = (join_id == null) ? AIStation.STATION_NEW : join_id;
        local f = StationDT._Foot(ox, oy, k, spec);
        local lo = AITileList();
        lo.AddRectangle(f[0], f[1]);
        if (lo.IsEmpty()) return false;
        local maxh = 0; local minh = 99;
        foreach (t, _ in lo) {
            if (!AIMap.IsValidTile(t) || AITile.IsWaterTile(t)) return false;
            if (AIIndustry.IsValidIndustry(AIIndustry.GetIndustryID(t))) return false;   // not through an industry
            local hh = AITile.GetMaxHeight(t);
            if (hh > maxh) maxh = hh;
            if (hh < minh) minh = hh;
        }
        if (maxh - minh > 2) return false;
        local pp = StationDT._PlatformParams(k, spec);
        local tm = AITestMode();
        return AIRail.BuildRailStation(StationDT._Tile(ox, oy, pp.corner), pp.dir, pp.num, pp.len, jid);
    }

    // How well the station serves the cargo (real GetCargoProduction/Acceptance per
    // platform tile). 0 = doesn't serve it.
    static function CoverScore(ox, oy, k, cargo, is_source, spec) {
        local cov = AIStation.GetCoverageRadius(AIStation.STATION_TRAIN);
        local n = 0;
        for (local px = spec.plat_c1[0]; px <= spec.plat_c2[0]; px++)
            for (local py = spec.plat_c1[1]; py <= spec.plat_c2[1]; py++) {
                local t = StationDT._Tile(ox, oy, StationDT._Rot(px, py, k, spec));
                local v = is_source
                    ? AITile.GetCargoProduction(t, cargo, 1, 1, cov)
                    : AITile.GetCargoAcceptance(t, cargo, 1, 1, cov);
                if (v >= (is_source ? 1 : 8)) n++;
            }
        return n;
    }

    // Build at origin (ox,oy), rotation k, using `spec`. join_id != STATION_NEW
    // merges this physical station into an existing station id (one logical station,
    // separate platform-lines). Returns record or null.
    static function Build(ox, oy, k, cargo, is_source, spec, join_id = null) {
        local jid = (join_id == null) ? AIStation.STATION_NEW : join_id;
        local f = StationDT._Foot(ox, oy, k, spec);
        AITile.LevelTiles(f[0], f[1]);

        local pp = StationDT._PlatformParams(k, spec);
        local corner = StationDT._Tile(ox, oy, pp.corner);
        local built = (cargo == null)
            ? AIRail.BuildRailStation(corner, pp.dir, pp.num, pp.len, jid)
            : AIRail.BuildNewGRFRailStation(corner, pp.dir, pp.num, pp.len, jid,
                  cargo, AIIndustryType.INDUSTRYTYPE_UNKNOWN, AIIndustryType.INDUSTRYTYPE_UNKNOWN, 500, is_source);
        if (!built) {
            Log.Warn(Log.PHASE_STATION, "[dt] platform build failed: " + AIError.GetLastErrorString());
            return null;
        }
        local station_id = AIStation.GetStationID(corner);

        // Stamp the throat (entries in [throat_min..throat_max]; drop signals/bridges
        // whose far end is past the trim), rotated by k.
        local throat = [];
        foreach (e in spec.throat) {
            if (e[1] < spec.throat_min || e[1] > spec.throat_max) continue;
            if ((e[0] == "S" || e[0] == "B") && e[3] > spec.throat_max) continue;
            throat.push(e);
        }
        local origin = AIMap.GetTileIndex(ox, oy);
        JunctionBuilder.StampList(origin, JunctionBuilder.Rotate(throat, k));

        // Optional station depot (dead-end siding), rotated by k.
        local depot = null;
        if (spec.depot != null) {
            local dp = StationDT._Rot(spec.depot[0], spec.depot[1], k, spec);
            local df = StationDT._Rot(spec.depot_front[0], spec.depot_front[1], k, spec);
            depot = StationDT._Tile(ox, oy, dp);
            if (!AIRail.BuildRailDepot(depot, StationDT._Tile(ox, oy, df))
                && AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
                Log.Warn(Log.PHASE_DEPOT, "[dt] station depot failed: " + AIError.GetLastErrorString());
                depot = null;
            }
        }

        local maP = StationDT._Rot(spec.main_a[0], spec.main_a[1], k, spec);
        local maV = StationDT._Rot(spec.main_a_prev[0], spec.main_a_prev[1], k, spec);
        local mbP = StationDT._Rot(spec.main_b[0], spec.main_b[1], k, spec);
        local mbV = StationDT._Rot(spec.main_b_prev[0], spec.main_b_prev[1], k, spec);

        Log.Info(Log.PHASE_STATION, "[dt] built id=" + station_id + " at (" + ox + "," + oy + ") k=" + k
            + " num=" + spec.num + " throat=" + throat.len());
        return {
            station_id = station_id, platform_tile = corner, tile = corner,
            main_a = StationDT._Tile(ox, oy, maP), main_a_prev = StationDT._Tile(ox, oy, maV),
            main_b = StationDT._Tile(ox, oy, mbP), main_b_prev = StationDT._Tile(ox, oy, mbV),
            depot = depot,
            ox = ox, oy = oy, k = k, foot_w = spec.foot_w, foot_h = spec.foot_h,
        };
    }

    // Demolish a built station (cleanup). foot dims stored on the record.
    static function Demolish(st) {
        if (st == null) return;
        local fw = ("foot_w" in st) ? st.foot_w : 14;
        local fh = ("foot_h" in st) ? st.foot_h : 4;
        local k  = ("k" in st) ? st.k : 0;
        local d  = (k % 2 == 0) ? [fw, fh] : [fh, fw];
        local a = AIMap.GetTileIndex(st.ox, st.oy);
        local b = AIMap.GetTileIndex(st.ox + d[0] - 1, st.oy + d[1] - 1);
        AIRail.RemoveRailStationTileRectangle(a, b, false);
        local lo = AITileList();
        lo.AddRectangle(a, b);
        foreach (t, _ in lo) if (AIRail.IsRailTile(t)) AITile.DemolishTile(t);
    }

    // Rotation whose throat/main exit points from `self` toward `partner`.
    static function DirToward(self_tile, partner_tile) {
        local dx = AIMap.GetTileX(partner_tile) - AIMap.GetTileX(self_tile);
        local dy = AIMap.GetTileY(partner_tile) - AIMap.GetTileY(self_tile);
        if (abs(dx) >= abs(dy)) return dx >= 0 ? 0 : 2;
        return dy >= 0 ? 1 : 3;
    }
}
