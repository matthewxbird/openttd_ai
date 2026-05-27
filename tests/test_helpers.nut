// tests/test_helpers.nut
// Tiny assertion helpers. No framework dependency.

if (!("Tests" in getroottable())) {
    Tests <- { passed = 0, failed = 0 };
}

function assert_true(cond, msg) {
    if (cond) {
        Tests.passed++;
        print("  OK   " + msg + "\n");
    } else {
        Tests.failed++;
        print("  FAIL " + msg + "\n");
    }
}

function assert_eq(actual, expected, msg) {
    assert_true(actual == expected, msg + " (got " + actual + ", want " + expected + ")");
}

function assert_close(actual, expected, tol, msg) {
    local diff = actual - expected;
    if (diff < 0) diff = -diff;
    assert_true(diff <= tol, msg + " (got " + actual + ", want ~" + expected + " +/- " + tol + ")");
}
