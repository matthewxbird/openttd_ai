// src/trains.nut
// Pick an engine + wagon for a cargo, buy them at a depot, attach
// wagons, set orders, and start the train.
//
// "Best engine" = lowest running cost per (top_speed * capacity).
// Lower is better. Wagons evaluated the same way but only on capacity.


class Trains {

    static MIN_WAGONS = 4;
    static MAX_WAGONS = 20;  // demand cap only; real limit is platform length
                             // and engine power (see BuildTrain)
    static POWER_PER_WAGON = 220;  // hp budget needed per loaded wagon; below
                                   // this the train crawls, so we cap wagons or
                                   // double-head the engine

    // Pick best engine for (cargo, railtype). Returns engine id or -1.
    static function PickEngine(cargo, railtype) {
        local list = AIEngineList(AIVehicle.VT_RAIL);
        local best = -1;
        local best_score = null;  // higher score = better

        foreach (eng, _ in list) {
            if (AIEngine.IsWagon(eng)) continue;
            if (!AIEngine.CanRunOnRail(eng, railtype)) continue;
            if (!AIEngine.HasPowerOnRail(eng, railtype)) continue;
            if (!AIEngine.CanPullCargo(eng, cargo) && !AIEngine.CanRefitCargo(eng, cargo)) continue;

            local speed   = AIEngine.GetMaxSpeed(eng);
            local power   = AIEngine.GetPower(eng);
            local cost    = AIEngine.GetRunningCost(eng);
            if (speed <= 0 || cost <= 0) continue;

            // Higher is better.
            local score = (speed * power).tofloat() / cost.tofloat();
            if (best_score == null || score > best_score) {
                best = eng;
                best_score = score;
            }
        }

        if (best == -1) {
            Log.Err(Log.PHASE_TRAIN, "No suitable engine for cargo=" + cargo);
        } else {
            Log.Info(Log.PHASE_TRAIN,
                "Engine pick: " + AIEngine.GetName(best)
                + " (speed=" + AIEngine.GetMaxSpeed(best)
                + " power=" + AIEngine.GetPower(best)
                + " cost=" + AIEngine.GetRunningCost(best) + ")");
        }
        return best;
    }

    // Pick best wagon for (cargo, railtype). Returns engine id or -1.
    static function PickWagon(cargo, railtype) {
        local list = AIEngineList(AIVehicle.VT_RAIL);
        local best = -1;
        local best_cap = -1;

        foreach (eng, _ in list) {
            if (!AIEngine.IsWagon(eng)) continue;
            if (!AIEngine.CanRunOnRail(eng, railtype)) continue;
            if (!AIEngine.CanRefitCargo(eng, cargo) && AIEngine.GetCargoType(eng) != cargo) continue;

            local cap = AIEngine.GetCapacity(eng);
            if (cap <= 0) continue;
            if (cap > best_cap) {
                best = eng;
                best_cap = cap;
            }
        }

        if (best == -1) {
            Log.Err(Log.PHASE_TRAIN, "No suitable wagon for cargo=" + cargo);
        } else {
            Log.Info(Log.PHASE_TRAIN,
                "Wagon pick: " + AIEngine.GetName(best) + " (cap=" + best_cap + ")");
        }
        return best;
    }

    static PROD_PER_TRAIN = 120;   // monthly output one train can clear, roughly

    // How many trains to start a route with, based on the producer's monthly
    // output (bigger producers need more trains from day one). Clamped to `cap`.
    static function PickNumTrains(production, cap) {
        local n = production / Trains.PROD_PER_TRAIN;
        if (n < 1)   n = 1;
        if (n > cap) n = cap;
        return n;
    }

    // Pick a wagon count from route distance AND producer output.
    // Longer routes and bigger producers get fuller (longer) trains, capped by
    // the platform length. Favours filling big stations to capacity.
    static function PickNumWagons(distance, production = null) {
        local n = distance / 25;   // crude distance heuristic
        if (production != null) {
            local by_prod = production / 40;   // ~MAX at heavy output
            if (by_prod > n) n = by_prod;
        }
        if (n < Trains.MIN_WAGONS) n = Trains.MIN_WAGONS;
        if (n > Trains.MAX_WAGONS) n = Trains.MAX_WAGONS;
        return n;
    }

