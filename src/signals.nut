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
    // Returns count of signals placed.
    static function PlaceAlong(path, forward, label) {
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
            if (AIRail.BuildSignal(tile, front, AIRail.SIGNALTYPE_PBS_ONEWAY)) {
                placed++;
            }
        }

        Log.Info(Log.PHASE_SIGNAL, "[" + label + "] placed " + placed + " PBS one-way signals");
        return placed;
    }
}
