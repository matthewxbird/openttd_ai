// src/junction_builder.nut
// Builds CLEAN, FIXED junction templates (not ad-hoc pathfinder bits, which
// come out cramped). Every template is composed from a validated "atom" and is
// dry-run in AITestMode first - if it doesn't fit, nothing is built (no mess).
//
// See docs/JUNCTIONS_TODO.md for the design rules and the build order. This
// file currently provides:
//   * MergeWithFlow  - the atom: tie one branch track into one main track,
//                      merging WITH the flow on a single 45-degree curve.
//   * GradeSeparate  - bridge a branch track OVER a main track (conflict-free
//                      crossing), the basis of the two-level T-junctions.
// Composite templates (flat T, two-level T, cloverleaf) build on these.

class JunctionBuilder {

    // ATOM: merge a branch into a main line, WITH the flow.
    // Main line runs a -> b -> c (single track, flow toward c). `branch` is a
    // tile adjacent to b (off the line) carrying the incoming branch track. We
    // add the single corner on b that lets a branch train curve onto the main
    // line heading toward c - one 45-degree curve, never a 90.
    // dry_run: only test (no build). Returns true if it builds / would build.
    static function MergeWithFlow(a, b, c, branch, dry_run) {
        // The merge piece on b connects the branch edge and the downstream edge.
        if (dry_run) {
            local tm = AITestMode();
            return AIRail.BuildRail(branch, b, c)
                || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT;
        }
        local ok = AIRail.BuildRail(branch, b, c)
                || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT;
        if (ok) {
            // One-way PBS just upstream so the merge is a clean split-point.
            AIRail.BuildSignal(branch, b, AIRail.SIGNALTYPE_PBS_ONEWAY);
        }
        return ok;
    }

    // Bridge a branch OVER a main track for a conflict-free (two-level) crossing.
    // `from` -> `over` -> `to` are collinear; `over` is the main-track tile being
    // crossed. Builds a short bridge from `from` to `to` spanning `over`.
    // dry_run: test only. Returns true on success / feasibility.
    static function GradeSeparate(from, over, to, dry_run) {
        local len = AIMap.DistanceManhattan(from, to);     // tiles spanned + 1
        local bl  = AIBridgeList_Length(len + 1);
        if (bl.IsEmpty()) return false;
        if (dry_run) {
            local tm = AITestMode();
            return AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), from, to);
        }
        return AIBridge.BuildBridge(AIVehicle.VT_RAIL, bl.Begin(), from, to);
    }

    // Validate-then-build wrapper: run `build_fn` (a function(dry) -> bool)
    // first as a dry run; only if it passes, run it for real. Guarantees we
    // never half-build a template. Returns true if built for real.
    static function Stamp(build_fn) {
        if (!build_fn(true)) return false;   // wouldn't fit - build nothing
        return build_fn(false);
    }

    // FLAT double-track T-junction ("basic one level"). A branch double-track
    // ties into a main double-track at grade. Layout, main running along `d`
    // with its two tracks one tile apart on `p` (near track = track 0):
    //
    //        a0 == j0 == c0      main track 0  (flow ->, toward c0)
    //              \\  X
    //        a1 == j1 == c1      main track 1  (flow <-, toward a1)
    //              ||
    //        bn0  bn1            branch double-track approaching from the p side
    //
    //   j0 = junction tile on track 0,  j1 = j0 + p (track 1)
    //   branch tiles sit on the far-p side: t0 = j0 - p (feeds track 0),
    //                                       t1 = j1 + p (feeds track 1)
    // The branch merges WITH each track's flow; the one unavoidable conflict is
    // the single diamond where the branch crosses track 0 to reach track 1 -
    // protected by PBS. Everything is dry-run via Stamp first.
    //
    // Returns true if the junction was stamped. `d` and `p` are unit tile steps
    // (perpendicular to each other); a0/c0 are j0-d / j0+d.
    static function BuildFlatDoubleT(j0, d, p) {
        // Main double-track: row 0 at j0, row 1 at j0+p.
        local j1 = j0 + p;
        local a0 = j0 - d;  local c0 = j0 + d;
        local a1 = j1 - d;  local c1 = j1 + d;
        // Branch double-track comes in from the -p side on two columns:
        //   column W under j0  (wA = j0-p, going further -p)
        //   column E under c0  (eA = c0-p, going further -p)
        local wA = j0 - p;   local wB = j0 - 2 * p;
        local eA = c0 - p;   local eB = c0 - 2 * p;

        return JunctionBuilder.Stamp(function(dry) : (j0, j1, a0, c0, a1, c1, wA, wB, eA, eB, d, p) {
            local ok = true;
            // Main through-lines (both rows straight).
            ok = ok && JunctionBuilder._Rail(a0, j0, c0, dry);
            ok = ok && JunctionBuilder._Rail(a1, j1, c1, dry);
            // Branch double-track straights (both columns run along p).
            ok = ok && JunctionBuilder._Rail(j0, wA, wB, dry);
            ok = ok && JunctionBuilder._Rail(c0, eA, eB, dry);
            // West branch column <-> main row 0:  out merges east (wA->j0->c0),
            // in diverges from the west (a0->j0->wA). j0 = a 3-way + the diamond.
            ok = ok && JunctionBuilder._Rail(wA, j0, c0, dry);
            ok = ok && JunctionBuilder._Rail(a0, j0, wA, dry);
            // East branch column crosses row 0 (diamond at c0) down to row 1,
            // merging with row 1's flow both ways (eA<->c1, eA<->the cross).
            ok = ok && JunctionBuilder._Rail(eA, c0, c1, dry);   // straight p-axis on c0 = the diamond
            ok = ok && JunctionBuilder._Rail(eA, c0, j0, dry);   // and toward j0 (west on row 0)
            if (ok && !dry) {
                // Two-way PBS guarding the two diamonds (j0 and c0).
                foreach (s in [[a0, j0], [c0, j0], [wA, j0], [j1, j0],
                               [j0, c0], [eA, c0], [c1, c0]]) {
                    if (AIRail.IsRailTile(s[0])) AIRail.BuildSignal(s[0], s[1], AIRail.SIGNALTYPE_PBS);
                }
            }
            return ok;
        });
    }

    // Build (or test) a rail piece from->tile->to, treating ALREADY_BUILT as ok.
    static function _Rail(from, tile, to, dry) {
        if (dry) {
            local tm = AITestMode();
            return AIRail.BuildRail(from, tile, to)
                || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT;
        }
        return AIRail.BuildRail(from, tile, to)
            || AIError.GetLastError() == AIError.ERR_ALREADY_BUILT;
    }
}
