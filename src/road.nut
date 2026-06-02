// src/road.nut
// Phase 3 - ROAD mode (short hauls + town bus routes) and the foundation for
// Phase 9 feeders. Road sidesteps rail's track-laying cost/deadlock for SHORT,
// low-volume cargo: cheap drive-through stops, a depot, road vehicles, orders.
//
// Like air, road has its own thin lifecycle (road vehicles don't deadlock a
// reversing terminus); rail Maintenance skips `road=true` routes.
//
// Scope (v1, kept deliberately simple + defensive so it never crashes the AI):
//   - town<->town PASSENGER bus routes (short hops air/rail won't bother with),
//   - short industry producer->accepter TRUCK routes,
//   ranked on the shared value surface (Estimator VT_ROAD).
// The pathfinder routes over flat land / existing road and AVOIDS water (no
// bridges in v1): if no dry path exists the candidate fails cleanly and the
// ranker moves on. Foreign property is never built on (Phase 8 discipline).

class Road {
    static MAX_VEH      = 8;    // road vehicles per route (stop throughput)
    static MIN_DISTANCE = 8;    // shorter isn't worth a station pair
    static MAX_DISTANCE = 28;   // beyond this rail/air win - road is for short hauls
    static MAX_TOWNS    = 12;   // biggest N towns for bus pairing
    static MIN_TOWN_POP = 300;
    static PF_BUDGET     = 8000; // A* node budget for a (short) road path
    static STATION_RADIUS = 4;   // search radius for a drive-through stop near a target

    static _veh_cache = {};

    static function ClearCache() { Road._veh_cache.clear(); }

    // Choose + set the fastest available road type (plain road, not tram). Call
    // once before any road/station/depot build. Returns true if a type was set.
    static function EnsureRoadType() {
        try {
            local cur = AIRoad.GetCurrentRoadType();
            if (AIRoad.IsRoadTypeAvailable(cur)
                    && AIRoad.GetRoadTramType(cur) == AIRoad.ROADTRAMTYPES_ROAD) {
                return true;
            }
            // Pick the first available plain-road type (ranking by speed varies by
            // API version; early game there's typically just one).
            local list = AIRoadTypeList(AIRoad.ROADTRAMTYPES_ROAD);
            foreach (rt, _ in list) {
                if (AIRoad.IsRoadTypeAvailable(rt)) {
                    AIRoad.SetCurrentRoadType(rt);
                    return true;
                }
            }
        } catch (e) {
            Log.Warn(Log.PHASE_BOOT, "[road] road-type API unavailable: " + e);
        }
        return false;
    }

    // Best road vehicle for a cargo: capacity*speed / running cost. Cached.
    // Returns { engine, capacity, running_cost, speed, price } or null.
    static function VehicleSet(cargo) {
        if (cargo in Road._veh_cache) return Road._veh_cache[cargo];
        local best = null, best_score = null;
        local list = AIEngineList(AIVehicle.VT_ROAD);
        foreach (eng, _ in list) {
            if (!AIEngine.IsBuildable(eng)) continue;
            if (AIEngine.GetRoadType(eng) != AIRoad.ROADTYPE_ROAD) continue;
            local cap = AIEngine.GetCapacity(eng);
            if (AIEngine.GetCargoType(eng) != cargo && !AIEngine.CanRefitCargo(eng, cargo)) continue;
            if (cap <= 0) continue;
            local speed = AIEngine.GetMaxSpeed(eng);
            if (speed <= 0) speed = 80;
            local cost = AIEngine.GetRunningCost(eng);
            if (cost <= 0) cost = 1;
            local score = cap.tofloat() * speed.tofloat() / cost.tofloat();
            if (best_score == null || score > best_score) {
                best_score = score;
                best = { engine = eng, capacity = cap, running_cost = cost,
                         speed = speed, price = AIEngine.GetPrice(eng) };
            }
        }
        Road._veh_cache[cargo] <- best;
        return best;
    }

    // ---- Road pathfinder (compact A* over the shared AyStar engine) -------
    // dir encoding: 1=+1, 2=-1, 3=+mapX, 4=-mapX (small ints; AyStar keys on
    // dir & 0x0F so these stay distinct).

