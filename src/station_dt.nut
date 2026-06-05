// src/station_dt.nut
// SMART TERMINUS v2 (Phase 11) - built from AAHOG's REAL captured throat
// (Captures.WronstonThroat(), scanned in-game, replays ok=62 fail=0).
//
// AAHOG terminus = 3 stub platforms whose throat MERGES into a double main via
// corner turnouts + a short grade-separation BRIDGE + combo/PBS signals, so an
// arriving and a departing train never conflict (no reversing-throat deadlock).
//
// Capture frame (0-origin, k=0 = main exits +X/east):
//   platforms: 3 rows dy1..3, straight along X for dx0..5; dx6 = throat entry.
//   throat+bridge: dx6..12.  double main: rows dy1 (ARRIVAL, west-facing signals)
//   and dy2 (DEPARTURE, east-facing PBS). main connect tiles (17,1)/(17,2).
//
// ROTATION: the whole layout (throat descriptor + platform rect + main anchors)
// rotates k*90 CW so a station's throat/main can FACE its partner:
//   k=0 main +X(east)  k=1 +Y(south)  k=2 -X(west)  k=3 -Y(north).
// Gated behind MvBAI.USE_RAIL2.

class StationDT {
    static PLAT_NUM = 3;
    static PLAT_LEN = 6;
    static FOOT_W = 19;   // capture width  (dx 0..18)
    static FOOT_H = 4;    // capture height (dy 0..3)
    static THROAT_MIN_DX = 6;

    // k=0 anchors (capture frame):
    static PLAT_C1 = [0, 1];   static PLAT_C2 = [5, 3];   // platform rect corners
    static MAIN_A  = [17, 1];  static MAIN_A_PREV = [16, 1];  // ARRIVAL track
    static MAIN_B  = [17, 2];  static MAIN_B_PREV = [16, 2];  // DEPARTURE track

    // Rotate a point (x,y) by k*90 CW within the FOOT_W x FOOT_H grid (grid dims
    // swap each 90). Returns [x,y].
    static function _Rot(x, y, k) {
        local w = StationDT.FOOT_W; local h = StationDT.FOOT_H;
        local px = x; local py = y;
        for (local i = 0; i < (k % 4); i++) {
            local nx = h - 1 - py;
            local ny = px;
            px = nx; py = ny;
            local t = w; w = h; h = t;
        }
        return [px, py];
    }
    // Footprint dims after k rotations.
    static function _FootDims(k) {
        return (k % 2 == 0) ? [StationDT.FOOT_W, StationDT.FOOT_H]
                            : [StationDT.FOOT_H, StationDT.FOOT_W];
    }
    static function _Tile(ox, oy, pt) { return AIMap.GetTileIndex(ox + pt[0], oy + pt[1]); }

    static function _Foot(ox, oy, k) {
        local d = StationDT._FootDims(k);
        return [AIMap.GetTileIndex(ox, oy), AIMap.GetTileIndex(ox + d[0] - 1, oy + d[1] - 1)];
    }

    // The BuildRailStation params for rotation k: {corner_pt, dir, num, len}.
    static function _PlatformParams(k) {
        local r1 = StationDT._Rot(StationDT.PLAT_C1[0], StationDT.PLAT_C1[1], k);
        local r2 = StationDT._Rot(StationDT.PLAT_C2[0], StationDT.PLAT_C2[1], k);
        local cx = r1[0] < r2[0] ? r1[0] : r2[0];
        local cy = r1[1] < r2[1] ? r1[1] : r2[1];
        // k even: track along X (NE_SW); k odd: along Y (NW_SE).
        local dir = (k % 2 == 0) ? AIRail.RAILTRACK_NE_SW : AIRail.RAILTRACK_NW_SE;
        return { corner = [cx, cy], dir = dir, num = StationDT.PLAT_NUM, len = StationDT.PLAT_LEN };
    }

