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
            // CROSSOVER linking the two main tracks at the junction, so a train
            // off the branch can reach EITHER direction of the main line.
            ok = ok && JunctionBuilder._Rail(j0, c0, c1, dry);   // row0 east -> row1 (diagonal)
            ok = ok && JunctionBuilder._Rail(c1, j1, j0, dry);   // row1 -> row0 west (diagonal)
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

    // DOUBLE-TRACK CROSS: two double-track lines crossing at grade (matches the
    // clean catalogue cross). One line runs along `d` (two tracks one tile apart
    // on `p`), the other along `p` (two tracks one tile apart on `d`); where they
    // overlap, OpenTTD forms the 2x2 of diamond crossings automatically. `center`
    // is the NW tile of that 2x2; `half` = arm length each way.
    static function BuildDoubleCross(center, d, p, half) {
        return JunctionBuilder.Stamp(function(dry) : (center, d, p, half) {
            local ok = true;
            // Line along d: two tracks at rows `center` and `center+p`.
            foreach (row in [center, center + p]) {
                for (local k = -half; k <= half; k++) {
                    local cur = row + d * k;
                    ok = ok && JunctionBuilder._Rail(cur - d, cur, cur + d, dry);
                }
            }
            // Line along p: two tracks at cols `center` and `center+d`.
            foreach (col in [center, center + d]) {
                for (local k = -half; k <= half; k++) {
                    local cur = col + p * k;
                    ok = ok && JunctionBuilder._Rail(cur - p, cur, cur + p, dry);
                }
            }
            if (ok && !dry) {
                // Two-way PBS on each of the 8 arm approaches, just outside the
                // 2x2 core, so the crossings reserve one train at a time.
                local core = half;   // tiles from center to first arm-tile beyond core
                local sigs = [
                    [center + d * 2,        center + d],          // line-d, east arm, row0
                    [center + p + d * 2,    center + p + d],      // line-d, east arm, row1
                    [center - d * 2,        center - d],          // line-d, west arm, row0
                    [center + p - d * 2,    center + p - d],      // line-d, west arm, row1
                    [center + p * 2,        center + p],          // line-p, south arm, col0
                    [center + d + p * 2,    center + d + p],      // line-p, south arm, col1
                    [center - p * 2,        center - p],          // line-p, north arm, col0
                    [center + d - p * 2,    center + d - p],      // line-p, north arm, col1
                ];
                foreach (s in sigs) {
                    if (AIMap.IsValidTile(s[0]) && AIRail.IsRailTile(s[0])) {
                        AIRail.BuildSignal(s[0], s[1], AIRail.SIGNALTYPE_PBS);
                    }
                }
            }
            return ok;
        });
    }

    // GRADE-SEPARATED double-track cross: line A runs straight on the ground
    // along `d`; line B runs along `p` and BRIDGES over A's two tracks - so the
    // lines cross with NO diamond and NO collision. `center` is the NW tile of
    // the 2x2 where the lines meet; A's rows are `center` and `center+p`,
    // B's cols are `center` and `center+d`. `half` = arm length each way.
    static function BuildGradeSeparatedCross(center, d, p, half) {
        return JunctionBuilder.Stamp(function(dry) : (center, d, p, half) {
            local ok = true;

            // Line A (ground), two tracks straight along d.
            foreach (row in [center, center + p]) {
                for (local k = -half; k <= half; k++) {
                    local cur = row + d * k;
                    ok = ok && JunctionBuilder._Rail(cur - d, cur, cur + d, dry);
                }
            }

            // Line B, two tracks along p, each bridging OVER A's two rows.
            // Bridge heads sit one tile clear of A on each side: hi = center - p
            // (before A) and hj = center + 2*p (after A), spanning center & +p.
            foreach (col in [center, center + d]) {
                local hi = col - p;          // south head (ground)
                local hj = col + 2 * p;      // north head (ground)
                // South arm straights (beyond hi), heading toward the bridge.
                for (local k = 1; k < half; k++) {
                    local cur = hi - p * (k - 1);     // hi, hi-p, ...
                    ok = ok && JunctionBuilder._Rail(cur + p, cur, cur - p, dry);
                }
                // North arm straights (beyond hj).
                for (local k = 1; k < half; k++) {
                    local cur = hj + p * (k - 1);
                    ok = ok && JunctionBuilder._Rail(cur - p, cur, cur + p, dry);
                }
                // The bridge over A (hi -> hj). GradeSeparate builds it.
                ok = ok && JunctionBuilder.GradeSeparate(hi, col, hj, dry);
            }
            return ok;
        });
    }

    // GRADE-SEPARATED double-track T (flying junction, crossover-free).
    // Main runs along `d`: near track at row `m` (flow +d), far track at row
    // `m - p` (flow -d). The branch comes in from the `+p` side (two columns).
    // The two movements that would cross the near track instead FLY OVER it on
    // a bridge, so there are no diamonds. `half` = arm length.
    //
    //   far  == .. == f0 == .. ==        (flow <-, row m-p)
    //                 ||  (bridges over near track)
    //   near == .. == n0 == ne == ..     (flow ->, row m)   ne = n0+d
    //                 \\        //
    //   branch:      bOut      bIn         (from +p side)
    static function BuildGradeSeparatedT(m, d, p, half) {
        local far = m - p;                 // far main track row
        return JunctionBuilder.Stamp(function(dry) : (m, far, d, p, half) {
            local ok = true;
            // Main through-lines: near (row m) and far (row m-p=far).
            for (local k = -half; k <= half; k++) {
                ok = ok && JunctionBuilder._Rail(m   + d*(k-1), m   + d*k, m   + d*(k+1), dry);
                ok = ok && JunctionBuilder._Rail(far + d*(k-1), far + d*k, far + d*(k+1), dry);
            }

            local n0 = m;            // near-track junction tile (branch OUT merges here)
            local ne = m + d;        // near-track tile for the IN diverge
            local bOut = n0 + p;     // branch outbound column tile (south of n0)
            local bIn  = ne + p;     // branch inbound column tile (south of ne)

            // Branch double-track straights heading south (+p).
            for (local k = 1; k < half; k++) {
                ok = ok && JunctionBuilder._Rail(bOut + p*(k-1), bOut + p*k, bOut + p*(k+1), dry);
                ok = ok && JunctionBuilder._Rail(bIn  + p*(k-1), bIn  + p*k, bIn  + p*(k+1), dry);
            }

            // AT-GRADE on the near track (no crossing): branch OUT merges onto
            // the near track heading +d; the near track diverges into branch IN.
            ok = ok && JunctionBuilder._Rail(bOut, n0, n0 + d, dry);   // bOut -> near east
            ok = ok && JunctionBuilder._Rail(n0,   ne, bIn,    dry);   // near -> branch IN

            // FLY-OVER to the far track (crosses the near track on a bridge, so
            // no diamond): a ramp from the branch up over the near track onto
            // the far track, and back. Bridge spans the single near-track row.
            //   bridge from (n0 + p) area over n0 to far: heads at bOut and far0.
            local upHead   = bOut;          // ground head on the branch side
            local downHead = far;           // ground head on the far track
            ok = ok && JunctionBuilder.GradeSeparate(upHead, n0, downHead, dry);
            // and the return ramp one tile east.
            ok = ok && JunctionBuilder.GradeSeparate(bIn, ne, far + d, dry);

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
