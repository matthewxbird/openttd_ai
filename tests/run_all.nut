// tests/run_all.nut
// Entrypoint for sq.exe. Loads stubs, source modules, test files, then
// prints a summary and exits non-zero on failure.
//
// Run from repo root:
//   sq.exe tests/run_all.nut

dofile("tests/stubs/ai_stubs.nut");
dofile("tests/test_helpers.nut");

// Source modules under test (pure ones only).
dofile("src/scoring.nut");
dofile("src/estimator.nut");
dofile("src/strategy.nut");
dofile("src/candidates.nut");
dofile("src/money.nut");
dofile("src/town_authority.nut");
dofile("src/trains.nut");
dofile("src/maintenance.nut");

// Test files.
dofile("tests/test_scoring.nut");
dofile("tests/test_estimator.nut");
dofile("tests/test_strategy.nut");
dofile("tests/test_candidates.nut");
dofile("tests/test_money.nut");
dofile("tests/test_town_authority.nut");
dofile("tests/test_trains.nut");
dofile("tests/test_maintenance.nut");

print("\n----\n");
print("passed: " + Tests.passed + "\n");
print("failed: " + Tests.failed + "\n");

if (Tests.failed > 0) {
    throw "TESTS FAILED";
}
print("ALL TESTS PASSED\n");
