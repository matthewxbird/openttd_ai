// src/candidates.nut
// PURE module - NO AI* calls. Tested via sq.exe.
//
// A "candidate" is a route we MIGHT build, represented as a plain table:
//   { cargo = <id>, producer = <id>, accepter = <id>, distance = <int>,
//     score = <float> }
//
// The blacklist is a set of pair keys (strings) we never want to retry
// in this session - e.g. pathfinder failed twice, terrain impossible.

class Blacklist {
    keys = null;

    constructor() {
        this.keys = {};
    }

    // Stable key for a (cargo, producer, accepter) triple.
    static function MakeKey(cargo, producer, accepter) {
        return cargo + ":" + producer + ":" + accepter;
    }

    function Add(cargo, producer, accepter) {
        this.keys[Blacklist.MakeKey(cargo, producer, accepter)] <- true;
    }

    function Has(cargo, producer, accepter) {
        return Blacklist.MakeKey(cargo, producer, accepter) in this.keys;
    }

    function Size() {
        local n = 0;
        foreach (_ in this.keys) n++;
        return n;
    }
}

class Candidates {
    // Sort candidates by `.score` descending. Stable for equal scores
    // (preserves input order so tests are deterministic).
    // Skips any candidate present in `blacklist` (may be null).
    static function Rank(candidates, blacklist = null) {
        local kept = [];
        foreach (c in candidates) {
            if (blacklist != null && blacklist.Has(c.cargo, c.producer, c.accepter)) {
                continue;
            }
            kept.append(c);
        }
        // Insertion sort - stable and fine for the small N we expect.
        for (local i = 1; i < kept.len(); i++) {
            local cur = kept[i];
            local j = i - 1;
            while (j >= 0 && kept[j].score < cur.score) {
                kept[j + 1] = kept[j];
                j--;
            }
            kept[j + 1] = cur;
        }
        return kept;
    }
}
