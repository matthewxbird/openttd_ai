// tests/test_trains.nut
// Unit tests for Trains.EngineValue (PURE loco-ranking metric).

(function() {
    local K = Trains.POWER_SPEED_K;   // 50.0

    // Adequate power: sustainable = 50*1200/500 = 120 < rated 128 -> eff 120.
    assert_close(Trains.EngineValue(128, 1200, 500, 200), 120.0 / 200.0, 0.0001,
        "power-limited below rated -> eff = sustainable / cost");

    // Plenty of power: sustainable = 50*2000/400 = 250 > rated 100 -> eff 100.
    assert_close(Trains.EngineValue(100, 2000, 400, 300), 100.0 / 300.0, 0.0001,
        "power-rich -> capped at rated speed");

    // Weak engine penalised: sustainable = 50*500/500 = 50 << rated 200 -> eff 50.
    assert_close(Trains.EngineValue(200, 500, 500, 100), 50.0 / 100.0, 0.0001,
        "underpowered loco can't hold its rated speed");

    // A faster, adequately-powered loco beats a weak fast one at equal cost.
    local strong = Trains.EngineValue(120, 1500, 500, 200);
    local weak   = Trains.EngineValue(200, 400,  500, 200);
    assert_true(strong > weak, "adequately-powered beats underpowered at equal cost");

    // Zero max_speed means "no limit" -> treated as very fast (rated 1000).
    assert_close(Trains.EngineValue(0, 2000, 400, 200), 250.0 / 200.0, 0.0001,
        "max_speed 0 (unlimited) uses power-limited speed");

    // Guard rails.
    assert_true(Trains.EngineValue(100, 1000, 500, 0) < 0.0, "zero cost -> invalid (-1)");
})();
