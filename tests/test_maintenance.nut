// tests/test_maintenance.nut
// Unit tests for the PURE route-retirement helpers in Maintenance.

(function() {
    // NextLossStreak: increment on a losing year, reset on a profitable one.
    assert_eq(Maintenance.NextLossStreak(0, -5), 1, "first losing year -> streak 1");
    assert_eq(Maintenance.NextLossStreak(2, -1), 3, "another losing year -> streak +1");
    assert_eq(Maintenance.NextLossStreak(3, 10), 0, "a profitable year resets the streak");
    assert_eq(Maintenance.NextLossStreak(0, 0),  0, "break-even (0) is not a loss");

    // ShouldRetire: retire only at/after the limit.
    assert_true(!Maintenance.ShouldRetire(1, 2), "1 losing year -> keep");
    assert_true(Maintenance.ShouldRetire(2, 2),  "2 losing years -> retire");
    assert_true(Maintenance.ShouldRetire(3, 2),  "3 losing years -> retire");
})();
