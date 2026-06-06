// src/rail_pf.nut
// Custom rail pathfinder wrapping the AyStar engine.
// Adapted from AAAHogEx by rei-artist (https://github.com/rei-artist/AAAHogEx).
//
// OVERVIEW
// ========
// RailPathFinder supplies four callbacks to AyStar:
//   _Cost       â€“ how expensive was each step we just took?
//   _Estimate   â€“ how far (optimistically) are we from the goal?
//   _Neighbours â€“ which tiles can we move to from here?
//   _CheckDir   â€“ should we reject this direction? (always false here)
//
// KEY FEATURE: DOUBLE-TRACK SEPARATION
// =====================================
// When building the "back" track, pass the already-built "out" path as
// `reversePath`. The pathfinder builds a `_reverseNears` distance-map
// around the out-path and charges a heavy penalty for tiles that are
// right next to (or on top of) the out-path, nudging the back track to
// run one tile to the side â€” exactly what double-track needs.
//
// COST CATEGORIES (cheapest â†’ most expensive)
// =============================================
//  straight tile        :  50   (baseline; now the cheapest move)
//  diagonal tile        : 100   (zig-zag NE/NW/SE/SW move; now dearer than straight)
//  gentle turn          : 300   (path changes direction over 3-tile window)
//  slope penalty        : 100   (height rises or falls 2+ tiles)
//  bridge per tile      : 50 extra per tile
//  tunnel per tile      :   0   (prefer tunnel over climbing a hill)
//  tight 180Â° turn      :1500   (immediate reversal - nearly forbidden)
//  reverse-track penalty: 300â€“3000  (when isOutward=true, keeps room for back track)
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
    _cost_bridge_fixed   = null;  // flat overhead per bridge (discourage trivial bridges)
    _cost_tunnel_per_tile = null;
    _cost_coast          = null;
    _cost_crossing_rail  = null;
    _cost_foreign_rail   = null;  // flat join onto a RIVAL's rail: forbidden (Phase 8)
    _cost_level_crossing = null;
    _cost_guide          = null;  // per-level reverse-separation penalty
    _cost_curve_spacing  = null;  // penalty when 2+ corners fall within a train length
    _cost_uphill         = null;  // per-tile penalty for an ascending (climbing) step
    _cost_height_change  = null;  // per-tile penalty for ANY change in ground height
    _cost_sawtooth       = null;  // heavy penalty for an up-then-down (or down-up) reversal
    _estimate_rate       = null;  // heuristic multiplier (>1 = faster, less optimal)
    _max_slope           = null;  // height diff over this many tiles triggers slope cost
    _curve_window        = null;  // lookback tiles that count as "one train length"
    _max_bridge_length   = null;
    _max_tunnel_length   = null;

    // -- state ------------------------------------------------------------
    _pathfinder  = null;  // the AyStar engine instance
    _goals       = null;  // the raw goals array
    _goals_map   = null;  // table: tile -> goal array (fast lookup)

    // -- double-track fields ----------------------------------------------
    isOutward    = null;  // true = building out-track (check rev-tile buildability)
    reversePath  = null;  // AyStar.Path chain for already-built out-track (legacy)
    outTiles     = null;  // array of out-track tiles (src->dst order) for back guide
    leftHand     = null;  // true = trains drive on the left (default true)
    _reverseNears = null; // table: tile -> distance-level (0=adjacent, 1..20=further)
    _preferSide  = null;  // table: tile -> true (correct side for left-hand running)
    _avoidSide   = null;  // table: tile -> true (wrong side; penalise hard)

    constructor() {
        this._max_cost            = 200000000;  // high ceiling: the heavy sawtooth/
                                                // crossing/water penalties must BIAS
                                                // the search, not blow the budget and
                                                // leave the open set empty (= no path)
        this._cost_tile           = 50;   // straight step (now the CHEAP move)
        this._cost_diagonal_tile  = 100;  // zig-zag diagonal step (now dearer than straight)
        this._cost_turn           = 300;
        this._cost_tight_turn     = 1500;
        this._cost_slope          = 100;
        this._cost_bridge_per_tile = 100;
        this._cost_bridge_fixed   = 500;   // trivial dip-bridges lose to terraformed ground
        this._cost_tunnel_per_tile = 0;    // tunnels preferred over climbing
        this._cost_coast          = 20;
        this._cost_crossing_rail  = 3000;  // building onto existing OWN rail: discouraged
                                           // (prefer a bridge for a pure crossing) but
                                           // allowed so real JUNCTIONS can be laid
        // Flat join onto a RIVAL company's rail FAILS to build
        // (ERR_OWNED_BY_ANOTHER_COMPANY) and we can't demolish it. Price it just
        // below the budget ceiling so A* treats it as a near-wall: it detours
        // around foreign track, or jumps OVER it grade-separated (the bridge/
        // tunnel neighbour, which never builds on the foreign tile), and only
        // ever flat-crosses if there is genuinely no other route at all. (Phase 8)
        this._cost_foreign_rail   = 100000000;
        this._cost_level_crossing = 200;  // crossing/clearing a road is cheap vs
                                          // a long detour around it
        this._cost_guide          = 900;   // per level of reverse-tile distance
        this._cost_curve_spacing  = 600;   // corners closer than a train length = 55km/h cap
        this._cost_uphill         = 80;    // each climbing tile drags train speed down
        this._cost_height_change  = 200;   // prefer routes that stay at one height
        this._cost_sawtooth       = 6000;  // discourage humps, but not so hard that
                                           // the line weaves/detours instead of just
                                           // terraforming a small bump flat (the
                                           // builder levels isolated bumps anyway)
        this._estimate_rate       = 1.2;   // WEIGHTED A* (user-requested): inflate the
                                           // heuristic so search is greedier toward the
                                           // goal -> far fewer nodes expanded (kills the
                                           // 600-chunk grind, saves opcodes). Cost: paths
                                           // can be slightly curvier/suboptimal. 1.0 =
                                           // admissible/optimal; 1.4 = moderate weighting.
        this._max_slope           = 2;     // penalise if height changes >= 2 over 4 tiles
        this._curve_window        = 6;     // ~longest-train length; corners within = tight
        this._max_bridge_length   = 5;
        this._max_tunnel_length   = 5;

        this.isOutward   = null;
        this.reversePath = null;
        this.outTiles    = null;
        this.leftHand    = true;
        this._reverseNears = null;
        this._preferSide   = null;
        this._avoidSide    = null;
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
        // at tile_A from direction tile_Bâ†’tile_A. We seed two nodes so
        // AyStar starts with the correct directional context.
        local nsources = [];
        foreach (node in sources) {
            local path = AyStar.Path(null, node[1], 0xFF, null, RailPathFinder._Cost, this);
            path = AyStar.Path(path, node[0], 0xFF, null, RailPathFinder._Cost, this);
            nsources.push(path);
        }
        this._pathfinder.InitializePath(nsources, goals, ignored_tiles);
    }

    // Run up to `limitCount * _CHUNK` AyStar iterations.
    // Returns array of tiles (srcâ†’dst order), or null on failure.
    // `eventPoller` (optional): object with OnPathFindingInterval() â†’ bool;
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
            // Throttle: log every 10 chunks, not every one (AILog is slow).
            if (counter % 50 == 0) {
                Log.Info(Log.PHASE_TRACK, "  chunk " + counter + "/" + limitCount
                    + " open=" + this._pathfinder._open.Count());
            }
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
        // Path is stored goalâ†’start; reverse to get startâ†’goal.
        local ordered = [];
        for (local i = tiles.len() - 1; i >= 0; i--) ordered.append(tiles[i]);
        Log.Info(Log.PHASE_TRACK, "Path length = " + ordered.len() + " tiles.");
        return ordered;
    }

    // PURE (unit-tested): cost of stepping onto a tile that already carries rail.
    // is_mine: does COMPANY_SELF own that rail? Own rail is a legal (discouraged)
    // junction; a rival's is an unbuildable near-wall. (Phase 8)
    static function RailCrossCost(is_mine, own_cost, foreign_cost) {
        return is_mine ? own_cost : foreign_cost;
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
        while (cur != null && t.len() < 4) {
            local tile = cur.GetTile();
            t.push(tile);
            local d = AIMap.DistanceManhattan(prev, tile);
            dist.push(d);
            dirs.push((prev - tile) / d);  // unit step in direction from tileâ†’prev
            prev = tile;
            cur  = cur.GetParent();
        }

        local cost = 0;

        // ---- TIGHT-TURN PENALTY ----------------------------------------
        // A tight turn = the path goes Aâ†’B then reverses direction Bâ†’A within
        // 4 tiles (a hairpin). Nearly impossible for a train; very heavy penalty.
        // dirs[0] = newâ†’t[1], dirs[1] = t[1]â†’t[2], dirs[2] = t[2]â†’t[3],  etc.
        if (self._cost_tight_turn > 0 && t.len() >= 5) {
            // Tight 180: dirs[0]==dirs[1] and dirs[2]==dirs[3] and they're opposite.
            if (dirs[0] == dirs[1] && dirs[2] == dirs[3] && dirs[0] != dirs[2]) {
                cost += self._cost_tight_turn;
            }
        }

        // ---- CURVE SPACING (tight-curve speed limit) -------------------
        // OpenTTD speed-caps a train (down to 55 km/h) when its body spans
        // two corners at once. Avoid that by leaving straight tiles between
        // curves >= the longest train. Detect 2+ heading changes inside the
        // train-length lookback window and penalise. Heading uses a 2-tile
        // vector (t[k]-t[k+2]) so a smooth diagonal zig-zag reads as ONE
        // heading, not a string of corners.
        if (self._cost_curve_spacing > 0 && t.len() >= 4) {
            local span = t.len() - 2;            // number of 2-tile headings
            if (span > self._curve_window) span = self._curve_window;
            local changes = 0;
            for (local k = 0; k + 1 < span; k++) {
                if ((t[k] - t[k + 2]) != (t[k + 1] - t[k + 3])) changes++;
            }
            if (changes >= 2) cost += self._cost_curve_spacing;
        }

        // ---- PER-TILE GRADIENT (climbing slows trains) -----------------
        // Each ascending tile drags real train speed down regardless of the
        // steep-gradient check below. Travel goes t[1] -> t[0] (t[0] newest).
        if (self._cost_uphill > 0 && t.len() >= 2) {
            if (AITile.GetMaxHeight(t[0]) > AITile.GetMaxHeight(t[1])) {
                cost += self._cost_uphill;
            }
        }

        // ---- VERTICAL PROFILE: penalise height changes, BAN sawtooth ----
        // Prefer routes that hold one height. Any height change costs; an
        // up-then-down or down-then-up reversal within 3 tiles is a sawtooth
        // (the worst case for train speed) and is penalised hard so the
        // pathfinder routes around rolling terrain instead of riding over it.
        if (t.len() >= 2) {
            local d01 = AITile.GetMaxHeight(t[0]) - AITile.GetMaxHeight(t[1]);
            if (d01 != 0) {
                cost += self._cost_height_change;
                // Look back to the most recent EARLIER slope within a train
                // length. If it went the opposite way, the profile reverses
                // (up-then-down or down-then-up) - a sawtooth - even if flat
                // tiles sit between the two slopes. Penalise it brutally.
                local window = self._curve_window;
                if (window > t.len() - 1) window = t.len() - 1;
                for (local k = 1; k < window; k++) {
                    local dk = AITile.GetMaxHeight(t[k]) - AITile.GetMaxHeight(t[k + 1]);
                    if (dk != 0) {
                        if ((dk > 0) != (d01 > 0)) cost += self._cost_sawtooth;
                        break;  // only the nearest prior slope defines the reversal
                    }
                }
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
                // Bridge: per-tile cost + a flat overhead so a short bridge
                // over a small dip loses to a ground route we can terraform.
                cost += self._cost_bridge_fixed
                    + total_tiles * (self._cost_tile + self._cost_bridge_per_tile);
            }

            // DOUBLE-TRACK: if building outward, check the parallel tile is
            // buildable for the return track. The back track will sit one tile
            // to the right of out-travel (left-hand running), so reserve THAT
            // side - not the opposite one.
            if (self.isOutward) {
                local unit = (t[0] - t[1]) / step;
                local roff = RailPathFinder._RightOffset(unit);
                local rev  = self.leftHand ? roff : -roff;
                if (rev != 0) {
                    if (mode != null && mode instanceof RailPathFinder.UndergroundMode) {
                        if (AITunnel.GetOtherTunnelEnd(t[0] + rev) != t[1] + rev) {
                            cost += 3000;
                        }
                    } else {
                        local bl = AIBridgeList_Length(step + 1);
                        if (bl.IsEmpty() || !AIBridge.BuildBridge(
                                AIVehicle.VT_RAIL, bl.Begin(), t[1] + rev, t[0] + rev)) {
                            cost += 3000;
                        }
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
                    // Straightâ†’diagonal transition: partial cost
                    cost += self._cost_turn / 3;
                } else {
                    cost += self._cost_turn;
                }
            }

            // ---- CROSSING EXISTING RAIL --------------------------------
            // Building rail on a tile that already carries rail means the tracks
            // cross. OUR OWN rail (another route's line / our out-track) is a
            // legal junction, penalised so A* prefers to route around it. A
            // RIVAL's rail can't be built on at all (ERR_OWNED_BY_ANOTHER_COMPANY)
            // - price it as a near-wall so the search detours or jumps over it
            // grade-separated. (The back track is additionally blocked from
            // out-track tiles via ignored_tiles.)
            if (AIRail.IsRailTile(t[0])) {
                cost += RailPathFinder.RailCrossCost(
                    AICompany.IsMine(AITile.GetOwner(t[0])),
                    self._cost_crossing_rail, self._cost_foreign_rail);
            }

            // ---- WATER: can't lay ground rail on it --------------------
            // A normal rail tile on water fails to build. Water must be
            // BRIDGED (a multi-tile step), so make a ground step onto water
            // hugely expensive - A* will bridge across instead.
            if (AITile.IsWaterTile(t[0])) cost += 200000;

            // ---- COAST SURCHARGE ----------------------------------------
            if (AITile.IsCoastTile(t[0])) cost += self._cost_coast;

            // ---- SLOPE PENALTY ------------------------------------------
            // If the max height over `max_slope+1` tiles changes by >= max_slope
            // tiles, it's a steep gradient â€” slow for trains.
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
                local roff = RailPathFinder._RightOffset(t[0] - t[1]);
                local rev  = self.leftHand ? roff : -roff;
                if (rev != 0) {
                    if (!AITile.IsBuildable(t[0] + rev)
                            || !AITile.IsBuildable(t[1] + rev)) {
                        cost += 3000;
                    }
                }
            }
        }

        // ---- REVERSE-TRACK GUIDE PENALTY --------------------------------
        // When _reverseNears is set (building the back track) we want it to hug
        // the out-track ONE tile to the side (level 1) for a clean parallel
        // double track. _reverseNears tags: level 0 = on the out-path itself,
        // level 1 = adjacent, ... up to 20 = far. So the penalty is a V with
        // its minimum at level 1:
        //   level 0  -> huge  (never build ON the out-track: collision)
        //   level 1  -> zero  (the sweet spot we want)
        //   level n  -> grows with distance from the out-track
        //   off-guide -> max  (keep the search in a tight corridor = fast)
        // The old formula was inverted: it made "far away" free, so the back
        // track wandered off and the open set exploded.
        if (self._reverseNears != null) {
            if (t[0] in self._reverseNears) {
                local level = self._reverseNears[t[0]];
                if (level == 0) cost += self._cost_guide * 20;  // never ON the out-track
                else            cost += self._cost_guide * (level - 1);  // level 1 = free
            } else {
                cost += self._cost_guide * 25;  // totally off the guide corridor
            }
            // SIDE BIAS (left-hand running): squeeze the back track onto the
            // preferred side. Wrong side is heavily penalised so the two tracks
            // stay parallel on consistent sides and never swap (which would
            // force a crossing). Costs stay non-negative (A* needs that).
            if (self._avoidSide != null && t[0] in self._avoidSide) {
                cost += self._cost_guide * 8;
            }
        }

        return path.GetCost() + cost;
    }

    // -----------------------------------------------------------------------
    // ESTIMATE CALLBACK (heuristic)
    // Returns a lower bound on cost from cur_tile to any goal.
    // Must never OVERestimate or A* loses optimality â€” but inflating by
    // `_estimate_rate` makes search faster at the cost of some path quality.
    // -----------------------------------------------------------------------
    static function _Estimate(self, cur_tile, cur_dir, goals_map) {
        local min_cost = self._max_cost;
        foreach (tile, g in goals_map) {
            local dx = abs(AIMap.GetTileX(cur_tile) - AIMap.GetTileX(tile));
            local dy = abs(AIMap.GetTileY(cur_tile) - AIMap.GetTileY(tile));
            // Cheapest possible: every tile is a straight step (50); the minimum
            // number of orthogonal steps to span (dx,dy) is the Manhattan dx+dy.
            // (Diagonal is now dearer at 100, so an all-straight route is the
            // lower bound.) Admissible lower bound = (dx+dy) * cheapest tile.
            local h = (dx + dy) * 50;
            if (h < min_cost) min_cost = h;
        }
        // Keep the estimate an INTEGER (aystar's heap/AIList priority must be int;
        // a float _estimate_rate like 1.4 makes this a float and crashes Insert).
        return (min_cost * self._estimate_rate).tointeger();
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
            // Already handled via multi-tile jump in _GetBridgesAndTunnels â€”
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
                if (offset == -dir) continue;   // never reverse straight off the span
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
            // BACK TRACK: hard-stay on the correct side of the out track. The
            // wrong-side tiles are a HARD no-go (not just a cost) so the back
            // track can never weave across and cross the out track.
            if (self._avoidSide != null && (next in self._avoidSide)) continue;

            // TILE MODEL PRUNE (search-space cut): never make a FLAT move onto an
            // AVOID tile (houses/industry/objects/edge) OR a BRIDGE tile (water,
            // rival infra, our non-track infra). Both are pruned without the
            // expensive test-BuildRail probe or node expansion - BRIDGE tiles are
            // crossed only via the bridge/tunnel jump generator below, never stepped
            // on. GROUND + JOIN (our rail, run-along) fall through to the probe.
            local _cls = TileModel.Classify(next);
            if (_cls == TileModel.AVOID || _cls == TileModel.BRIDGE) continue;

            // Seed tile (no parent): always allow.
            if (par_tile == null) {
                tiles.push([next, RailPathFinder._GetDir(par_tile, cur_node, next)]);
                continue;
            }

            local buildable = AIRail.BuildRail(par_tile, cur_node, next);
            local lerr      = AIError.GetLastError();
            local joinable  = !buildable && (lerr == AIError.ERR_ALREADY_BUILT);
            // ROCKS / rough UNOWNED ground: test-BuildRail fails AREA_NOT_CLEAR
            // (rocks block until cleared) but the real build clears them (~GBP200).
            // Treat as a NORMAL buildable tile - no detour, no penalty (user request).
            // (Rival property gives a different error; only allow none/own-owned.)
            local own = AITile.GetOwner(cur_node);
            local clearable = !buildable && (lerr == AIError.ERR_AREA_NOT_CLEAR)
                && (own == AICompany.COMPANY_INVALID || own == -1 || AICompany.IsMine(own));
            if (!buildable && !joinable && !clearable) continue;

            // Existing rail that is NOT our goal:
            //   - Near a station: never touch it (tangles the throat).
            //   - Laying a NEW piece onto it = a flat at-grade crossing/merge.
            //     A* makes these cramped and ugly, so we DON'T: skip the flat
            //     move and let the bridge/tunnel jump GRADE-SEPARATE the crossing
            //     (clean, collision-free).
            //   - Joining where the connecting rail ALREADY exists is fine -
            //     that just runs the train along a shared corridor.
            if (AIRail.IsRailTile(next) && !(next in self._goals_map)) {
                // A RIVAL's rail: never join or build on it (we can't, and the
                // builder would fail ERR_OWNED_BY_ANOTHER_COMPANY). Skip the flat
                // move entirely; a grade-separated bridge/tunnel jump OVER it is
                // offered separately below and never touches the foreign tile.
                if (!AICompany.IsMine(AITile.GetOwner(next))) continue;
                if (RailPathFinder._NearStationTile(next, RailPathFinder.JUNCTION_STATION_GUARD)) {
                    continue;
                }
                if (buildable) continue;   // no flat crossing - bridge over instead
                // joinable: run along the existing shared OWN track.
            }

            tiles.push([next, RailPathFinder._GetDir(par_tile, cur_node, next)]);
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
    // CHECK-DIRECTION CALLBACK â€” always allow; direction filtering is in _Cost.
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
            // Push ONLY the shortest viable bridge: the first landing on a
            // buildable tile at the same height. Pushing every length 2..max
            // explodes the open set (each length is a separate search node).
            for (local i = 2; i < self._max_bridge_length; i++) {
                local target = cur + dir * i;
                if (!AIMap.IsValidTile(target)) break;
                // Landing must be buildable land at the start height.
                if (!AITile.IsBuildable(target)) continue;
                if (AITile.GetMaxHeight(target) != level) continue;
                local bl = AIBridgeList_Length(i + 1);
                if (!bl.IsEmpty() &&
                        AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), cur, target)) {
                    tiles.push([target, bdir]);
                    break;  // shortest viable bridge only
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
        // Prefer the explicit out-tile array; fall back to walking a legacy
        // reversePath chain if that's all we were given.
        local src = this.outTiles;
        if (src == null && this.reversePath != null) {
            src = [];
            local node = this.reversePath;
            while (node != null) { src.append(node.GetTile()); node = node.GetParent(); }
        }
        if (src == null || src.len() == 0) {
            this._reverseNears = null;
            this._preferSide   = null;
            this._avoidSide    = null;
            return;
        }

        this._reverseNears = {};
        this._preferSide   = {};
        this._avoidSide    = {};
        local nears = {};

        // Level 0: tiles directly on the out-path itself (back track must
        // never sit here - that would be a collision / crossing).
        foreach (t in src) {
            if (!(t in this._reverseNears)) {
                this._reverseNears.rawset(t, 0);
                nears.rawset(t, 0);
            }
        }

        // Tag a PREFERRED and an AVOID side for every straight out-track step.
        // For left-hand running the return track must hug ONE consistent side
        // of the out-track. The preferred side is one tile to the right of the
        // out-direction of travel (so the out train rides the left rail); the
        // opposite side is penalised so the back track can't drift across.
        for (local i = 0; i + 1 < src.len(); i++) {
            local a = src[i];
            local b = src[i + 1];
            if (AIMap.DistanceManhattan(a, b) != 1) continue;  // skip bridge/tunnel jumps
            local right = RailPathFinder._RightOffset(b - a);
            if (right == 0) continue;
            local pref = this.leftHand ? right : -right;
            local av   = -pref;
            foreach (base in [a, b]) {
                local pt = base + pref;
                local at = base + av;
                if (!(pt in this._reverseNears)) this._preferSide.rawset(pt, true);
                if (!(at in this._reverseNears)) this._avoidSide.rawset(at, true);
            }
        }

        // Levels 1..20: BFS outward from the out-path tiles (search corridor).
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

    // Compound direction from three tiles (preâ†’fromâ†’to).
    // Used as the direction stored on each Path node.
    static function _GetDir(pre, from, to) {
        if (pre == null) return RailPathFinder._Dir4(from, to);
        return (RailPathFinder._Dir4(pre, from) << 4) | RailPathFinder._Dir4(from, to);
    }

    // The perpendicular tile one step to the "right" of the direction of travel.
    // Used to check if there's room for a parallel return track.
    // isRevReverse=false (default): right-hand side of travel.
    // One-tile offset to the RIGHT of a unit direction of travel `d` (= to-from).
    // Used to pick the consistent side for the parallel return track so trains
    // run on the left. Returns 0 for non-unit (diagonal/zero) directions.
    static function _RightOffset(d) {
        local mx = AIMap.GetMapSizeX();
        if (d ==  1)  return  mx;  // travelling +x -> right is +y
        if (d == -1)  return -mx;  // travelling -x -> right is -y
        if (d ==  mx) return -1;   // travelling +y -> right is -x
        if (d == -mx) return  1;   // travelling -y -> right is +x
        return 0;
    }

    static JUNCTION_STATION_GUARD = 6;  // no junctions within this many tiles of a station

    // True if any rail-station tile lies within `r` tiles of `tile`. Used to
    // forbid junctions near stations (where they tangle the throats).
    static function _NearStationTile(tile, r) {
        local mx = AIMap.GetMapSizeX();
        for (local dy = -r; dy <= r; dy++) {
            for (local dx = -r; dx <= r; dx++) {
                local t = tile + dx + dy * mx;
                if (AIMap.IsValidTile(t) && AIRail.IsRailStationTile(t)) return true;
            }
        }
        return false;
    }

    static function _RevDir(cur, prev) {
        local d = cur - prev;
        local mx = AIMap.GetMapSizeX();
        // 90-degree rotation: Eâ†’N, Nâ†’W, Wâ†’S, Sâ†’E
        if (d == 1)   return -mx;  // going E â†’ perpendicular is N
        if (d == -1)  return  mx;  // going W â†’ perpendicular is S
        if (d ==  mx) return  1;   // going S â†’ perpendicular is E
        if (d == -mx) return -1;   // going N â†’ perpendicular is W
        return 0;
    }
}


// Metadata object attached to Path nodes that represent the far end of a
// newly-bored tunnel (not an existing pre-built tunnel).
class RailPathFinder.UndergroundMode {
}