    // Build the train in `depot`. Returns vehicle id or -1.
    // Fills the train to the platform length (max hauling) but caps the wagon
    // count at what the engine can pull; if a single engine is too weak for the
    // wagons that fit, it double-heads (adds a second engine) when there is room.
    // max_wagons = demand-based upper bound (from PickNumWagons).
    static function BuildTrain(depot_tile, engine, wagon, cargo, max_wagons) {
        local plat_units = StationBuilder.PLATFORM_LENGTH * 16;  // length in 1/16 tiles

        // Engine.
        local v = AIVehicle.BuildVehicle(depot_tile, engine);
        if (!AIVehicle.IsValidVehicle(v)) {
            Log.Err(Log.PHASE_TRAIN, "Engine buy failed: " + AIError.GetLastErrorString());
            return -1;
        }
        if (AIEngine.CanRefitCargo(engine, cargo)) AIVehicle.RefitVehicle(v, cargo);
        local engine_len = AIVehicle.GetLength(v);

        // Measure one wagon (built standalone, attached later as the first).
        local w0 = AIVehicle.BuildVehicle(depot_tile, wagon);
        if (!AIVehicle.IsValidVehicle(w0)) {
            Log.Err(Log.PHASE_TRAIN, "Wagon buy failed: " + AIError.GetLastErrorString());
            AIVehicle.SellVehicle(v);
            return -1;
        }
        if (AIEngine.CanRefitCargo(wagon, cargo)) AIVehicle.RefitVehicle(w0, cargo);
        local wagon_len = AIVehicle.GetLength(w0);
        if (wagon_len <= 0) wagon_len = 8;   // guard against odd data

        // How many wagons fit behind one engine, and how many the engine can
        // pull. The smaller wins - that's the balance of length vs power.
        local engines   = 1;
        local power_cap = AIEngine.GetPower(engine) / Trains.POWER_PER_WAGON;
        if (power_cap < 1) power_cap = 1;
        local fit  = (plat_units - engine_len) / wagon_len;
        local want = max_wagons;
        if (fit < want) want = fit;

        // If the engine can't pull what fits, double-head (second engine at the
        // front) provided that still leaves room for a worthwhile train.
        if (power_cap < want) {
            local fit2 = (plat_units - 2 * engine_len) / wagon_len;
            if (fit2 >= Trains.MIN_WAGONS) {
                local v2 = AIVehicle.BuildVehicle(depot_tile, engine);
                if (AIVehicle.IsValidVehicle(v2)) {
                    if (AIEngine.CanRefitCargo(engine, cargo)) AIVehicle.RefitVehicle(v2, cargo);
                    AIVehicle.MoveWagon(v2, 0, v, 0);   // attach to the front
                    engines = 2;
                    power_cap *= 2;
                    if (fit2 < want) want = fit2;
                }
            }
        }
        if (power_cap < want) want = power_cap;
        // Final length sanity for the engine(s) actually fitted.
        local hard_fit = (plat_units - engines * engine_len) / wagon_len;
        if (want > hard_fit) want = hard_fit;
        if (want < 1) want = 1;

        // Attach the measured wagon, then the rest up to `want`.
        AIVehicle.MoveWagon(w0, 0, v, 0);
        local count = 1;
        while (count < want) {
            local w = AIVehicle.BuildVehicle(depot_tile, wagon);
            if (!AIVehicle.IsValidVehicle(w)) {
                Log.Warn(Log.PHASE_TRAIN, "Wagon buy " + count + " failed: " + AIError.GetLastErrorString());
                break;
            }
            if (AIEngine.CanRefitCargo(wagon, cargo)) AIVehicle.RefitVehicle(w, cargo);
            AIVehicle.MoveWagon(w, 0, v, 0);
            if (AIVehicle.GetLength(v) > plat_units) {  // safety: don't overhang
                AIVehicle.SellVehicle(w);
                break;
            }
            count++;
        }

        Log.Info(Log.PHASE_TRAIN,
            "Train built id=" + v + " engines=" + engines + " wagons=" + count
            + " (len=" + AIVehicle.GetLength(v) + "/" + plat_units
            + ", powerCap=" + power_cap + ")");
        return v;
    }

