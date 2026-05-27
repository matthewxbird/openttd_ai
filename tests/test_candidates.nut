// tests/test_candidates.nut
// Ranking + blacklist behaviour for pure Candidates module.

print("test_candidates:\n");

local cands = [
    { cargo = 1, producer = 10, accepter = 20, distance = 50, score = 0.5 },
    { cargo = 1, producer = 11, accepter = 20, distance = 80, score = 0.9 },
    { cargo = 2, producer = 12, accepter = 21, distance = 30, score = 0.1 },
    { cargo = 1, producer = 13, accepter = 22, distance = 60, score = 0.5 },  // tie with first
];

// Rank with no blacklist.
local ranked = Candidates.Rank(cands);
assert_eq(ranked.len(), 4, "rank keeps all when no blacklist");
assert_close(ranked[0].score, 0.9, 0.0001, "top score is 0.9");
assert_close(ranked[3].score, 0.1, 0.0001, "lowest score is 0.1");

// Stable tie-break: ties preserve original order. Original order of
// the two 0.5 entries was producer 10 then producer 13.
assert_eq(ranked[1].producer, 10, "stable tie-break: producer 10 comes first");
assert_eq(ranked[2].producer, 13, "stable tie-break: producer 13 comes second");

// With blacklist excluding the top entry.
local bl = Blacklist();
bl.Add(1, 11, 20);
local ranked2 = Candidates.Rank(cands, bl);
assert_eq(ranked2.len(), 3, "blacklist removes one entry");
assert_close(ranked2[0].score, 0.5, 0.0001, "new top is 0.5");

// Empty input.
local empty = Candidates.Rank([]);
assert_eq(empty.len(), 0, "empty input returns empty");

// Blacklist Has/Add.
local bl2 = Blacklist();
assert_true(!bl2.Has(1, 2, 3), "fresh blacklist contains nothing");
bl2.Add(1, 2, 3);
assert_true(bl2.Has(1, 2, 3), "added pair is found");
assert_true(!bl2.Has(1, 2, 4), "unadded pair is not found");
assert_eq(bl2.Size(), 1, "blacklist size 1 after one add");
