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

    // VALUE SURFACE (Phase 1). The economics of a route split cleanly into:
    //   - UNIT economics: payment per unit, per-train capacity, running cost,
    //     trip days, build cost - these depend only on (mode, cargo, DISTANCE),
    //     NOT on how much the producer makes. This is the per-(mode,cargo,dist)
    //     "value surface" AAAHogEx precomputes and reuses across every place.
    //   - PRODUCTION scaling: given a producer's output, Compute() sizes the
    //     fleet and the serviced volume from the unit economics.
    // Factoring it this way (a) lets us compare MODES at a given cargo/distance
    // and pick the best (rail today; road/air slot in here in Phases 2/3), and
    // (b) keeps Compute() - the tested pure core - unchanged.

    // Per-(mode,cargo,distance) unit economics, production-independent. Returns
    // a params table ready for Compute (minus production/max_trains), with the
    // chosen `mode`, or null if this mode can't serve the cargo. AI* glue.
    // vehicleType selects the mode; only VT_RAIL is implemented today - road/air
    // return null until Phases 3/2 add them, so the mode picker simply skips them.
    static function UnitEconomics(vehicleType, cargo, dist, railtype) {
        if (vehicleType == AIVehicle.VT_AIR)  return Estimator._AirUnit(cargo, dist);
        if (vehicleType == AIVehicle.VT_ROAD) return Estimator._RoadUnit(cargo, dist);
        if (vehicleType != AIVehicle.VT_RAIL) return null;

        local set = Estimator.EngineSet(cargo, railtype);
        if (set == null) return null;

        local rail_dist = (dist.tofloat() * Estimator.RAIL_DIST_FACTOR).tointeger();

        // One-way trip days from effective speed; payment is for that transit.
        local trip_days = (rail_dist.tofloat()
                           / (set.speed.tofloat() * Estimator.TILES_PER_DAY_PER_KMH)).tointeger();
        if (trip_days < 1) trip_days = 1;

        return {
            mode                   = vehicleType,
            capacity_per_train     = set.capacity_per_train,
            running_cost_per_train = set.running_cost_per_train,
            trip_days              = trip_days,
            payment_per_unit       = AICargo.GetCargoIncome(cargo, rail_dist, trip_days),
            build_cost             = Scoring.BuildCostEstimate(dist),
        };
    }

    // Per-(cargo,distance) unit economics for AIR. Planes fly near-straight, so
    // the effective distance is ~euclidean (cheaper than rail's detour factor),
    // and the fleet is fast with no track to build - just two airports + plane.
    static function _AirUnit(cargo, dist) {
        local plane = Air.PlaneSet(cargo);
        if (plane == null) return null;
        // Euclidean-ish flight distance from the manhattan span.
        local air_dist = dist;   // dist is already manhattan; planes ~0.8x of it
        local fly = (air_dist.tofloat() * 0.8).tointeger();
        if (fly < 1) fly = 1;
        local trip_days = (fly.tofloat()
                           / (plane.speed.tofloat() * Estimator.TILES_PER_DAY_PER_KMH)).tointeger();
        if (trip_days < 1) trip_days = 1;
        return {
            mode                   = AIVehicle.VT_AIR,
            capacity_per_train     = plane.capacity,
            running_cost_per_train = plane.running_cost,
            trip_days              = trip_days,
            payment_per_unit       = AICargo.GetCargoIncome(cargo, fly, trip_days),
            build_cost             = 2 * Air.AIRPORT_COST_EST + plane.price,
        };
    }

    // Per-(cargo,distance) unit economics for ROAD. Roads wind a bit (factor
    // 1.3); a road vehicle is slow but the infrastructure is cheap (drive-through
    // stops + depot + per-tile road), so road wins for SHORT, low-volume hauls.
    static function _RoadUnit(cargo, dist) {
        local veh = Road.VehicleSet(cargo);
        if (veh == null) return null;
        local road_dist = (dist.tofloat() * 1.3).tointeger();
        local trip_days = (road_dist.tofloat()
                           / (veh.speed.tofloat() * Estimator.TILES_PER_DAY_PER_KMH)).tointeger();
        if (trip_days < 1) trip_days = 1;
        // Cheap infra: ~400/tile road + 2 drive-through stops (~4000 each) + depot.
        local build_cost = dist * 400 + 2 * 4000 + 2000 + veh.price;
        return {
            mode                   = AIVehicle.VT_ROAD,
            capacity_per_train     = veh.capacity,
            running_cost_per_train = veh.running_cost,
            trip_days              = trip_days,
            payment_per_unit       = AICargo.GetCargoIncome(cargo, road_dist, trip_days),
            build_cost             = build_cost,
        };
    }

    // The modes we will weigh, cheapest-infrastructure first. Road is a no-op
    // (UnitEconomics returns null) until Phase 3. Air is estimated explicitly by
    // the air scan (mode=VT_AIR), not via this default rail-pair loop, so it
    // stays out of MODES (rail industry pairs must not be priced as flights).
    static MODES = [AIVehicle.VT_RAIL];

    // Full estimate for a candidate route, choosing the BEST available mode at
    // this cargo/distance. Returns a metrics table (with `mode`), or null if no
    // mode can serve the cargo. AI* glue around the pure Compute().
    // `mode` may be forced (a specific AIVehicle.VT_*); default = pick the best.
    static function Estimate(cargo, dist, production, railtype, max_trains, mode = null) {
        local modes = (mode != null) ? [mode] : Estimator.MODES;
        local best = null;
        foreach (vt in modes) {
            local ue = Estimator.UnitEconomics(vt, cargo, dist, railtype);
            if (ue == null) continue;
            local m = Estimator.Compute({
                capacity_per_train     = ue.capacity_per_train,
                running_cost_per_train = ue.running_cost_per_train,
                trip_days              = ue.trip_days,
                production_per_month   = production,
                payment_per_unit       = ue.payment_per_unit,
                build_cost             = ue.build_cost,
                dist                   = dist,
                max_trains             = max_trains,
            });
            m.mode <- vt;
            // Rank modes by annual profit at this place's production (the same
            // figure the scan ranks pairs on), so the cheaper-infra mode only
            // wins when it actually earns more here.
            if (best == null || m.annual_profit > best.annual_profit) best = m;
        }
        return best;
    }

    // Distance buckets for the precomputed value surface: Fibonacci-spaced from
    // 10 up to `max_dist` (10,20,30,50,80,130,210,...). Dense at short range
    // where a tile or two changes the economics a lot, sparse at long range
    // where it doesn't - the same spacing AAAHogEx samples. PURE (unit-tested).
    static function DistanceBuckets(max_dist) {
        local out = [];
        local pred = 10;
        local d = 10;
        while (d < max_dist) {
            out.append(d);
            local nd = d + pred;
            pred = d;
            d = nd;
        }
        return out;
    }

    // Index of the bucket nearest `dist` in a bucket array. PURE (unit-tested).
    static function NearestBucket(buckets, dist) {
        if (buckets.len() == 0) return -1;
        local best = 0;
        local bestd = abs(buckets[0] - dist);
        for (local i = 1; i < buckets.len(); i++) {
            local dd = abs(buckets[i] - dist);
            if (dd < bestd) { bestd = dd; best = i; }
        }
        return best;
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