    static function _Offsets() {
        local mx = AIMap.GetMapSizeX();
        return [ [1, 1], [-1, 2], [mx, 3], [-mx, 4] ];
    }

    // A road tile is usable if on-map, dry, and either already road or buildable
    // land - and NEVER foreign-owned property (rail/road/station/building).
    static function _Usable(tile) {
        if (!AIMap.IsValidTile(tile)) return false;
        if (AITile.IsWaterTile(tile)) return false;
        local owner = AITile.GetOwner(tile);
        local mine  = AICompany.IsMine(owner);
        local none  = (owner == AICompany.COMPANY_INVALID) || (owner == -1);
        if (!mine && !none) {
            // Town-owned road is fine to drive on; other foreign property isn't.
            if (!(AIRoad.IsRoadTile(tile) && !AICompany.IsMine(owner))) {
                if (AIRail.IsRailTile(tile) || AITile.IsStationTile(tile)) return false;
            }
        }
        if (AIRoad.IsRoadTile(tile)) return true;
        if (AITile.IsBuildable(tile)) return true;
        return false;
    }

    static function _Cost(self, path, new_tile, new_dir, mode) {
        if (path == null) return 0;
        local c = path.GetCost() + 10;
        if (AIRoad.IsRoadTile(new_tile)) c -= 6;   // reuse existing road
        // mild slope penalty (roads handle slopes but slower).
        if (AITile.GetSlope(new_tile) != AITile.SLOPE_FLAT) c += 4;
        return c;
    }

    static function _Estimate(self, tile, dir, goals) {
        // manhattan to the nearest goal tile.
        local best = 0x7FFFFFFF;
        foreach (gt, _ in goals) {
            local d = AIMap.DistanceManhattan(tile, gt) * 10;
            if (d < best) best = d;
        }
        return best == 0x7FFFFFFF ? 0 : best;
    }

    static function _Neighbours(self, path, tile) {
        local out = [];
        foreach (o in Road._Offsets()) {
            local nt = tile + o[0];
            if (!Road._Usable(nt)) continue;
            out.push([nt, o[1]]);
        }
        return out;
    }

    static function _CheckDir(tile, old_dir, new_dir, self) { return false; }

    // Find a road path between two tiles. Returns ordered tile array or null.
    static function FindPath(from_tile, to_tile) {
        local pf = AyStar(null, Road._Cost, Road._Estimate, Road._Neighbours, Road._CheckDir);
        local src = AyStar.Path(null, from_tile, 0xFF, null, Road._Cost, null);
        local _tm = AITestMode();
        pf.InitializePath([src], [[to_tile, from_tile]], []);
        local raw = false, counter = 0;
        while (raw == false && counter < Road.PF_BUDGET / 50) {
            raw = pf.FindPath(50);
            counter++;
        }
        if (raw == false || raw == null) return null;
        local tiles = [], node = raw;
        while (node != null) { tiles.append(node.GetTile()); node = node.GetParent(); }
        local ordered = [];
        for (local i = tiles.len() - 1; i >= 0; i--) ordered.append(tiles[i]);
        return ordered;
    }

    // Lay road along an ordered tile path (real build). Returns true if every
    // consecutive pair is connected at the end.
    static function BuildAlong(tiles) {
        for (local i = 0; i + 1 < tiles.len(); i++) {
            local a = tiles[i], b = tiles[i + 1];
            if (AIRoad.AreRoadTilesConnected(a, b)) continue;
            if (!AIRoad.BuildRoad(a, b)) {
                local e = AIError.GetLastError();
                if (e != AIError.ERR_ALREADY_BUILT
                        && !AIRoad.AreRoadTilesConnected(a, b)) {
                    Log.Warn(Log.PHASE_TRACK,
                        "[road] BuildRoad failed " + a + "->" + b + ": "
                        + AIError.GetLastErrorString());
                    return false;
                }
            }
        }
        return true;
    }

