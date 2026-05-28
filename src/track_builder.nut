// src/track_builder.nut
// Build a double-track rail line between two "front-of-station" tiles.
//
// Uses our custom RailPathFinder (src/rail_pf.nut) â€” no external library
// dependency. Runs in two passes:
//   Pass 1 ("out"): src_front â†’ dst_front, isOutward=true
//     The cost function reserves room for a parallel return track.
//   Pass 2 ("back"): dst_front â†’ src_front, reversePath = out-path result
//     The cost function uses the out-path to guide the back track parallel.
//
// Returns a pair { out, back } where each value is an array of tile indices
// in travel order, or null if that direction failed.


class TrackBuilder {

    static MAX_CHUNKS = 500;   // pathfinder chunks per attempt
    static RETRY_CHUNKS = 800; // chunks for the relaxed-cost retry

    // Build both tracks. Returns { out, back } (either may be null on failure).
    // src_front, dst_front: first tile outside each station entrance (from
    //   StationBuilder.BuildAt result.front_tile).
    // src_prev, dst_prev:   the tile BEFORE front_tile along the approach
    //   direction, so the pathfinder starts with correct directional context.
    //   If null, a synthetic neighbour tile is inferred from the front tile.
    static function BuildDoubleTracks(src_front, src_prev, dst_front, dst_prev) {
        if (src_prev == null) src_prev = src_front + AIMap.GetTileIndex(-1, 0);
        if (dst_prev == null) dst_prev = dst_front + AIMap.GetTileIndex(-1, 0);

        // --- Pass 1: out track ---
        Log.Info(Log.PHASE_TRACK, "Pass 1 (out): pathfinding srcâ†’dst");
        local out_tiles = TrackBuilder._RunPathfinder(
            src_front, src_prev, dst_front, dst_prev,
            true,  // isOutward
            null,  // no reversePath yet
            "out");
        if (out_tiles == null) {
            Log.Err(Log.PHASE_TRACK, "Out track: pathfinding failed both attempts.");
            return { out = null, back = null };
        }

        // Reconstruct a Path chain from the tile array for use as reversePath.
        local out_path_chain = TrackBuilder._TilesToPathChain(out_tiles);

        // --- Pass 2: back track ---
        Log.Info(Log.PHASE_TRACK, "Pass 2 (back): pathfinding dstâ†’src alongside out-track");
        local back_tiles = TrackBuilder._RunPathfinder(
            dst_front, dst_prev, src_front, src_prev,
            false,        // isOutward = false for back track
            out_path_chain, // guide the back track to run parallel
            "back");
        if (back_tiles == null) {
            Log.Warn(Log.PHASE_TRACK, "Back track: pathfinding failed; single track only.");
        }

        return { out = out_tiles, back = back_tiles };
    }

    // Single pass: find a path then physically build it.
    // Returns the tile array on success, null on failure.
    static function _RunPathfinder(src_f, src_p, dst_f, dst_p,
                                    is_outward, rev_path, label) {
        local tiles = TrackBuilder._FindPath(
            src_f, src_p, dst_f, dst_p, is_outward, rev_path,
            TrackBuilder.MAX_CHUNKS, label);

        if (tiles == null) {
            // Retry with larger budget and relaxed cost.
            Log.Warn(Log.PHASE_TRACK, "[" + label + "] retry with relaxed budget");
            tiles = TrackBuilder._FindPathRelaxed(
                src_f, src_p, dst_f, dst_p, is_outward, rev_path, label);
        }
        if (tiles == null) return null;

        // The pathfinder stops at dst_f (the tile OUTSIDE the dest platform).
        // Append dst_p (the platform-entry tile) so _BuildPath lays the final
        // rail piece linking the approach through dst_f INTO the station.
        // (The source side already connects: src_p is prepended as a seed.)
        if (tiles[tiles.len() - 1] == dst_f
                && dst_p != null && tiles[tiles.len() - 1] != dst_p) {
            tiles.push(dst_p);
        }

        return TrackBuilder._BuildPath(tiles, label);
    }

