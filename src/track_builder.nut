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

    static MAX_CHUNKS = 2000;   // pathfinder chunks per attempt
    static RETRY_CHUNKS = 6000; // chunks for the relaxed-cost retry
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
        // The handedness MUST be measured against ONE global axis (src -> dst)
        // at BOTH stations - not each station's local outbound direction. If we
        // used the local direction, the destination (whose throat faces back
        // toward the source) would pick the opposite physical side, and the two
        // parallel tracks would be forced to cross somewhere in the middle.
        local global_dir = TrackBuilder._DominantStep(src.enter_tile, dst.enter_tile);
        local s_pf = TrackBuilder._PickPlatforms(src, global_dir);  // { out, back }
        local d_pf = TrackBuilder._PickPlatforms(dst, global_dir);

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
    // `global_dir`: one-tile step along the dominant src->dst axis, the SAME
    // for both stations. The out track always rides the LEFT of this global
    // direction; so we pick, at each station, the platform on that left side.
    static function _PickPlatforms(st, global_dir) {
        local p0 = { enter = st.enter_tile,   front = st.front_tile };
        local p1 = { enter = st.enter_tile_b, front = st.front_tile_b };

        local right = RailPathFinder._RightOffset(global_dir);  // right-of-global offset
        local perp  = st.front_tile_b - st.front_tile;          // p0 -> p1 offset

        // perp points p0 -> p1. If it points to the RIGHT, then p1 is the
        // right-hand platform and p0 is the left -> out (left) uses p0.
        // If perp points LEFT, p1 is the left platform -> out uses p1.
        if (right != 0 && perp == right) {
            return { out = p0, back = p1 };
        }
        return { out = p1, back = p0 };
    }

    // One-tile step (+-1 or +-MapSizeX) along the dominant axis from -> to.
    static function _DominantStep(from, to) {
        local dx = AIMap.GetTileX(to) - AIMap.GetTileX(from);
        local dy = AIMap.GetTileY(to) - AIMap.GetTileY(from);
        if (abs(dx) >= abs(dy)) return (dx >= 0) ? 1 : -1;
        local mx = AIMap.GetMapSizeX();
        return (dy >= 0) ? mx : -mx;
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

        // A path that doesn't actually reach the destination is worse than no
        // path: building it lays a dead-end track and any train dispatched on
        // it strands at the station, unable to leave. Treat a non-arriving
        // (partial / budget-exhausted) result as failure so the route is
        // blacklisted instead of half-built.
        if (tiles != null && !TrackBuilder._Reaches(tiles, dst_f, dst_p)) {
            Log.Warn(Log.PHASE_TRACK, "[" + label + "] path did not reach destination; discarding");
            tiles = null;
        }

        if (tiles == null) {
            // Retry with larger budget and relaxed cost.
            Log.Warn(Log.PHASE_TRACK, "[" + label + "] retry with relaxed budget");
            tiles = TrackBuilder._FindPathRelaxed(
                src_f, src_p, dst_f, dst_p, is_outward, guide_tiles, label);
            if (tiles != null && !TrackBuilder._Reaches(tiles, dst_f, dst_p)) {
                Log.Warn(Log.PHASE_TRACK, "[" + label + "] relaxed path still short; giving up");
                tiles = null;
            }
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

    // Did the path actually arrive at the destination? True if its last tile
    // is the dest approach (front) or platform-entry tile, or adjacent to one.
    static function _Reaches(tiles, dst_f, dst_p) {
        if (tiles == null || tiles.len() == 0) return false;
        local last = tiles[tiles.len() - 1];
        if (last == dst_f || last == dst_p) return true;
        if (AIMap.DistanceManhattan(last, dst_f) <= 1) return true;
        if (dst_p != null && AIMap.DistanceManhattan(last, dst_p) <= 1) return true;
        return false;
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
        pf._max_cost        = 500000000;
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

    // Validate that a built path is actually CONTINUOUS rail end-to-end.
    // Walks the tile array and checks each segment really exists: a normal step
    // must be a rail / station / bridge / tunnel tile; a multi-tile step must be
    // a bridge or tunnel spanning exactly from prev to cur. Returns the index of
    // the FIRST broken segment, or -1 if the whole path is intact.
    static function FindGap(tiles) {
        if (tiles == null || tiles.len() < 2) return 0;
        for (local i = 1; i < tiles.len(); i++) {
            local prev = tiles[i - 1];
            local cur  = tiles[i];
            local step = AIMap.DistanceManhattan(prev, cur);
            if (step > 1) {
                // Expect a bridge or tunnel from prev to cur.
                local ok =
                    (AIBridge.IsBridgeTile(prev) && AIBridge.GetOtherBridgeEnd(prev) == cur)
                 || (AITunnel.IsTunnelTile(prev) && AITunnel.GetOtherTunnelEnd(prev) == cur)
                 || (AIBridge.IsBridgeTile(cur)  && AIBridge.GetOtherBridgeEnd(cur)  == prev)
                 || (AITunnel.IsTunnelTile(cur)  && AITunnel.GetOtherTunnelEnd(cur)  == prev);
                if (!ok) return i;
            } else {
                // Normal step: cur must carry rail of some kind.
                local ok = AIRail.IsRailTile(cur)
                        || AIRail.IsRailStationTile(cur)
                        || AIBridge.IsBridgeTile(cur)
                        || AITunnel.IsTunnelTile(cur);
                if (!ok) return i;
            }
        }
        return -1;
    }

    static function IsConnected(tiles) {
        return TrackBuilder.FindGap(tiles) == -1;
    }

    // Validate a path and, if broken, try to repair it by re-running the
    // builder (BuildRail/Bridge/Tunnel are idempotent - existing pieces report
    // ERR_ALREADY_BUILT, missing ones get built). Returns true if the path is
    // intact afterwards.
    static function ValidateAndRepair(tiles, label) {
        local gap = TrackBuilder.FindGap(tiles);
        if (gap == -1) return true;
        Log.Warn(Log.PHASE_TRACK,
            "[" + label + "] track gap at segment " + gap
            + " (tile " + tiles[gap] + ") - attempting repair.");
        TrackBuilder._BuildPath(tiles, label + ":repair");
        gap = TrackBuilder.FindGap(tiles);
        if (gap == -1) {
            Log.Info(Log.PHASE_TRACK, "[" + label + "] repair succeeded; track now continuous.");
            return true;
        }
        Log.Err(Log.PHASE_TRACK,
            "[" + label + "] still broken at segment " + gap + " after repair.");
        return false;
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
