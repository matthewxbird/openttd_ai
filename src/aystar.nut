// src/aystar.nut
// Generic A* (AyStar) pathfinding engine.
// Adapted from AAAHogEx by rei-artist (https://github.com/rei-artist/AAAHogEx).
//
// HOW IT WORKS
// ============
// A* explores the cheapest-looking path first. Each node on the frontier
// stores the tile it landed on, the accumulated cost to get there, and
// a pointer back to its parent (forming a linked list from current tile
// back to the start). The open-set priority queue sorts nodes by
// (accumulated_cost + heuristic_estimate_to_goal), so we always expand
// whichever node looks cheapest overall.
//
// USAGE (see rail_pf.nut for a concrete example)
// -----------------------------------------------
// 1. Create an AyStar with four callback functions.
// 2. Call InitializePath(sources, goals, ignored).
//    sources = array of AyStar.Path chains representing starting positions.
//    goals   = array of [tile, prev_tile] pairs marking the destination.
// 3. Call FindPath(max_iterations) in a loop until it returns non-false.
//    Returns: AyStar.Path (found), false (still running), null (no path).
// 4. Walk the returned Path via GetParent() to reconstruct the route.

class AyStar {

    _self          = null;  // the outer "self" passed back into callbacks
    _cost_fn       = null;  // cost_fn(self, path, new_tile, new_dir, mode) -> int
    _estimate_fn   = null;  // estimate_fn(self, tile, direction, goals)    -> int
    _neighbours_fn = null;  // neighbours_fn(self, path, tile)              -> array of [tile, dir] or [tile, dir, mode]
    _check_dir_fn  = null;  // check_dir_fn(tile, old_dir, new_dir, self)   -> bool (true = reject this transition)

    _open    = null;  // AyStar.Open: priority queue of candidate paths
    _closed  = null;  // table: closed_key -> true  (don't re-expand)
    _goals_map = null; // table: tile -> goal array (fast goal-tile lookup)
    _ignored = null;  // table: tile -> true (tiles pathfinder must not cross)

    constructor(self, cost_fn, estimate_fn, neighbours_fn, check_dir_fn) {
        this._self          = self;
        this._cost_fn       = cost_fn;
        this._estimate_fn   = estimate_fn;
        this._neighbours_fn = neighbours_fn;
        this._check_dir_fn  = check_dir_fn;
        this._open      = AyStar.Open();
        this._closed    = {};
        this._goals_map = {};
        this._ignored   = {};
    }

    // Seed the search. Sources and goals are arrays of [tile, prev_tile]
    // (or longer, for multi-tile history). Ignored_tiles is an array of
    // tile indices the path must not use.
    function InitializePath(sources, goals, ignored_tiles) {
        this._open    = AyStar.Open();
        this._closed  = {};
        this._goals_map = {};
        this._ignored = {};

        foreach (g in goals) {
            this._goals_map[g[0]] <- g;
        }
        foreach (t in ignored_tiles) {
            this._ignored[t] <- true;
        }
        foreach (path in sources) {
            local est = this._estimate_fn(
                this._self, path.GetTile(), path.GetDirection(), goals);
            this._open.Insert(path, path.GetCost(), est);
        }
    }

    // Run up to `iterations` expansion steps. Returns:
    //   AyStar.Path  — a goal was reached; walk GetParent() to reconstruct.
    //   false        — iterations exhausted, call again to continue.
    //   null         — open set empty, no path exists.
    function FindPath(iterations) {
        while (iterations > 0) {
            if (this._open.IsEmpty()) return null;

            local path     = this._open.Pop();
            local cur_tile = path.GetTile();
            local cur_dir  = path.GetDirection();

            // Closed-set check: skip this tile+direction if already expanded.
            // Using a compound key so approaching the same tile from different
            // directions is treated as distinct (handles junctions).
            local closed_key = cur_tile.tostring() + "_" + cur_dir.tostring();
            if (closed_key in this._closed) continue;
            if (this._check_dir_fn(cur_tile, 0, cur_dir, this._self)) continue;
            this._closed[closed_key] <- true;

            // Goal check.
            if (cur_tile in this._goals_map) return path;

            // Expand neighbours.
            local neighbours = this._neighbours_fn(this._self, path, cur_tile);
            foreach (item in neighbours) {
                local next_tile = item[0];
                local next_dir  = item[1];
                local next_mode = item.len() >= 3 ? item[2] : null;

                if (next_tile in this._ignored) continue;

                local next_path = AyStar.Path(
                    path, next_tile, next_dir, next_mode, this._cost_fn, this._self);
                local next_est = this._estimate_fn(
                    this._self, next_tile, next_dir, this._goals_map);
                this._open.Insert(next_path, next_path.GetCost(), next_est);
            }

            iterations--;
        }
        return false; // still running, call again
    }

}


