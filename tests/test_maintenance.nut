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

    // NextStuckStreak: increment while a train is stalled, reset when none are.
    assert_eq(Maintenance.NextStuckStreak(0, 1), 1, "a stuck train -> streak 1");
    assert_eq(Maintenance.NextStuckStreak(2, 3), 3, "still stuck -> streak +1");
    assert_eq(Maintenance.NextStuckStreak(2, 0), 0, "no stuck trains resets the streak");

    // ShouldCondemnStuck: condemn only at/after the limit.
    assert_true(!Maintenance.ShouldCondemnStuck(2, 3), "2 stuck passes -> keep");
    assert_true(Maintenance.ShouldCondemnStuck(3, 3),  "3 stuck passes -> condemn");
    assert_true(Maintenance.ShouldCondemnStuck(5, 3),  "5 stuck passes -> condemn");
})();
