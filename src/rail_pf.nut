// src/rail_pf.nut
// Custom rail pathfinder wrapping the AyStar engine.
// Adapted from AAAHogEx by rei-artist (https://github.com/rei-artist/AAAHogEx).
//
// OVERVIEW
// ========
// RailPathFinder supplies four callbacks to AyStar:
//   _Cost       – how expensive was each step we just took?
//   _Estimate   – how far (optimistically) are we from the goal?
//   _Neighbours – which tiles can we move to from here?
//   _CheckDir   – should we reject this direction? (always false here)
//
// KEY FEATURE: DOUBLE-TRACK SEPARATION
// =====================================
// When building the "back" track, pass the already-built "out" path as
// `reversePath`. The pathfinder builds a `_reverseNears` distance-map
// around the out-path and charges a heavy penalty for tiles that are
// right next to (or on top of) the out-path, nudging the back track to
// run one tile to the side — exactly what double-track needs.
//
// COST CATEGORIES (cheapest → most expensive)
// =============================================
//  diagonal tile        :  67   (NE/NW/SE/SW move, cheaper than two straights)
//  straight tile        : 100   (baseline)
//  gentle turn          : 300   (path changes direction over 3-tile window)
//  slope penalty        : 100   (height rises or falls 2+ tiles)
//  bridge per tile      : 100 extra per tile
//  tunnel per tile      :   0   (prefer tunnel over climbing a hill)
//  tight 180° turn      :1500   (immediate reversal - nearly forbidden)
//  reverse-track penalty: 300–3000  (when isOutward=true, keeps room for back track)
//
// USAGE EXAMPLE (from track_builder.nut)
// ----------------------------------------
//   local pf = RailPathFinder();
//   pf.isOutward = true;                  // building first (out) track
//   pf.InitializePath([[src, src_prev]], [[dst, dst_prev]]);
//   local path = pf.FindPath(500, null);  // 500 chunk iterations max
//   -- then for the back track --
//   local pf2 = RailPathFinder();
//   pf2.isOutward = false;
//   pf2.reversePath = out_path_result;    // keep room for this track
//   pf2.InitializePath([[dst, dst_prev]], [[src, src_prev]]);
//   local path2 = pf2.FindPath(500, null);

require("src/logger.nut");
require("src/aystar.nut");

// Directions: 0=W 1=E 2=N 3=S (matching AAAHogEx _dir encoding).
// Stored as integer 0-3. 0xFF = "any direction" for source nodes.
// DIAG_DIRECTIONS maps the _dir-encoded from+to combination to the
// diagonal bitmask used by _GetDirection.

class RailPathFinder {

    // -- tunable cost constants -------------------------------------------
    _max_cost            = null;
    _cost_tile           = null;
    _cost_diagonal_tile  = null;
    _cost_turn           = null;
    _cost_tight_turn     = null;
    _cost_slope          = null;
    _cost_bridge_per_tile = null;
    _cost_tunnel_per_tile = null;
    _cost_coast          = null;
    _cost_crossing_rail  = null;
    _cost_level_crossing = null;
    _cost_guide          = null;  // per-level reverse-separation penalty
    _estimate_rate       = null;  // heuristic multiplier (>1 = faster, less optimal)
    _max_slope           = null;  // height diff over this many tiles triggers slope cost
    _max_bridge_length   = null;
    _max_tunnel_length   = null;

    // -- state ------------------------------------------------------------
    _pathfinder  = null;  // the AyStar engine instance
    _goals       = null;  // the raw goals array
    _goals_map   = null;  // table: tile -> goal array (fast lookup)

    // -- double-track fields ----------------------------------------------
    isOutward    = null;  // true = building out-track (check rev-tile buildability)
    reversePath  = null;  // AyStar.Path chain for already-built out-track
    _reverseNears = null; // table: tile -> distance-level (0=adjacent, 1..20=further)

