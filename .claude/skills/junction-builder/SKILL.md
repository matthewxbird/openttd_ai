---
name: junction-builder
description: >-
  Capture an in-game OpenTTD rail layout (junction, crossover, station throat,
  any track setup) the user has hand-built, and transcribe it into an exact,
  reusable code template in the MvB AI (src/junction_builder.nut). Use whenever
  the user says things like "scan this junction", "capture this layout",
  "transcribe what I built", "make a template from this in-game setup", "turn
  this junction into a template", or asks to reproduce/rotate a layout they
  drew in the game. The method: scan the tiles -> read the descriptor from the
  AI Debug log -> bake a StampList descriptor -> replay to verify -> add
  rotation. Never hand-guess tile geometry; always capture from a real build.
---

# Junction Builder — capture in-game layouts into templates

Hand-deriving multi-tile rail layouts blind is unreliable. Instead the user
**builds the layout in-game** and the AI **scans it back into code**, exactly,
tile-for-tile. This skill is that round-trip.

Key code lives in `src/junction_builder.nut`; debug hooks in `main.nut`.

## The loop

### 1. Scan the user's build
In `main.nut` (class `MvBAI`):
```
static DEBUG_SCAN = true;
static SCAN_X1 = <corner X>;  static SCAN_Y1 = <corner Y>;
static SCAN_X2 = <opp.  X>;   static SCAN_Y2 = <opp.  Y>;   // any order
```
Get the corner tile coords with the **land-info / query tool** (shows `X Y`).
Pad the box **+2 tiles on every side** so diagonal arms / curves aren't clipped.
Reload. `JunctionBuilder.ScanToLog` dumps to the AI Debug log:
```
[scan] BEGIN WxH origin=(X1,Y1)
[scan] R dx dy trackbits          ; rail tile, offset from top-left, bit-mask
[scan] S dx dy fdx fdy type       ; signal on (dx,dy) facing (fdx,fdy)
[scan] B dx dy ox oy              ; bridge dx,dy -> ox,oy   (U = tunnel)
[scan] END
```

### 2. Transcribe to a StampList descriptor
Re-base to a 0-origin (subtract the min dx and min dy seen). Write the entries
into a `static function TemplateN()` returning an array:
```
["R", dx, dy, trackbits]
["S", dx, dy, fdx, fdy, sigtype]
["B"/"U", dx, dy, ox, oy]
```
**Track bits** (`GetRailTracks` mask; combine by adding):
`1=NE_SW, 2=NW_SE, 4=NW_NE, 8=SW_SE, 16=NW_SW, 32=NE_SE`. e.g. `3`=both
straights (a diamond crossing); `9`=`1+8`; corners (4/8/16/32) are the curves —
**if the dump has no corner bits, the box clipped the turn-curves: widen and
re-scan.**
**Signal types**: `1`=normal, `2`=entry, `3`=exit, `4`=combo, `5`=PBS (two-way),
`6`=PBS one-way.

### 3. Replay to verify
```
static DEBUG_SCAN = false;
static DEBUG_JUNCTION = true;   // _DebugStampJunction terraforms a patch + StampList(base, TemplateN())
```
Reload, screenshot at the stamp location (logged as `[debug] ... at (x,y)`),
compare with the original. The log shows `[stamp] rail pieces ok=N fail=M` —
expect `fail=0`. If pieces fail, the error string names the tile/cause.

### 4. Rotation
`JunctionBuilder.Rotate(entries, k)` rotates `k*90` CW (remaps offsets, signal
fronts, and track bits via `_RotBit`). Verify all 4 orientations with the 4-way
debug stamp before relying on it.

### 5. Turn debug off
Set `DEBUG_SCAN` and `DEBUG_JUNCTION` back to `false` for normal play.

## Gotchas (learned the hard way)
- **Clear + flatten first.** `BuildRailTrack` fails on trees/objects/slopes.
  `StampList` demolishes non-buildable tiles; the debug `LevelTiles` the patch.
  Bake on flat ground.
- **Box too small = clipped curves.** No corner bits in the dump ⇒ widen it.
- **Build order matters.** `StampList` does bridges/tunnels first (need clear
  ground), then rail bits, then signals.
- **Squirrel statics can't be reassigned at runtime.** Return descriptors from a
  function (`TemplateN()`), don't store as a reassigned `static` array.
- **Capture, don't guess.** If geometry looks wrong, re-scan a real build rather
  than nudging tile offsets by hand.
- **Rotation chirality**: track-bit corner remap must match the offset
  transform. If 0/180 are right but 90/270 are mirrored, flip the corner cycle
  in `_RotBit` (straights and 180 are unaffected).

## Relevant API
`AIRail.GetRailTracks / BuildRailTrack / GetSignalType / BuildSignal`,
`AIBridge.IsBridgeTile / GetOtherBridgeEnd / BuildBridge`,
`AITunnel.IsTunnelTile / GetOtherTunnelEnd / BuildTunnel`,
`AITile.LevelTiles / DemolishTile / IsBuildable`, `AIMap.GetTileIndex/GetTileX/GetTileY`.