    // Build a drive-through stop at `tile` oriented along the road toward
    // `toward` (an adjacent path tile). Returns station record or null.
    static function BuildStop(tile, toward, cargo, is_pax) {
        local front = toward;
        local veh_type = is_pax ? AIRoad.ROADVEHTYPE_BUS : AIRoad.ROADVEHTYPE_TRUCK;
        // Ensure the stop tile has road to its front so it's drive-through.
        if (!AIRoad.AreRoadTilesConnected(tile, front)) {
            if (!AIRoad.BuildRoad(tile, front) && !AIRoad.AreRoadTilesConnected(tile, front)) {
                return null;
            }
        }
        if (!AIRoad.BuildDriveThroughRoadStation(tile, front, veh_type, AIStation.STATION_NEW)
                && !AIRoad.IsRoadStationTile(tile)) {
            // LOCAL AUTHORITY refused? Lift rating with trees, retry once.
            if (TownAuthority.WasRefused()) {
                local town = AITile.GetTownAuthority(tile);
                if (AITown.IsValidTown(town)) TownAuthority.PlantTrees(town);
            }
            if (!AIRoad.BuildDriveThroughRoadStation(tile, front, veh_type, AIStation.STATION_NEW)
                    && !AIRoad.IsRoadStationTile(tile)) {
                Log.Warn(Log.PHASE_STATION,
                    "[road] stop build failed at " + tile + ": " + AIError.GetLastErrorString());
                return null;
            }
        }
        local sid = AIStation.GetStationID(tile);
        return { station_id = sid, tile = tile, front = front, road = true };
    }

    // ---- Build a road route ---------------------------------------------

    // cand: { cargo, producer, accepter, acc_is_town, src_is_town, distance,
    //         production, road=true }. Builds a road, two drive-through stops, a
    //         depot, vehicles, orders. Defensive: any failure -> clean up + false.
    static function TryBuild(state, c) {
        if (!Road.EnsureRoadType()) return false;
        local veh = Road.VehicleSet(c.cargo);
        if (veh == null) return false;
        local is_pax = (AICargo.GetTownEffect(c.cargo) == AICargo.TE_PASSENGERS);

        local src_loc = ("src_is_town" in c && c.src_is_town)
            ? AITown.GetLocation(c.producer) : AIIndustry.GetLocation(c.producer);
        local dst_loc = c.acc_is_town
            ? AITown.GetLocation(c.accepter) : AIIndustry.GetLocation(c.accepter);

        // Find a buildable stop tile near each endpoint (a flat dry tile with a
        // dry neighbour for the drive-through front).
        local src_pair = Road._FindStopTile(src_loc);
        local dst_pair = Road._FindStopTile(dst_loc);
        if (src_pair == null || dst_pair == null) return false;

        // Pathfind between the two stop tiles and lay the road.
        local path = Road.FindPath(src_pair.tile, dst_pair.tile);
        if (path == null || path.len() < 2) return false;
        if (!Road.BuildAlong(path)) return false;

        local src_st = Road.BuildStop(src_pair.tile, src_pair.front, c.cargo, is_pax);
        if (src_st == null) return false;
        local dst_st = Road.BuildStop(dst_pair.tile, dst_pair.front, c.cargo, is_pax);
        if (dst_st == null) return false;

        // Depot beside the source stop.
        local depot = Road._BuildDepot(src_pair.tile);
        if (depot == -1) return false;

        // Build + dispatch one vehicle.
        local v = Road._BuildVehicle(depot, veh, c.cargo, src_st, dst_st, is_pax);
        if (v == -1) return false;

        local route = Route.New(c.cargo, c.producer, c.accepter, c.distance, c.production, c.acc_is_town);
        route.road        <- true;
        route.src_station = src_st;
        route.dst_station = dst_st;
        route.depot_tile  = depot;
        route.trains      = [v];
        route.train_id    = v;
        route.status      = "probation";
        route.probation_date = AIDate.GetCurrentDate();
        route.road_path   <- path;
        state.AddRoute(route);
        Log.Info(Log.PHASE_RANK, "ROAD route built; on PROBATION. Routes=" + state.CountRoutes());
        return true;
    }

