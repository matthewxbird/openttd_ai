// src/signals.nut
// Place one-way PBS signals along a built path. PBS_ONEWAY blocks
// wrong-direction entry, which is what we want on a double-track main
// line (each track flows in only one direction).
//
// We skip the first and last few tiles (station throat) and place a
// signal every N tiles.


class Signals {

    static SPACING        = 4;   // tiles between signals
    static SKIP_NEAR_END  = 2;   // don't signal right at the station entrance

    // path:    tiles in order src -> dst
    // forward: true if the track flows src -> dst (front tile = next),
    //          false if dst -> src.
    // oneway:  one-way PBS (double-track main, each rail one direction) vs
    //          two-way PBS (single-track route run by ONE reversing train, which
    //          must be allowed to pass each signal in BOTH directions).
    // Returns count of signals placed.
    static function PlaceAlong(path, forward, label, oneway = true) {
        local sigtype = oneway ? AIRail.SIGNALTYPE_PBS_ONEWAY : AIRail.SIGNALTYPE_PBS;
        if (path == null || path.len() < (Signals.SKIP_NEAR_END * 2 + Signals.SPACING)) {
            Log.Warn(Log.PHASE_SIGNAL, "[" + label + "] path too short for signals");
            return 0;
        }

        local placed = 0;
        local start  = Signals.SKIP_NEAR_END;
        local end    = path.len() - Signals.SKIP_NEAR_END - 1;

        for (local i = start; i < end; i += Signals.SPACING) {
            local tile = path[i];
            local front_index = forward ? (i + 1) : (i - 1);
            if (front_index < 0 || front_index >= path.len()) continue;
            local front = path[front_index];

            // BuildSignal returns false if already exists or terrain
            // disallows; we tolerate failures silently except logging
            // totals at the end.
            if (AIRail.BuildSignal(tile, front, sigtype)) {
                placed++;
            }
        }

        Log.Info(Log.PHASE_SIGNAL, "[" + label + "] placed " + placed + " PBS one-way signals");
        return placed;
    }

    // Strip every signal along a path (both facings per tile). The single->double
    // UPGRADE clears the route's two-way PBS before laying one-way PBS, because
    // BuildSignal won't overwrite an existing signal. Returns count removed.
    static function RemoveAlong(path, label) {
        if (path == null) return 0;
        local removed = 0;
        for (local i = 1; i < path.len() - 1; i++) {
            local tile = path[i];
            foreach (j in [i + 1, i - 1]) {
                if (j < 0 || j >= path.len()) continue;
                if (AIRail.GetSignalType(tile, path[j]) != AIRail.SIGNALTYPE_NONE) {
                    if (AIRail.RemoveSignal(tile, path[j])) removed++;
                }
            }
        }
        Log.Info(Log.PHASE_SIGNAL, "[" + label + "] removed " + removed + " signals for upgrade");
        return removed;
    }
}