    constructor() {
        this._max_cost            = 5000000;
        this._cost_tile           = 100;
        this._cost_diagonal_tile  = 67;
        this._cost_turn           = 300;
        this._cost_tight_turn     = 1500;
        this._cost_slope          = 100;
        this._cost_bridge_per_tile = 100;
        this._cost_tunnel_per_tile = 0;    // tunnels preferred over climbing
        this._cost_coast          = 20;
        this._cost_crossing_rail  = 50;
        this._cost_level_crossing = 900;
        this._cost_guide          = 900;   // per level of reverse-tile distance
        this._estimate_rate       = 2;     // inflate heuristic → faster search
        this._max_slope           = 2;     // penalise if height changes >= 2 over 4 tiles
        this._max_bridge_length   = 20;
        this._max_tunnel_length   = 11;

        this.isOutward   = null;
        this.reversePath = null;
        this._reverseNears = null;
        this._goals_map  = {};
    }

    // Call after setting all public fields (isOutward, reversePath, etc.)
    // before InitializePath.
    function InitializePath(sources, goals, ignored_tiles = []) {
        this._pathfinder = AyStar(
            this,
            RailPathFinder._Cost,
            RailPathFinder._Estimate,
            RailPathFinder._Neighbours,
            RailPathFinder._CheckDir
        );
        this._goals     = goals;
        this._goals_map = {};
        foreach (g in goals) {
            this._goals_map[g[0]] <- g;
        }
        this._BuildReverseNears();

        // Build AyStar.Path seed nodes from source tile pairs.
        // Each source = [tile_A, tile_B] where we want the path to ARRIVE
        // at tile_A from direction tile_B→tile_A. We seed two nodes so
        // AyStar starts with the correct directional context.
        local nsources = [];
        foreach (node in sources) {
            local path = this._pathfinder.Path(null, node[1], 0xFF, null, RailPathFinder._Cost, this);
            path = this._pathfinder.Path(path, node[0], 0xFF, null, RailPathFinder._Cost, this);
            nsources.push(path);
        }
        this._pathfinder.InitializePath(nsources, goals, ignored_tiles);
    }

    // Run up to `limitCount * _CHUNK` AyStar iterations.
    // Returns array of tiles (src→dst order), or null on failure.
    // `eventPoller` (optional): object with OnPathFindingInterval() → bool;
    // return false from there to abort early.
    static CHUNK = 50;
    function FindPath(limitCount, eventPoller) {
        Log.Info(Log.PHASE_TRACK, "Pathfinding... max_chunks=" + limitCount);
        // AITestMode: all AI* build calls inside callbacks become dry-run checks.
        // Without this, _Neighbours/_GetBridgesAndTunnels would actually lay track.
        local _test_mode = AITestMode();
        local counter = 0;
        local raw = false;
        while (raw == false) {
            if (counter >= limitCount) break;
            raw = this._pathfinder.FindPath(RailPathFinder.CHUNK);
            counter++;
            Log.Info(Log.PHASE_TRACK, "  chunk " + counter + "/" + limitCount
                + " open=" + this._pathfinder._open.Count());
            if (raw == false && eventPoller != null) {
                if (!eventPoller.OnPathFindingInterval()) {
                    Log.Warn(Log.PHASE_TRACK, "Pathfinding aborted by event poller.");
                    return null;
                }
            }
        }

        if (raw == false) {
            // Ran out of budget. Use best partial path from open set.
            Log.Warn(Log.PHASE_TRACK, "Budget exhausted; using partial path.");
            raw = this._pathfinder._open.Peek();
        } else if (raw == null) {
            Log.Err(Log.PHASE_TRACK, "No path found (open set empty).");
            return null;
        } else {
            Log.Info(Log.PHASE_TRACK, "Path found in " + counter + " chunks.");
        }
        if (raw == null) return null;

        // Walk the linked list back-to-front and collect tiles in order.
        local tiles = [];
        local node  = raw;
        while (node != null) {
            tiles.append(node.GetTile());
            node = node.GetParent();
        }
        // Path is stored goal→start; reverse to get start→goal.
        local ordered = [];
        for (local i = tiles.len() - 1; i >= 0; i--) ordered.append(tiles[i]);
        Log.Info(Log.PHASE_TRACK, "Path length = " + ordered.len() + " tiles.");
        return ordered;
    }

