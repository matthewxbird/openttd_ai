// src/roro.nut
// Drive-through (RoRo) terminus: a far-end return loop so trains DON'T reverse.
//
// WHY
// ===
// Our default station is a dead-end terminus: a train drives in, REVERSES, and
// leaves over a shared throat crossover. With 2+ trains that single crossover
// diamond is contended and DEADLOCKS — which is why MAX_TRAINS is pinned at 2
// and cramped maps prefer single-track. (See PLAN.md "reversing-terminus
// deadlock" / Phase 10.)
//
// RoRo removes the reversal entirely. We already lay TWO parallel tracks between
// the stations (out + back) and give each its own platform. Instead of crossing
// them at the NEAR throat (the reversing diamond), we connect the two platforms'
// FAR ends with a small U-turn loop. A train then flows as a one-way LOOP:
//
//     out-track --> platform-A (near..far) --> [far U-turn] -->
//     platform-B (far..near) --> back-track
//
// No reversal, no shared near-throat diamond, so many trains can circulate. The
// mainline one-way PBS (already placed on path_out / path_back) enforces the
// loop direction; the U-turn itself gets two-way PBS (a flat junction PBS
// reserves for one train at a time, like the old crossover did).
//
// GEOMETRY (from a StationBuilder record)
// =======================================
//   out_dir = front_tile - enter_tile     // points OUT of the near throat
//   perp    = enter_tile_b - enter_tile    // platform 0 -> platform 1 (1 tile)
//   L       = PLATFORM_LENGTH
//   far_in0  = enter_tile - out_dir*(L-1)  // platform 0, far-end station tile
//   far_out0 = enter_tile - out_dir*L      // one tile past the far end (outside)
//   far_in1/far_out1 = the platform-1 equivalents (+ perp)
// The loop connects far_out0 <-> far_out1 with a turnaround, which the rail
// pathfinder lays as a small balloon (reusing the robust builder, so we never
// hand-bake fragile curve geometry).

class RoRo {

    static TURN_DEPTH = 4;   // tiles of clear land the far-end turnaround needs

    // PRE-FLIGHT: is there room for the far-end turnaround loop? A flat crossover
    // over the platform gap is impossible (it forces a forbidden 90°), so a gapped
    // station has NO valid reversing fallback — if the loop can't be laid the route
    // is broken. We therefore only GAP a station (build it RoRo) when this returns
    // true; otherwise it is built as a normal adjacent terminus. far_out0/far_out1
    // are the tiles just past each platform's FAR end; out_dir points OUT the near
    // throat, so the turnaround extends in -out_dir (further from the station).
    static function TurnaroundClear(far_out0, far_out1, out_dir) {
        local corners = [
            far_out0, far_out1,
            far_out0 - out_dir * RoRo.TURN_DEPTH,
            far_out1 - out_dir * RoRo.TURN_DEPTH,
        ];
        local minx = AIMap.GetTileX(corners[0]); local maxx = minx;
        local miny = AIMap.GetTileY(corners[0]); local maxy = miny;
        foreach (c in corners) {
            local x = AIMap.GetTileX(c); local y = AIMap.GetTileY(c);
            if (x < minx) minx = x;
            if (x > maxx) maxx = x;
            if (y < miny) miny = y;
            if (y > maxy) maxy = y;
        }
        for (local x = minx; x <= maxx; x++) {
            for (local y = miny; y <= maxy; y++) {
                local t = AIMap.GetTileIndex(x, y);
                if (!AIMap.IsValidTile(t)) return false;
                if (!AITile.IsBuildable(t)) return false;   // water / slope / occupied
            }
        }
        return true;
    }

