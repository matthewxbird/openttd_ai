// src/track_builder.nut
// Build a double-track rail line between two "front-of-station" tiles.
//
// Uses our custom RailPathFinder (src/rail_pf.nut) â€” no external library
// dependency. Trains drive on the LEFT and the two tracks never cross.
//
// Runs in two passes:
//   Pass 1 ("out"): left platform â†’ left platform, isOutward=true.
//     The cost function reserves room one tile to the RIGHT of travel for the
//     parallel return track (so the out train rides the left rail).
//   Pass 2 ("back"): right platform â†’ right platform. The out-track tiles are
//     handed in as a guide: they bias the back track onto the correct (right)
//     side AND are passed as hard ignored_tiles, so the back track can never
//     sit on an out-track tile â€” guaranteeing the two tracks never cross.
//
// Which physical platform is "left" depends on station orientation, so
// _PickPlatforms chooses per station (see below).
//
// Returns a pair { out, back } where each value is an array of tile indices
// in travel order, or null if that direction failed.


class TrackBuilder {

    static MAX_CHUNKS = 500;   // pathfinder chunks per attempt
    static RETRY_CHUNKS = 800; // chunks for the relaxed-cost retry
    static MAX_SMOOTH  = 2;    // only flatten isolated bumps/dips up to this height diff
    static STATION_GUARD = 2;  // don't terraform this many tiles next to a station
    static LEAD_IN     = 3;    // straight tiles out of each platform before any curve

    // Build both tracks between two stations. Returns { out, back }.
    // `src`, `dst`: StationBuilder.BuildAt result tables. Each has front_tile/
    //   enter_tile (platform 0) and front_tile_b/enter_tile_b (platform 1).
    //
    // The out-track uses platform 0 at both stations; the back-track uses
    // platform 1. Each track gets its OWN platform so neither has to cross
    // over at the throat (which is what caused the tight S-curve). Before
    // pathfinding we lay a straight lead-in stub out of each platform so any
    // curve is pushed well clear of the station entrance.
    static function BuildDoubleTracks(src, dst) {
        local src_h = AITile.GetMaxHeight(src.enter_tile);
        local dst_h = AITile.GetMaxHeight(dst.enter_tile);

        // LEFT-HAND ASSIGNMENT. The out train must ride the LEFT rail of the
        // pair. A station's two platforms (0 and 1) sit perpendicular to the
        // track axis; which one is on the left of departure depends on the
        // station's orientation. Pick, at each station, the platform that is on
        // the left of out-travel for the OUT track; the back track uses the
        // other. That makes the back track consistently the RIGHT-hand rail
        // (= left for the returning train), and it lines up with the
        // right-of-travel side the pathfinder reserves and biases toward.
        local s_pf = TrackBuilder._PickPlatforms(src);  // { out, back } tile pairs
        local d_pf = TrackBuilder._PickPlatforms(dst);

        // --- Pass 1: out track (left platform -> left platform) ---
        Log.Info(Log.PHASE_TRACK, "Pass 1 (out): straight lead-ins + pathfind srcâ†’dst");
        local s_out = TrackBuilder._BuildLeadIn(s_pf.out.enter, s_pf.out.front, src_h);
        local d_out = TrackBuilder._BuildLeadIn(d_pf.out.enter, d_pf.out.front, dst_h);
        local out_tiles = TrackBuilder._RunPathfinder(
            s_out.tip, s_out.prev, d_out.tip, d_out.prev,
            true,  // isOutward
            null,  // no guide yet
            "out");
        if (out_tiles == null) {
            Log.Err(Log.PHASE_TRACK, "Out track: pathfinding failed both attempts.");
            return { out = null, back = null };
        }

        // --- Pass 2: back track (right platform -> right platform) ---
        // The out-track tiles are passed as the guide: they (a) seed the
        // parallel side-bias so the back track hugs ONE side (left-hand
        // running) and (b) are used as hard ignored_tiles so the back track
        // can never sit on an out-track tile - guaranteeing the two tracks
        // never cross.
        Log.Info(Log.PHASE_TRACK, "Pass 2 (back): straight lead-ins + pathfind dstâ†’src");
        local s_back = TrackBuilder._BuildLeadIn(s_pf.back.enter, s_pf.back.front, src_h);
        local d_back = TrackBuilder._BuildLeadIn(d_pf.back.enter, d_pf.back.front, dst_h);
        local back_tiles = TrackBuilder._RunPathfinder(
            d_back.tip, d_back.prev, s_back.tip, s_back.prev,
            false,      // isOutward = false for back track
            out_tiles,  // guide + no-cross set
            "back");
        if (back_tiles == null) {
            Log.Warn(Log.PHASE_TRACK, "Back track: pathfinding failed; single track only.");
        }

        return { out = out_tiles, back = back_tiles };
    }

