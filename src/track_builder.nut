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

    static DEBUG_DUMP = true;   // on a track-build failure, log an ASCII map of
                                // the region so we can see WHY the path failed
                                // (water/steep/blocked). Turn off once robust.
    static MAX_CHUNKS = 300;    // pathfinder chunks per attempt. Capped low
                                // (manual-test feedback): a route needing >300
                                // chunks (open set in the thousands) is too complex
                                // for us to build well - GIVE UP fast and move to a
                                // simpler, profitable route instead of grinding the
                                // opcode budget on one hard line.
    static RETRY_CHUNKS = 600;  // relaxed-cost retry - also capped (was 6000, which
                                // would just grind on after the 300 cap failed)
    static MAX_REBUILD = 5;     // reroute attempts around un-buildable segments
                                // (kept: the reroutes ARE load-bearing - measured)
    static MAX_SMOOTH  = 3;    // flatten isolated bumps/dips up to this height diff
    static STATION_GUARD = 2;  // don't terraform this many tiles next to a station
    static LEAD_IN     = 3;    // straight tiles out of each platform before any curve

    // Every tile we lay rail on during one BuildDoubleTracks call (lead-ins,
    // every path attempt, reroutes). Used to fully clean up a failed route -
    // partial track and lead-in stubs aren't in the returned path arrays.
    // NOTE: a static class slot can't be REASSIGNED at runtime in Squirrel, so
    // we mutate this array in place (clear/push), never `= []`.
    static _touched = [];
    static function _Touch(t) { TrackBuilder._touched.push(t); }

    static PREFLIGHT_RADIUS = 6;   // search this far around each industry for endpoints

    // PRE-FLIGHT (test mode, FREE): is there ANY rail path between these two
    // industries? Runs a single dry-run pathfind between buildable tiles near
    // each (no stations, no track, no money). Returns false ONLY when we are
    // confident no path exists, so the caller can blacklist the route WITHOUT
    // first building (and then tearing down) stations + lead-ins. When endpoints
    // can't be determined we return true (don't block - let the normal build try).
    // Skipped for town accepters (towns sit on open/road land; path is rarely
    // the blocker there and town endpoints are awkward to guess).
    static function CanReach(src_id, dst_id) {
        local sloc = AIIndustry.GetLocation(src_id);
        local dloc = AIIndustry.GetLocation(dst_id);
        local s = TrackBuilder._NearBuildable(
            AITileList_IndustryProducing(src_id, TrackBuilder.PREFLIGHT_RADIUS), dloc);
        local d = TrackBuilder._NearBuildable(
            AITileList_IndustryAccepting(dst_id, TrackBuilder.PREFLIGHT_RADIUS), sloc);
        if (s == null || d == null) return true;   // can't decide; don't block
        local sp = TrackBuilder._StepToward(s, sloc);
        local dp = TrackBuilder._StepToward(d, dloc);
        local tm = AITestMode();   // belt-and-braces: nothing here builds anyway
        local tiles = TrackBuilder._FindPath(
            s, sp, d, dp, true, null, [], TrackBuilder.MAX_CHUNKS, "preflight");
        return tiles != null && TrackBuilder._Reaches(tiles, d, dp);
    }

    // Nearest buildable tile in `list` to `target`, or null if none buildable.
    static function _NearBuildable(list, target) {
        if (list.IsEmpty()) return null;
        list.Valuate(AIMap.DistanceManhattan, target);
        list.Sort(AIList.SORT_BY_VALUE, true);   // nearest first
        foreach (t, _ in list) {
            if (AIMap.IsValidTile(t) && AITile.IsBuildable(t)) return t;
        }
        return null;
    }

    // One-tile step from `tile` toward `target` along the dominant axis.
    static function _StepToward(tile, target) {
        local dx = AIMap.GetTileX(target) - AIMap.GetTileX(tile);
        local dy = AIMap.GetTileY(target) - AIMap.GetTileY(tile);
        if (abs(dx) >= abs(dy)) return tile + ((dx >= 0) ? 1 : -1);
        local mx = AIMap.GetMapSizeX();
        return tile + ((dy >= 0) ? mx : -mx);
    }

    // Build both tracks between two stations. Returns { out, back }.
    // `src`, `dst`: StationBuilder.BuildAt result tables. Each has front_tile/
    //   enter_tile (platform 0) and front_tile_b/enter_tile_b (platform 1).
    //
    // The out-track uses platform 0 at both stations; the back-track uses
    // platform 1. Each track gets its OWN platform so neither has to cross
    // over at the throat (which is what caused the tight S-curve). Before
    // pathfinding we lay a straight lead-in stub out of each platform so any
    // curve is pushed well clear of the station entrance.
    // single_only: EARLY land-grab doctrine - build ONLY the out track (one
    // reversing train, two-way PBS) deliberately, skipping the back-track pass
    // entirely. Cheaper + faster to lay, so we plant more lines sooner and claim
    // map space. (This is the same single-track shape the back-track-failure
    // salvage produces, but chosen up front instead of as a fallback.)
    static function BuildDoubleTracks(src, dst, single_only = false) {
        TrackBuilder._touched.clear();   // start tracking every tile we lay rail on
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
            // Visual diagnosis: render the terrain between the endpoints so the
            // failure cause (water, steep gradient, blocked corridor) is legible
            // in the log without a GUI.
            if (TrackBuilder.DEBUG_DUMP) {
                MapDump.Region(src.enter_tile, dst.enter_tile,
                    [s_out.tip, d_out.tip], "out-fail");
            }
            // Return the tiles touched SO FAR (lead-in stubs, partial attempts) so
            // the caller can clean them up. Must always include `touched` - a
            // missing key crashes the whole AI on `tracks.touched` access.
            local touched_fail = [];
            foreach (t in TrackBuilder._touched) touched_fail.push(t);
            return { out = null, back = null, touched = touched_fail };
        }

        // EARLY land-grab: stop here with the out track only. One reversing
        // train runs it (two-way PBS), no second crossing to pay for or fail on.
        if (single_only) {
            Log.Info(Log.PHASE_TRACK, "Single-track (land-grab): skipping back-track pass.");
            local touched_s = [];
            foreach (t in TrackBuilder._touched) touched_s.push(t);
            return { out = out_tiles, back = null, touched = touched_s };
        }

        // --- Pass 2: back track (right platform -> right platform) ---
        local back_tiles = TrackBuilder.BuildBackTrack(src, dst, out_tiles);

        // Return a COPY so the caller's list survives the next build's clear().
        local touched = [];
        foreach (t in TrackBuilder._touched) touched.push(t);
        return { out = out_tiles, back = back_tiles, touched = touched };
    }

    // Build the BACK track of a route whose out track already exists, parallel
    // to it. Used both by the double-track first build (pass 2) and by the
    // demand-driven single->double UPGRADE. The out-track tiles guide it: they
    // (a) seed the parallel side-bias so the back track hugs ONE side (left-hand
    // running) and (b) are hard ignored_tiles so the back track can never sit on
    // an out-track tile - guaranteeing the two never cross. Returns the back
    // tiles or null. Appends to TrackBuilder._touched (caller collects/clears it).
    static function BuildBackTrack(src, dst, out_tiles) {
        local src_h = AITile.GetMaxHeight(src.enter_tile);
        local dst_h = AITile.GetMaxHeight(dst.enter_tile);
        local global_dir = TrackBuilder._DominantStep(src.enter_tile, dst.enter_tile);
        local s_pf = TrackBuilder._PickPlatforms(src, global_dir);
        local d_pf = TrackBuilder._PickPlatforms(dst, global_dir);

        Log.Info(Log.PHASE_TRACK, "Back track: straight lead-ins + pathfind dstâ†’src");
        local s_back = TrackBuilder._BuildLeadIn(s_pf.back.enter, s_pf.back.front, src_h);
        local d_back = TrackBuilder._BuildLeadIn(d_pf.back.enter, d_pf.back.front, dst_h);
        local back_tiles = TrackBuilder._RunPathfinder(
            d_back.tip, d_back.prev, s_back.tip, s_back.prev,
            false,      // isOutward = false for back track
            out_tiles,  // guide + no-cross set
            "back");
        if (back_tiles == null) {
            Log.Warn(Log.PHASE_TRACK, "Back track: pathfinding failed.");
            if (TrackBuilder.DEBUG_DUMP) {
                MapDump.Region(src.enter_tile, dst.enter_tile,
                    [s_back.tip, d_back.tip], "back-fail");
            }
        }
        return back_tiles;
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
            TrackBuilder._Touch(cur);
            back = cur;
            prev = cur; cur = next; tip = next;
        }
        return { tip = tip, prev = back };
    }

    // Find a path, build it, and VALIDATE it is continuous. If a segment can't
    // be built (water, blocked bridge, etc.) leaving a gap, add the offending
    // tiles to an avoid set and pathfind a DETOUR around them - retrying several
    // times before giving up. This backtracks and finds alternate routes instead
    // of abandoning at the first bad tile.
    // Returns the built (and verified) tile array, or null if no clean route.
    static function _RunPathfinder(src_f, src_p, dst_f, dst_p,
                                    is_outward, guide_tiles, label) {
        local avoid = [];   // tiles a previous attempt couldn't build on

        for (local attempt = 0; attempt < TrackBuilder.MAX_REBUILD; attempt++) {
            local ignored = TrackBuilder._MergeIgnored(guide_tiles, avoid);

            local tiles = TrackBuilder._FindPath(
                src_f, src_p, dst_f, dst_p, is_outward, guide_tiles, ignored,
                TrackBuilder.MAX_CHUNKS, label);
            // NO relaxed-budget retry (manual-test feedback): if the capped search
            // can't reach in MAX_CHUNKS, the route is too complex for us - GIVE UP
            // and let the ranker pick a simpler, profitable route. Grinding more
            // chunks is why we're slow vs AAHOG; speed (build many cheap routes
            // fast) beats completeness (one hard route slowly).
            if (tiles == null || !TrackBuilder._Reaches(tiles, dst_f, dst_p)) {
                Log.Warn(Log.PHASE_TRACK,
                    "[" + label + "] no path on attempt " + (attempt + 1)
                    + " (avoiding " + avoid.len() + " tiles).");
                if (avoid.len() == 0) return null;   // nothing to detour around
                continue;                            // shouldn't happen, but try again
            }

            // Append the platform-entry tile so the final rail links into the
            // station (pathfinder stops at dst_f, the tile outside the platform).
            if (tiles[tiles.len() - 1] == dst_f
                    && dst_p != null && tiles[tiles.len() - 1] != dst_p) {
                tiles.push(dst_p);
            }

            TrackBuilder._BuildPath(tiles, label);

            // Accept ONLY a path that is continuous AND has no 90-degree pivot.
            // A 90-degree turn is categorically rejected: we reroute around it
            // (or, failing that, abandon) so a train-stalling kink is never kept.
            local gap   = TrackBuilder.FindGap(tiles);
            local pivot = TrackBuilder.Find90Turn(tiles);
            if (gap == -1 && pivot == -1) return tiles;   // clean

            local bad    = (gap != -1) ? gap : pivot;
            local reason = (gap != -1) ? "build gap" : "90-degree turn";
            Log.Warn(Log.PHASE_TRACK,
                "[" + label + "] " + reason + " at segment " + bad + " (tile " + tiles[bad]
                + "); rerouting around it (attempt " + (attempt + 1) + "/"
                + TrackBuilder.MAX_REBUILD + ").");
            TrackBuilder._AddAvoid(avoid, tiles, bad);
        }

        Log.Err(Log.PHASE_TRACK,
            "[" + label + "] could not build a continuous track after "
            + TrackBuilder.MAX_REBUILD + " reroutes.");
        return null;
    }

    // Add the tiles around a build gap to the avoid set so the next pathfind
    // routes around them: the gap tile, its path neighbours, and its 4 map
    // neighbours (to push the detour clear of the obstacle).
    static function _AddAvoid(avoid, tiles, gap) {
        local mx = AIMap.GetMapSizeX();
        local seeds = [tiles[gap]];
        if (gap - 1 >= 0)          seeds.push(tiles[gap - 1]);
        if (gap + 1 < tiles.len()) seeds.push(tiles[gap + 1]);
        foreach (s in seeds) {
            foreach (off in [0, 1, -1, mx, -mx]) {
                local t = s + off;
                if (AIMap.IsValidTile(t)) avoid.push(t);
            }
        }
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

    // Merge the guide (no-cross) set with an avoid set into one ignored list.
    static function _MergeIgnored(guide_tiles, avoid) {
        local out = [];
        if (guide_tiles != null) foreach (t in guide_tiles) out.push(t);
        if (avoid != null)       foreach (t in avoid)       out.push(t);
        return out;
    }

    // Invoke RailPathFinder with standard cost settings.
    // guide_tiles: side-bias guide (back pass). ignored: hard no-go tiles
    // (guide + any avoided tiles from a failed build).
    static function _FindPath(src_f, src_p, dst_f, dst_p,
                               is_outward, guide_tiles, ignored, max_chunks, label) {
        local pf = RailPathFinder();
        pf.isOutward = is_outward;
        pf.outTiles  = guide_tiles;   // null for out pass, out-track array for back
        pf.InitializePath([[src_f, src_p]], [[dst_f, dst_p]], ignored);
        return pf.FindPath(max_chunks, null);
    }

    // Retry with relaxed budget: bigger cost ceiling, longer spans, more chunks.
    static function _FindPathRelaxed(src_f, src_p, dst_f, dst_p,
                                      is_outward, guide_tiles, ignored, label) {
        local pf = RailPathFinder();
        pf._max_cost        = 500000000;
        pf._max_bridge_length = 30;
        pf._max_tunnel_length = 20;
        pf.isOutward = is_outward;
        pf.outTiles  = guide_tiles;
        pf.InitializePath([[src_f, src_p]], [[dst_f, dst_p]], ignored);
        return pf.FindPath(TrackBuilder.RETRY_CHUNKS, null);
    }

    // Physically lay rail/bridges/tunnels along a tile list.
    // Returns the tile list on success (with warnings for any per-tile errors),
    // or null if the path is too short to be useful.
    // `repair`: LAST-RESORT mode (the post-build repair pass). Only then do we
    // aggressively terraform a failed tile flat / bridge a failed tunnel - on the
    // FIRST pass we leave failures as gaps for the reroute to detour, because
    // forcing rail onto terraformed/bridged tiles undoes the pathfinder's
    // deliberate slope/water avoidance and SLOWS the line (measured: eager
    // terraform regressed solo ~25%). In repair the alternative is abandoning the
    // route, so terraforming is pure upside.
    static function _BuildPath(tiles, label, repair = false) {
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
                        TrackBuilder._Touch(prev);   // we built this; track for cleanup
                    } else if (TrackBuilder._GroundCross(prev, cur, label)) {
                        built++;   // terraformed across instead of tunnelling
                    } else if (repair && TrackBuilder._BridgeSpan(prev, cur)) {
                        // Tunnel refused (often ERR_TUNNEL_CANNOT_BUILD_ON_WATER)
                        // and the span can't be ground-crossed (water). LAST-RESORT
                        // only: bridge it rather than abandon the route.
                        bridges++;
                    } else {
                        BuildDiag.Report(prev, label, "tunnel span");
                    }
                } else {
                    local bl = AIBridgeList_Length(step + 1);
                    if (!bl.IsEmpty()
                            && AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), prev, cur)) {
                        bridges++;
                        TrackBuilder._Touch(prev);   // we built this; track for cleanup
                    } else {
                        // The pathfinder's bridge endpoint was BLOCKED at build time
                        // (e.g. it must clear an existing rail and land BEYOND it -
                        // the correct grade-separated crossing - or a rival took the
                        // tile). EXTEND the bridge to the next CLEAR collinear path
                        // tile so it spans the obstacle and lands solid. Returns the
                        // new landing index; we splice out the spanned tiles so the
                        // continuity check sees one clean bridge.
                        local land_idx = TrackBuilder._BuildBridgeExtend(tiles, i);
                        if (land_idx > i) {
                            bridges++;
                            for (local k = land_idx - 1; k >= i; k--) tiles.remove(k);
                            // tiles[i] is now the bridge far end; loop i++ continues
                            // from there (prev = far end on the next iteration).
                        } else if (TrackBuilder._GroundCross(prev, cur, label)) {
                            built++;   // terraform + ground rail across (short obstacles)
                        } else {
                            BuildDiag.Report(prev, label, "bridge span");
                        }
                    }
                }
                continue;
            }

            local pre_rail = AIRail.IsRailTile(cur);   // existing line we're joining?
            if (AIRail.BuildRail(prev, cur, next)) {
                built++;
                // Only record tiles whose rail WE created. A junction tile that
                // already had rail must not be tracked, or a failed-route cleanup
                // would demolish the whole tile and break the existing line.
                if (!pre_rail) TrackBuilder._Touch(cur);
            } else if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) {
                // already there (existing line we're joining); do NOT touch it,
                // so a failed-route cleanup never demolishes another route's rail
            } else if (!near_station && !AIRail.IsRailTile(cur)
                    && !AIRail.IsRailStationTile(cur)
                    && TrackBuilder._ClearAndLay(prev, cur, next, repair)) {
                // Something was in the way (stray road, trees, or - in repair mode
                // - a slope worth terraforming). Clear it and lay rail - beats a
                // long detour. NEVER touch existing rail/stations or rival property
                // (those can't be cleared); _ClearAndLay then fails and we fall
                // through to the classified report, leaving the gap for the reroute.
                Log.Info(Log.PHASE_TRACK, "[" + label + "] cleared/terraformed " + cur + " to lay rail.");
                built++;
                TrackBuilder._Touch(cur);
            } else {
                // Unbuildable. Emit ONE classified line (owner + tile state, so
                // "ERR_UNKNOWN" becomes meaningful); the reroute pass detours.
                BuildDiag.Report(cur, label, "rail step");
            }
        }

        Log.Info(Log.PHASE_TRACK,
            "[" + label + "] built " + built + " rail, "
            + bridges + " bridges, " + tunnels + " tunnels, "
            + leveled + " tiles leveled.");
        return tiles;
    }

    // Recover a single failed flat-rail step on `cur` (between prev and next):
    // first try CLEARING a clearable obstacle (trees / object / stray road),
    // then try TERRAFORMING the tile flat (a slope or rough ground that gave
    // ERR_LAND_SLOPED_WRONG / ERR_AREA_NOT_CLEAR). Both no-op safely on rival
    // property (DemolishTile / Raise/LowerTile just fail), so this never touches
    // what isn't ours. Returns true if rail now sits on the tile. (Phase 8)
    static function _ClearAndLay(prev, cur, next, allow_terraform = false) {
        // Always try clearing a clearable obstacle (trees / object / stray road).
        if (AITile.DemolishTile(cur) && AIRail.BuildRail(prev, cur, next)) return true;
        // Terraforming a slope flat is LAST-RESORT only (repair pass): doing it on
        // the first pass fights the pathfinder's slope avoidance and slows lines.
        if (!allow_terraform) return false;
        TrackBuilder._FlattenToHeight(cur, AITile.GetMaxHeight(cur));
        return AIRail.BuildRail(prev, cur, next);
    }

    // Build a rail bridge spanning prev->cur (collinear, distance>=2). Used as a
    // fallback when a tunnel is refused over water. Returns true on success and
    // records the near end for cleanup. (Phase 8)
    static function _BridgeSpan(prev, cur) {
        local step = AIMap.DistanceManhattan(prev, cur);
        if (step < 2) return false;
        local bl = AIBridgeList_Length(step + 1);
        if (bl.IsEmpty()) return false;
        if (AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), prev, cur)) {
            TrackBuilder._Touch(prev);
            return true;
        }
        return false;
    }

    // EXTEND a blocked bridge to the next CLEAR collinear path tile. tiles[i] is
    // the pathfinder's bridge far end that failed to build (blocked / on an
    // obstacle); we want to span FURTHER and land on solid clear ground beyond it
    // (the correct grade-separated crossing - e.g. a bridge over an existing rail,
    // landing on the clear tile past it). Bridges are axis-aligned, so we only
    // extend along the straight approach: walk forward over path tiles that stay
    // collinear with prev->cur, and build the SHORTEST bridge that lands on a clear,
    // level tile. Returns that landing's path index (> i) on success, else -1.
    static function _BuildBridgeExtend(tiles, i) {
        local prev = tiles[i - 1];
        local px = AIMap.GetTileX(prev), py = AIMap.GetTileY(prev);
        local cx = AIMap.GetTileX(tiles[i]), cy = AIMap.GetTileY(tiles[i]);
        local dx = cx - px, dy = cy - py;
        if (dx != 0 && dy != 0) return -1;     // bridges are axis-aligned only
        local sx = (dx > 0) ? 1 : (dx < 0 ? -1 : 0);
        local sy = (dy > 0) ? 1 : (dy < 0 ? -1 : 0);
        local hprev = AITile.GetMaxHeight(prev);
        for (local j = i; j < tiles.len() - 1; j++) {
            local land = tiles[j];
            local lx = AIMap.GetTileX(land), ly = AIMap.GetTileY(land);
            // Must stay on the bridge axis, strictly forward of prev.
            if (sx != 0 && (ly != py || (lx - px) * sx <= 0)) break;
            if (sy != 0 && (lx != px || (ly - py) * sy <= 0)) break;
            local blen = AIMap.DistanceManhattan(prev, land);
            if (blen > 30) break;              // past max bridge length
            if (blen < 2) continue;
            if (!AITile.IsBuildable(land)) continue;             // endpoint must be clear
            if (AITile.GetMaxHeight(land) != hprev) continue;    // level endpoints
            local bl = AIBridgeList_Length(blen + 1);
            if (!bl.IsEmpty()
                    && AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), prev, land)) {
                TrackBuilder._Touch(prev);
                Log.Info(Log.PHASE_TRACK,
                    "[bridge] extended span over obstacle to clear tile " + land
                    + " (len " + blen + ").");
                return j;
            }
        }
        return -1;
    }

    // Fallback for a failed bridge/tunnel span: terraform the gap FLAT and lay
    // plain ground rail across it. Often a "bridge" the pathfinder picked for a
    // small bump fails (ERR_AREA_NOT_CLEAR) when a simple terraform + ground
    // rail would have worked. Returns true if the whole span is now ground rail.
    // a, b are the span endpoints (straight, collinear); water can't be ground-
    // crossed so we bail in that case (leaving the gap for a reroute).
    static function _GroundCross(a, b, label) {
        local step = AIMap.DistanceManhattan(a, b);
        if (step < 2) return false;
        local dir = (b - a) / step;
        local h   = AITile.GetMaxHeight(a);

        // Bail if the span touches water or existing rail/stations - we must not
        // terraform or build over a line; leave it for a bridge/reroute.
        for (local k = 0; k <= step; k++) {
            local t = a + dir * k;
            if (!AIMap.IsValidTile(t)) return false;
            if (AITile.IsWaterTile(t)) return false;
            if (AIRail.IsRailTile(t) || AIRail.IsRailStationTile(t)) return false;
        }
        // Flatten every tile of the span to one height.
        for (local k = 0; k <= step; k++) {
            TrackBuilder._FlattenToHeight(a + dir * k, h);
        }

        // Lay ground rail across the interior tiles (a and b get their rail from
        // the surrounding path steps).
        for (local k = 1; k < step; k++) {
            local pv = a + dir * (k - 1);
            local cu = a + dir * k;
            local nx = a + dir * (k + 1);
            if (!AIRail.BuildRail(pv, cu, nx)) {
                if (!(AITile.DemolishTile(cu) && AIRail.BuildRail(pv, cu, nx))) return false;
            }
            TrackBuilder._Touch(cu);
        }
        Log.Info(Log.PHASE_TRACK, "[" + label + "] terraformed a ground crossing instead of bridge/tunnel.");
        return true;
    }

    // Validate that a built path is actually CONTINUOUS rail end-to-end.
    // Walks the tile array and checks each segment really exists: a normal step
    // must be a rail / station / bridge / tunnel tile; a multi-tile step must be
    // a bridge or tunnel spanning exactly from prev to cur. Returns the index of
    // the FIRST broken segment, or -1 if the whole path is intact.
    static function FindGap(tiles) {
        if (tiles == null) return -1;   // no path => nothing broken (IsConnected safe)
        if (tiles.len() < 2) return 0;
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

    // Global guard: scan a path for any 90-degree turn. A 90-degree turn is a
    // window of four single-step tiles A,B,C,D where the last step (C->D) is the
    // exact reverse of the first (A->B) - the train pivots 90 degrees and stalls.
    // The pathfinder already forbids these; this verifies none slipped through
    // (e.g. via a bridge/tunnel exit). Returns the index of the first offending
    // tile, or -1 if the path is clean.
    static function Find90Turn(tiles) {
        if (tiles == null || tiles.len() < 4) return -1;
        for (local i = 0; i + 3 < tiles.len(); i++) {
            local s1 = tiles[i + 1] - tiles[i];
            local s2 = tiles[i + 2] - tiles[i + 1];
            local s3 = tiles[i + 3] - tiles[i + 2];
            // Only consider single-step (non bridge/tunnel) moves.
            if (AIMap.DistanceManhattan(tiles[i],     tiles[i + 1]) != 1) continue;
            if (AIMap.DistanceManhattan(tiles[i + 1], tiles[i + 2]) != 1) continue;
            if (AIMap.DistanceManhattan(tiles[i + 2], tiles[i + 3]) != 1) continue;
            if (s3 == -s1 && s1 != s2) return i + 2;   // 90-degree pivot
        }
        return -1;
    }

    // Validate a path and, if broken, try to repair it by re-running the
    // builder (BuildRail/Bridge/Tunnel are idempotent - existing pieces report
    // ERR_ALREADY_BUILT, missing ones get built). Returns true if the path is
    // intact afterwards.
    static function ValidateAndRepair(tiles, label) {
        // Null path (e.g. a single-track route has no back track): nothing to
        // validate. Returning true here also makes IsConnected(null) safe.
        if (tiles == null) return true;
        // Global 90-degree-turn guard: should never fire (the pathfinder bans
        // them) - if it does, log loudly so the source can be found and fixed.
        local bad = TrackBuilder.Find90Turn(tiles);
        if (bad != -1) {
            Log.Err(Log.PHASE_TRACK,
                "[" + label + "] 90-DEGREE TURN at tile " + tiles[bad] + " - trains may stall here.");
        }

        local gap = TrackBuilder.FindGap(tiles);
        if (gap == -1) return true;
        Log.Warn(Log.PHASE_TRACK,
            "[" + label + "] track gap at segment " + gap
            + " (tile " + tiles[gap] + ") - attempting repair.");
        TrackBuilder._BuildPath(tiles, label + ":repair", true);   // last-resort terraform allowed
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