    // Invoke RailPathFinder with standard cost settings.
    static function _FindPath(src_f, src_p, dst_f, dst_p,
                               is_outward, rev_path, max_chunks, label) {
        local pf = RailPathFinder();
        pf.isOutward   = is_outward;
        pf.reversePath = rev_path;
        pf.InitializePath(
            [[src_f, src_p]],
            [[dst_f, dst_p]]);
        return pf.FindPath(max_chunks, null);
    }

    // Retry with relaxed budget: double max_cost, allow more chunks.
    static function _FindPathRelaxed(src_f, src_p, dst_f, dst_p,
                                      is_outward, rev_path, label) {
        local pf = RailPathFinder();
        pf._max_cost        = 10000000;
        pf._max_bridge_length = 30;
        pf._max_tunnel_length = 20;
        pf.isOutward   = is_outward;
        pf.reversePath = rev_path;
        pf.InitializePath(
            [[src_f, src_p]],
            [[dst_f, dst_p]]);
        return pf.FindPath(TrackBuilder.RETRY_CHUNKS, null);
    }

    // Physically lay rail/bridges/tunnels along a tile list.
    // Returns the tile list on success (with warnings for any per-tile errors),
    // or null if the path is too short to be useful.
    static function _BuildPath(tiles, label) {
        if (tiles == null || tiles.len() < 3) {
            Log.Err(Log.PHASE_TRACK, "[" + label + "] path too short (" +
                (tiles != null ? tiles.len() : 0) + " tiles)");
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
                // Multi-tile step = bridge or existing tunnel.
                if (AITunnel.IsTunnelTile(prev) &&
                        AITunnel.GetOtherTunnelEnd(prev) == cur) {
                    // Existing tunnel, no build needed.
                    tunnels++;
                } else if (AITunnel.GetOtherTunnelEnd(prev) == cur) {
                    if (AITunnel.BuildTunnel(AIVehicle.VT_RAIL, prev)) {
                        tunnels++;
                    } else {
                        Log.Warn(Log.PHASE_TRACK,
                            "[" + label + "] tunnel build failed at " + prev
                            + ": " + AIError.GetLastErrorString());
                    }
                } else {
                    local bl = AIBridgeList_Length(step + 1);
                    if (!bl.IsEmpty()) {
                        if (AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), prev, cur)) {
                            bridges++;
                        } else {
                            Log.Warn(Log.PHASE_TRACK,
                                "[" + label + "] bridge build failed at " + prev
                                + ": " + AIError.GetLastErrorString());
                        }
                    }
                }
                continue;
            }

            if (AIRail.BuildRail(prev, cur, next)) {
                built++;
            } else {
                local err = AIError.GetLastError();
                if (err != AIError.ERR_ALREADY_BUILT) {
                    Log.Warn(Log.PHASE_TRACK,
                        "[" + label + "] rail fail at tile " + cur
                        + ": " + AIError.GetLastErrorString());
                }
            }
        }

        Log.Info(Log.PHASE_TRACK,
            "[" + label + "] built " + built + " rail, "
            + bridges + " bridges, " + tunnels + " tunnels.");
        return tiles;
    }

    // Reconstruct a lightweight AyStar.Path chain from an ordered tile array.
    // Used to pass the out-path result as `reversePath` to the back-track PF.
    // The chain doesn't need real costs â€” just tile linkage.
    static function _TilesToPathChain(tiles) {
        if (tiles == null || tiles.len() == 0) return null;
        // Cost function that returns 0 (we only need the tile structure).
        local zero_cost = function(self_, path, tile, dir, mode) { return 0; };
        local chain = null;
        foreach (tile in tiles) {
            chain = AyStar.Path(chain, tile, 0xFF, null, zero_cost, null);
        }
        return chain;
    }
}
