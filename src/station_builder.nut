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

        // Compute front_tile: one tile in the "forward" direction from
        // the entrance. We use the tile's offset along `direction`.
        local front_tile = StationBuilder._FrontTile(tile, direction);
        local depot_tile = StationBuilder._DepotTile(tile, direction);

        // Try to place a depot. If it fails (terrain etc.), we keep the
        // station but report no depot - trains can still run on an
        // explicit depot built later.
        local depot_ok = AIRail.BuildRailDepot(depot_tile, tile);
        if (!depot_ok) {
            Log.Warn(Log.PHASE_STATION,
                "Station built but depot failed: " + AIError.GetLastErrorString());
            depot_tile = null;
        }

        Log.Info(Log.PHASE_STATION,
            "Built " + (is_source ? "source" : "dest") + " station id=" + station_id
            + " at tile=" + tile + " dir=" + direction
            + (depot_tile != null ? " depot=" + depot_tile : " (no depot)"));

        return {
            station_id = station_id,
            tile       = tile,
            front_tile = front_tile,
            depot_tile = depot_tile,
            direction  = direction,
        };
    }

    // One tile in front of the station, along the track direction.
    static function _FrontTile(tile, direction) {
        // Offsets per RAILTRACK enum: NE_SW points along x (east-west),
        // NW_SE points along y (north-south).
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return tile + AIMap.GetTileIndex(StationBuilder.PLATFORM_LENGTH, 0);
        }
        return tile + AIMap.GetTileIndex(0, StationBuilder.PLATFORM_LENGTH);
    }

    // One tile beyond the back end (opposite of front) - good spot for a depot.
    static function _DepotTile(tile, direction) {
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return tile + AIMap.GetTileIndex(-1, 0);
        }
        return tile + AIMap.GetTileIndex(0, -1);
    }
}
