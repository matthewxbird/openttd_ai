// src/air.nut
// Phase 2 - AIRCRAFT, the early-cash engine.
//
// Air sidesteps the fragile rail track-builder entirely: two airports + a plane
// + orders, no track to misbuild and no reversing-terminus deadlock. Planes
// never get "stuck" on a line, so air routes need only a thin lifecycle (prune
// dead planes, add capacity, condemn a dud) - NOT the rail health pass.
//
// We run TOWN<->TOWN passenger (and mail) shuttles: both endpoints PRODUCE the
// cargo, so the plane loads on BOTH legs (native backhaul) for double revenue.
//
// Integration:
//   - Estimator.UnitEconomics(VT_AIR, ...) prices the air value surface (uses
//     Air.PlaneSet); air candidates are estimated with mode=VT_AIR and ranked
//     ALONGSIDE rail candidates (multi-modal global ranking, Phase 1).
//   - Air candidates carry `air=true`; the main build loop routes them here.
//   - Air routes carry `air=true` on the Route record; rail Maintenance skips
//     them and calls Air.MaintainRoute instead.

class Air {
    // Airport types small->large with the town population each suits and whether
    // it takes big planes. (Costs/maintenance are read live from the API.)
    // `planes` = how many planes the type's terminals/runways can usefully serve
    // before they queue/circle (small airport = 1 runway; the big ones have 2-4).
    static TRAITS = [
        { type = AIAirport.AT_SMALL,         pop = 0,     big = false, planes = 3  },
        { type = AIAirport.AT_COMMUTER,      pop = 1000,  big = false, planes = 4  },
        { type = AIAirport.AT_LARGE,         pop = 2000,  big = true,  planes = 6  },
        { type = AIAirport.AT_METROPOLITAN,  pop = 4000,  big = true,  planes = 10 },
        { type = AIAirport.AT_INTERNATIONAL, pop = 10000, big = true,  planes = 14 },
        { type = AIAirport.AT_INTERCON,      pop = 20000, big = true,  planes = 20 },
    ];

    static AIRPORT_COST_EST = 30000;  // rough per-airport build cost for ranking
    static MAX_PLANES       = 20;     // hard ceiling; the per-route cap from
                                      // airport size (PlaneCap) is the real limit
    static SEARCH_R         = 12;     // tiles around town centre to site an airport
    static MIN_TOWN_POP     = 500;    // don't bother with tiny towns
    static MAX_TOWNS        = 12;     // only pair the biggest N towns (keeps scan cheap)
    static MIN_DISTANCE     = 30;     // shorter than this, planes barely earn
    static MAX_DISTANCE     = 300;    // beyond this, prefer rail trunks

    static _plane_cache = {};

    static function ClearCache() {
        Air._plane_cache.clear();   // mutate in place; never reassign a static slot
    }

    // Airport types that are valid + information-available this game, small->large.
    static function AvailableTraits() {
        local out = [];
        foreach (t in Air.TRAITS) {
            if (AIAirport.IsValidAirportType(t.type)
                    && AIAirport.IsAirportInformationAvailable(t.type)) {
                out.push(t);
            }
        }
        return out;
    }

    // How many planes a route can usefully run = the smaller airport's capacity
    // (the bottleneck). Scales the fleet with the infrastructure, like hog does,
    // instead of one tiny global cap that throttles big-town trunks.
    static function PlaneCap(src_st, dst_st) {
        local cap = Air.MAX_PLANES;
        foreach (st in [src_st, dst_st]) {
            if (st == null || !("airport_type" in st)) continue;
            foreach (t in Air.TRAITS) {
                if (t.type == st.airport_type && t.planes < cap) cap = t.planes;
            }
        }
        return cap;
    }

    // Can we build any airport that accepts big planes? (Cheap; ~6 traits.)
    static function BigAvailable() {
        foreach (t in Air.AvailableTraits()) if (t.big) return true;
        return false;
    }

    // Build an airport near `town`: try the LARGEST type that FITS, falling back
    // to smaller ones. Big airports have more terminals (throughput = revenue),
    // so we want the biggest that the site allows - but a rival-grown town is
    // densely built up, so a large footprint (INTERNATIONAL/INTERCON 7x7+) often
    // won't fit. The OLD code picked one size by population and GAVE UP on failure
    // (54 site-fails, 0 airports in 1v1); pure smallest-first builds but starves
    // throughput. Largest-that-fits dominates both. Traits are small->large, so
    // iterate in reverse.
    static function BuildBestAirportNear(town) {
        local avail = Air.AvailableTraits();
        for (local i = avail.len() - 1; i >= 0; i--) {
            local st = Air.BuildAirportNear(town, avail[i].type);
            if (st != null) return st;
        }
        return null;
    }

