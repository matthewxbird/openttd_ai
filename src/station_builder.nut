// src/station_builder.nut
// Find a flat 2xN strip near an industry and build a double-track
// terminus station there, with a depot adjacent to one platform.
//
// Returns a table:
//   { station_id, tile, front_tile, depot_tile, direction }
// or null if no suitable spot found.
//
// "front_tile" is the tile in front of the station entrance - this is
// what the pathfinder uses as the connection point.


class StationBuilder {

    static PLATFORM_LENGTH = 5;
    static NUM_PLATFORMS   = 2;       // double-track => 2 platforms
    static SEARCH_RADIUS   = 5;       // tiles around industry to consider

    // Build a station at a producer.  `is_source = true`.
    // Build a station at an accepter. `is_source = false`.
    static function BuildAt(industry_id, cargo, is_source) {
        local label = is_source ? "producer" : "accepter";
        local tiles;
        if (is_source) tiles = AITileList_IndustryProducing(industry_id, StationBuilder.SEARCH_RADIUS);
        else           tiles = AITileList_IndustryAccepting(industry_id, StationBuilder.SEARCH_RADIUS);

        if (tiles.IsEmpty()) {
            Log.Warn(Log.PHASE_STATION, "No tiles near " + label + " " + industry_id);
            return null;
        }

        // Try each candidate tile, in each of the two orientations.
        // Orientation = "rail track direction at the station".
        local dirs = [AIRail.RAILTRACK_NE_SW, AIRail.RAILTRACK_NW_SE];

        foreach (tile, _ in tiles) {
            foreach (dir in dirs) {
                local result = StationBuilder._TryBuild(tile, dir, industry_id, cargo, is_source);
                if (result != null) return result;
            }
        }

        Log.Warn(Log.PHASE_STATION, "No suitable station spot at " + label + " " + industry_id);
        return null;
    }

    // Internal: attempt one (tile, direction) pair. Returns result or null.
    static function _TryBuild(tile, direction, industry_id, cargo, is_source) {
        // Quick reject: target tile must be buildable land.
        if (!AITile.IsBuildable(tile)) return null;

        // We rely on AIRail.BuildRailStation to validate the full footprint.
        // If it succeeds, we then place a depot one tile beyond the
        // station's "back" end.
        local ok = AIRail.BuildRailStation(
            tile,
            direction,
            StationBuilder.NUM_PLATFORMS,
            StationBuilder.PLATFORM_LENGTH,
            AIStation.STATION_NEW
        );
        if (!ok) return null;

        local station_id = AIStation.GetStationID(tile);

        // front_tile: first tile just OUTSIDE the station exit.
        // enter_tile: last platform tile, ADJACENT to front_tile. The
        // pathfinder needs front + an adjacent prev so its first step is
        // length 1 — passing the station origin (PLATFORM_LENGTH away)
        // makes the first segment look like a bridge and the build fails.
        local front_tile = StationBuilder._FrontTile(tile, direction);
        local enter_tile = StationBuilder._EnterTile(tile, direction);

        // Depot is NOT built here. Terminus depots at the station end force
        // trains to reverse and block the platform. DepotBuilder places a
        // spur depot off the mainline instead, after tracks are laid.

        Log.Info(Log.PHASE_STATION,
            "Built " + (is_source ? "source" : "dest") + " station id=" + station_id
            + " at tile=" + tile + " dir=" + direction);

        return {
            station_id = station_id,
            tile       = tile,
            front_tile = front_tile,
            enter_tile = enter_tile,
            direction  = direction,
        };
    }

    // One tile in front of the station exit (just outside the platforms).
    static function _FrontTile(tile, direction) {
        // Offsets per RAILTRACK enum: NE_SW points along x (east-west),
        // NW_SE points along y (north-south).
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return tile + AIMap.GetTileIndex(StationBuilder.PLATFORM_LENGTH, 0);
        }
        return tile + AIMap.GetTileIndex(0, StationBuilder.PLATFORM_LENGTH);
    }

    // Last platform tile, adjacent to front_tile (one step back from front).
    // Used as the pathfinder's "prev" so the first step length is 1.
    static function _EnterTile(tile, direction) {
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return tile + AIMap.GetTileIndex(StationBuilder.PLATFORM_LENGTH - 1, 0);
        }
        return tile + AIMap.GetTileIndex(0, StationBuilder.PLATFORM_LENGTH - 1);
    }
}