    static SERVICE_RELIABILITY_DROP = 25;  // service when reliability falls 25%

    // Try to make trains service at a 25% reliability drop. Both routes for
    // this (AIGameSettings.SetValue and AIVehicle.SetServiceInterval) are
    // absent in some API versions, so the whole thing is wrapped: if the calls
    // aren't available we just fall back to the game's default servicing.
    static function ConfigureServicing() {
        try {
            local pkey = "vehicle.servint_ispercent";
            local tkey = "vehicle.servint_trains";
            local pct = false;
            if (AIGameSettings.IsValid(pkey)) pct = AIGameSettings.SetValue(pkey, 1);
            if (AIGameSettings.IsValid(tkey)) {
                AIGameSettings.SetValue(tkey, Trains.SERVICE_RELIABILITY_DROP);
                Log.Info(Log.PHASE_BOOT,
                    "Train servicing set to " + Trains.SERVICE_RELIABILITY_DROP
                    + (pct ? "% reliability drop." : " (days)."));
            }
        } catch (e) {
            Log.Warn(Log.PHASE_BOOT,
                "Service interval not settable by AI; using game default servicing.");
        }
    }

    // Platform capacity in 1/16-tile length units.
    static function PlatformUnits() {
        return StationBuilder.PLATFORM_LENGTH * 16;
    }

    // True if a train is notably shorter than the platform (room to grow).
    static function IsUnderLength(vehicle) {
        return AIVehicle.GetLength(vehicle) < (Trains.PlatformUnits() * 3) / 4;
    }

    // Add wagons to an existing train that is sitting IN A DEPOT, growing it
    // toward the platform length but capped by the front engine's power.
    // Returns the number of wagons added.
    static function GrowInDepot(vehicle, wagon, cargo) {
        local depot     = AIVehicle.GetLocation(vehicle);
        local plat      = Trains.PlatformUnits();
        local etype     = AIVehicle.GetEngineType(vehicle);
        local power_cap = AIEngine.GetPower(etype) / Trains.POWER_PER_WAGON;
        if (power_cap < 1) power_cap = 1;

        local added = 0;
        while (added < power_cap) {
            if (AIVehicle.GetLength(vehicle) >= plat) break;
            local w = AIVehicle.BuildVehicle(depot, wagon);
            if (!AIVehicle.IsValidVehicle(w)) break;
            if (AIEngine.CanRefitCargo(wagon, cargo)) AIVehicle.RefitVehicle(w, cargo);
            AIVehicle.MoveWagon(w, 0, vehicle, 0);
            if (AIVehicle.GetLength(vehicle) > plat) {  // overshot the platform
                AIVehicle.SellVehicle(w);
                break;
            }
            added++;
        }
        return added;
    }

    // Set load/unload orders + start vehicle.
    // src_station_tile: a station tile at the source (full load any)
    // dst_station_tile: a station tile at the destination (unload + no-load)
    static function DispatchTrain(vehicle, src_station_tile, dst_station_tile) {
        local ok1 = AIOrder.AppendOrder(vehicle, src_station_tile, AIOrder.OF_FULL_LOAD_ANY);
        local ok2 = AIOrder.AppendOrder(vehicle, dst_station_tile, AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD);
        if (!ok1 || !ok2) {
            Log.Err(Log.PHASE_TRAIN, "Order append failed: " + AIError.GetLastErrorString());
            return false;
        }
        if (!AIVehicle.StartStopVehicle(vehicle)) {
            Log.Err(Log.PHASE_TRAIN, "Start failed: " + AIError.GetLastErrorString());
            return false;
        }
        Log.Info(Log.PHASE_TRAIN, "Train " + vehicle + " dispatched.");
        return true;
    }
}