// ---------------------------------------------------------------------------
// AyStar.Path — one node in the search graph.
//
// Nodes form a singly-linked list (via _parent) from the most recently
// visited tile BACK toward the start. To reconstruct a route forward,
// either reverse the list or collect tiles into an array.
//
// Cost is accumulated at construction time so comparing two paths is O(1).
// ---------------------------------------------------------------------------
class AyStar.Path {
    _tile      = null;
    _direction = null;
    _parent    = null;
    _cost      = null;
    mode       = null;  // optional metadata (e.g. Underground tunnel state)

    // cost_fn(cost_self, parent_path, tile, direction, mode) -> int
    constructor(parent, tile, direction, mode_, cost_fn, cost_self) {
        this._tile      = tile;
        this._direction = direction;
        this._parent    = parent;
        this.mode       = mode_;
        this._cost      = cost_fn(cost_self, parent, tile, direction, mode_);
    }

    function GetTile()      { return this._tile; }
    function GetDirection() { return this._direction; }
    function GetParent()    { return this._parent; }
    function GetCost()      { return this._cost; }

    // Number of tiles in the chain from this node back to the start.
    function GetLength() {
        local len = 1;
        local p = this._parent;
        while (p != null) { len++; p = p.GetParent(); }
        return len;
    }

    // Returns true if `tile` appears anywhere in this path's ancestry.
    // Used to detect loops during neighbour expansion.
    function Contains(tile) {
        local p = this;
        while (p != null) {
            if (p._tile == tile) return true;
            p = p._parent;
        }
        return false;
    }

    // Build a table of all ancestor tiles for O(1) lookup.
    // More expensive than Contains() but useful for batch checks.
    function GetParentTable() {
        local t = {};
        local p = this;
        while (p != null) {
            t.rawset(p._tile, p._tile);
            p = p._parent;
        }
        return t;
    }
}


// ---------------------------------------------------------------------------
// AyStar.Open — priority queue for the A* open set.
//
// Backed by an AIList (tile-id -> sort-value). We store an integer ID for
// each inserted path and keep a parallel table mapping id -> Path object.
// AIList.Sort(SORT_BY_VALUE, true) puts the lowest-cost+estimate entry first.
// ---------------------------------------------------------------------------
class AyStar.Open {
    _list    = null;  // AIList: id -> (cost + estimate)
    _paths   = null;  // table:  id -> AyStar.Path
    _next_id = 0;

    constructor() {
        this._list    = AIList();
        this._paths   = {};
        this._next_id = 0;
    }

    // Add `path` to the open set; sort priority = cost + estimate.
    function Insert(path, cost, estimate) {
        local id = this._next_id++;
        this._paths[id] <- path;
        this._list.AddItem(id, cost + estimate);
    }

    // Remove and return the lowest-priority (cheapest) path.
    function Pop() {
        if (this._list.IsEmpty()) return null;
        this._list.Sort(AIList.SORT_BY_VALUE, true);
        local id   = this._list.Begin();
        local path = this._paths[id];
        this._list.RemoveItem(id);
        delete this._paths[id];
        return path;
    }

    // Peek at the cheapest path without removing it.
    function Peek() {
        if (this._list.IsEmpty()) return null;
        this._list.Sort(AIList.SORT_BY_VALUE, true);
        return this._paths[this._list.Begin()];
    }

    function Count()   { return this._list.Count(); }
    function IsEmpty() { return this._list.IsEmpty(); }
}
