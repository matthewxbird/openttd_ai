// tests/test_estimator.nut
// Unit tests for Estimator.Compute - the PURE arithmetic core (no AI* calls).

(function() {
    // Helper: a baseline params table; override fields per case.
    local mk = function(over) {
        local p = {
            capacity_per_train     = 100,    // units a train holds
            running_cost_per_train = 5000,   // /yr
            trip_days              = 25,      // one way
            production_per_month   = 200,
            payment_per_unit       = 50,
            build_cost             = 200000,
            dist                   = 100,
            max_trains             = 4,
        };
        foreach (k, v in over) p[k] <- v;
        return p;
    };

    // round_trip = 2*25 + 10 = 60 days -> ~6.083 trips/yr.
    // per_train_year = 100 * 6.083 = 608.3 ; annual_prod = 200*12 = 2400.
    // num_trains = round(2400 / 608.3) = round(3.945) = 4 (capped at 4).
    {
        local m = Estimator.Compute(mk({}));
        assert_eq(m.num_trains, 4, "num_trains sized to production (capped)");
        // fleet_capacity = 608.3*4 = 2433 > annual_prod 2400 -> serviced=2400.
        assert_close(m.serviced_per_year, 2400.0, 1.0, "serviced capped by production");
        // income = 2400*50 = 120000.
        assert_close(m.income_per_year, 120000.0, 1.0, "income = serviced * payment");
        // running = 5000*4 = 20000 ; amort = 200000/10 = 20000.
        // profit = 120000 - 20000 - 20000 = 80000.
        assert_close(m.annual_profit, 80000.0, 1.0, "annual profit nets running + amortised build");
        // roi = 80000 / 200000 = 0.4
        assert_close(m.roi, 0.4, 0.001, "roi = profit / build_cost");
    }

    // Production-limited: tiny producer -> 1 train, serviced = production.
    {
        local m = Estimator.Compute(mk({ production_per_month = 30 }));
        assert_eq(m.num_trains, 1, "small producer -> 1 train");
        assert_close(m.serviced_per_year, 360.0, 1.0, "serviced = annual production when below fleet capacity");
    }

    // Capacity-limited: huge producer, cap trains -> serviced = fleet capacity.
    {
        local m = Estimator.Compute(mk({ production_per_month = 100000 }));
        assert_eq(m.num_trains, 4, "huge producer clamped to max_trains");
        // fleet capacity = 608.3 * 4 = ~2433, far below annual production.
        assert_true(m.serviced_per_year < 2500.0, "serviced limited by fleet capacity, not production");
    }

    // Distance affects trips: shorter trip -> more trips/yr -> fewer trains for
    // same production.
    {
        local short_trip = Estimator.Compute(mk({ trip_days = 5 }));
        local long_trip  = Estimator.Compute(mk({ trip_days = 60 }));
        assert_true(short_trip.trips_per_year > long_trip.trips_per_year,
            "shorter trips -> more trips per year");
    }

    // Negative profit when build cost dwarfs revenue.
    {
        local m = Estimator.Compute(mk({ payment_per_unit = 1, build_cost = 5000000 }));
        assert_true(m.annual_profit < 0.0, "unprofitable route has negative profit");
        assert_true(m.roi < 0.0, "unprofitable route has negative roi");
    }

    // ---- DistanceBuckets: Fibonacci-spaced value-surface distance axis ----
    {
        local b = Estimator.DistanceBuckets(250);
        assert_eq(b[0], 10, "first bucket is 10");
        assert_eq(b[1], 20, "second bucket is 20");
        assert_eq(b[2], 30, "third bucket is 30");
        assert_eq(b[3], 50, "fourth bucket is 50");
        assert_eq(b[4], 80, "fifth bucket is 80");
        assert_eq(b[5], 130, "sixth bucket is 130");
        assert_eq(b[6], 210, "seventh bucket is 210");
        assert_true(b[b.len() - 1] < 250, "all buckets below max_dist");
        // Buckets strictly increase (spacing widens with distance).
        local mono = true;
        for (local i = 1; i < b.len(); i++) if (b[i] <= b[i - 1]) mono = false;
        assert_true(mono, "buckets strictly increasing");
    }

    // ---- NearestBucket: snap a distance to the closest bucket --------------
    {
        local b = Estimator.DistanceBuckets(250);   // [10,20,30,50,80,130,210]
        assert_eq(Estimator.NearestBucket(b, 10), 0, "exact 10 -> bucket 0");
        assert_eq(Estimator.NearestBucket(b, 12), 0, "12 -> nearest 10");
        assert_eq(Estimator.NearestBucket(b, 100), 4, "100 -> nearest 80");
        assert_eq(Estimator.NearestBucket(b, 1000), b.len() - 1, "beyond max -> last bucket");
        assert_eq(Estimator.NearestBucket([], 50), -1, "empty buckets -> -1");
    }

})();
