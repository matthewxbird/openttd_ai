// src/station_dt.nut
// SMART TERMINUS (Phase 11 rail rewrite) - a faithful port of AAAHogEx's
// SmartStation (_aaahogex_ref/station.nut:3735). This is the KEYSTONE that busts
// our ~2-train/route deadlock cap.
//
// WHY this shape: our old terminus reverses trains through a SHARED two-way-PBS
// crossover, which deadlocks past ~2 trains (the measured value ceiling). AAHOG's
// SmartStation is ALSO a reversing terminus, but its throat SEPARATES the arrival
// line (column 0) from the departure line (column 1) and GRADE-SEPARATES them with
// a BRIDGE so an arriving and a departing train can NEVER conflict. With N
// platforms + a conflict-free throat, a route runs many trains without deadlock.
//
// Local coord system (AAHOG's At/MoveTile, ported exactly). A station has:
//   platformTile : NW corner of the platform rectangle (engine-facing rules below)
//   dir          : one of DIR_SE/SW/NW/NE - which way the throat (and main line)
//                  points AWAY from the platforms
//   num          : platform count (2 or 3)
//   len          : platform length (tiles)
// At(x,y) maps station-local (x = across platforms 0..num-1, y = along length;
// y=0 is the platform's stop end, y grows toward the throat/main line) to a world
// tile, rotated by dir. The throat rails sit at y in [len .. len+6].
//
// Build() lays: platforms (one BuildRailStation call) -> throat rails (GetRails)
// -> the grade-separation bridge -> depot (num==3) -> PBS signals. Returns a
// record exposing the arrival + departure connection tiles for the main-line
// pathfinder, or null if anything failed (caller cleans up / falls back).

class StationDT {
    static DIR_NW = 0;
    static DIR_NE = 1;
    static DIR_SW = 2;
    static DIR_SE = 3;

    // MoveTile: station-local (dx,dy) -> world tile offset from `tile`, per dir.
    // Ported from AAHOG HgStation.MoveTile (station.nut:2334).
    static function _Move(tile, dir, dx, dy) {
        switch (dir) {
            case StationDT.DIR_SE: return tile + AIMap.GetTileIndex(dx, dy);
            case StationDT.DIR_SW: return tile + AIMap.GetTileIndex(dy, -dx);
            case StationDT.DIR_NW: return tile + AIMap.GetTileIndex(-dx, -dy);
            case StationDT.DIR_NE: return tile + AIMap.GetTileIndex(-dy, dx);
        }
        return tile;
    }

    // originTile from platformTile + dir (SmartStation constructor, station.nut:2857).
    static function _Origin(platformTile, dir, num, len) {
        switch (dir) {
            case StationDT.DIR_SE: return StationDT._Move(platformTile, dir, 0, 0);
            case StationDT.DIR_NW: return StationDT._Move(platformTile, dir, 1 - num, -len + 1);
            case StationDT.DIR_NE: return StationDT._Move(platformTile, dir, 0, -len + 1);
            case StationDT.DIR_SW: return StationDT._Move(platformTile, dir, 1 - num, 0);
        }
        return platformTile;
    }

    // The rail track axis the platforms lie on (AIRail.RAILTRACK_*).
    static function _PlatformTrack(dir) {
        return (dir == StationDT.DIR_SE || dir == StationDT.DIR_NW)
            ? AIRail.RAILTRACK_NW_SE : AIRail.RAILTRACK_NE_SW;
    }

    // Throat rail segments (AAHOG SmartStation.GetRails, station.nut:3800). Each
    // entry is [from,mid,to] in throat-local coords; actual y is offset by `len`.
    static function _ThroatRails(num) {
        local rails = [
            [[0,-1],[0,0],[0,1]],
            [[1,-1],[1,0],[1,1]],
            [[0,0],[0,1],[0,2]],
            [[0,0],[0,1],[1,1]],
            [[1,0],[1,1],[1,2]],
            [[0,1],[1,1],[1,2]],
            [[1,0],[1,1],[2,1]],
            [[1,1],[2,1],[2,2]],
            [[0,1],[0,2],[0,3]],
            [[2,1],[2,2],[2,3]],
            [[0,2],[0,3],[0,4]],
            [[2,3],[1,3],[1,4]],
            [[2,2],[2,3],[1,3]],
            [[0,3],[0,4],[0,5]],
            [[1,4],[0,4],[0,5]],
            [[1,3],[1,4],[0,4]],
        ];
        if (num == 3) {
            rails.append([[2,-1],[2,0],[2,1]]);
            rails.append([[2,1],[1,1],[1,2]]);
            rails.append([[2,0],[2,1],[1,1]]);
            rails.append([[2,0],[2,1],[2,2]]);
            rails.append([[2,2],[2,3],[2,4]]);   // for depot
        }
        return rails;
    }

