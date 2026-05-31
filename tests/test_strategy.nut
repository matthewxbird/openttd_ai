// tests/test_strategy.nut
// Unit tests for the adaptive profit model's PURE parts: Decide, Metric, Apply.

(function() {
    // ---- Decide: mode selection by game state --------------------------
    {
        // Poor -> roi regardless of vehicle headroom.
        assert_eq(Strategy.Decide(100000, 0, 500), "roi", "poor company -> roi mode");
        assert_eq(Strategy.Decide(Strategy.RICH_CASH - 1, 0, 500), "roi", "just under rich -> roi");

        // Rich with lots of headroom -> buildtime.
        assert_eq(Strategy.Decide(1000000, 50, 500), "buildtime", "rich + headroom -> buildtime");

        // Rich but near the cap -> pervehicle (room < 30% and busy >= 70%).
        assert_eq(Strategy.Decide(1000000, 480, 500), "pervehicle", "rich + near cap -> pervehicle");

        // Cap unknown -> buildtime fallback when rich.
        assert_eq(Strategy.Decide(1000000, 0, 0), "buildtime", "rich + no cap info -> buildtime");
    }

    // ---- Metric: picks the right estimator field per mode --------------
    {
        local c = {
            est_roi = 0.4,
            est_income_per_btime = 1234.0,
            est_income_per_vehicle = 5678.0,
            est_profit = 80000.0,
            score = 1.0,
        };
        assert_close(Strategy.Metric(c, "roi"), 0.4, 0.0001, "roi mode -> est_roi");
        assert_close(Strategy.Metric(c, "buildtime"), 1234.0, 0.1, "buildtime mode -> per-build-time");
        assert_close(Strategy.Metric(c, "pervehicle"), 5678.0, 0.1, "pervehicle mode -> per-vehicle");

        // Missing metric -> falls back to est_profit.
        local bare = { est_profit = 999.0, score = 1.0 };
        assert_close(Strategy.Metric(bare, "roi"), 999.0, 0.1, "missing metric -> est_profit fallback");
    }

    // ---- Apply: rewrites score, preserves sign, weights distance -------
    {
        local cands = [
            { est_roi = 0.5, est_profit = 1.0, distance = 100, cluster = 2, score = 0.0 },
            { est_roi = -0.2, est_profit = 1.0, distance = 100, cluster = 2, score = 0.0 },
        ];
        Strategy.Apply(cands, "roi");
        // base 0.5, cluster 2 (no boost), distance 100 -> x(1+100/100)=x2 -> 1.0
        assert_close(cands[0].score, 1.0, 0.0001, "roi mode score = roi * distance weight");
        assert_true(cands[1].score < 0.0, "negative roi stays negative (excluded by build gate)");

        // Cluster boost increases score.
        local clustered = [{ est_roi = 0.5, distance = 0, cluster = 4, score = 0.0 }];
        Strategy.Apply(clustered, "roi");
        // cluster 4 -> extra 2 -> x(1+2*0.4)=x1.8 ; distance 0 -> x1 -> 0.9
        assert_close(clustered[0].score, 0.9, 0.0001, "cluster boost applied in all modes");
    }
})();
