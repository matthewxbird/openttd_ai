# Runtime proof of the no-90-degree-turn geometry rules.
# Ports the EXACT logic from the Squirrel code so we can execute it:
#   - RailPathFinder._Neighbours 90-degree rejection (rail_pf.nut ~L528)
#   - TrackBuilder.Find90Turn global validator (track_builder.nut)
#   - DepotBuilder straight-run requirement (depot_builder.nut)
# Tiles are encoded as y*MX + x, exactly like OpenTTD's TileIndex.

MX = 256
def tile(x, y): return y * MX + x
def dist(a, b):           # Manhattan, matching AIMap.DistanceManhattan
    return abs(a % MX - b % MX) + abs(a // MX - b // MX)

# --- ported: pathfinder rejects a step that reverses the step two moves back ---
def pathfinder_allows(gp, p, cur, nxt):
    # mirrors: if (next - cur_node == par.GetParent().GetTile() - par_tile) reject
    return (nxt - cur) != (gp - p)

# --- ported: TrackBuilder.Find90Turn -> index of first 90-deg pivot, or -1 ---
def find_90(tiles):
    for i in range(len(tiles) - 3):
        s1 = tiles[i+1] - tiles[i]
        s2 = tiles[i+2] - tiles[i+1]
        s3 = tiles[i+3] - tiles[i+2]
        if dist(tiles[i],   tiles[i+1]) != 1: continue
        if dist(tiles[i+1], tiles[i+2]) != 1: continue
        if dist(tiles[i+2], tiles[i+3]) != 1: continue
        if s3 == -s1 and s1 != s2:
            return i + 2
    return -1

# --- ported: depot only on a straight run (c - b == d) ---
def depot_allowed(a, b, c):
    return (b - a) == (c - b)

def path(steps, start=tile(10, 10)):
    t = [start]
    for s in steps: t.append(t[-1] + s)
    return t

E, W, N, S = 1, -1, -MX, MX
fails = 0
def check(name, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: got={got} want={want}")

print("Find90Turn (-1 == clean):")
check("straight line",        find_90(path([E,E,E,E])),     -1)
check("diagonal zigzag",      find_90(path([E,N,E,N,E])),   -1)   # smooth diagonal
check("single 90 corner",     find_90(path([E,E,N,N])),     -1)   # one curve = ok
check("S-curve (two curves)", find_90(path([E,N,N,E])),     -1)   # gentle, not a pivot
check("90-deg pivot E,N,W",   find_90(path([E,N,W])) != -1, True) # NE->NW pivot: flagged
check("90-deg pivot E,S,W",   find_90(path([E,S,W])) != -1, True)

print("Pathfinder neighbour ban (False == rejected):")
ts = path([E, N])               # gp,p,cur after stepping E then N
gp, p, cur = ts[0], ts[1], ts[2]
check("reject pivot back to -E", pathfinder_allows(gp, p, cur, cur + W), False)
check("allow continue diagonal", pathfinder_allows(gp, p, cur, cur + E), True)
check("allow straight on",       pathfinder_allows(gp, p, cur, cur + N), True)

print("Depot straight-run rule (True == allowed):")
check("straight run allowed", depot_allowed(tile(5,5), tile(6,5), tile(7,5)), True)
check("bend rejected",        depot_allowed(tile(5,5), tile(6,5), tile(6,6)), False)

# Consistency: any 4-tile window the pathfinder ALLOWS must be clean per Find90Turn.
print("Cross-check pathfinder vs Find90Turn over all step combos:")
dirs = [E, W, N, S]
mism = 0
for s1 in dirs:
    for s2 in dirs:
        for s3 in dirs:
            t = path([s1, s2, s3])
            # pathfinder would build this window only if each step is allowed
            allowed = (pathfinder_allows(t[0], t[1], t[2], t[3])
                       and t[2] != t[0] and t[3] != t[1])   # no immediate reversals
            clean = find_90(t) == -1
            if allowed and not clean:
                mism += 1
                print(f"    MISMATCH steps={s1,s2,s3} allowed but has 90")
check("no allowed-but-dirty windows", mism, 0)

print()
print("ALL TESTS PASSED" if fails == 0 else f"{fails} TEST(S) FAILED")
raise SystemExit(1 if fails else 0)
