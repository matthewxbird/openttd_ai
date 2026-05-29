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
}
