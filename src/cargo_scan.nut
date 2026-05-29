// src/cargo_scan.nut
// Walk all cargoes the current climate offers, find every (producer,
// accepter) industry pair for each cargo, score it by ROI, and return
// a ranked candidate list. No building - just looking.
//
// Heavy AI* usage here: AICargoList, AIIndustryList_CargoProducing/Accepting,
// AIIndustry, AIMap. Verified in-game, not in unit tests.


class CargoScan {

    // How many days the income estimate uses. ~30 days = 1 month, a
    // reasonable expected delivery time for a medium route.
    static INCOME_DAYS = 30;

    // Minimum route length (tiles). Cargo payment scales with distance, so very
    // short hauls earn little per trip and aren't worth a whole double-track
    // line + station overhead - skip them.
    static MIN_DISTANCE = 40;

    // Towns this small aren't worth delivering end-chain goods/food to.
    static MIN_TOWN_POP = 300;

    // Build full list of candidate routes across all cargoes.
    // Returns array of { cargo, producer, accepter, distance, score }.
    static function Scan() {
        local out = [];
        local cargoes = AICargoList();
        Log.Info(Log.PHASE_SCAN, "Cargoes detected: " + cargoes.Count());

        foreach (cargo, _ in cargoes) {
            CargoScan._ScanCargo(cargo, out);
        }
        Log.Info(Log.PHASE_SCAN, "Total candidate pairs: " + out.len());
        return out;
    }

    // Append candidates for a single cargo to `out`.
    static function _ScanCargo(cargo, out) {
        local cargo_label = AICargo.GetCargoLabel(cargo);

        local producers  = AIIndustryList_CargoProducing(cargo);
        local accepters  = AIIndustryList_CargoAccepting(cargo);
        local town_cargo = CargoScan._TownAccepts(cargo);
        // Need producers, and SOMEWHERE to deliver: an industry accepter or
        // (for end-chain cargo) towns.
        if (producers.IsEmpty()) return;
        if (accepters.IsEmpty() && !town_cargo) return;

        Log.Info(Log.PHASE_SCAN,
            cargo_label + ": " + producers.Count() + " producers, "
            + accepters.Count() + " industry accepters"
            + (town_cargo ? " (+towns)" : ""));

        // End-chain cargoes (GOODS, FOOD, ...) are accepted by TOWNS, not
        // industries - that's where the chain terminates and the money is.
        foreach (prod_id, _ in producers) {
            local prod_loc = AIIndustry.GetLocation(prod_id);
            local prod_amt = AIIndustry.GetLastMonthProduction(prod_id, cargo);
            if (prod_amt <= 0) continue;

            // Industry accepters.
            foreach (acc_id, _ in accepters) {
                if (acc_id == prod_id) continue;
                CargoScan._Consider(out, cargo, prod_id, prod_amt, prod_loc,
                    acc_id, AIIndustry.GetLocation(acc_id), false);
            }

            // Town accepters (end of chain).
            if (town_cargo) {
                local towns = AITownList();
                foreach (town, _ in towns) {
                    if (AITown.GetPopulation(town) < CargoScan.MIN_TOWN_POP) continue;
                    CargoScan._Consider(out, cargo, prod_id, prod_amt, prod_loc,
                        town, AITown.GetLocation(town), true);
                }
            }
        }
    }

    // True if towns accept this cargo (it has a delivery town effect).
    static function _TownAccepts(cargo) {
        local te = AICargo.GetTownEffect(cargo);
        return te != AICargo.TE_NONE;
    }

    // Score one producer->accepter pair and append it as a candidate.
    static function _Consider(out, cargo, prod_id, prod_amt, prod_loc, acc_id, acc_loc, acc_is_town) {
        local dist = AIMap.DistanceManhattan(prod_loc, acc_loc);
        if (dist < CargoScan.MIN_DISTANCE) return;

        local payment    = AICargo.GetCargoIncome(cargo, dist, CargoScan.INCOME_DAYS);
        local build_cost = Scoring.BuildCostEstimate(dist);
        local profit     = Scoring.AnnualProfit(prod_amt, 99999, payment, build_cost);
        local score      = Scoring.DistanceWeighted(profit, dist);

        out.append({
            cargo       = cargo,
            producer    = prod_id,
            accepter    = acc_id,
            acc_is_town = acc_is_town,
            distance    = dist,
            production  = prod_amt,
            score       = score,
        });
    }

    // Log the single best candidate FOR EACH cargo, so you can confirm the
    // AI weighed every cargo - not just coal - and see why one wins. `ranked`
    // must already be sorted by score descending; the first time we see a
    // cargo is therefore its best route.
    static function LogPerCargoBest(ranked) {
        local seen = {};
        Log.Info(Log.PHASE_RANK, "Best annual profit per cargo:");
        foreach (c in ranked) {
            if (c.cargo in seen) continue;
            seen[c.cargo] <- true;
            Log.Info(Log.PHASE_RANK,
                "  " + AICargo.GetCargoLabel(c.cargo)
                + " best profit/yr=" + c.score
                + " (" + AIIndustry.GetName(c.producer)
                + " -> " + Route.AccepterName(c)
                + ", dist=" + c.distance + ")");
        }
    }

    // Log the top N candidates for visibility in the AI Debug window.
    static function LogTop(ranked, n = 5) {
        local limit = ranked.len() < n ? ranked.len() : n;
        for (local i = 0; i < limit; i++) {
            local c = ranked[i];
            local cargo_label = AICargo.GetCargoLabel(c.cargo);
            local prod_name   = AIIndustry.GetName(c.producer);
            local acc_name    = Route.AccepterName(c);
            Log.Info(Log.PHASE_RANK,
                "#" + (i + 1) + " " + cargo_label
                + " | " + prod_name + " -> " + acc_name
                + " | dist=" + c.distance
                + " | profit/yr=" + c.score);
        }
    }
}