    // Convenience: world tile at station-local (x,y).
    static function _At(origin, dir, x, y) {
        return StationDT._Move(origin, dir, x, y);
    }

    // The footprint bounding corners (covers platforms + throat) for leveling.
    static function _FootprintCorners(origin, dir, num, len) {
        local far_x = (num - 1 > 2) ? (num - 1) : 2;
        return [StationDT._At(origin, dir, 0, 0),
                StationDT._At(origin, dir, far_x, len + 6)];
    }

    // DRY-RUN: cheap pre-flight before spend. The footprint must be roughly FLAT
    // (the grade-separation bridge needs equal-height heads); the real Build levels
    // it, but a site with too much relief can't be levelled, so reject early.
    static function CanBuild(platformTile, dir, num, len) {
        local origin = StationDT._Origin(platformTile, dir, num, len);
        local c = StationDT._FootprintCorners(origin, dir, num, len);
        // Build a tile list over the footprint rectangle; reject if relief > 2.
        local lo = AITileList();
        lo.AddRectangle(c[0], c[1]);
        if (lo.IsEmpty()) return false;
        local maxh = 0; local minh = 99;
        foreach (t, _ in lo) {
            local h = AITile.GetMaxHeight(t);
            if (h > maxh) maxh = h;
            if (h < minh) minh = h;
        }
        if (maxh - minh > 2) return false;   // too hilly to level cleanly
        local tm = AITestMode();
        return AIRail.BuildRailStation(platformTile, StationDT._PlatformTrack(dir), num, len, AIStation.STATION_NEW);
    }

