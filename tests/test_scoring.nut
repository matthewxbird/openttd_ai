// tests/test_scoring.nut
// Exercise the pure scoring math.

print("test_scoring:\n");

// BuildCostEstimate grows roughly linearly with distance.
local c50  = Scoring.BuildCostEstimate(50);
local c100 = Scoring.BuildCostEstimate(100);
assert_true(c100 > c50, "build cost increases with distance");
assert_true(c100 < c50 * 3, "build cost roughly linear, not explosive");

// ROI: zero production => negative (only cost, no revenue).
local roi_zero = Scoring.EstimateROI(0, 100, 10, 100000);
assert_true(roi_zero < 0, "zero production yields negative ROI");

// ROI: accepter cap limits serviced amount.
local roi_capped   = Scoring.EstimateROI(500, 100, 50, 200000);
local roi_uncapped = Scoring.EstimateROI(500, 99999, 50, 200000);
assert_true(roi_uncapped > roi_capped, "uncapped accepter scores higher than capped");

// ROI: zero build cost guards against div-by-zero.
local roi_safe = Scoring.EstimateROI(100, 100, 50, 0);
assert_eq(roi_safe, -1.0, "zero build cost returns -1 sentinel");

// ROI: a healthy route should be positive.
local roi_good = Scoring.EstimateROI(200, 200, 80, 150000);
assert_true(roi_good > 0, "healthy route has positive ROI");