    static function CanBuild(ox, oy, k) {
        local f = StationDT._Foot(ox, oy, k);
        local lo = AITileList();
        lo.AddRectangle(f[0], f[1]);
        if (lo.IsEmpty()) return false;
        local maxh = 0; local minh = 99;
        foreach (t, _ in lo) {
            if (!AIMap.IsValidTile(t) || AITile.IsWaterTile(t)) return false;
            local hh = AITile.GetMaxHeight(t);
            if (hh > maxh) maxh = hh;
            if (hh < minh) minh = hh;
        }
        if (maxh - minh > 2) return false;
        local pp = StationDT._PlatformParams(k);
        local tm = AITestMode();
        return AIRail.BuildRailStation(StationDT._Tile(ox, oy, pp.corner), pp.dir, pp.num, pp.len, AIStation.STATION_NEW);
    }

    // Build at origin (ox,oy), rotation k. Returns record or null.
    static function Build(ox, oy, k, cargo, is_source) {
        local f = StationDT._Foot(ox, oy, k);
        AITile.LevelTiles(f[0], f[1]);

        local pp = StationDT._PlatformParams(k);
        local corner = StationDT._Tile(ox, oy, pp.corner);
        local built = (cargo == null)
            ? AIRail.BuildRailStation(corner, pp.dir, pp.num, pp.len, AIStation.STATION_NEW)
            : AIRail.BuildNewGRFRailStation(corner, pp.dir, pp.num, pp.len, AIStation.STATION_NEW,
                  cargo, AIIndustryType.INDUSTRYTYPE_UNKNOWN, AIIndustryType.INDUSTRYTYPE_UNKNOWN, 500, is_source);
        if (!built) {
            Log.Warn(Log.PHASE_STATION, "[dt] platform build failed: " + AIError.GetLastErrorString());
            return null;
        }
        local station_id = AIStation.GetStationID(corner);

        // Stamp the throat: capture entries with THROAT_MIN_DX <= dx <= 17, rotated
        // by k. We DROP dx18 (AAHOG's post-throat curve where its main turns north):
        // it blocks the east neighbour of our connect tiles (17,1)/(17,2), so the
        // long-haul main can't exit straight. Dropping it leaves clean parallel ends
        // with open ground east -> reliable connect.
        local throat = [];
        foreach (e in Captures.WronstonThroat()) {
            if (e[1] >= StationDT.THROAT_MIN_DX && e[1] <= 17) throat.push(e);
        }
        local origin = AIMap.GetTileIndex(ox, oy);
        JunctionBuilder.StampList(origin, JunctionBuilder.Rotate(throat, k));

        local maP = StationDT._Rot(StationDT.MAIN_A[0], StationDT.MAIN_A[1], k);
        local maV = StationDT._Rot(StationDT.MAIN_A_PREV[0], StationDT.MAIN_A_PREV[1], k);
        local mbP = StationDT._Rot(StationDT.MAIN_B[0], StationDT.MAIN_B[1], k);
        local mbV = StationDT._Rot(StationDT.MAIN_B_PREV[0], StationDT.MAIN_B_PREV[1], k);

        Log.Info(Log.PHASE_STATION, "[dt] built id=" + station_id + " at (" + ox + "," + oy + ") k=" + k
            + " throat=" + throat.len());
        return {
            station_id = station_id, platform_tile = corner, tile = corner,
            main_a = StationDT._Tile(ox, oy, maP), main_a_prev = StationDT._Tile(ox, oy, maV),
            main_b = StationDT._Tile(ox, oy, mbP), main_b_prev = StationDT._Tile(ox, oy, mbV),
            ox = ox, oy = oy, k = k,
        };
    }

    static function Demolish(st) {
        if (st == null) return;
        local f = StationDT._Foot(st.ox, st.oy, ("k" in st) ? st.k : 0);
        AIRail.RemoveRailStationTileRectangle(f[0], f[1], false);
        local lo = AITileList();
        lo.AddRectangle(f[0], f[1]);
        foreach (t, _ in lo) if (AIRail.IsRailTile(t)) AITile.DemolishTile(t);
    }

    // Which rotation makes the main/throat exit point toward `partner` from `self`.
    static function DirToward(self_tile, partner_tile) {
        local dx = AIMap.GetTileX(partner_tile) - AIMap.GetTileX(self_tile);
        local dy = AIMap.GetTileY(partner_tile) - AIMap.GetTileY(self_tile);
        if (abs(dx) >= abs(dy)) return dx >= 0 ? 0 : 2;   // +X=k0, -X=k2
        return dy >= 0 ? 1 : 3;                            // +Y=k1, -Y=k3
    }
}
