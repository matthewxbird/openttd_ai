// src/trains.nut
// Pick an engine + wagon for a cargo, buy them at a depot, attach
// wagons, set orders, and start the train.
//
// "Best engine" = lowest running cost per (top_speed * capacity).
// Lower is better. Wagons evaluated the same way but only on capacity.

require("logger.nut");

class Trains {

    static MIN_WAGONS = 3;
    static MAX_WAGONS = 4;   // platform length is 5; leave room for engine

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

    // Pick a wagon count based on route distance.
    // Longer route -> more wagons (capped by station length minus engine).
    static function PickNumWagons(distance) {
        local n = distance / 30;   // crude heuristic
        if (n < Trains.MIN_WAGONS) n = Trains.MIN_WAGONS;
        if (n > Trains.MAX_WAGONS) n = Trains.MAX_WAGONS;
        return n;
    }

    // Build the train in `depot`. Returns vehicle id or -1.
    // Refits all wagons to the target cargo.
    static function BuildTrain(depot_tile, engine, wagon, cargo, num_wagons) {
        local v = AIVehicle.BuildVehicle(depot_tile, engine);
        if (!AIVehicle.IsValidVehicle(v)) {
            Log.Err(Log.PHASE_TRAIN, "Engine buy failed: " + AIError.GetLastErrorString());
            return -1;
        }
        if (AIEngine.CanRefitCargo(engine, cargo)) AIVehicle.RefitVehicle(v, cargo);

        for (local i = 0; i < num_wagons; i++) {
            local w = AIVehicle.BuildVehicle(depot_tile, wagon);
            if (!AIVehicle.IsValidVehicle(w)) {
                Log.Warn(Log.PHASE_TRAIN, "Wagon buy " + i + " failed: " + AIError.GetLastErrorString());
                break;
            }
            if (AIEngine.CanRefitCargo(wagon, cargo)) AIVehicle.RefitVehicle(w, cargo);
            AIVehicle.MoveWagon(w, 0, v, 0);
        }

        Log.Info(Log.PHASE_TRAIN, "Train built id=" + v + " wagons=" + num_wagons);
        return v;
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