    // A drive-through stop needs a tile + an adjacent tile both usable. Search a
    // small ring around `near`. Returns { tile, front } or null.
    static function _FindStopTile(near) {
        local cx = AIMap.GetTileX(near), cy = AIMap.GetTileY(near);
        local mx = AIMap.GetMapSizeX(), my = AIMap.GetMapSizeY();
        for (local r = 1; r <= Road.STATION_RADIUS; r++) {
            for (local dy = -r; dy <= r; dy++) {
                for (local dx = -r; dx <= r; dx++) {
                    if (abs(dx) != r && abs(dy) != r) continue;   // ring only
                    local x = cx + dx, y = cy + dy;
                    if (x < 1 || y < 1 || x >= mx - 1 || y >= my - 1) continue;
                    local t = AIMap.GetTileIndex(x, y);
                    if (!Road._Usable(t) || AITile.IsStationTile(t)) continue;
                    foreach (o in Road._Offsets()) {
                        local f = t + o[0];
                        if (Road._Usable(f) && !AITile.IsStationTile(f)) {
                            return { tile = t, front = f };
                        }
                    }
                }
            }
        }
        return null;
    }

    static function _BuildDepot(near) {
        foreach (o in Road._Offsets()) {
            local d = near + o[0];
            if (!Road._Usable(d) || AITile.IsStationTile(d)) continue;
            if (AIRoad.AreRoadTilesConnected(near, d) || AIRoad.BuildRoad(near, d)) {
                if (AIRoad.BuildRoadDepot(d, near)) return d;
            }
        }
        return -1;
    }

    static function _BuildVehicle(depot, veh, cargo, src_st, dst_st, is_pax) {
        local v = AIVehicle.BuildVehicle(depot, veh.engine);
        if (!AIVehicle.IsValidVehicle(v)) return -1;
        if (AIEngine.GetCargoType(veh.engine) != cargo && AIEngine.CanRefitCargo(veh.engine, cargo)) {
            AIVehicle.RefitVehicle(v, cargo);
        }
        // Continuous shuttle (load+leave), like air - keeps vehicles moving.
        local ok1 = AIOrder.AppendOrder(v, src_st.tile, 0);
        local ok2 = AIOrder.AppendOrder(v, dst_st.tile, 0);
        if (!ok1 || !ok2 || !AIVehicle.StartStopVehicle(v)) {
            AIVehicle.SellVehicle(v);
            return -1;
        }
        return v;
    }

    // ---- Phase 9: intra-town bus FEEDER into a trunk (airport/rail) ------

