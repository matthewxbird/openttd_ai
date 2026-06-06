// src/terminus.nut
// Build the throat crossover at a terminus station.
//
// Our stations are terminuses: trains drive IN, load/unload, then REVERSE and
// drive back out. We run double track, so a train arrives on the "out" line
// (into platform 0) and should leave on the "back" line (which connects to
// platform 1). For that to be possible the two platform throats must be linked
// at the station mouth so a train can cross between them. That link is this
// crossover.
//
// Geometry at one station throat (axis = the platform direction):
//
//     e0 == f0 == m0      platform 0 -> its mainline tile
//          \\  //
//     e1 == f1 == m1      platform 1 -> its mainline tile
//
//   e0/e1 : last platform tile (inside the station)
//   f0/f1 : front tile, just outside the platform (the "throat")
//   m0/m1 : first mainline tile beyond the throat
//   f0/f1 are side-by-side (one tile apart, perpendicular to the axis).
//
// We add the two diagonal "\\ //" pieces on each front tile. Combined with the
// straight platform->mainline pieces the pathfinder already laid, this turns
// the throat into a junction: a train can enter either platform from either
// mainline and leave on either mainline. PBS signals (placed separately) keep
// it collision-free.

class Terminus {

    // Build the crossover at both ends of a route.
    // src/dst are the station tables from StationBuilder.BuildAt.
    static function BuildBothEnds(src, dst) {
        local a = Terminus._BuildThroat(src);
        local b = Terminus._BuildThroat(dst);
        return a || b;   // at least one crossover built
    }

    // Build the crossover at one station throat.
    // Returns true if at least one diagonal piece was added.
    //
    // The crossover is placed ONE TILE OUT from the platform fronts, not on the
    // fronts themselves: f0/f1 stay as clean straight platform exits, and the
    // two lines only cross over each other at m0/m1, a tile clear of the
    // station. (Connecting right at the platform makes the unacceptable mess.)
    static function _BuildThroat(st) {
        local e0 = st.enter_tile;
        local f0 = st.front_tile;
        local e1 = st.enter_tile_b;
        local f1 = st.front_tile_b;

        // Axis pointing OUT of the station (platform -> throat -> mainline).
        local out_dir = f0 - e0;
        local m0 = f0 + out_dir;        // one tile out from platform 0 throat
        local m1 = f1 + out_dir;        // one tile out from platform 1 throat
        local n0 = m0 + out_dir;        // the next tile out again
        local n1 = m1 + out_dir;

        // Diagonal links at m0/m1 (one tile clear of the platforms), connecting
        // the two parallel lines so a train can swap tracks there - never on the
        // platform front. Best-effort: try all, count wins.
        local built = 0;
        local tries = [
            [f0, m0, m1],   // from platform 0 line -> cross to m1 side
            [n0, m0, m1],   // from outer mainline   -> cross to m1 side
            [f1, m1, m0],   // from platform 1 line -> cross to m0 side
            [n1, m1, m0],   // from outer mainline   -> cross to m0 side
        ];
        foreach (t in tries) {
            if (AIRail.BuildRail(t[0], t[1], t[2])) {
                built++;
            } else {
                local err = AIError.GetLastErrorString();
                // ERR_ALREADY_BUILT means the link is already there - fine.
                if (err == "ERR_ALREADY_BUILT") built++;
            }
        }

        // PROTECT THE CROSSOVER with TWO-WAY PBS path signals. The crossover is
        // a flat diamond; without signals two trains can enter and collide. We
        // use two-way (not one-way) path signals: at a terminus a train reverses
        // and passes the throat in BOTH directions, so a one-way signal would
        // block it from behind (the wrong-direction signals seen before).
        // Two-way PBS still reserves the whole crossover for one train at a time
        // (PBS won't deadlock); travel direction is enforced by the one-way
        // signals out on the main line, not here.
        local pbs = AIRail.SIGNALTYPE_PBS;
        local sigs = [
            [n0, m0], [f0, m0],   // approaches into m0 (mainline side, station side)
            [n1, m1], [f1, m1],   // approaches into m1
        ];
        foreach (s in sigs) {
            if (AIMap.IsValidTile(s[0]) && AIRail.IsRailTile(s[0])) {
                AIRail.BuildSignal(s[0], s[1], pbs);   // best-effort
            }
        }

        if (built == 0) {
            Log.Warn(Log.PHASE_TRACK,
                "Terminus crossover failed at station " + st.station_id
                + " (throat " + f0 + "/" + f1 + ").");
        } else {
            Log.Info(Log.PHASE_TRACK,
                "Terminus crossover built + signalled at station " + st.station_id
                + " (" + built + "/4 pieces).");
        }
        return built > 0;
    }
}