    // Best plane engine for a cargo: maximise capacity*speed / running cost.
    // Big planes are skipped unless a big-plane airport is available.
    // Returns { engine, capacity, running_cost, speed, price } or null. Cached.
    static function PlaneSet(cargo) {
        if (cargo in Air._plane_cache) return Air._plane_cache[cargo];

        local big_ok = Air.BigAvailable();
        local list = AIEngineList(AIVehicle.VT_AIR);
        local best = null;
        local best_score = null;
        foreach (eng, _ in list) {
            if (!AIEngine.IsBuildable(eng)) continue;
            local pt = AIEngine.GetPlaneType(eng);
            if (!big_ok && pt == AIAirport.PT_BIG_PLANE) continue;
            local cap = AIEngine.GetCapacity(eng);   // capacity in the engine's default cargo
            if (AIEngine.GetCargoType(eng) != cargo) {
                if (!AIEngine.CanRefitCargo(eng, cargo)) continue;
                // capacity after refit is unknown without a vehicle; use the
                // default as a proxy (good enough for RELATIVE ranking).
            }
            if (cap <= 0) continue;
            local speed = AIEngine.GetMaxSpeed(eng);
            if (speed <= 0) speed = 200;
            local cost  = AIEngine.GetRunningCost(eng);
            if (cost <= 0) cost = 1;
            local score = cap.tofloat() * speed.tofloat() / cost.tofloat();
            if (best_score == null || score > best_score) {
                best_score = score;
                best = {
                    engine       = eng,
                    capacity     = cap,
                    running_cost = cost,
                    speed        = speed,
                    price        = AIEngine.GetPrice(eng),
                    big          = (pt == AIAirport.PT_BIG_PLANE),
                };
            }
        }
        Air._plane_cache[cargo] <- best;
        return best;
    }

    // --- Airport siting ---------------------------------------------------

    // Build an airport of `atype` near `town` so it covers the town centre.
    // Searches tiles around the centre, honours the town's noise budget, and
    // test-builds before committing. Returns a station record { station_id,
    // tile, hangar, airport_type, num_platforms, air=true } or null.
    static function BuildAirportNear(town, atype) {
        local w = AIAirport.GetAirportWidth(atype);
        local h = AIAirport.GetAirportHeight(atype);
        if (w <= 0 || h <= 0) return null;
        local center = AITown.GetLocation(town);
        local cx = AIMap.GetTileX(center);
        local cy = AIMap.GetTileY(center);
        local mx = AIMap.GetMapSizeX();
        local my = AIMap.GetMapSizeY();

        // Candidate origin tiles (top-left of the WxH rectangle), nearest the
        // town centre first.
        local cands = [];
        for (local dy = -Air.SEARCH_R; dy <= Air.SEARCH_R; dy++) {
            for (local dx = -Air.SEARCH_R; dx <= Air.SEARCH_R; dx++) {
                local x = cx + dx - w / 2;
                local y = cy + dy - h / 2;
                if (x < 1 || y < 1 || x + w >= mx || y + h >= my) continue;
                cands.push({ tile = AIMap.GetTileIndex(x, y),
                             d = abs(dx) + abs(dy) });
            }
        }
        cands.sort(function(a, b) { return a.d - b.d; });

        // Noise only constrains siting when the setting is enabled; otherwise
        // GetAllowedNoise is meaningless, so don't let it block builds.
        local noise_on = false;
        try { noise_on = AIGameSettings.IsValid("economy.station_noise_level")
                         && AIGameSettings.GetValue("economy.station_noise_level") != 0; } catch (e) {}
        local allowed_noise = noise_on ? AITown.GetAllowedNoise(town) : 0x7FFFFFFF;
        local tm = AITestMode();
        foreach (cand in cands) {
            local origin = cand.tile;
            if (noise_on && AIAirport.GetNoiseLevelIncrease(origin, atype) > allowed_noise) continue;
            if (!AIAirport.BuildAirport(origin, atype, AIStation.STATION_NEW)) continue;
            // Test passed; commit for real.
            local em = AIExecMode();
            if (!AIAirport.BuildAirport(origin, atype, AIStation.STATION_NEW)) {
                Log.Warn(Log.PHASE_STATION,
                    "Airport build failed at " + origin + ": " + AIError.GetLastErrorString());
                return null;
            }
            local sid = AIStation.GetStationID(origin);
            Log.Info(Log.PHASE_STATION,
                "Built airport id=" + sid + " type=" + atype + " for "
                + AITown.GetName(town) + " at " + origin);
            return {
                station_id    = sid,
                tile          = AIStation.GetLocation(sid),
                hangar        = AIAirport.GetHangarOfAirport(origin),
                airport_type  = atype,
                num_platforms = 1,
                air           = true,
            };
        }
        return null;
    }

