# Junction & Station Templating — Roadmap

Goal: replace ad-hoc pathfinder junction bits (which come out cramped/tangled)
with **fixed, clean templates**, stamped at the merge/cross point and validated
in `AITestMode` before any real build (so a template that doesn't fit is
rejected cleanly, never leaving a mess).

Reference: https://www.transporttycoon.net/junctions3 (double-track T-junctions).

## Design rules (from the rail guides)

- **Split before merge** (CRAB): diverging tracks split, then merge, so trains
  rarely hit a red signal.
- A turning/holding track must fit the **longest train + 2 tiles** so a waiting
  train never blocks the main line behind it.
- **Grade-separate** real crossings (bridge/tunnel) — the page's two-level
  designs are the safe default; the flat "basic one level" T has one diamond.
- **No 90° pieces** — all turns are single 45° curves or diagonals.
- One-way PBS on the main line; two-way PBS only where a train reverses.

## Build order (each phase verified against in-game screenshots)

1. **Atom: with-flow merge turnout** — connect ONE branch track into ONE main
   track, merging WITH the flow via a diagonal turnout (no 90°). Test-validated
   + revert. *(implemented in `src/junction_builder.nut`)*
2. **Flat double-track T-junction** ("basic one level") — two atoms (one per
   main track) + the single diamond, signalled. Matches the flat interchange
   look requested.
3. **Two-level T-junction (bridge)** — branch merges the near track at grade,
   flies OVER the far track. Fully conflict-free. Preferred where space allows.
4. **Two-level T-junction (tunnel)** — as above, under instead of over.
5. **Half-cloverleaf / cloverleaf** — all-direction interchanges (large).
6. **Compact / expanded 2×2** — 4-track main lines.

## Integration

- Track builder: when a route would tie into an existing corridor (rather than
  reach its own station), pick the nearest valid junction site on that corridor,
  stamp the best-fitting template (test-mode), then pathfind the branch to it.
- Junctions remain BANNED within `JUNCTION_STATION_GUARD` tiles of any station.

## TODO (after junctions land successfully)

- **Station templates**: do the same for stations — fixed, clean station + throat
  + crossover layouts stamped and validated, instead of the current
  pathfinder-driven throat that keeps regressing. (Deferred until junction
  templating is proven.)