    // Decide which of a station's two platforms the OUT track uses so the out
    // train rides the LEFT rail of the pair. Returns:
    //   { out  = { enter, front },   // platform on the left of out-travel
    //     back = { enter, front } }  // the other platform
    // Platform 0 = { enter_tile, front_tile }; platform 1 = the *_b tiles,
    // sitting one tile to the side (perp) of platform 0.
    static function _PickPlatforms(st) {
        local p0 = { enter = st.enter_tile,   front = st.front_tile };
        local p1 = { enter = st.enter_tile_b, front = st.front_tile_b };

        local depart = st.front_tile - st.enter_tile;          // out-travel direction
        local left   = -RailPathFinder._RightOffset(depart);   // left-of-travel offset
        local perp   = st.front_tile_b - st.front_tile;        // p0 -> p1 offset

        // If platform 1 sits on the left of departure, the out track uses it.
        if (left != 0 && perp == left) {
            return { out = p1, back = p0 };
        }
        return { out = p0, back = p1 };
    }

    // Lay a straight lead-in stub out of a platform along the platform axis,
    // so the main line approaches the station dead straight (no tight turn at
    // the throat). Best-effort: stops early if terrain blocks it.
    //   enter -> front is the one-tile outward step; we extend up to LEAD_IN
    //   tiles further. Returns { tip, prev } for the pathfinder to start from:
    //   tip = furthest tile reached, prev = the tile one step toward the station.
    static function _BuildLeadIn(enter, front, target_h) {
        local step = front - enter;          // unit step pointing AWAY from station
        local prev = enter;
        local cur  = front;
        local tip  = front;
        local back = enter;                  // tile one step toward station from tip
        for (local k = 0; k < TrackBuilder.LEAD_IN; k++) {
            local next = cur + step;
            if (!AIMap.IsValidTile(next)) break;
            if (!AITile.IsBuildable(next)) break;
            TrackBuilder._FlattenToHeight(cur,  target_h);
            TrackBuilder._FlattenToHeight(next, target_h);
            if (!AIRail.BuildRail(prev, cur, next)) break;  // rail on `cur`
            back = cur;
            prev = cur; cur = next; tip = next;
        }
        return { tip = tip, prev = back };
    }

