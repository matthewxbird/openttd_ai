// src/strategy.nut
// ADAPTIVE PROFIT MODEL. The single most important thing to optimise changes
// with the state of the company, so each tick we pick ONE objective and rank
// candidate routes by it:
//
//   "roi"        - cash-poor / early game: maximise return on investment so the
//                  bank grows as fast as possible (cheap, high-% routes first).
//   "buildtime"  - established with lots of vehicle headroom: maximise income
//                  per unit of building effort (throughput; expand fast).
//   "pervehicle" - approaching the vehicle cap: maximise income per vehicle so
//                  each scarce vehicle slot earns the most.
//
// The estimator already attaches roi / income-per-building-time /
// income-per-vehicle to every candidate; Strategy just chooses which one
// becomes the ranking score, and keeps the distance + cluster preferences as a
// consistent secondary weighting within the chosen mode.

class Strategy {
    // Below this bank balance we're "poor" -> grow capital (roi mode). TUNE.
    static RICH_CASH = 500000;

    // buildtime mode needs both real headroom AND not being near the cap.
    static HEADROOM_FRACTION = 0.30;   // >= 30% of the cap still free
    static BUSY_FRACTION     = 0.70;   // and < 70% of the cap in use

    // -- PURE decision (no AI* calls) -------------------------------------
    // cash:     bank balance
    // vehicles: current vehicle count of the dominant type
    // cap:      max vehicles allowed for that type
    // Returns the mode string.
    static function Decide(cash, vehicles, cap) {
        if (cash < Strategy.RICH_CASH) return "roi";
        if (cap <= 0) return "buildtime";
        local room = cap - vehicles;
        if (room >= cap * Strategy.HEADROOM_FRACTION
            && vehicles < cap * Strategy.BUSY_FRACTION) {
            return "buildtime";
        }
        return "pervehicle";
    }

    // The raw metric a candidate should be ranked by in `mode`, BEFORE distance
    // / cluster weighting. PURE. Falls back to annual profit if a metric is
    // missing (e.g. a candidate built before the estimator existed).
    static function Metric(c, mode) {
        if (mode == "roi"        && ("est_roi" in c))                return c.est_roi;
        if (mode == "buildtime"  && ("est_income_per_btime" in c))  return c.est_income_per_btime;
        if (mode == "pervehicle" && ("est_income_per_vehicle" in c)) return c.est_income_per_vehicle;
        return ("est_profit" in c) ? c.est_profit : c.score;
    }

    // Recompute each candidate's `.score` for the active mode. Distance and
    // cluster preferences are applied consistently so longer / multi-industry
    // routes stay favoured within the mode (the scan stores `cluster` on each
    // candidate for exactly this). Sign is preserved so unprofitable routes
    // (negative metric) stay excluded by the build loop's `score <= 0` gate.
    static function Apply(cands, mode) {
        foreach (c in cands) {
            local base = Strategy.Metric(c, mode);
            local cluster = ("cluster" in c) ? c.cluster : 2;
            c.score = Scoring.DistanceWeighted(Scoring.ClusterBoost(base, cluster), c.distance);
        }
    }

    // -- AI* wrapper: read game state and decide --------------------------
    static function DecideFromGame() {
        local cash = Money.Cash();
        local vehicles = AIGroup.GetNumVehicles(AIGroup.GROUP_ALL, AIVehicle.VT_RAIL);
        local cap = Strategy.MaxTrains();
        local mode = Strategy.Decide(cash, vehicles, cap);
        Log.Info(Log.PHASE_RANK,
            "[strategy] mode=" + mode + " (cash=" + cash
            + " trains=" + vehicles + "/" + cap + ")");
        return mode;
    }

    // Global max trains setting, with a safe fallback if unreadable.
    static function MaxTrains() {
        try {
            if (AIGameSettings.IsValid("max_trains")) {
                return AIGameSettings.GetValue("max_trains");
            }
        } catch (e) {}
        return 500;
    }
}
