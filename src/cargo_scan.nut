// src/cargo_scan.nut
// Walk all cargoes the current climate offers, find every (producer,
// accepter) industry pair for each cargo, score it by ROI, and return
// a ranked candidate list. No building - just looking.
//
// Heavy AI* usage here: AICargoList, AIIndustryList_CargoProducing/Accepting,
// AIIndustry, AIMap. Verified in-game, not in unit tests.


class CargoScan {

    // How many days the income estimate uses. ~30 days = 1 month, a
    // reasonable expected delivery time for a medium route.
    static INCOME_DAYS = 30;

    // Emit road-truck candidates for short industry freight. OFF: lower-value
    // solo (regressed the bench); the value is in 1v1/manual play. Flip on there.
    static ROAD_TRUCK_CANDIDATES = false;

    // Minimum route length (tiles). Cargo payment scales with distance, so very
    // short hauls earn little per trip and aren't worth a whole double-track
    // line + station overhead - skip them.
    static MIN_DISTANCE = 40;

    // Towns this small aren't worth delivering end-chain goods/food to.
    static MIN_TOWN_POP = 300;

    // How far around an industry counts as "the same station catchment" when
    // measuring how many OTHER industries a station here could also serve.
    static CLUSTER_RADIUS = 8;

    // Count industries within CLUSTER_RADIUS of `tile` (a rough measure of how
    // many cargoes one station placed here could pick up / drop off).
    static function _ClusterCount(tile) {
        local list = AIIndustryList();
        list.Valuate(AIIndustry.GetDistanceManhattanToTile, tile);
        list.KeepBelowValue(CargoScan.CLUSTER_RADIUS);
        return list.Count();
    }

    // Build full list of candidate routes across all cargoes.
    // Returns array of { cargo, producer, accepter, distance, score, ... }.
    // `railtype` is needed so the estimator can simulate the real fleet.
    static function Scan(railtype) {
        local out = [];
        local cargoes = AICargoList();
        Log.Info(Log.PHASE_SCAN, "Cargoes detected: " + cargoes.Count());

        Estimator.ClearCache();   // engine sets may have changed since last scan
        foreach (cargo, _ in cargoes) {
            CargoScan._ScanCargo(cargo, out, railtype);
        }
        Log.Info(Log.PHASE_SCAN, "Total candidate pairs: " + out.len());
        return out;
    }

    // Append candidates for a single cargo to `out`.
    static function _ScanCargo(cargo, out, railtype) {
        local cargo_label = AICargo.GetCargoLabel(cargo);

        local producers  = AIIndustryList_CargoProducing(cargo);
        local accepters  = AIIndustryList_CargoAccepting(cargo);
        local town_cargo = CargoScan._TownAccepts(cargo);
        // Need producers, and SOMEWHERE to deliver: an industry accepter or
        // (for end-chain cargo) towns.
        if (producers.IsEmpty()) return;
        if (accepters.IsEmpty() && !town_cargo) return;

        Log.Info(Log.PHASE_SCAN,
            cargo_label + ": " + producers.Count() + " producers, "
            + accepters.Count() + " industry accepters"
            + (town_cargo ? " (+towns)" : ""));

        // End-chain cargoes (GOODS, FOOD, ...) are accepted by TOWNS, not
        // industries - that's where the chain terminates and the money is.
        foreach (prod_id, _ in producers) {
            local prod_loc = AIIndustry.GetLocation(prod_id);
            local prod_amt = AIIndustry.GetLastMonthProduction(prod_id, cargo);
            if (prod_amt <= 0) continue;

            // How many industries cluster around this producer: a station here
            // could serve them all (multiple cargoes from one build). >1 because
            // the producer itself is counted.
            local prod_cluster = CargoScan._ClusterCount(prod_loc);

            // Industry accepters.
            foreach (acc_id, _ in accepters) {
                if (acc_id == prod_id) continue;
                local acc_loc = AIIndustry.GetLocation(acc_id);
                CargoScan._Consider(out, cargo, prod_id, prod_amt, prod_loc,
                    acc_id, acc_loc, false,
                    prod_cluster + CargoScan._ClusterCount(acc_loc), railtype);
            }

            // Town accepters (end of chain). A town is inherently multi-cargo,
            // so it gets a flat cluster bonus on top of the producer's.
            if (town_cargo) {
                local towns = AITownList();
                foreach (town, _ in towns) {
                    if (AITown.GetPopulation(town) < CargoScan.MIN_TOWN_POP) continue;
                    CargoScan._Consider(out, cargo, prod_id, prod_amt, prod_loc,
                        town, AITown.GetLocation(town), true, prod_cluster + 2, railtype);
                }
            }
        }
    }

    // True if towns accept this cargo (it has a delivery town effect).
    static function _TownAccepts(cargo) {
        local te = AICargo.GetTownEffect(cargo);
        return te != AICargo.TE_NONE;
    }