    // Build for real. Returns a station record or null.
    //   { station_id, dir, num, len, platform_tile, origin,
    //     arrival_tiles, departure_tiles, depot }
    // arrival_tiles[0] / departure_tiles[0] are the OUTERMOST throat tiles the
    // main line connects to (arrival = column 0 top, departure = column 1 top).
    static function Build(platformTile, dir, num, len, cargo, is_source) {
        local origin = StationDT._Origin(platformTile, dir, num, len);
        local track  = StationDT._PlatformTrack(dir);

        // 0. LEVEL the footprint (the throat bridge needs equal-height heads, and
        //    sloped ground fails the rail/station build). AAHOG levels before any
        //    build; AITile.LevelTiles flattens the rectangle to one height.
        local fc = StationDT._FootprintCorners(origin, dir, num, len);
        AITile.LevelTiles(fc[0], fc[1]);

        // 1. Platforms (one call builds the N x len block).
        local built = (cargo == null)
            ? AIRail.BuildRailStation(platformTile, track, num, len, AIStation.STATION_NEW)
            : AIRail.BuildNewGRFRailStation(platformTile, track, num, len, AIStation.STATION_NEW,
                  cargo, AIIndustryType.INDUSTRYTYPE_UNKNOWN, AIIndustryType.INDUSTRYTYPE_UNKNOWN,
                  500, is_source);
        if (!built) {
            Log.Warn(Log.PHASE_STATION, "[dt] platform build failed: " + AIError.GetLastErrorString());
            return null;
        }
        local station_id = AIStation.GetStationID(platformTile);

        // 2. The grade-separation bridge over the throat (At(1,len+2)->At(1,len+5)).
        local bA = StationDT._At(origin, dir, 1, len + 2);
        local bB = StationDT._At(origin, dir, 1, len + 5);
        local blist = AIBridgeList_Length(AIMap.DistanceManhattan(bA, bB) + 1);
        if (blist.IsEmpty()
            || !AIBridge.BuildBridge(AIVehicle.VT_RAIL, blist.Begin(), bA, bB)) {
            if (AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
                Log.Warn(Log.PHASE_STATION, "[dt] throat bridge failed: " + AIError.GetLastErrorString());
                StationDT._Demolish(platformTile, origin, dir, num, len);
                return null;
            }
        }

        // 3. Throat rails. Clear any obstacle (trees/objects) on each tile first
        //    so a non-clear tile doesn't fail the rail (ERR_AREA_NOT_CLEAR).
        local okc = 0; local fail = 0; local first_err = "";
        foreach (seg in StationDT._ThroatRails(num)) {
            local a = StationDT._At(origin, dir, seg[0][0], seg[0][1] + len);
            local b = StationDT._At(origin, dir, seg[1][0], seg[1][1] + len);
            local c = StationDT._At(origin, dir, seg[2][0], seg[2][1] + len);
            foreach (t in [a, b, c]) {
                if (!AITile.IsBuildable(t) && !AIRail.IsRailTile(t) && !AITile.IsStationTile(t)) {
                    AITile.DemolishTile(t);
                }
            }
            if (AIRail.BuildRail(a, b, c)
                || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) {
                okc++;
            } else {
                fail++;
                if (first_err == "") first_err = AIError.GetLastErrorString();
            }
        }
        if (fail > 0) {
            Log.Warn(Log.PHASE_STATION, "[dt] throat rails fail=" + fail + " ok=" + okc
                + " firstErr=" + first_err);
            StationDT._Demolish(platformTile, origin, dir, num, len);
            return null;
        }

        // 4. Depot (num==3) at At(2,len+4) facing At(2,len+3).
        local depot = null;
        if (num == 3) {
            depot = StationDT._At(origin, dir, 2, len + 4);
            local front = StationDT._At(origin, dir, 2, len + 3);
            if (!AIRail.BuildRailDepot(depot, front)
                && AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
                Log.Warn(Log.PHASE_DEPOT, "[dt] depot failed: " + AIError.GetLastErrorString());
                depot = null;   // route can still build a main-line depot
            }
        }

        // 5. PBS signal at each platform exit (At(x,len)->At(x,len-1)).
        for (local x = 0; x < num; x++) {
            local s  = StationDT._At(origin, dir, x, len);
            local sf = StationDT._At(origin, dir, x, len - 1);
            AIRail.BuildSignal(s, sf, AIRail.SIGNALTYPE_PBS);
        }

        // Connection tiles for the main-line pathfinder.
        local arrival = [
            StationDT._At(origin, dir, 0, len + 5),
            StationDT._At(origin, dir, 0, len + 4),
            StationDT._At(origin, dir, 0, len + 3),
        ];
        local departure = [
            StationDT._At(origin, dir, 1, len + 6),
            StationDT._At(origin, dir, 1, len + 5),
            StationDT._At(origin, dir, 1, len + 2),
        ];
        Log.Info(Log.PHASE_STATION, "[dt] built station id=" + station_id
            + " dir=" + dir + " num=" + num + " len=" + len + " rails ok=" + okc
            + (depot != null ? " depot" : ""));
        return {
            station_id = station_id,
            dir = dir, num = num, len = len,
            platform_tile = platformTile, origin = origin,
            arrival_tiles = arrival,
            departure_tiles = departure,
            depot = depot,
            // legacy fields some callers read:
            tile = platformTile,
        };
    }

    // Tear down a partially/fully built station (cleanup on failure).
    static function _Demolish(platformTile, origin, dir, num, len) {
        local corner = StationDT._At(origin, dir, num - 1, len - 1);
        AIRail.RemoveRailStationTileRectangle(platformTile, platformTile, false);
        foreach (seg in StationDT._ThroatRails(num)) {
            local a = StationDT._At(origin, dir, seg[0][0], seg[0][1] + len);
            local b = StationDT._At(origin, dir, seg[1][0], seg[1][1] + len);
            local c = StationDT._At(origin, dir, seg[2][0], seg[2][1] + len);
            AIRail.RemoveRail(a, b, c);
        }
        local bA = StationDT._At(origin, dir, 1, len + 2);
        AIBridge.RemoveBridge(bA);
        if (num == 3) AITile.DemolishTile(StationDT._At(origin, dir, 2, len + 4));
    }
}
