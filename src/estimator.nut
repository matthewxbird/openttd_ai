// src/estimator.nut
// Pre-build route ESTIMATOR. Before committing money to a route we simulate
// the actual fleet that would run it - real engine, real wagon, real capacity,
// real running cost - and from that derive the figures the ranker needs:
//   annual profit, ROI, income per vehicle, income per building-time.
//
// This replaces the old "production x payment minus amortised constant-cost"
// guess in cargo_scan, which ignored how much a train can actually HAUL, what
// it costs to RUN, and how many trips it makes per year.
//
// Split into two parts:
//   - Estimator.Compute(...)  PURE math, no AI* calls -> unit-tested in tests/.
//   - Estimator.EngineSet(...) / Estimate(...)  the AI* glue (engine lookups,
//     cargo income, build cost). Verified in-game.

class Estimator {
    // ---- Calibratable constants (TUNE in-game against realised profit) -----

    // Rail path is longer than the manhattan distance (curves, detours).
    static RAIL_DIST_FACTOR = 1.25;

    // Tiles a train covers per in-game day, per km/h of (effective) top speed.
    // 100 km/h -> ~5 tiles/day -> a 100-tile leg ~= 20 days one way. Rough but
    // good enough for RELATIVE ranking; calibrate later.
    static TILES_PER_DAY_PER_KMH = 0.05;

    // Days lost each end loading/unloading + accelerating, per round trip.
    static TERMINAL_DAYS = 10;

    // Wagon / engine length in 1/16-tile units, for estimating how many wagons
    // fill a platform without actually building the train.
    static WAGON_LEN_EST  = 8;
    static ENGINE_LEN_EST = 8;

    // Amortise build cost over this many years when computing annual profit.
    static AMORTIZE_YEARS = 10;

    // Building time (abstract units) ~ fixed station/depot overhead + per-tile
    // track laying. Used for income-per-building-time ranking (Phase 2).
    static BUILD_TIME_FIXED    = 60;
    static BUILD_TIME_PER_TILE = 1.0;

    // ---- Engine-set cache (cleared each scan; many pairs share cargo) ------
    static _engine_cache = {};

    // Clear IN PLACE. Squirrel crashes if you reassign a static slot
    // (Estimator._engine_cache = {}), so mutate the existing table instead.
    static function ClearCache() {
        Estimator._engine_cache.clear();
    }

    // Find the best engine+wagon for a cargo on a railtype and return the fleet
    // shape (capacity per train, running cost per train, effective speed).
    // Returns null if no usable engine/wagon. AI* calls; result cached.
    static function EngineSet(cargo, railtype) {
        local key = cargo + ":" + railtype;
        if (key in Estimator._engine_cache) return Estimator._engine_cache[key];

        local engine = Trains.PickEngine(cargo, railtype);
        local wagon  = Trains.PickWagon(cargo, railtype);
        if (engine == -1 || wagon == -1) {
            Estimator._engine_cache[key] <- null;
            return null;
        }

        local wagon_cap = AIEngine.GetCapacity(wagon);
        if (wagon_cap <= 0) wagon_cap = 1;

        // How many wagons fit a platform, and whether we must double-head.
        local plat_units = StationBuilder.PLATFORM_LENGTH * 16;
        local num_wagons = (plat_units - Estimator.ENGINE_LEN_EST) / Estimator.WAGON_LEN_EST;
        if (num_wagons < 1) num_wagons = 1;

        local power     = AIEngine.GetPower(engine);
        local power_cap = power / Trains.POWER_PER_WAGON;
        if (power_cap < 1) power_cap = 1;

        local engines = 1;
        if (power_cap < num_wagons) {
            // Double-head: 2nd engine costs one wagon's length but doubles power.
            num_wagons = (plat_units - 2 * Estimator.ENGINE_LEN_EST) / Estimator.WAGON_LEN_EST;
            if (num_wagons < 1) num_wagons = 1;
            engines = 2;
            power_cap *= 2;
        }
        if (power_cap < num_wagons) num_wagons = power_cap;   // still weak: shorten

        local eng_speed  = AIEngine.GetMaxSpeed(engine);
        local rail_speed = AIRail.GetMaxSpeed(railtype);
        local speed = eng_speed;
        if (rail_speed > 0 && rail_speed < speed) speed = rail_speed;
        if (speed <= 0) speed = 100;

        local running = engines * AIEngine.GetRunningCost(engine)
                      + num_wagons * AIEngine.GetRunningCost(wagon);

        local set = {
            engine               = engine,
            wagon                = wagon,
            engines              = engines,
            num_wagons           = num_wagons,
            capacity_per_train   = wagon_cap * num_wagons,
            running_cost_per_train = running,
            speed                = speed,
        };
        Estimator._engine_cache[key] <- set;
        return set;
    }

