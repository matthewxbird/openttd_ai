---
name: solo-bench
description: >-
  Run the MvB AI solo (no-opponent) headless benchmark, parse per-seed company
  value, and compare against the recorded baseline toward the 1,000,000 target.
  Use whenever working toward beating AAHOG: after any src/ change to measure its
  effect, when the user says "bench", "run the benchmark", "measure", "did that
  help", "compare to baseline", or when iterating on a hypothesis. Solo runs are
  fast because there is no opponent; only switch to 1v1 vs AAHOG once solo value
  reaches ~1M. Knows the harness flags, that src is mounted (no rebuild needed),
  and how to diagnose a single failing seed.
---

# Solo benchmark — measure MvB AI toward the 1M goal

Goal: beat AAHOG. Strategy: iterate solo (fast), reach ~1,000,000 company value,
THEN benchmark 1v1 vs AAHOG. Always measure before/after every change.

## Key facts
- `src/` is mounted read-only into the container at run time, so **code changes
  take effect without rebuilding** the `mvb-ottd` image. Only `-Rebuild` after
  Dockerfile/OpenTTD changes.
- Baseline + diagnoses live in memory: `bench-baseline`, `deadlock-terminus`,
  `scaling-caps`. Update `bench-baseline` whenever a change shifts the numbers.
- Matches print results only at the END (after Wait-Job). Don't tail the output
  file expecting progress; run in background and wait for the completion event.

## Run the standard solo benchmark
```powershell
.\tools\run_bench.ps1 -Seeds 1,2,3,4,5 -Years 12
```
Run it in the background (it takes minutes; 5 seeds in parallel). Output per seed:
`seed N   value=<company value> | <standings>`. Compute mean and compare each seed
to the recorded baseline. A seed at `value=1` is BANKRUPT.

## Diagnose a single failing seed
```powershell
.\tools\run_match.ps1 -Seed <N> -Years 12 -Keep            # standings + keep log
.\tools\run_match.ps1 -Seed <N> -Years 12 -Keep -Verbose   # full AI Info log
```
Log saved to `tools/match/last_match.log`. Grep it:
- `\[OBSERVE\]` — yearly value/cash timeline (find when value/cash collapsed).
- `condemn|retir|abandon|stuck|STUCK|never reached` — route lifecycle failures.
- `\[review\].*trains=` — per-route train count, waiting cargo, station ratings.

## Validate pure-math changes first
```powershell
.\tools\run_tests.ps1
```
Any change to a pure helper (scoring/estimator/strategy/maintenance/money) should
keep all unit tests green; add a test for new pure functions.

## Workflow per hypothesis
1. State the hypothesis + which constant/code it touches.
2. `run_tests.ps1` (if pure math touched).
3. `run_bench.ps1` solo, background, wait.
4. Compare mean + per-seed vs baseline. Keep if it helps broadly; revert if not.
5. Commit the winning change (commit to the plan). Update memory + PLAN.md.
