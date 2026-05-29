// src/planner.nut
// Look-ahead planning. When the build loop is HOLDING (a route is on probation,
// or an existing line still needs scaling) we don't sit idle - we spend the
// tick planning the next moves: log the routes we intend to build next, in ROI
// order, and pre-vet the top one's station feasibility in test mode so an
// impossible candidate is culled NOW instead of wasting a real build attempt
// later.

class Planner {

    static LOOKAHEAD = 3;   // how many upcoming routes to report

    // Run a planning pass over the ranked candidate list.
    static function LookAhead(state, ranked, railtype) {
        local shown = 0;
        foreach (c in ranked) {
            if (state.HasRoute(c.cargo, c.producer, c.accepter)) continue;
            if (state.blacklist.Has(c.cargo, c.producer, c.accepter)) continue;
            if (state.ProducerServed(c.producer)) continue;   // producer already feeds a line
            if (c.score <= 0) break;   // nothing worthwhile left

            local label = AICargo.GetCargoLabel(c.cargo);
            Log.Info(Log.PHASE_RANK,
                "[plan] next #" + (shown + 1) + ": " + label + " "
                + AIIndustry.GetName(c.producer) + " -> " + AIIndustry.GetName(c.accepter)
                + " (dist=" + c.distance + ", profit/yr=" + c.score + ")");

            // Pre-vet ONLY the top candidate (bounded work): confirm both ends
            // can actually take a station. If not, blacklist it now so the build
            // loop never wastes a real attempt on it.
            if (shown == 0) {
                local p_tile = AIIndustry.GetLocation(c.producer);
                local a_tile = AIIndustry.GetLocation(c.accepter);
                local src_ok = StationBuilder.CanBuildAt(c.producer, true,  a_tile);
                local dst_ok = StationBuilder.CanBuildAt(c.accepter, false, p_tile);
                if (!src_ok || !dst_ok) {
                    Log.Warn(Log.PHASE_RANK,
                        "[plan] top candidate has no station spot ("
                        + (src_ok ? "" : "src ") + (dst_ok ? "" : "dst ")
                        + "blocked); blacklisting ahead of time.");
                    state.blacklist.Add(c.cargo, c.producer, c.accepter);
                } else {
                    Log.Info(Log.PHASE_RANK, "[plan] top candidate pre-vetted: stations fit both ends.");
                }
            }

            shown++;
            if (shown >= Planner.LOOKAHEAD) break;
        }

        if (shown == 0) Log.Info(Log.PHASE_RANK, "[plan] no further viable routes to plan right now.");
    }
}
