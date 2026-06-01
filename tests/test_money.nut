// tests/test_money.nut
// Pure threshold check for Money.ShouldRepay. No AI* calls.

print("test_money:\n");

// No loan -> never repay.
assert_true(!Money.ShouldRepay(100000, 0, 10000), "no loan -> no repay");

// Cash below loan -> definitely no repay.
assert_true(!Money.ShouldRepay(5000, 100000, 10000), "cash below loan -> no repay");

// Cash equals loan + 1 step -> still no repay (need headroom).
assert_true(!Money.ShouldRepay(110000, 100000, 10000), "tight margin -> no repay");

// Cash way above loan -> repay.
assert_true(Money.ShouldRepay(200000, 100000, 10000), "comfortable surplus -> repay");

// headroom argument respected.
assert_true(Money.ShouldRepay(150000, 100000, 10000, 4), "exactly 4 steps headroom -> repay");
assert_true(!Money.ShouldRepay(140000, 100000, 10000, 5), "5-step headroom not met -> no repay");

// Zero step guard.
assert_true(!Money.ShouldRepay(999999, 100, 0), "zero step -> no repay");

// ---- RepayAmount: pay down to a cash buffer, whole steps only ----------
// No loan / no step -> nothing.
assert_eq(Money.RepayAmount(500000, 0, 10000, 80000), 0, "no loan -> repay 0");
assert_eq(Money.RepayAmount(500000, 100000, 0, 80000), 0, "no step -> repay 0");
// Cash at/under buffer -> nothing.
assert_eq(Money.RepayAmount(80000, 100000, 10000, 80000), 0, "cash == buffer -> repay 0");
assert_eq(Money.RepayAmount(50000, 100000, 10000, 80000), 0, "cash < buffer -> repay 0");
// Spare above buffer, rounded down to whole steps.
assert_eq(Money.RepayAmount(165000, 100000, 10000, 80000), 80000, "spare 85k -> repay 80k (whole steps)");
// Repay never exceeds the loan.
assert_eq(Money.RepayAmount(500000, 30000, 10000, 80000), 30000, "repay capped at loan");

// ---- BorrowTarget: raise loan just enough to cover a need --------------
// Already covered -> loan unchanged.
assert_eq(Money.BorrowTarget(100000, 50000, 80000, 10000, 500000), 50000, "cash covers need -> loan unchanged");
// Shortfall borrowed, rounded UP to whole steps.
assert_eq(Money.BorrowTarget(20000, 0, 55000, 10000, 500000), 40000, "borrow 35k shortfall -> 40k (whole steps)");
// Clamped to max loan.
assert_eq(Money.BorrowTarget(0, 0, 999999, 10000, 300000), 300000, "borrow clamped to max loan");
