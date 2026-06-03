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

    static PLATFORM_LENGTH = 7;       // long platforms => long trains => more cargo
    static NUM_PLATFORMS   = 2;       // double-track => 2 platforms
    static SEARCH_RADIUS   = 6;       // tiles around industry to consider

    // Build a station at a producer.  `is_source = true`.
    // Build a station at an accepter. `is_source = false`.
    // partner_tile = location of the OTHER industry on this route; the
    // station throat is oriented to face it so the main line fans straight
    // out toward the partner instead of wrapping around the back.
    static function BuildAt(industry_id, cargo, is_source, partner_tile, roro = false) {
        local label = is_source ? "producer" : "accepter";
        local tiles;
        if (is_source) tiles = AITileList_IndustryProducing(industry_id, StationBuilder.SEARCH_RADIUS);
        else           tiles = AITileList_IndustryAccepting(industry_id, StationBuilder.SEARCH_RADIUS);

        if (tiles.IsEmpty()) {
            Log.Warn(Log.PHASE_STATION, "No tiles near " + label + " " + industry_id);
            return null;
        }

        // Orient the station so its PLATFORM AXIS points toward the partner.
        // The throat then fans straight out toward the partner and the two
        // parallel tracks run alongside each other without crossing. Pick the
        // orientation whose axis matches the dominant component of the vector
        // from this industry to the partner; try the other only as a fallback.
        local self_tile = AIIndustry.GetLocation(industry_id);

        // Try the tiles CLOSEST to the industry first, so the station hugs it
        // and the catchment area covers as much of the industry as possible
        // (instead of landing on the first buildable tile, which can be far off
        // and miss the production).
        tiles.Valuate(AIMap.DistanceManhattan, self_tile);
        tiles.Sort(AIList.SORT_BY_VALUE, true);   // ascending: nearest first

        local dx = AIMap.GetTileX(partner_tile) - AIMap.GetTileX(self_tile);
        local dy = AIMap.GetTileY(partner_tile) - AIMap.GetTileY(self_tile);
        local dirs = (abs(dx) >= abs(dy))
            ? [AIRail.RAILTRACK_NE_SW, AIRail.RAILTRACK_NW_SE]   // mostly east-west
            : [AIRail.RAILTRACK_NW_SE, AIRail.RAILTRACK_NE_SW];  // mostly north-south

        // Orientation OUTER, tiles INNER: exhaust every candidate tile in the
        // partner-facing orientation before falling back to the other.
        foreach (dir in dirs) {
            foreach (tile, _ in tiles) {
                local result = StationBuilder._TryBuild(tile, dir, industry_id, cargo, is_source, partner_tile, roro);
                if (result != null) return result;
            }
        }

        Log.Warn(Log.PHASE_STATION, "No suitable station spot at " + label + " " + industry_id);
        return null;
    }

    // Demolish a station we built (used when cleaning up an abandoned route).
    // Removes the whole NUM_PLATFORMS x PLATFORM_LENGTH footprint.
    static function Remove(st) {
        if (st == null) return;
        local axis = StationBuilder._AxisStep(st.direction);
        local perp = StationBuilder._PerpStep(st.direction);
        local far  = st.tile + axis * (StationBuilder.PLATFORM_LENGTH - 1)
                            + perp * (StationBuilder.NUM_PLATFORMS - 1);
        if (!AIRail.RemoveRailStationTileRectangle(st.tile, far, false)) {
            AITile.DemolishTile(st.tile);   // fallback
        }
    }

    static TOWN_RADIUS = 12;   // search this far around a town centre for a goods station

    // Build a station IN A TOWN to receive end-chain cargo (goods/food). Unlike
    // an industry, a town has no tile list; we search a square around the town
    // centre, keep tiles that actually accept the cargo (so it registers), and
    // build the nearest-to-centre one facing the partner. Returns a station
    // record (same shape as BuildAt) or null.
    static function BuildAtTown(town_id, cargo, partner_tile, roro = false) {
        local centre = AITown.GetLocation(town_id);
        local r      = StationBuilder.TOWN_RADIUS;
        local tiles  = AITileList();
        tiles.AddRectangle(centre - AIMap.GetTileIndex(r, r), centre + AIMap.GetTileIndex(r, r));

        // Keep tiles whose station coverage would accept the cargo (>= 8).
        local cov = AIStation.GetCoverageRadius(AIStation.STATION_TRAIN);
        tiles.Valuate(AITile.GetCargoAcceptance, cargo, 1, 1, cov);
        tiles.KeepAboveValue(7);
        if (tiles.IsEmpty()) {
            Log.Warn(Log.PHASE_STATION, "Town " + AITown.GetName(town_id) + " doesn't accept "
                + AICargo.GetCargoLabel(cargo) + " anywhere buildable.");
            return null;
        }

        // Nearest the town centre first (stations hug the town).
        tiles.Valuate(AIMap.DistanceManhattan, centre);
        tiles.Sort(AIList.SORT_BY_VALUE, true);

        local dx = AIMap.GetTileX(partner_tile) - AIMap.GetTileX(centre);
        local dy = AIMap.GetTileY(partner_tile) - AIMap.GetTileY(centre);
        local dirs = (abs(dx) >= abs(dy))
            ? [AIRail.RAILTRACK_NE_SW, AIRail.RAILTRACK_NW_SE]
            : [AIRail.RAILTRACK_NW_SE, AIRail.RAILTRACK_NE_SW];

        foreach (dir in dirs) {
            foreach (tile, _ in tiles) {
                local result = StationBuilder._TryBuild(tile, dir, town_id, cargo, false, partner_tile, roro);
                if (result != null) return result;
            }
        }
        Log.Warn(Log.PHASE_STATION, "No buildable goods station spot in town " + AITown.GetName(town_id));
        return null;
    }

    // Look-ahead feasibility: would a station FIT at this industry? Runs the
    // same nearest-first search in AITestMode (no money, nothing placed) and
    // returns true if any (tile, orientation) would build. Used by the planner
    // to pre-vet a candidate before we commit to it.
    static function CanBuildAt(industry_id, is_source, partner_tile) {
        local tiles = is_source
            ? AITileList_IndustryProducing(industry_id, StationBuilder.SEARCH_RADIUS)
            : AITileList_IndustryAccepting(industry_id, StationBuilder.SEARCH_RADIUS);
        if (tiles.IsEmpty()) return false;

        local self_tile = AIIndustry.GetLocation(industry_id);
        tiles.Valuate(AIMap.DistanceManhattan, self_tile);
        tiles.Sort(AIList.SORT_BY_VALUE, true);

        local tm = AITestMode();   // nothing below is actually built
        foreach (dir in [AIRail.RAILTRACK_NE_SW, AIRail.RAILTRACK_NW_SE]) {
            foreach (tile, _ in tiles) {
                if (!AITile.IsBuildable(tile)) continue;
                if (AIRail.BuildRailStation(tile, dir, StationBuilder.NUM_PLATFORMS,
                        StationBuilder.PLATFORM_LENGTH, AIStation.STATION_NEW)) {
                    return true;
                }
            }
        }
        return false;
    }

    static FRONTAGE = 3;   // clear buildable tiles required in front of the throat

    // Free tiles to leave BETWEEN the two platforms when building a RoRo
    // (drive-through) station. A 1-tile gap puts the platforms 2 tiles apart,
    // which is the room a far-end return loop needs to reverse with legal 45°
    // curves (a 0-gap/adjacent station forces a forbidden 90° in the turnaround).
    static RORO_GAP = 1;

    // Internal: attempt one (tile, direction) pair. Returns result or null.
    // roro=true builds two 1-wide platforms separated by RORO_GAP free tiles
    // (joined to one station id) so a drive-through return loop fits at the far
    // end; roro=false builds the original adjacent 2-wide terminus.
    static function _TryBuild(tile, direction, industry_id, cargo, is_source, partner_tile, roro = false) {
        // Quick reject: target tile must be buildable land.
        if (!AITile.IsBuildable(tile)) return null;

        // Decide the throat geometry FIRST (no build needed) so we can check the
        // frontage before committing. A rail station is open at BOTH ends; the
        // "throat" is the end facing the partner industry.
        local axis = StationBuilder._AxisStep(direction);
        local perp = StationBuilder._PerpStep(direction);

        local plus_front  = tile + axis * StationBuilder.PLATFORM_LENGTH;
        local plus_enter  = tile + axis * (StationBuilder.PLATFORM_LENGTH - 1);
        local minus_front = tile - axis;
        local minus_enter = tile;

        local use_minus =
            AIMap.DistanceManhattan(minus_front, partner_tile)
          < AIMap.DistanceManhattan(plus_front,  partner_tile);

        local front_tile = use_minus ? minus_front : plus_front;
        local enter_tile = use_minus ? minus_enter : plus_enter;
        local out_dir    = front_tile - enter_tile;   // points away from station

        // RoRo PRE-FLIGHT: a gapped (drive-through) station only works if the
        // far-end turnaround loop can be laid - a gapped station has NO valid
        // reversing fallback (the gap crossover would be a forbidden 90°). So if
        // the turnaround footprint isn't clear, downgrade to a normal ADJACENT
        // terminus here (eff_roro=false) rather than build a station that can't run.
        local eff_roro = roro;
        if (eff_roro) {
            local L        = StationBuilder.PLATFORM_LENGTH;
            local far_out0 = enter_tile - out_dir * L;
            local far_out1 = far_out0 + perp * (1 + StationBuilder.RORO_GAP);
            if (!RoRo.TurnaroundClear(far_out0, far_out1, out_dir)) eff_roro = false;
        }
        // Sideways offset from platform 0 to platform 1. RoRo spreads them apart
        // by the gap; the normal terminus keeps them adjacent (offset 1).
        local perp_b = eff_roro ? perp * (1 + StationBuilder.RORO_GAP) : perp;

        // FRONTAGE CHECK: the tiles just outside BOTH platform throats, running
        // toward the partner, must be clear buildable land. Without this the
        // station can land boxed in against water/terrain (like a riverbank)
        // with no room to lay the line - better to skip and pick a spot further
        // back. (Reject early, before we build anything.)
        if (!StationBuilder._FrontageClear(front_tile, front_tile + perp_b, out_dir)) {
            return null;
        }

        local station_id;
        if (eff_roro) {
            // Two 1-wide platforms with a free gap column between them, joined to
            // one station id. The gap gives the far-end loop room to turn around.
            if (!AIRail.BuildRailStation(tile, direction, 1,
                    StationBuilder.PLATFORM_LENGTH, AIStation.STATION_NEW)) {
                return null;
            }
            station_id = AIStation.GetStationID(tile);
            local origin_b = tile + perp_b;
            if (!AIRail.BuildRailStation(origin_b, direction, 1,
                    StationBuilder.PLATFORM_LENGTH, station_id)) {
                // second platform didn't fit - remove the first so we leave no stub
                AIRail.RemoveRailStationTileRectangle(
                    tile, tile + axis * (StationBuilder.PLATFORM_LENGTH - 1), false);
                return null;
            }
        } else {
            // Original adjacent 2-wide terminus. Footprint validated by the call.
            if (!AIRail.BuildRailStation(tile, direction,
                    StationBuilder.NUM_PLATFORMS, StationBuilder.PLATFORM_LENGTH,
                    AIStation.STATION_NEW)) {
                return null;
            }
            station_id = AIStation.GetStationID(tile);
        }

        // Depot is NOT built here; DepotBuilder places spur depots off the
        // mainline later. The throat crossover / loop is built by Terminus/RoRo.

        Log.Info(Log.PHASE_STATION,
            "Built " + (is_source ? "source" : "dest") + " station id=" + station_id
            + " at tile=" + tile + " dir=" + direction
            + (eff_roro ? " RoRo(gap=" + StationBuilder.RORO_GAP + ")" : "")
            + " throat=" + (use_minus ? "minus" : "plus") + " toward partner");

        return {
            station_id    = station_id,
            tile          = tile,
            front_tile    = front_tile,           // platform 0 throat
            enter_tile    = enter_tile,
            front_tile_b  = front_tile + perp_b,  // platform 1 throat (gapped if roro)
            enter_tile_b  = enter_tile + perp_b,
            direction     = direction,
            num_platforms = StationBuilder.NUM_PLATFORMS,
            roro          = eff_roro,
        };
    }

    static MAX_PLATFORMS = 6;   // grow a busy station up to this many platforms

    // Platform count a station should have for a given monthly output:
    //   <=200t -> 2, >200 -> 3, >300 -> 4, >400 -> 5 ...  (+1 per 100t over 200)
    static function PlatformsForOutput(output) {
        local n = (output <= 200) ? 2 : 2 + (output - 101) / 100;
        if (n > StationBuilder.MAX_PLATFORMS) n = StationBuilder.MAX_PLATFORMS;
        if (n < StationBuilder.NUM_PLATFORMS) n = StationBuilder.NUM_PLATFORMS;
        return n;
    }

    // Grow a station to match the output target, adding platforms one at a time
    // (each verified/reverted by AddPlatform). Returns how many were added.
    static function GrowToMatch(st, output) {
        if (!("num_platforms" in st)) st.num_platforms <- StationBuilder.NUM_PLATFORMS;
        local target = StationBuilder.PlatformsForOutput(output);
        local added = 0;
        while (st.num_platforms < target) {
            if (!StationBuilder.AddPlatform(st)) break;   // couldn't add more; stop
            added++;
        }
        return added;
    }

    // Add one more platform to a station that is queuing trains, joined to the
    // same station and connected into the throat crossover so trains can use it.
    // Strongly guarded: if the new platform can't be connected it is removed
    // again (no broken mess). Returns true if a platform was added.
    static function AddPlatform(st) {
        if (!("num_platforms" in st)) st.num_platforms <- StationBuilder.NUM_PLATFORMS;
        if (st.num_platforms >= StationBuilder.MAX_PLATFORMS) return false;

        local p       = st.num_platforms;            // index of the new platform
        local axis    = StationBuilder._AxisStep(st.direction);
        local perp    = StationBuilder._PerpStep(st.direction);
        local out_dir = st.front_tile - st.enter_tile;

        local new_origin = st.tile + perp * p;
        // Join a 1-wide platform to the existing station.
        if (!AIRail.BuildRailStation(new_origin, st.direction, 1,
                StationBuilder.PLATFORM_LENGTH, st.station_id)) {
            return false;
        }

        local new_front = st.front_tile + perp * p;
        local new_enter = st.enter_tile + perp * p;
        local m_new     = new_front + out_dir;
        local m_prev    = st.front_tile + perp * (p - 1) + out_dir;  // adjacent platform's mainline tile

        // Straight out of the new platform, then cross into the adjacent line
        // (which is part of the existing throat crossover).
        local ok = AIRail.BuildRail(new_enter, new_front, m_new)
                && AIRail.BuildRail(new_front, m_new, m_prev);
        if (ok) AIRail.BuildSignal(m_new, m_prev, AIRail.SIGNALTYPE_PBS);  // two-way: terminus reverses

        if (!ok || !DepotBuilder._RailExists(new_front, m_new, m_prev)) {
            // Couldn't connect it - tear the new platform back out.
            AIRail.RemoveRail(new_enter, new_front, m_new);
            AIRail.RemoveRail(new_front, m_new, m_prev);
            AIRail.RemoveRailStationTileRectangle(
                new_origin, new_origin + axis * (StationBuilder.PLATFORM_LENGTH - 1), false);
            Log.Warn(Log.PHASE_STATION,
                "Could not connect a new platform at station " + st.station_id + "; reverted.");
            return false;
        }

        st.num_platforms = p + 1;
        Log.Info(Log.PHASE_STATION,
            "Enlarged station " + st.station_id + " to " + st.num_platforms + " platforms.");
        return true;
    }

    // True if both platform throats have FRONTAGE clear buildable tiles running
    // out toward the partner. f0 = platform 0 throat, f1 = platform 1 throat,
    // out_dir = step away from the station.
    static function _FrontageClear(f0, f1, out_dir) {
        for (local k = 0; k < StationBuilder.FRONTAGE; k++) {
            local t0 = f0 + out_dir * k;
            local t1 = f1 + out_dir * k;
            if (!AIMap.IsValidTile(t0) || !AITile.IsBuildable(t0)) return false;
            if (!AIMap.IsValidTile(t1) || !AITile.IsBuildable(t1)) return false;
        }
        return true;
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
