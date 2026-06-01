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
            local metric = Strategy.Metric(c, mode);
            local cluster = ("cluster" in c) ? c.cluster : 2;
            local score = Scoring.ClusterBoost(metric, cluster);
            // In ROI mode (cash-poor / early game) DON'T add the distance weight:
            // ROI already rewards capital efficiency, and distance-weighting on
            // top biases toward long, expensive routes that drain the small early
            // bank and fail to path more often. Cheap, short, high-ROI routes get
            // income flowing first. Throughput / per-vehicle modes still favour
            // distance (longer hauls earn more per trip once we're established).
            if (mode != "roi") score = Scoring.DistanceWeighted(score, c.distance);
            c.score = score;
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

    // ===================================================================
    // GAME-PHASE DOCTRINE (EARLY -> MID -> LATE). Separate axis from the
    // profit objective above: this picks the BUILD STYLE, not the ranking.
    //   early - land-grab: cheap single-track one-train lines, fast + wide.
    //   mid   - upgrade the proven lines (double-track / more trains), grow towns.
    //   late  - extreme optimisation, compound routes. (not yet a distinct build
    //           path; folded into mid until those features land.)
    // Phase is chosen from how many lines we've PROVEN, per the plan's
    // "upgrade once we have ~half a dozen" rule.
    // ===================================================================

    // Exit EARLY once this many routes are proven (promoted past probation).
    static EARLY_BUILT_EXIT = 6;

    // EARLY single-track is now a PER-ROUTE "simplest that works" decision, not a
    // blanket map-size switch (AAAHogEx-style: build the cheapest layout the route
    // actually needs, on any map). The old blanket single-track sank 256x256 (-13%)
    // because LONG, high-output lines starve on one reversing train; but that's a
    // throughput problem, not a map-size one. The estimator already sizes the fleet
    // a route's production justifies (est_num_trains, capped at MAX_TRAINS). So:
    //   - production a single reversing train can service  -> single-track
    //     (cheap, fast, collision-free land-grab; claims space) ON ANY MAP.
    //   - production that needs >=2 trains                  -> double-track
    //     (the only layout that can run a 2nd train without head-on collision).
    // This single-tracks the many low/medium-output land-grab lines everywhere
    // (the speed + footprint the early game wants) while still double-tracking the
    // few genuinely high-throughput routes that would otherwise starve.
    static EARLY_SINGLE_MAX_TRAINS = 1;

    // PURE: should an EARLY route be built single-track? `trains_needed` is the
    // fleet the estimator says the route's production justifies.
    static function EarlySingleTrack(phase, trains_needed) {
        return phase == "early" && trains_needed <= Strategy.EARLY_SINGLE_MAX_TRAINS;
    }

    // PURE: pick the build-style phase from the count of proven (built) routes.
    static function GamePhase(built_routes) {
        if (built_routes < Strategy.EARLY_BUILT_EXIT) return "early";
        return "mid";
    }

    // AI* wrapper: read the proven-route count and decide the build phase.
    static function GamePhaseFromGame(state) {
        local built = state.CountBuilt();
        local phase = Strategy.GamePhase(built);
        Log.Info(Log.PHASE_RANK,
            "[phase] " + phase + " (built=" + built
            + "/" + Strategy.EARLY_BUILT_EXIT + ")");
        return phase;
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
