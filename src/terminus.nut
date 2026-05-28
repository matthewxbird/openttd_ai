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
    static function _BuildThroat(st) {
        local e0 = st.enter_tile;
        local f0 = st.front_tile;
        local e1 = st.enter_tile_b;
        local f1 = st.front_tile_b;

        // Axis pointing OUT of the station (platform -> throat -> mainline).
        local out_dir = f0 - e0;
        local m0 = f0 + out_dir;
        local m1 = f1 + out_dir;

        // Diagonal links on each throat tile, connecting it to the OTHER
        // platform's tiles. These cross the two parallel lines together.
        // Best-effort: some pieces may already exist or be blocked; we only
        // need the crossover to be passable, so we try all and count wins.
        local built = 0;
        local tries = [
            [e0, f0, f1],   // platform 0 -> cross to f1 side
            [m0, f0, f1],   // out mainline -> cross to f1 side
            [e1, f1, f0],   // platform 1 -> cross to f0 side
            [m1, f1, f0],   // back mainline -> cross to f0 side
        ];
        foreach (t in tries) {
            if (AIRail.BuildRail(t[0], t[1], t[2])) {
                built++;
            } else {
                local err = AIError.GetLastErrorString();
                // ERR_ALREADY_BUILT means the link is already there — fine.
                if (err == "ERR_ALREADY_BUILT") built++;
            }
        }

        if (built == 0) {
            Log.Warn(Log.PHASE_TRACK,
                "Terminus crossover failed at station " + st.station_id
                + " (throat " + f0 + "/" + f1 + ").");
        } else {
            Log.Info(Log.PHASE_TRACK,
                "Terminus crossover built at station " + st.station_id
                + " (" + built + "/4 pieces).");
        }
        return built > 0;
    }
}
