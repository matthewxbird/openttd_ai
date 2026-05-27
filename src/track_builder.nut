// src/track_builder.nut
// Use the Pathfinder.Rail library to find a rail path between two
// "front" tiles, then build that path tile-by-tile (rail/bridge/tunnel).
//
// For double-track we run the pathfinder twice (once per direction).
// Simple and dumb: the two tracks are independent. They may end up
// nowhere near each other - acceptable for v1.
//
// Pathfinder.Rail must be imported in main.nut with:
//   import("pathfinder.rail", "RailPF", 1);
// We reference `RailPF` (the imported class name) at call time.

require("src/logger.nut");

class TrackBuilder {

    static MAX_PF_ITERATIONS = 10000;   // safety cap per attempt
    static PF_ITER_STEP      = 250;     // run pathfinder in chunks for logging

    // Find + build one track between two endpoints.
    // src_front / dst_front are the "front of station" tiles.
    // Retries once with relaxed cost if first attempt fails.
    // Returns array of tiles in the built path, or null on failure.
    static function BuildTrack(src_front, dst_front, label) {
        local path = TrackBuilder._FindPath(src_front, dst_front, label, false);
        if (path == null) {
            Log.Warn(Log.PHASE_TRACK, "[" + label + "] retry with relaxed cost");
            path = TrackBuilder._FindPath(src_front, dst_front, label, true);
        }
        if (path == null) {
            Log.Err(Log.PHASE_TRACK, "[" + label + "] pathfinder gave up");
            return null;
        }

        return TrackBuilder._BuildPath(path, label);
    }

    // Returns array of tiles (from src to dst) or null.
    static function _FindPath(src_front, dst_front, label, relaxed) {
        local pf = RailPF();
        pf.cost.max_cost     = relaxed ? 200000 : 100000;
        pf.cost.tile         = 100;
        pf.cost.diagonal_tile = 80;
        // Pathfinder.Rail wants pairs of [tile, tile-in-front-of-tile]
        // so it knows direction of entry/exit.
        pf.InitializePath(
            [[src_front, src_front + AIMap.GetTileIndex(1, 0)]],  // source: shoot in some direction
            [[dst_front, dst_front + AIMap.GetTileIndex(1, 0)]]   // dest
        );

        local iters = 0;
        local result = false;
        while (result == false && iters < TrackBuilder.MAX_PF_ITERATIONS) {
            result = pf.FindPath(TrackBuilder.PF_ITER_STEP);
            iters += TrackBuilder.PF_ITER_STEP;
            Log.Info(Log.PHASE_TRACK, "[" + label + "] pathfinder iter=" + iters);
        }

        if (result == null || result == false) {
            return null;
        }

        // Walk the linked Path back from goal to start, collect tiles.
        local tiles = [];
        local node = result;
        while (node != null) {
            tiles.append(node.GetTile());
            node = node.GetParent();
        }
        // Reverse so order is src -> dst.
        local reversed = [];
        for (local i = tiles.len() - 1; i >= 0; i--) reversed.append(tiles[i]);

        Log.Info(Log.PHASE_TRACK, "[" + label + "] path found, length=" + reversed.len());
        return reversed;
    }

    // Build rail/bridges/tunnels along a tile list. Returns the list on
    // success (so caller can place signals), null if any step failed
    // unrecoverably.
    static function _BuildPath(tiles, label) {
        if (tiles.len() < 3) {
            Log.Err(Log.PHASE_TRACK, "[" + label + "] path too short to build");
            return null;
        }

        local built = 0;
        local bridges = 0;
        local tunnels = 0;

        for (local i = 1; i < tiles.len() - 1; i++) {
            local prev = tiles[i - 1];
            local cur  = tiles[i];
            local next = tiles[i + 1];
            local step = AIMap.DistanceManhattan(prev, cur);

            if (step > 1) {
                // Gap means bridge or tunnel.
                if (AITunnel.GetOtherTunnelEnd(prev) == cur) {
                    if (AITunnel.BuildTunnel(AIVehicle.VT_RAIL, prev)) tunnels++;
                    else Log.Warn(Log.PHASE_TRACK, "tunnel fail: " + AIError.GetLastErrorString());
                } else {
                    local bridge_list = AIBridgeList_Length(step + 1);
                    if (!bridge_list.IsEmpty()) {
                        local bridge_type = bridge_list.Begin();
                        if (AIBridge.BuildBridge(AIVehicle.VT_RAIL, bridge_type, prev, cur)) bridges++;
                        else Log.Warn(Log.PHASE_TRACK, "bridge fail: " + AIError.GetLastErrorString());
                    }
                }
                continue;
            }

            if (AIRail.BuildRail(prev, cur, next)) {
                built++;
            } else {
                local err = AIError.GetLastError();
                if (err != AIError.ERR_ALREADY_BUILT) {
                    Log.Warn(Log.PHASE_TRACK, "rail fail at " + cur + ": " + AIError.GetLastErrorString());
                }
            }
        }

        Log.Info(Log.PHASE_TRACK,
            "[" + label + "] built rail=" + built + " bridges=" + bridges + " tunnels=" + tunnels);
        return tiles;
    }
}
