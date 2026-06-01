// tests/test_town_authority.nut
// Unit tests for TownAuthority.ShouldBuildStatue (PURE decision).

(function() {
    local MIN = TownAuthority.MIN_CASH_AFTER;

    // Already has a statue -> never act again.
    assert_true(!TownAuthority.ShouldBuildStatue(1000000, true, true, MIN),
        "skip when town already has our statue");

    // Action not available -> can't act.
    assert_true(!TownAuthority.ShouldBuildStatue(1000000, false, false, MIN),
        "skip when build-statue action unavailable");

    // Affordable, available, no statue yet -> act.
    assert_true(TownAuthority.ShouldBuildStatue(MIN, false, true, MIN),
        "build statue when affordable + available + none yet");
    assert_true(TownAuthority.ShouldBuildStatue(MIN + 1, false, true, MIN),
        "build statue when comfortably above the floor");

    // Below the cash floor -> preserve build capital, don't act.
    assert_true(!TownAuthority.ShouldBuildStatue(MIN - 1, false, true, MIN),
        "skip when below the cash floor");
})();