    // -----------------------------------------------------------------------
    // COST CALLBACK
    // Called by AyStar.Path at construction time to compute accumulated cost.
    // `path`     = parent Path node (null for the very first node)
    // `new_tile` = tile we're about to enter
    // `new_dir`  = direction integer
    // `mode`     = nil for normal, RailPathFinder.Underground for tunnels
    // -----------------------------------------------------------------------
    static function _Cost(self, path, new_tile, new_dir, mode) {
        if (path == null) return 0;  // first node, no movement cost yet

        // Collect up to 7 recent tiles + their pairwise distances + directions.
        // This lookback is what lets us detect tight turns, diagonal runs,
        // and slope gradients without needing separate state.
        local t = [new_tile];
        local dist = [];
        local dirs = [];
        local cur  = path;
        local prev = new_tile;
        while (cur != null && t.len() < 7) {
            local tile = cur.GetTile();
            t.push(tile);
            local d = AIMap.DistanceManhattan(prev, tile);
            dist.push(d);
            dirs.push((prev - tile) / d);  // unit step in direction from tile→prev
            prev = tile;
            cur  = cur.GetParent();
        }

        local cost = 0;

        // ---- TIGHT-TURN PENALTY ----------------------------------------
        // A tight turn = the path goes A→B then reverses direction B→A within
        // 4 tiles (a hairpin). Nearly impossible for a train; very heavy penalty.
        // dirs[0] = new→t[1], dirs[1] = t[1]→t[2], dirs[2] = t[2]→t[3],  etc.
        if (self._cost_tight_turn > 0 && t.len() >= 5) {
            // Tight 180: dirs[0]==dirs[1] and dirs[2]==dirs[3] and they're opposite.
            if (dirs[0] == dirs[1] && dirs[2] == dirs[3] && dirs[0] != dirs[2]) {
                cost += self._cost_tight_turn;
            }
        }

        // ---- LEVEL CROSSING PENALTY ------------------------------------
        if (AITile.HasTransportType(t[0], AITile.TRANSPORT_ROAD)) {
            cost += self._cost_level_crossing;
        }

        local step = dist[0];

        if (step > 1) {
            // ---- BRIDGE OR TUNNEL (multi-tile jump) ----------------------
            // AyStar.Neighbours adds the far end of a bridge/tunnel as a
            // direct neighbour. Cost covers every tile in the span.
            local total_tiles = step;
            if (mode != null && mode instanceof RailPathFinder.UndergroundMode) {
                // Tunnel
                cost += total_tiles * (self._cost_tile + self._cost_tunnel_per_tile);
            } else {
                // Bridge
                cost += total_tiles * (self._cost_tile + self._cost_bridge_per_tile);
            }

            // DOUBLE-TRACK: if building outward, check the parallel tile is
            // buildable for the return track. If not, add a separation penalty.
            if (self.isOutward) {
                local rev = RailPathFinder._RevDir(t[0], t[1]);
                if (mode != null && mode instanceof RailPathFinder.UndergroundMode) {
                    // Tunnel: check if parallel tunnel end is reachable
                    if (AITunnel.GetOtherTunnelEnd(t[0] + rev) != t[1] + rev) {
                        cost += 3000;
                    }
                } else {
                    // Bridge: check if a parallel bridge can be built
                    local bl = AIBridgeList_Length(step + 1);
                    if (bl.IsEmpty() || !AIBridge.BuildBridge(
                            AIVehicle.VT_RAIL, bl.Begin(), t[1] + rev, t[0] + rev)) {
                        cost += 3000;
                    }
                }
            }
        } else {
            // ---- NORMAL TILE STEP ----------------------------------------

            // Is this a diagonal move? Diagonal = prev tile is orthogonal but
            // direction changed from prior step.
            local diagonal = false;
            if (t.len() >= 3 && dist[1] == 1 && dirs[1] != dirs[0]) {
                diagonal = true;
            }

            if (diagonal) {
                cost += self._cost_diagonal_tile;
            } else {
                cost += self._cost_tile;
            }

            // ---- TURN PENALTY ------------------------------------------
            // A normal turn: 3-tile window where direction changes.
            // dirs[2] != dirs[0] at 3-tile distance == gentle curve.
            if (t.len() >= 4 && AIMap.DistanceManhattan(t[0], t[3]) == 3
                    && dirs[2] != dirs[0]) {
                if (dirs[1] != dirs[2]) {
                    // Straight→diagonal transition: partial cost
                    cost += self._cost_turn / 3;
                } else {
                    cost += self._cost_turn;
                }
            }

            // ---- COAST SURCHARGE ----------------------------------------
            if (AITile.IsCoastTile(t[0])) cost += self._cost_coast;

            // ---- SLOPE PENALTY ------------------------------------------
            // If the max height over `max_slope+1` tiles changes by >= max_slope
            // tiles, it's a steep gradient — slow for trains.
            if (self._cost_slope > 0 && t.len() >= self._max_slope + 2) {
                local h_here = AITile.GetMaxHeight(t[0]);
                local h_back = AITile.GetMaxHeight(t[self._max_slope + 1]);
                if (abs(h_here - h_back) >= self._max_slope) {
                    cost += self._cost_slope;
                }
            }

            // ---- DOUBLE-TRACK SEPARATION --------------------------------
            // When building outward, ensure the tile one step to the side
            // (the reverse direction of travel) is buildable for the return
            // track. If not, penalise heavily.
            if (self.isOutward && t.len() >= 2) {
                local rev = RailPathFinder._RevDir(t[0], t[1]);
                local side_cur  = t[0] + rev;
                local side_prev = t[1] + rev;
                if (!AITile.IsBuildable(side_cur) || !AITile.IsBuildable(side_prev)) {
                    cost += 3000;
                }
            }
        }

        // ---- REVERSE-TRACK GUIDE PENALTY --------------------------------
        // When _reverseNears is set (building the back track), steer AWAY from
        // tiles that are far from the already-built out-track. The out-path
        // tiles have level 0; adjacent tiles level 1; and so on up to 20.
        // Higher level = farther from out-track = bigger penalty (we want the
        // back track close to the out-track for a proper double-track layout).
        if (self._reverseNears != null && t[0] in self._reverseNears) {
            local level = self._reverseNears[t[0]];
            cost += self._cost_guide * (20 - level);  // invert: level 0 = max penalty, level 20 = none
        } else if (self._reverseNears != null) {
            cost += self._cost_guide * 20;  // totally off the guide line
        }

        return path.GetCost() + cost;
    }

