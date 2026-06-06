// src/town_authority.nut
// PHASE 5 - Town authority management.
//
// For routes that deliver end-chain cargo (goods/food/pax/mail) INTO a town,
// the town's local authority rating gates how much cargo our station there
// accepts and how freely we can build. Building a STATUE gives a permanent
// rating boost on every station we own in that town - so more cargo flows and
// the company earns more, for a one-off cost. We do it once per town we serve,
// when we can afford it.
//
// The decision (ShouldBuildStatue) is PURE and unit-tested; Tick() is the AI*
// glue that scans our town routes and performs the action.

class TownAuthority {
    // Keep at least this much cash AFTER funding an authority action, so we
    // never spend build capital we need for routes on a statue.
    static MIN_CASH_AFTER = 80000;

    // -- PURE decision (no AI* calls) -------------------------------------
    // cash:           current bank balance
    // has_statue:     does the town already have our statue?
    // action_avail:   is the build-statue action currently available?
    // min_cash_after: cash floor to preserve
    static function ShouldBuildStatue(cash, has_statue, action_avail, min_cash_after) {
        if (has_statue) return false;     // already done; permanent
        if (!action_avail) return false;  // authority won't allow it now
        return cash >= min_cash_after;    // only when comfortably affordable
    }

    // Raise our LOCAL-AUTHORITY rating in a town by planting a block of trees
    // near its centre (cheap, ~GBP1-2k, and authorities love trees). Use this to
    // recover from ERR_LOCAL_AUTHORITY_REFUSES before retrying a build (airport/
    // station), or proactively when a town's rating is poor.
    static function PlantTrees(town) {
        if (!AITown.IsValidTown(town)) return;
        local c   = AITown.GetLocation(town);
        local cx  = AIMap.GetTileX(c), cy = AIMap.GetTileY(c);
        local mx  = AIMap.GetMapSizeX(), my = AIMap.GetMapSizeY();
        local x1  = cx - 10, y1 = cy - 10;
        if (x1 < 1) x1 = 1; if (y1 < 1) y1 = 1;
        if (x1 + 20 >= mx) x1 = mx - 21; if (y1 + 20 >= my) y1 = my - 21;
        if (x1 < 1) x1 = 1; if (y1 < 1) y1 = 1;
        local before = AITown.GetRating(town, AICompany.COMPANY_SELF);
        AITile.PlantTreeRectangle(AIMap.GetTileIndex(x1, y1), 20, 20);
        Log.Info(Log.PHASE_STATION,
            "[authority] planted trees at " + AITown.GetName(town)
            + " to lift rating (was " + before + ").");
    }

    // True if the LAST AIError was a local-authority refusal.
    static function WasRefused() {
        return AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES;
    }

    // -- AI* glue ---------------------------------------------------------
    // Once per tick, look at every route that delivers into a town and build a
    // statue there if we should. Cheap: most ticks every served town already
    // has a statue and we skip.
    static function Tick(state) {
        local cash = Money.Cash();
        local done = {};   // town_id -> true, so we act at most once per town

        foreach (_, r in state.routes) {
            local is_town = ("acc_is_town" in r) ? r.acc_is_town : false;
            if (!is_town) continue;
            local town = r.accepter;
            if (town in done) continue;
            done[town] <- true;

            local has_statue   = AITown.HasStatue(town);
            local action_avail = AITown.IsActionAvailable(town, AITown.TOWN_ACTION_BUILD_STATUE);
            if (!TownAuthority.ShouldBuildStatue(cash, has_statue, action_avail, TownAuthority.MIN_CASH_AFTER)) {
                continue;
            }

            if (AITown.PerformTownAction(town, AITown.TOWN_ACTION_BUILD_STATUE)) {
                Log.Info(Log.PHASE_LOOP,
                    "[authority] built statue in " + AITown.GetName(town)
                    + " (rating boost for our stations there).");
                cash = Money.Cash();   // refresh after spending
            } else {
                Log.Warn(Log.PHASE_LOOP,
                    "[authority] statue in " + AITown.GetName(town)
                    + " failed: " + AIError.GetLastErrorString());
            }
        }
    }
}
