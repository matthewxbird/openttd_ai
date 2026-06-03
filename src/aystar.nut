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
            // Key by tile + ENTRY direction only (low nibble of the compound
            // dir). Using the full compound dir would treat every distinct
            // 2-step history as a new state, defeating pruning and blowing up
            // the open set. Entry-dir gives at most 4 states per tile.
            //
            // Key is a packed INTEGER (tile<<5 | dir), not a string: string
            // concat + tostring() ran on every pop (the hottest loop in the
            // AI) and were a measurable opcode sink. Dir nibble is 0..15;
            // the 0xFF start sentinel maps to 16, so 5 bits hold it without
            // colliding with a real direction. Tile<<5 stays < 2^31 for every
            // legal map (max 4096^2 tiles -> 16.7M << 5 = 536M).
            local dir_key = (cur_dir == 0xFF) ? 16 : (cur_dir & 0x0F);
            local closed_key = (cur_tile << 5) | dir_key;
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
    constructor(parent_path, tile, direction, mode_, cost_fn, cost_self) {
        this._tile      = tile;
        this._direction = direction;
        this._parent    = parent_path;
        this.mode       = mode_;
        this._cost      = cost_fn(cost_self, parent_path, tile, direction, mode_);
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
// A pure-Squirrel BINARY MIN-HEAP. Insert and Pop are both O(log n).
//
// The previous implementation was an AIList that called
// `Sort(SORT_BY_VALUE)` on EVERY Pop — i.e. an O(n log n) re-sort of the
// entire open set per expansion step. On a 256-tile haul the open set runs
// into the thousands of nodes, so the pathfinder spent most of its opcode
// budget re-sorting. The heap removes that: each push/pop touches only
// log2(n) entries. Squirrel arrays + integer `/` (floor division) make this
// cheap and allocation-light (one 2-slot array per node).
//
// Each heap slot is a 3-element array [priority, seq, path]; the heap is
// ordered by (priority, seq) — priority = cost + estimate, and `seq` is a
// monotonic insertion counter used ONLY to break f-cost ties.
//
// Why the seq tiebreak matters (measured): the old AIList re-sort popped the
// EARLIEST-inserted node among equal-f-cost ties (stable, FIFO-ish — favours
// shallower / earlier-committed nodes, giving straight A* paths). A bare heap
// breaks ties by heap structure (~LIFO), which on cramped 128 maps picked
// different equal-cost layouts and regressed solo value ~26% @128. Replaying
// the FIFO tiebreak restores the old route choices while keeping O(log n).
// ---------------------------------------------------------------------------
class AyStar.Open {
    _heap = null;  // array of [priority, seq, path], min-heap by (priority, seq)
    _seq  = 0;     // monotonic insertion counter (FIFO tiebreak)

    constructor() {
        this._heap = [];
        this._seq  = 0;
    }

    // True if heap slot `a` should sort BEFORE `b`: lower priority first, and
    // on equal priority the earlier-inserted (lower seq) first.
    function _Less(a, b) {
        if (a[0] != b[0]) return a[0] < b[0];
        return a[1] < b[1];
    }

    // Add `path` to the open set; priority = cost + estimate. Sift up.
    function Insert(path, cost, estimate) {
        local h = this._heap;
        h.push([cost + estimate, this._seq++, path]);
        local i = h.len() - 1;
        while (i > 0) {
            local par = (i - 1) / 2;
            if (!_Less(h[i], h[par])) break;
            local tmp = h[i]; h[i] = h[par]; h[par] = tmp;
            i = par;
        }
    }

    // Remove and return the lowest-priority (cheapest) path. Sift down.
    function Pop() {
        local h = this._heap;
        local n = h.len();
        if (n == 0) return null;
        local top = h[0][2];
        local last = h.pop();
        n--;
        if (n > 0) {
            h[0] = last;
            local i = 0;
            while (true) {
                local l = 2 * i + 1;
                local r = 2 * i + 2;
                local small = i;
                if (l < n && _Less(h[l], h[small])) small = l;
                if (r < n && _Less(h[r], h[small])) small = r;
                if (small == i) break;
                local tmp = h[i]; h[i] = h[small]; h[small] = tmp;
                i = small;
            }
        }
        return top;
    }

    // Peek at the cheapest path without removing it.
    function Peek() {
        if (this._heap.len() == 0) return null;
        return this._heap[0][2];
    }

    function Count()   { return this._heap.len(); }
    function IsEmpty() { return this._heap.len() == 0; }
}