    // -----------------------------------------------------------------------
    // ESTIMATE CALLBACK (heuristic)
    // Returns a lower bound on cost from cur_tile to any goal.
    // Must never OVERestimate or A* loses optimality — but inflating by
    // `_estimate_rate` makes search faster at the cost of some path quality.
    // -----------------------------------------------------------------------
    static function _Estimate(self, cur_tile, cur_dir, goals_map) {
        local min_cost = self._max_cost;
        foreach (tile, g in goals_map) {
            local dx = abs(AIMap.GetTileX(cur_tile) - AIMap.GetTileX(tile));
            local dy = abs(AIMap.GetTileY(cur_tile) - AIMap.GetTileY(tile));
            // Best case: diagonals first (67 per tile), then straight (100 per tile).
            local h = min(dx, dy) * 67 * 2 + abs(dx - dy) * 100;
            if (h < min_cost) min_cost = h;
        }
        return min_cost * self._estimate_rate;
    }

    // -----------------------------------------------------------------------
    // NEIGHBOURS CALLBACK
    // Given the current path and tile, return an array of reachable next tiles.
    // Each entry: [tile, direction] or [tile, direction, mode].
    // -----------------------------------------------------------------------
    static function _Neighbours(self, path, cur_node) {
        if (path.GetCost() >= self._max_cost) return [];

        local tiles    = [];
        local par      = path.GetParent();
        local par_tile = par != null ? par.GetTile() : null;
        local par_dist = par_tile != null ? AIMap.DistanceManhattan(cur_node, par_tile) : 0;

        // ---- BRIDGE / TUNNEL CONTINUATION --------------------------------
        // Once on a bridge or tunnel, the only valid move is straight ahead
        // (no branching mid-bridge).
        if (AIBridge.IsBridgeTile(cur_node) || AITunnel.IsTunnelTile(cur_node)) {
            // Already handled via multi-tile jump in _GetBridgesAndTunnels —
            // if we somehow land mid-bridge, skip.
            return [];
        }

        // ---- CONTINUING A MULTI-TILE JUMP (bridge/tunnel far end) --------
        if (par_dist > 1) {
            local dir      = (cur_node - par_tile) / par_dist;
            local next     = cur_node + dir;
            if (!AIMap.IsValidTile(next)) return [];
            // Offer all 4 cardinal exits from the bridge/tunnel end.
            local offsets = [
                AIMap.GetTileIndex(1,0), AIMap.GetTileIndex(-1,0),
                AIMap.GetTileIndex(0,1), AIMap.GetTileIndex(0,-1)
            ];
            foreach (offset in offsets) {
                if (AIRail.BuildRail(cur_node, next, next + offset)) {
                    tiles.push([next, RailPathFinder._GetDir(par_tile, cur_node, next)]);
                }
            }
            return tiles;
        }

        // ---- NORMAL TILE: try all 4 cardinal neighbours ------------------
        local offsets = [
            AIMap.GetTileIndex(1,0), AIMap.GetTileIndex(-1,0),
            AIMap.GetTileIndex(0,1), AIMap.GetTileIndex(0,-1)
        ];
        foreach (offset in offsets) {
            local next = cur_node + offset;
            if (!AIMap.IsValidTile(next)) continue;
            // Never turn back the way we came.
            if (par_tile != null && next == par_tile) continue;
            // Disallow 90-degree turns (trains can't do them).
            if (par_tile != null && par.GetParent() != null) {
                if (next - cur_node == par.GetParent().GetTile() - par_tile) continue;
            }
            if (par_tile == null || AIRail.BuildRail(par_tile, cur_node, next)) {
                tiles.push([next, RailPathFinder._GetDir(par_tile, cur_node, next)]);
            }
        }

        // ---- BRIDGE / TUNNEL JUMPS ---------------------------------------
        // Try to leap over obstacles by bridging or tunneling.
        if (par != null) {
            local bt = RailPathFinder._GetBridgesAndTunnels(self, par_tile, cur_node);
            foreach (item in bt) tiles.push(item);
        }

        return tiles;
    }