    // --- Build a town<->town air route -----------------------------------

    // cand: { cargo, producer (src town), accepter (dst town), distance,
    //         production, ... air=true }. Builds both airports (reusing one we
    //         already have at a town), a plane, bidirectional full-load orders.
    static function TryBuild(state, c) {
        local cargo  = c.cargo;
        local src_t  = c.producer;
        local dst_t  = c.accepter;
        local label  = AICargo.GetCargoLabel(cargo);
        Log.Info(Log.PHASE_RANK,
            "AIR " + label + " " + AITown.GetName(src_t) + " <-> "
            + AITown.GetName(dst_t) + " (dist=" + c.distance + ", profit/yr=" + c.score + ")");

        local plane = Air.PlaneSet(cargo);
        if (plane == null) {
            Log.Err(Log.PHASE_TRAIN, "AIR: no usable plane for " + label);
            return false;
        }

        // Reuse an existing airport at either town if we built one before.
        local new_src = false, new_dst = false;
        local src_st = Air._FindAirport(state, src_t);
        if (src_st == null) {
            src_st = Air.BuildBestAirportNear(src_t);
            new_src = true;
        }
        if (src_st == null) { Log.Warn(Log.PHASE_STATION, "AIR: no src airport site."); return false; }

        local dst_st = Air._FindAirport(state, dst_t);
        if (dst_st == null) {
            dst_st = Air.BuildBestAirportNear(dst_t);
            new_dst = true;
        }
        if (dst_st == null) {
            Log.Warn(Log.PHASE_STATION, "AIR: no dst airport site.");
            if (new_src) Air._RemoveAirport(src_st);
            return false;
        }

        // Build one plane in the source hangar, refit, bidirectional full-load.
        local v = Air._BuildPlane(src_st.hangar, plane, cargo, src_st, dst_st);
        if (v == -1) {
            if (new_src) Air._RemoveAirport(src_st);
            if (new_dst) Air._RemoveAirport(dst_st);
            return false;
        }

        local route = Route.New(cargo, src_t, dst_t, c.distance, c.production, true);
        route.air         <- true;
        route.src_station = src_st;
        route.dst_station = dst_st;
        route.trains      = [v];     // (planes; reuse the same slot the lifecycle reads)
        route.train_id    = v;
        route.depot_tile  = src_st.hangar;
        route.status      = "probation";
        route.probation_date = AIDate.GetCurrentDate();
        state.AddRoute(route);
        Log.Info(Log.PHASE_RANK, "AIR route built; on PROBATION. Routes=" + state.CountRoutes());
        return true;
    }

    // Build + dispatch one plane on a route (src hangar). Returns vehicle or -1.
    static function _BuildPlane(hangar, plane, cargo, src_st, dst_st) {
        local v = AIVehicle.BuildVehicle(hangar, plane.engine);
        if (!AIVehicle.IsValidVehicle(v)) {
            Log.Err(Log.PHASE_TRAIN, "AIR: plane buy failed: " + AIError.GetLastErrorString());
            return -1;
        }
        if (AIEngine.GetCargoType(plane.engine) != cargo
                && AIEngine.CanRefitCargo(plane.engine, cargo)) {
            AIVehicle.RefitVehicle(v, cargo);
        }
        // CONTINUOUS SHUTTLE: load whatever pax are waiting and leave at once
        // (no full-load wait). Both towns produce pax, so both legs load (native
        // backhaul); not waiting to fill keeps the plane making many trips/year -
        // far more revenue for the same running cost than idling to top off, and
        // it avoids the money-losing routes a full-load wait created on thin pairs.
        local ok1 = AIOrder.AppendOrder(v, src_st.tile, 0);   // no flags: load+leave
        local ok2 = AIOrder.AppendOrder(v, dst_st.tile, 0);
        if (!ok1 || !ok2 || !AIVehicle.StartStopVehicle(v)) {
            Log.Err(Log.PHASE_TRAIN, "AIR: order/start failed: " + AIError.GetLastErrorString());
            AIVehicle.SellVehicle(v);
            return -1;
        }
        return v;
    }