    // Build the far-end return loops at BOTH stations of a route. Returns true
    // only if BOTH loops built (so the whole route can run as a drive-through
    // loop). On failure the caller must clean-fail the route: a gapped station has
    // NO working reversing fallback (the gap crossover would be a forbidden 90°),
    // so a half-looped route can't run. (We only reach here for stations the
    // pre-flight TurnaroundClear passed, so failure is rare.)
    static function BuildBothEnds(src, dst) {
        local a = RoRo._BuildLoop(src);
        if (!a) {
            Log.Warn(Log.PHASE_TRACK, "RoRo loop failed at src station "
                + src.station_id + "; route will fall back to reversing terminus.");
            return false;
        }
        local b = RoRo._BuildLoop(dst);
        if (!b) {
            Log.Warn(Log.PHASE_TRACK, "RoRo loop failed at dst station "
                + dst.station_id + "; route will fall back to reversing terminus.");
            return false;
        }
        Log.Info(Log.PHASE_TRACK, "RoRo drive-through loops built at both ends "
            + "(src=" + src.station_id + " dst=" + dst.station_id + ").");
        return true;
    }

    // Build the U-turn loop connecting the two platforms' FAR ends at one
    // station. Returns true on success.
    static function _BuildLoop(st) {
        local L       = StationBuilder.PLATFORM_LENGTH;
        local out_dir = st.front_tile - st.enter_tile;        // out of near throat
        local perp    = st.enter_tile_b - st.enter_tile;       // platform0 -> platform1

        local far_in0  = st.enter_tile - out_dir * (L - 1);    // platform0 far station tile
        local far_out0 = far_in0 - out_dir;                    // one past the far end
        local far_in1  = far_in0 + perp;                       // platform1 far station tile
        local far_out1 = far_out0 + perp;

        // The far-end tiles must be on the map and not the station itself.
        if (!AIMap.IsValidTile(far_out0) || !AIMap.IsValidTile(far_out1)) return false;

        local h = AITile.GetMaxHeight(far_in0);

        // Lay a short straight stub OUT of each platform's far end, so the
        // turnaround curve is laid clear of the platform mouth (same trick the
        // mainline lead-ins use). _BuildLeadIn returns { tip, prev }.
        local s0 = TrackBuilder._BuildLeadIn(far_in0, far_out0, h);
        local s1 = TrackBuilder._BuildLeadIn(far_in1, far_out1, h);
        if (s0 == null || s1 == null) return false;

        // Pathfind the turnaround from platform-0's far stub to platform-1's far
        // stub. is_outward=false: this is a tight connector, not a mainline, so
        // the pathfinder is allowed its tight-turn cost (cheap at short range)
        // and will lay a compact balloon. _RunPathfinder builds + validates the
        // track and rejects 90-degree kinks, returning null if it can't.
        local loop = TrackBuilder._RunPathfinder(
            s0.tip, s0.prev, s1.tip, s1.prev,
            false,          // not outward (allow the turnaround's tight curve)
            null,           // no side guide
            "roro-loop");
        if (loop == null) return false;

        // Two-way PBS along the loop: a flat junction that PBS reserves for one
        // train at a time (deadlock-proof), exactly like the old crossover. The
        // mainline one-way signals enforce overall loop direction.
        local placed = Signals.PlaceAlong(loop, true, "roro-loop", false);  // two-way PBS

        // The turnaround is often SHORTER than PlaceAlong's minimum length, so it
        // would otherwise get ZERO signals and the whole loop + both platform
        // mouths collapse into ONE pbs block — only one train could be in the
        // turnaround region at a time, queuing the rest (the measured bottleneck).
        // Force an entry and an exit PBS so the loop is its own block and trains
        // hold in the platforms instead. Two-way: a train passes the loop one way.
        if (placed == 0 && loop.len() >= 3) {
            local pbs = AIRail.SIGNALTYPE_PBS;
            AIRail.BuildSignal(loop[1], loop[2], pbs);                       // entry
            AIRail.BuildSignal(loop[loop.len() - 2], loop[loop.len() - 3], pbs);  // exit
        }

        return true;
    }
}