    // -----------------------------------------------------------------------
    // CHECK-DIRECTION CALLBACK — always allow; direction filtering is in _Cost.
    // -----------------------------------------------------------------------
    static function _CheckDir(tile, old_dir, new_dir, self) {
        return false;
    }

    // -----------------------------------------------------------------------
    // BRIDGE + TUNNEL JUMP DISCOVERY
    // Called from _Neighbours to offer long-range jumps.
    // -----------------------------------------------------------------------
    static function _GetBridgesAndTunnels(self, last, cur) {
        local tiles = [];
        local dir   = cur - last;
        if (dir == 0) return tiles;

        // --- BRIDGE: can we jump forward over unbuildable terrain? ---
        local level = AITile.GetMaxHeight(cur);
        local next  = cur + dir;
        if (!AIMap.IsValidTile(next)) return tiles;

        if (!AITile.IsBuildable(next) || level > AITile.GetMaxHeight(next)) {
            local bdir = RailPathFinder._GetDir(last, cur, cur + dir);
            for (local i = 2; i < self._max_bridge_length; i++) {
                local target = cur + dir * i;
                if (!AIMap.IsValidTile(target)) break;
                local bl = AIBridgeList_Length(i + 1);
                if (!bl.IsEmpty() &&
                        AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), cur, target)) {
                    tiles.push([target, bdir]);
                }
            }
        }

        // --- TUNNEL: can we bore under a hill? ---
        local slope = AITile.GetSlope(cur);
        if (slope == AITile.SLOPE_SW || slope == AITile.SLOPE_NW ||
                slope == AITile.SLOPE_SE || slope == AITile.SLOPE_NE) {
            local other = AITunnel.GetOtherTunnelEnd(cur);
            if (AIMap.IsValidTile(other)) {
                local tlen = AIMap.DistanceManhattan(cur, other);
                if (tlen >= 2 && tlen < self._max_tunnel_length &&
                        AITunnel.BuildTunnel(AIVehicle.VT_RAIL, cur)) {
                    local tdir = RailPathFinder._GetDir(last, cur, other);
                    tiles.push([other, tdir, RailPathFinder.UndergroundMode()]);
                }
            }
        }
        return tiles;
    }

    // -----------------------------------------------------------------------
    // REVERSE-NEAR MAP
    // Walk the out-path and tag tiles adjacent to it with distance levels
    // 0..20. The back-track _Cost uses these levels to penalise straying
    // far from the out-path (so both tracks stay parallel).
    // -----------------------------------------------------------------------
    function _BuildReverseNears() {
        if (this.reversePath == null) {
            this._reverseNears = null;
            return;
        }
        local nears = {};
        this._reverseNears = {};

        // Level 0: tiles directly on the out-path itself.
        local node = this.reversePath;
        while (node != null) {
            local t = node.GetTile();
            this._reverseNears.rawset(t, 0);
            nears.rawset(t, 0);
            node = node.GetParent();
        }

        // Levels 1..20: BFS outward from the out-path tiles.
        local offsets = [
            AIMap.GetTileIndex(1,0), AIMap.GetTileIndex(-1,0),
            AIMap.GetTileIndex(0,1), AIMap.GetTileIndex(0,-1)
        ];
        for (local level = 1; level <= 20; level++) {
            local next_wave = {};
            foreach (tile, _ in nears) {
                foreach (offset in offsets) {
                    local nb = tile + offset;
                    if (!AIMap.IsValidTile(nb)) continue;
                    if (!(nb in this._reverseNears)) {
                        next_wave.rawset(nb, level);
                        this._reverseNears.rawset(nb, level);
                    }
                }
            }
            nears = next_wave;
        }
    }

    // -----------------------------------------------------------------------
    // DIRECTION HELPERS
    // -----------------------------------------------------------------------

    // Simple 4-direction integer: 0=W 1=E 2=N 3=S (or 0xFF for "any").
    static function _Dir4(from, to) {
        local d = from - to;
        if (d ==  1) return 0;
        if (d == -1) return 1;
        if (d ==  AIMap.GetMapSizeX()) return 2;
        if (d == -AIMap.GetMapSizeX()) return 3;
        return 0xFF;
    }

    // Compound direction from three tiles (pre→from→to).
    // Used as the direction stored on each Path node.
    static function _GetDir(pre, from, to) {
        if (pre == null) return RailPathFinder._Dir4(from, to);
        return (RailPathFinder._Dir4(pre, from) << 4) | RailPathFinder._Dir4(from, to);
    }

    // The perpendicular tile one step to the "right" of the direction of travel.
    // Used to check if there's room for a parallel return track.
    // isRevReverse=false (default): right-hand side of travel.
    static function _RevDir(cur, prev) {
        local d = cur - prev;
        local mx = AIMap.GetMapSizeX();
        // 90-degree rotation: E→N, N→W, W→S, S→E
        if (d == 1)   return -mx;  // going E → perpendicular is N
        if (d == -1)  return  mx;  // going W → perpendicular is S
        if (d ==  mx) return  1;   // going S → perpendicular is E
        if (d == -mx) return -1;   // going N → perpendicular is W
        return 0;
    }
}


// Metadata object attached to Path nodes that represent the far end of a
// newly-bored tunnel (not an existing pre-built tunnel).
class RailPathFinder.UndergroundMode {
}