    // Single pass: find a path then physically build it.
    // Returns the tile array on success, null on failure.
    static function _RunPathfinder(src_f, src_p, dst_f, dst_p,
                                    is_outward, guide_tiles, label) {
        local tiles = TrackBuilder._FindPath(
            src_f, src_p, dst_f, dst_p, is_outward, guide_tiles,
            TrackBuilder.MAX_CHUNKS, label);

        if (tiles == null) {
            // Retry with larger budget and relaxed cost.
            Log.Warn(Log.PHASE_TRACK, "[" + label + "] retry with relaxed budget");
            tiles = TrackBuilder._FindPathRelaxed(
                src_f, src_p, dst_f, dst_p, is_outward, guide_tiles, label);
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
                               is_outward, guide_tiles, max_chunks, label) {
        local pf = RailPathFinder();
        pf.isOutward = is_outward;
        pf.outTiles  = guide_tiles;   // null for out pass, out-track array for back
        pf.InitializePath(
            [[src_f, src_p]],
            [[dst_f, dst_p]],
            guide_tiles == null ? [] : guide_tiles);  // hard no-cross set
        return pf.FindPath(max_chunks, null);
    }

    // Retry with relaxed budget: double max_cost, allow more chunks.
    static function _FindPathRelaxed(src_f, src_p, dst_f, dst_p,
                                      is_outward, guide_tiles, label) {
        local pf = RailPathFinder();
        pf._max_cost        = 10000000;
        pf._max_bridge_length = 30;
        pf._max_tunnel_length = 20;
        pf.isOutward = is_outward;
        pf.outTiles  = guide_tiles;
        pf.InitializePath(
            [[src_f, src_p]],
            [[dst_f, dst_p]],
            guide_tiles == null ? [] : guide_tiles);
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
        local leveled = 0;

        for (local i = 1; i < tiles.len() - 1; i++) {
            local prev = tiles[i - 1];
            local cur  = tiles[i];
            local next = tiles[i + 1];
            local step = AIMap.DistanceManhattan(prev, cur);

            // ---- TERRAFORM: flatten ONLY a clean isolated bump/dip ---------
            // Both neighbours must be at the SAME height and this tile a little
            // above/below them. Flattening it to that height yields three level
            // tiles - never a 1-step cliff between flat tiles (which renders as
            // sawtooth). Anything graded is left for the pathfinder to avoid;
            // it now penalises height changes and bans vertical zig-zags.
            local near_station = (i < TrackBuilder.STATION_GUARD)
                || (i >= tiles.len() - 1 - TrackBuilder.STATION_GUARD);
            local next_step = AIMap.DistanceManhattan(cur, next);
            if (step == 1 && next_step == 1 && !near_station) {
                local hp = AITile.GetMaxHeight(prev);
                local hc = AITile.GetMaxHeight(cur);
                local hn = AITile.GetMaxHeight(next);
                local d_local = abs(hc - hp);
                if (hp == hn                               // neighbours exactly level
                        && d_local >= 1
                        && d_local <= TrackBuilder.MAX_SMOOTH) {  // small bump only
                    if (TrackBuilder._FlattenToHeight(cur, hp)) leveled++;
                }
            }

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
            + bridges + " bridges, " + tunnels + " tunnels, "
            + leveled + " tiles leveled.");
        return tiles;
    }

    // Terraform a single tile FLAT at `target` height by raising/lowering each
    // corner one step at a time. Best-effort: every AI* call is allowed to fail
    // (e.g. blocked by a neighbour) and we just stop. Returns true if the tile
    // ends up flat at the target height.
    static function _FlattenToHeight(tile, target) {
        // corner query constant -> matching single-corner slope mask to move it.
        local corners = [
            [AITile.CORNER_W, AITile.SLOPE_W],
            [AITile.CORNER_S, AITile.SLOPE_S],
            [AITile.CORNER_E, AITile.SLOPE_E],
            [AITile.CORNER_N, AITile.SLOPE_N],
        ];
        for (local guard = 0; guard < 16; guard++) {
            if (AITile.GetSlope(tile) == AITile.SLOPE_FLAT
                    && AITile.GetMaxHeight(tile) == target) {
                return true;
            }
            local moved = false;
            foreach (c in corners) {
                local ch = AITile.GetCornerHeight(tile, c[0]);
                if (ch < target)      { if (AITile.RaiseTile(tile, c[1])) moved = true; }
                else if (ch > target) { if (AITile.LowerTile(tile, c[1])) moved = true; }
            }
            if (!moved) break;  // can't make progress (blocked) — give up
        }
        return AITile.GetSlope(tile) == AITile.SLOPE_FLAT
            && AITile.GetMaxHeight(tile) == target;
    }
}
