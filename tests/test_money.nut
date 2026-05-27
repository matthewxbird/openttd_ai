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