    // Full estimate for a candidate route. Returns a table of metrics, or null
    // if no fleet can serve the cargo. AI* glue around the pure Compute().
    static function Estimate(cargo, dist, production, railtype, max_trains) {
        local set = Estimator.EngineSet(cargo, railtype);
        if (set == null) return null;

        local rail_dist = (dist.tofloat() * Estimator.RAIL_DIST_FACTOR).tointeger();

        // One-way trip days from effective speed; payment is for that transit.
        local trip_days = (rail_dist.tofloat()
                           / (set.speed.tofloat() * Estimator.TILES_PER_DAY_PER_KMH)).tointeger();
        if (trip_days < 1) trip_days = 1;

        local payment    = AICargo.GetCargoIncome(cargo, rail_dist, trip_days);
        local build_cost = Scoring.BuildCostEstimate(dist);

        return Estimator.Compute({
            capacity_per_train     = set.capacity_per_train,
            running_cost_per_train = set.running_cost_per_train,
            trip_days              = trip_days,
            production_per_month   = production,
            payment_per_unit       = payment,
            build_cost             = build_cost,
            dist                   = dist,
            max_trains             = max_trains,
        });
    }

    // PURE arithmetic - no AI* calls, unit-tested. Takes a params table:
    //   capacity_per_train, running_cost_per_train (per year, per train),
    //   trip_days (one way), production_per_month, payment_per_unit,
    //   build_cost, dist, max_trains
    // Returns a metrics table.
    static function Compute(p) {
        local round_trip = 2 * p.trip_days + Estimator.TERMINAL_DAYS;
        if (round_trip < 1) round_trip = 1;
        local trips_per_year = 365.0 / round_trip.tofloat();

        // Throughput one train can move per year, and how many trains the
        // production justifies (don't run more than the producer can fill).
        local per_train_year = p.capacity_per_train.tofloat() * trips_per_year;
        local annual_prod    = p.production_per_month.tofloat() * 12.0;

        local num_trains = 1;
        if (per_train_year > 0.0) {
            num_trains = (annual_prod / per_train_year + 0.5).tointeger();
        }
        if (num_trains < 1) num_trains = 1;
        if (num_trains > p.max_trains) num_trains = p.max_trains;

        // Cargo actually delivered = min(what's produced, what the fleet hauls).
        local fleet_capacity = per_train_year * num_trains;
        local serviced = annual_prod;
        if (fleet_capacity < serviced) serviced = fleet_capacity;

        local income_per_year  = serviced * p.payment_per_unit.tofloat();
        local running_per_year = p.running_cost_per_train.tofloat() * num_trains;
        local amortized        = p.build_cost.tofloat() / Estimator.AMORTIZE_YEARS.tofloat();

        local annual_profit = income_per_year - running_per_year - amortized;

        local roi = -1.0;
        if (p.build_cost > 0) {
            roi = (income_per_year - running_per_year - amortized) / p.build_cost.tofloat();
        }

        // Per-vehicle yield (engines+wagons unknown here; use trains as proxy -
        // refined later). Per building-time yield for the throughput phase.
        local income_per_vehicle = (income_per_year - running_per_year) / num_trains.tofloat();
        local building_time = Estimator.BUILD_TIME_FIXED
                            + Estimator.BUILD_TIME_PER_TILE * p.dist.tofloat();
        local income_per_building_time = (income_per_year - running_per_year) / building_time;

        return {
            num_trains              = num_trains,
            serviced_per_year       = serviced,
            income_per_year         = income_per_year,
            running_cost_per_year   = running_per_year,
            annual_profit           = annual_profit,
            roi                     = roi,
            income_per_vehicle      = income_per_vehicle,
            income_per_building_time = income_per_building_time,
            building_time           = building_time,
            trips_per_year          = trips_per_year,
        };
    }
}