    // Build a bus feeder for `town`: pick up pax at the town centre and TRANSFER
    // them into `trunk_st` (a trunk station - e.g. an airport - already serving
    // the town), so the trunk vehicle hauls them the long, high-paying leg. This
    // extends the trunk's catchment to the dense town centre. Adds a road route
    // with feeder=true. Fully defensive: any failure cleans up and returns false.
    static function BuildFeeder(state, town, trunk_st, cargo) {
        if (!Road.EnsureRoadType()) return false;
        local veh = Road.VehicleSet(cargo);
        if (veh == null) return false;
        // One feeder per (town, cargo).
        foreach (_, r in state.routes) {
            if (("feeder" in r) && r.feeder && r.producer == town && r.cargo == cargo) return false;
        }

        local center = AITown.GetLocation(town);
        local src_pair = Road._FindStopTile(center);
        if (src_pair == null) return false;

        // A bus stop ADJACENT to the trunk station, JOINED to its station id, so
        // transferred pax sit at the trunk for the trunk vehicle to collect.
        local trunk_pair = Road._FindStopTile(trunk_st.tile);
        if (trunk_pair == null) return false;
        if (AIMap.DistanceManhattan(src_pair.tile, trunk_pair.tile) < 3) return false;  // already covered

        local path = Road.FindPath(src_pair.tile, trunk_pair.tile);
        if (path == null || path.len() < 2 || !Road.BuildAlong(path)) return false;

        // Town-centre stop (own station) + trunk-side stop joined to the trunk.
        local src_st = Road.BuildStop(src_pair.tile, src_pair.front, cargo, true);
        if (src_st == null) return false;
        if (!AIRoad.AreRoadTilesConnected(trunk_pair.tile, trunk_pair.front)
                && !AIRoad.BuildRoad(trunk_pair.tile, trunk_pair.front)
                && !AIRoad.AreRoadTilesConnected(trunk_pair.tile, trunk_pair.front)) {
            return false;
        }
        if (!AIRoad.BuildDriveThroughRoadStation(trunk_pair.tile, trunk_pair.front,
                AIRoad.ROADVEHTYPE_BUS, trunk_st.station_id)
                && !AIRoad.IsRoadStationTile(trunk_pair.tile)) {
            Log.Warn(Log.PHASE_STATION, "[feeder] trunk-side stop/join failed: " + AIError.GetLastErrorString());
            return false;
        }
        local trunk_bus = { station_id = trunk_st.station_id, tile = trunk_pair.tile, road = true };

        local depot = Road._BuildDepot(src_pair.tile);
        if (depot == -1) return false;

        local v = AIVehicle.BuildVehicle(depot, veh.engine);
        if (!AIVehicle.IsValidVehicle(v)) return false;
        if (AIEngine.GetCargoType(veh.engine) != cargo && AIEngine.CanRefitCargo(veh.engine, cargo)) {
            AIVehicle.RefitVehicle(v, cargo);
        }
        // Load pax at the centre; TRANSFER (no payment yet) at the trunk so the
        // trunk vehicle carries them onward for the big payment.
        local ok1 = AIOrder.AppendOrder(v, src_st.tile, AIOrder.OF_FULL_LOAD_ANY);
        local ok2 = AIOrder.AppendOrder(v, trunk_bus.tile, AIOrder.OF_TRANSFER | AIOrder.OF_NO_LOAD);
        if (!ok1 || !ok2 || !AIVehicle.StartStopVehicle(v)) { AIVehicle.SellVehicle(v); return false; }

        local route = Route.New(cargo, town, town, AIMap.DistanceManhattan(src_pair.tile, trunk_pair.tile), 0, true);
        route.road        <- true;
        route.feeder      <- true;
        route.src_station = src_st;
        route.dst_station = trunk_bus;
        route.depot_tile  = depot;
        route.trains      = [v];
        route.train_id    = v;
        route.status      = "built";   // feeders prove via the trunk; no probation
        route.road_path   <- path;
        state.AddRoute(route);
        Log.Info(Log.PHASE_RANK, "[feeder] bus feeder for " + AITown.GetName(town)
            + " -> trunk station " + trunk_st.station_id);
        return true;
    }

    // ---- Thin road lifecycle --------------------------------------------