    // Score one producer->accepter pair and append it as a candidate.
    // `cluster` = how many industries (+town) sit in the two stations' catchment;
    // more means one build serves more cargo, so we favour it.
    //
    // Scoring now comes from the ESTIMATOR: it simulates the real fleet (engine,
    // wagon, capacity, running cost, trips/year) and returns annual profit, ROI,
    // income-per-vehicle and income-per-building-time. We rank on
    // distance-weighted, cluster-boosted annual profit; the other metrics ride
    // along for the adaptive profit model (Phase 2) and fleet sizing.
    static function _Consider(out, cargo, prod_id, prod_amt, prod_loc, acc_id, acc_loc, acc_is_town, cluster, railtype) {
        local dist = AIMap.DistanceManhattan(prod_loc, acc_loc);

        // ROAD-TRUCK candidate for SHORT/medium INDUSTRY freight. Rail's MIN_DISTANCE
        // is 40 and its 2-station + double-track + depot build needs a long haul to
        // pay off; for short hauls a truck (cheap drive-through stops, no track) is
        // cheaper and WINS. We emit a road candidate alongside the rail one and let
        // the value surface pick per pair (same pair is deduped by HasRoute, so only
        // the winning mode actually builds). This is the short-haul mode rule -
        // without it, short coal->power hauls had ONLY a (marginal) rail option.
        // Road-truck candidates: OFF by default. They're the correct short-haul
        // mode (a truck beats a marginal short rail line), but road is lower-value
        // SOLO, so emitting them regressed the solo bench. Kept behind a flag for
        // 1v1 / manual play where board presence + serving short hauls matters.
        if (CargoScan.ROAD_TRUCK_CANDIDATES
                && !acc_is_town && dist >= Road.MIN_DISTANCE && dist <= Road.TRUCK_MAX_DISTANCE
                && Road.VehicleSet(cargo) != null) {
            local rest = Estimator.Estimate(cargo, dist, prod_amt, railtype, Road.MAX_VEH, AIVehicle.VT_ROAD);
            if (rest != null) {
                out.append(Road._Cand(cargo, prod_id, acc_id, false, false, dist, prod_amt, rest));
            }
        }

        // RAIL candidate: only for hauls long enough to amortise track + stations.
        if (dist < CargoScan.MIN_DISTANCE) return;

        local est = Estimator.Estimate(cargo, dist, prod_amt, railtype, Maintenance.MAX_TRAINS);
        if (est == null) return;   // no fleet can serve this cargo

        local score = Scoring.DistanceWeighted(est.annual_profit, dist);
        score       = Scoring.ClusterBoost(score, cluster);

        out.append({
            cargo       = cargo,
            producer    = prod_id,
            accepter    = acc_id,
            acc_is_town = acc_is_town,
            distance    = dist,
            production  = prod_amt,
            score       = score,
            cluster     = cluster,   // multi-industry catchment, for re-weighting per strategy mode
            // Estimator metrics (for Phase 2 ranking + sizing).
            est_profit              = est.annual_profit,
            est_roi                 = est.roi,
            est_income_per_vehicle  = est.income_per_vehicle,
            est_income_per_btime    = est.income_per_building_time,
            est_num_trains          = est.num_trains,
            est_mode                = ("mode" in est) ? est.mode : AIVehicle.VT_RAIL,
        });
    }

    // Log the single best candidate FOR EACH cargo, so you can confirm the
    // AI weighed every cargo - not just coal - and see why one wins. `ranked`
    // must already be sorted by score descending; the first time we see a
    // cargo is therefore its best route.
    static function LogPerCargoBest(ranked) {
        local seen = {};
        Log.Info(Log.PHASE_RANK, "Best annual profit per cargo:");
        foreach (c in ranked) {
            if (c.cargo in seen) continue;
            seen[c.cargo] <- true;
            Log.Info(Log.PHASE_RANK,
                "  " + AICargo.GetCargoLabel(c.cargo)
                + " best profit/yr=" + c.score
                + " (" + AIIndustry.GetName(c.producer)
                + " -> " + Route.AccepterName(c)
                + ", dist=" + c.distance + ")");
        }
    }

    // Log the top N candidates for visibility in the AI Debug window.
    static function LogTop(ranked, n = 5) {
        local limit = ranked.len() < n ? ranked.len() : n;
        for (local i = 0; i < limit; i++) {
            local c = ranked[i];
            local cargo_label = AICargo.GetCargoLabel(c.cargo);
            local prod_name   = AIIndustry.GetName(c.producer);
            local acc_name    = Route.AccepterName(c);
            Log.Info(Log.PHASE_RANK,
                "#" + (i + 1) + " " + cargo_label
                + " | " + prod_name + " -> " + acc_name
                + " | dist=" + c.distance
                + " | score=" + c.score
                + " | est profit/yr=" + ("est_profit" in c ? c.est_profit : "?")
                + " roi=" + ("est_roi" in c ? c.est_roi : "?")
                + " £/veh=" + ("est_income_per_vehicle" in c ? c.est_income_per_vehicle : "?")
                + " trains=" + ("est_num_trains" in c ? c.est_num_trains : "?"));
        }
    }
}
