// src/autoreplace.nut
// Yearly tick: for each cargo we serve, re-pick the best engine for the
// current railtype, and set autoreplace from any older engine to the
// new best. AIGroup.GROUP_ALL is fine for company-wide replacement.

require("logger.nut");
require("trains.nut");

class AutoReplace {

    last_year_ticked = -1;

    constructor() {
        this.last_year_ticked = -1;
    }

    // Call once per main loop. Internally throttles to once per game year.
    function Tick(railtype, state) {
        local year = AIDate.GetYear(AIDate.GetCurrentDate());
        if (year == this.last_year_ticked) return;
        this.last_year_ticked = year;

        Log.Info(Log.PHASE_REPLACE, "Yearly autoreplace check (year=" + year + ")");

        // Collect distinct cargoes served by built routes.
        local seen = {};
        foreach (_, r in state.routes) {
            seen[r.cargo] <- true;
        }

        foreach (cargo, _ in seen) {
            local best = Trains.PickEngine(cargo, railtype);
            if (best == -1) continue;

            // Set autoreplace for the company: every other rail engine
            // currently in use should be swapped for `best`.
            local all_engines = AIEngineList(AIVehicle.VT_RAIL);
            foreach (eng, __ in all_engines) {
                if (eng == best) continue;
                if (AIEngine.IsWagon(eng)) continue;
                if (!AIEngine.CanRunOnRail(eng, railtype)) continue;
                AIGroup.SetAutoReplace(AIGroup.GROUP_ALL, eng, best);
            }
            Log.Info(Log.PHASE_REPLACE,
                "Cargo " + AICargo.GetCargoLabel(cargo) + " -> autoreplace to "
                + AIEngine.GetName(best));
        }
    }
}