    static function _FindAirport(state, town) {
        foreach (_, r in state.routes) {
            if (!(("air" in r) && r.air)) continue;
            if (r.producer == town && r.src_station != null) return r.src_station;
            if (r.accepter == town && r.dst_station != null) return r.dst_station;
        }
        return null;
    }

    static function _RemoveAirport(st) {
        if (st != null && AIMap.IsValidTile(st.tile)) AIAirport.RemoveAirport(st.tile);
    }

    // --- Air route lifecycle (thin; no track / stuck logic) --------------

    // Health pass for ONE air route. Promotes a probation route once a plane
    // profits, adds a plane when pax pile up, condemns a route with no live
    // plane or one that never earns within a deadline.
    static function MaintainRoute(state, r) {
        local label = AICargo.GetCargoLabel(r.cargo);
        local name  = AITown.GetName(r.producer) + "<->" + AITown.GetName(r.accepter);

        // Prune dead planes (crashes); detect profit.
        local alive = [];
        local profit = false;
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (!AIVehicle.IsValidVehicle(v)) continue;
                alive.push(v);
                if (AIVehicle.GetProfitThisYear(v) > 0) profit = true;
            }
        }
        r.trains = alive;

        if (alive.len() == 0) {
            Log.Err(Log.PHASE_LOOP, "[air] " + name + ": no live plane; condemning.");
            Air._Condemn(state, r);
            return;
        }

        local waiting = AIStation.GetCargoWaiting(r.src_station.station_id, r.cargo)
                      + AIStation.GetCargoWaiting(r.dst_station.station_id, r.cargo);

        if (r.status == "probation") {
            local deadline = 600 + r.distance * 4;
            local elapsed  = AIDate.GetCurrentDate()
                           - (("probation_date" in r && r.probation_date != null)
                              ? r.probation_date : AIDate.GetCurrentDate());
            if (profit) {
                r.status = "built";
                Log.Info(Log.PHASE_LOOP, "[air] " + name + ": earning -> built.");
                // Phase 9: feed the dense town centres into these proven airports
                // with bus feeders (extends catchment -> more pax for the plane).
                if (Money.Cash() > 60000) {
                    foreach (pair in [[r.producer, r.src_station], [r.accepter, r.dst_station]]) {
                        if (AITown.GetPopulation(pair[0]) >= 1500) {
                            Road.BuildFeeder(state, pair[0], pair[1], r.cargo);
                        }
                    }
                }
            } else if (elapsed >= deadline) {
                Log.Err(Log.PHASE_LOOP, "[air] " + name + ": unprofitable in "
                    + deadline + "d; condemning.");
                Air._Condemn(state, r);
            }
            return;
        }

        // BUILT: yearly loss retirement, then capacity.
        local year = AIDate.GetYear(AIDate.GetCurrentDate());
        if (year > r.last_profit_year) {
            r.last_profit_year = year;
            local py = 0;
            foreach (v in alive) py += AIVehicle.GetProfitLastYear(v);
            r.loss_streak = Maintenance.NextLossStreak(r.loss_streak, py);
            if (Maintenance.ShouldRetire(r.loss_streak, Maintenance.RETIRE_LOSS_YEARS)) {
                Log.Err(Log.PHASE_LOOP, "[air] " + name + ": lost money "
                    + r.loss_streak + " yrs; retiring.");
                Air._Condemn(state, r);
                return;
            }
        }

        local cap = Air.PlaneCap(r.src_station, r.dst_station);
        Log.Info(Log.PHASE_LOOP,
            "[air] " + label + " " + name + " planes=" + alive.len()
            + "/" + cap + " waiting=" + waiting);

        if (waiting >= 80 && alive.len() < cap
                && Money.Cash() > Maintenance.MIN_CASH_FOR_TRAIN) {
            local plane = Air.PlaneSet(r.cargo);
            if (plane != null && Money.Cash() > plane.price) {
                local v = Air._BuildPlane(r.src_station.hangar, plane, r.cargo,
                                          r.src_station, r.dst_station);
                if (v != -1) {
                    r.trains.push(v);
                    Log.Info(Log.PHASE_LOOP, "[air] " + name
                        + ": backlog " + waiting + " -> added plane (now "
                        + r.trains.len() + ").");
                }
            }
        }
    }

    // Condemn an air route: blacklist, sell every plane (send to hangar; sell on
    // arrival), then remove the airports we own that no other route uses.
    static function _Condemn(state, r) {
        state.blacklist.Add(r.cargo, r.producer, r.accepter);
        r.status = "condemning";
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (AIVehicle.IsValidVehicle(v)) AIVehicle.SendVehicleToDepot(v);
            }
        }
    }

    // Finish condemning an air route: sell parked planes; once all gone, remove
    // airports not shared with another route. Returns true when fully torn down.
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

        // Remove airports we built that no OTHER route still uses.
        foreach (st in [r.src_station, r.dst_station]) {
            if (st == null) continue;
            local shared = false;
            foreach (_, o in state.routes) {
                if (o == r) continue;
                foreach (ost in [o.src_station, o.dst_station]) {
                    if (ost != null && ost.station_id == st.station_id) shared = true;
                }
            }
            if (!shared) Air._RemoveAirport(st);
        }
        Log.Info(Log.PHASE_LOOP, "[air] "
            + AITown.GetName(r.producer) + "<->" + AITown.GetName(r.accepter)
            + ": torn down.");
        return true;
    }

    // --- Candidate generation --------------------------------------------

    // Town<->town passenger/mail air candidates, scored on the air value surface
    // and emitted in the SAME shape as rail candidates so they rank together.
    // Each unordered town pair is emitted ONCE (the route flies both ways).
    static function ScanCandidates(railtype) {
        local out = [];
        if (Air.AvailableTraits().len() == 0) return out;   // no airports yet
        Air.ClearCache();

        // Biggest MAX_TOWNS towns (most pax/mail, best airport types).
        local tl = AITownList();
        tl.Valuate(AITown.GetPopulation);
        tl.KeepTop(Air.MAX_TOWNS);
        local towns = [];
        foreach (t, _ in tl) {
            if (AITown.GetPopulation(t) >= Air.MIN_TOWN_POP) towns.push(t);
        }

        // PAX and MAIL are both town-produced (first-class air cargo, Phase 9).
        // A mail route between two towns reuses their pax airports + adds a mail
        // plane - cheap incremental revenue on infrastructure we already built.
        foreach (cargo in [Air._PaxCargo(), Air._MailCargo()]) {
            if (cargo == -1 || Air.PlaneSet(cargo) == null) continue;
            local is_pax = (AICargo.GetTownEffect(cargo) == AICargo.TE_PASSENGERS);
            for (local i = 0; i < towns.len(); i++) {
                for (local j = i + 1; j < towns.len(); j++) {
                    local a = towns[i], b = towns[j];
                    local dist = AIMap.DistanceManhattan(AITown.GetLocation(a), AITown.GetLocation(b));
                    if (dist < Air.MIN_DISTANCE || dist > Air.MAX_DISTANCE) continue;
                    // mail volume ~ 1/3 of pax.
                    local prod = Air._PaxEstimate(a) + Air._PaxEstimate(b);
                    if (!is_pax) prod = prod / 3 + 1;
                    local est = Estimator.Estimate(cargo, dist, prod, railtype,
                                                   Air.MAX_PLANES, AIVehicle.VT_AIR);
                    if (est == null) continue;
                    out.append({
                        cargo       = cargo,
                        producer    = a,
                        accepter    = b,
                        acc_is_town = true,
                        air         = true,
                        distance    = dist,
                        production  = prod,
                        score       = Scoring.DistanceWeighted(est.annual_profit, dist),
                        cluster     = 2,
                        est_profit              = est.annual_profit,
                        est_roi                 = est.roi,
                        est_income_per_vehicle  = est.income_per_vehicle,
                        est_income_per_btime    = est.income_per_building_time,
                        est_num_trains          = est.num_trains,
                        est_mode                = AIVehicle.VT_AIR,
                    });
                }
            }
        }
        Log.Info(Log.PHASE_SCAN, "Air candidates: " + out.len());
        return out;
    }

    // The mail cargo id (town-effect mail), or -1.
    static function _MailCargo() {
        local cl = AICargoList();
        foreach (cargo, _ in cl) {
            if (AICargo.GetTownEffect(cargo) == AICargo.TE_MAIL) return cargo;
        }
        return -1;
    }

    // The passenger cargo id (town-effect passengers), or -1.
    static function _PaxCargo() {
        local cl = AICargoList();
        foreach (cargo, _ in cl) {
            if (AICargo.GetTownEffect(cargo) == AICargo.TE_PASSENGERS) return cargo;
        }
        return -1;
    }

    // Rough monthly passengers a town produces (population-scaled). The plane
    // and airport throughput cap the real figure; this just sizes the estimate.
    static function _PaxEstimate(town) {
        local pop = AITown.GetPopulation(town);
        local p = pop / 25;        // ~4% of pop per month, halved for realism
        if (p < 1) p = 1;
        return p;
    }
}