    static function MaintainRoute(state, r) {
        local alive = [], profit = false;
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (!AIVehicle.IsValidVehicle(v)) continue;
                alive.push(v);
                if (AIVehicle.GetProfitThisYear(v) > 0) profit = true;
            }
        }
        r.trains = alive;
        local name = AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r);
        if (alive.len() == 0) { Road._Condemn(state, r); return; }

        if (r.status == "probation") {
            local deadline = 500 + r.distance * 6;
            local elapsed = AIDate.GetCurrentDate()
                - (("probation_date" in r && r.probation_date != null) ? r.probation_date : AIDate.GetCurrentDate());
            if (profit) { r.status = "built"; Log.Info(Log.PHASE_LOOP, "[road] " + name + " -> built."); }
            else if (elapsed >= deadline) { Log.Err(Log.PHASE_LOOP, "[road] " + name + " unprofitable; condemning."); Road._Condemn(state, r); }
            return;
        }

        // FEEDERS pay nothing at the transfer (the fare credits the TRUNK
        // vehicle), so a feeder bus always shows a "loss" in isolation - never
        // retire it on profit. Its value is the extra pax it hands the trunk.
        local is_feeder = ("feeder" in r) && r.feeder;
        local year = AIDate.GetYear(AIDate.GetCurrentDate());
        if (!is_feeder && year > r.last_profit_year) {
            r.last_profit_year = year;
            local py = 0;
            foreach (v in alive) py += AIVehicle.GetProfitLastYear(v);
            r.loss_streak = Maintenance.NextLossStreak(r.loss_streak, py);
            if (Maintenance.ShouldRetire(r.loss_streak, Maintenance.RETIRE_LOSS_YEARS)) {
                Log.Err(Log.PHASE_LOOP, "[road] " + name + " lost money; retiring.");
                Road._Condemn(state, r); return;
            }
        }

        local waiting = AIStation.GetCargoWaiting(r.src_station.station_id, r.cargo);
        if (waiting >= 60 && alive.len() < Road.MAX_VEH
                && Money.Cash() > Maintenance.MIN_CASH_FOR_TRAIN) {
            local veh = Road.VehicleSet(r.cargo);
            local is_pax = (AICargo.GetTownEffect(r.cargo) == AICargo.TE_PASSENGERS);
            if (veh != null && Money.Cash() > veh.price) {
                local v = Road._BuildVehicle(r.depot_tile, veh, r.cargo, r.src_station, r.dst_station, is_pax);
                if (v != -1) { r.trains.push(v); Log.Info(Log.PHASE_LOOP, "[road] " + name + " +veh (" + r.trains.len() + ")"); }
            }
        }
    }

    static function _Condemn(state, r) {
        state.blacklist.Add(r.cargo, r.producer, r.accepter);
        r.status = "condemning";
        if (r.trains != null) foreach (v in r.trains) if (AIVehicle.IsValidVehicle(v)) AIVehicle.SendVehicleToDepot(v);
    }

    static function CheckCondemning(state, r) {
        local remaining = [];
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (!AIVehicle.IsValidVehicle(v)) continue;
                if (AIVehicle.GetState(v) == AIVehicle.VS_IN_DEPOT) {
                    AIVehicle.SellVehicle(v);
                    if (!AIVehicle.IsValidVehicle(v)) continue;
                }
                AIVehicle.SendVehicleToDepot(v);
                remaining.push(v);
            }
        }
        r.trains = remaining;
        if (remaining.len() > 0) return false;
        Log.Info(Log.PHASE_LOOP, "[road] "
            + AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r) + ": torn down.");
        return true;   // leave the road/stops (cheap, may be reused)
    }

    // ---- Candidate generation -------------------------------------------

    // Short-haul road candidates: town<->town bus (pax) + short industry truck
    // pairs, priced on the value surface (VT_ROAD). Emitted in the shared
    // candidate shape so they rank with rail + air.
    static function ScanCandidates(railtype) {
        local out = [];
        if (!Road.EnsureRoadType()) return out;
        Road.ClearCache();

        // Town<->town passenger bus (short hops).
        local pax = Road._PaxCargo();
        if (pax != -1 && Road.VehicleSet(pax) != null) {
            local tl = AITownList();
            tl.Valuate(AITown.GetPopulation);
            tl.KeepTop(Road.MAX_TOWNS);
            local towns = [];
            foreach (t, _ in tl) if (AITown.GetPopulation(t) >= Road.MIN_TOWN_POP) towns.push(t);
            for (local i = 0; i < towns.len(); i++) {
                for (local j = i + 1; j < towns.len(); j++) {
                    local a = towns[i], b = towns[j];
                    local dist = AIMap.DistanceManhattan(AITown.GetLocation(a), AITown.GetLocation(b));
                    if (dist < Road.MIN_DISTANCE || dist > Road.MAX_DISTANCE) continue;
                    local prod = (AITown.GetPopulation(a) + AITown.GetPopulation(b)) / 25;
                    local est = Estimator.Estimate(pax, dist, prod, railtype, Road.MAX_VEH, AIVehicle.VT_ROAD);
                    if (est == null) continue;
                    out.append(Road._Cand(pax, a, b, true, true, dist, prod, est));
                }
            }
        }
        Log.Info(Log.PHASE_SCAN, "Road candidates: " + out.len());
        return out;
    }

    static function _Cand(cargo, src, dst, src_is_town, acc_is_town, dist, prod, est) {
        return {
            cargo = cargo, producer = src, accepter = dst,
            acc_is_town = acc_is_town, src_is_town = src_is_town,
            road = true, distance = dist, production = prod,
            score = Scoring.DistanceWeighted(est.annual_profit, dist),
            cluster = 2,
            est_profit = est.annual_profit, est_roi = est.roi,
            est_income_per_vehicle = est.income_per_vehicle,
            est_income_per_btime = est.income_per_building_time,
            est_num_trains = est.num_trains, est_mode = AIVehicle.VT_ROAD,
        };
    }

    static function _PaxCargo() {
        local cl = AICargoList();
        foreach (cargo, _ in cl) if (AICargo.GetTownEffect(cargo) == AICargo.TE_PASSENGERS) return cargo;
        return -1;
    }
}
