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
    // partner_tile = location of the OTHER industry on this route; the
    // station throat is oriented to face it so the main line fans straight
    // out toward the partner instead of wrapping around the back.
    static function BuildAt(industry_id, cargo, is_source, partner_tile) {
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
                local result = StationBuilder._TryBuild(tile, dir, industry_id, cargo, is_source, partner_tile);
                if (result != null) return result;
            }
        }

        Log.Warn(Log.PHASE_STATION, "No suitable station spot at " + label + " " + industry_id);
        return null;
    }

    // Internal: attempt one (tile, direction) pair. Returns result or null.
    static function _TryBuild(tile, direction, industry_id, cargo, is_source, partner_tile) {
        // Quick reject: target tile must be buildable land.
        if (!AITile.IsBuildable(tile)) return null;

        // We rely on AIRail.BuildRailStation to validate the full footprint.
        local ok = AIRail.BuildRailStation(
            tile,
            direction,
            StationBuilder.NUM_PLATFORMS,
            StationBuilder.PLATFORM_LENGTH,
            AIStation.STATION_NEW
        );
        if (!ok) return null;

        local station_id = AIStation.GetStationID(tile);

        // A rail station is open at BOTH ends. For a terminus we pick ONE end
        // as the "throat" (where the main line connects) and leave the other
        // closed. Choose the end whose exit faces the partner industry, so the
        // line runs straight toward it instead of looping around the back.
        local axis = StationBuilder._AxisStep(direction);

        // Plus end: exit beyond tile + LEN*axis.  Minus end: exit before tile.
        local plus_front  = tile + axis * StationBuilder.PLATFORM_LENGTH;
        local plus_enter  = tile + axis * (StationBuilder.PLATFORM_LENGTH - 1);
        local minus_front = tile - axis;
        local minus_enter = tile;

        local use_minus =
            AIMap.DistanceManhattan(minus_front, partner_tile)
          < AIMap.DistanceManhattan(plus_front,  partner_tile);

        local front_tile = use_minus ? minus_front : plus_front;
        local enter_tile = use_minus ? minus_enter : plus_enter;

        // The two platforms sit side-by-side (perpendicular to the axis), so
        // platform 1's throat tiles are platform 0's offset sideways by one.
        local perp = StationBuilder._PerpStep(direction);

        // Depot is NOT built here; DepotBuilder places spur depots off the
        // mainline later. The throat crossover is built by Terminus.

        Log.Info(Log.PHASE_STATION,
            "Built " + (is_source ? "source" : "dest") + " station id=" + station_id
            + " at tile=" + tile + " dir=" + direction
            + " throat=" + (use_minus ? "minus" : "plus") + " toward partner");

        return {
            station_id   = station_id,
            tile         = tile,
            front_tile   = front_tile,         // platform 0 throat
            enter_tile   = enter_tile,
            front_tile_b = front_tile + perp,  // platform 1 throat
            enter_tile_b = enter_tile + perp,
            direction    = direction,
        };
    }

    // One-tile step ALONG the track axis, pointing toward the plus end.
    static function _AxisStep(direction) {
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return AIMap.GetTileIndex(1, 0);  // axis along x
        }
        return AIMap.GetTileIndex(0, 1);      // axis along y
    }

    // One-tile step perpendicular to the track axis (separates the 2 platforms).
    static function _PerpStep(direction) {
        if (direction == AIRail.RAILTRACK_NE_SW) {
            return AIMap.GetTileIndex(0, 1);  // axis along x -> platforms along y
        }
        return AIMap.GetTileIndex(1, 0);      // axis along y -> platforms along x
    }
}
