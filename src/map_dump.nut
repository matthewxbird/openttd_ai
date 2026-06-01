// src/map_dump.nut
// Textual "screenshot" of a map region, logged as an ASCII grid. Headless
// matches (null video driver) can't take real screenshots, so when a track
// build fails we render the terrain between the two endpoints as text and read
// it back from the log to understand WHY the pathfinder gave up (water to
// bridge, steep gradients it refused, no room, existing obstacles).
//
// Legend (one char per tile):
//   0-9  terrain height (clamped at 9); rapid digit changes = steep gradient
//   ~    water (needs a bridge)
//   ^    steep slope (pathfinder heavily penalises / bans these)
//   =    existing rail        S  rail station
//   r    road                 H  house / building / other unbuildable
//   A    source endpoint      B  destination endpoint
//   *    a caller-supplied marker (e.g. tile the build couldn't path through)
//
// The grid is X across (columns) and Y down (rows), matching AIMap tile coords.
// Large regions are downsampled so the dump never exceeds MAX_SPAN per side.

class MapDump {

    static ENABLED  = true; // master switch for all diagnostic dumps
    static MAX_SPAN = 56;   // max rendered cells per side; bigger regions sample
    static MARGIN   = 4;    // tiles of context padding around the endpoints

    // PURE: sampling step so a span of `span` tiles renders in <= `max` cells.
    // Returns >= 1. Unit-tested.
    static function Step(span, max) {
        if (max < 1) max = 1;
        local step = (span + max - 1) / max;   // ceil(span/max)
        if (step < 1) step = 1;
        return step;
    }

    // Render the rectangle covering tile_a and tile_b (plus MARGIN), marking
    // those two endpoints A/B and any tiles in `markers` (array of tile idx) as
    // '*'. Each grid row is logged on its own line under `label`.
    static function Region(tile_a, tile_b, markers, label) {
        if (!MapDump.ENABLED) return;
        if (!AIMap.IsValidTile(tile_a) || !AIMap.IsValidTile(tile_b)) return;
        local ax = AIMap.GetTileX(tile_a); local ay = AIMap.GetTileY(tile_a);
        local bx = AIMap.GetTileX(tile_b); local by = AIMap.GetTileY(tile_b);

        local x1 = (ax < bx ? ax : bx) - MapDump.MARGIN;
        local y1 = (ay < by ? ay : by) - MapDump.MARGIN;
        local x2 = (ax > bx ? ax : bx) + MapDump.MARGIN;
        local y2 = (ay > by ? ay : by) + MapDump.MARGIN;
        if (x1 < 1) x1 = 1; if (y1 < 1) y1 = 1;
        if (x2 >= AIMap.GetMapSizeX() - 1) x2 = AIMap.GetMapSizeX() - 2;
        if (y2 >= AIMap.GetMapSizeY() - 1) y2 = AIMap.GetMapSizeY() - 2;

        local sx = MapDump.Step(x2 - x1 + 1, MapDump.MAX_SPAN);
        local sy = MapDump.Step(y2 - y1 + 1, MapDump.MAX_SPAN);

        // Fast lookup set for caller markers.
        local mset = {};
        if (markers != null) foreach (t in markers) mset[t] <- true;

        Log.Warn(Log.PHASE_TRACK, "[mapdump:" + label + "] region x[" + x1 + ".." + x2
            + "] y[" + y1 + ".." + y2 + "] step=" + sx + "/" + sy
            + " A=src(" + ax + "," + ay + ") B=dst(" + bx + "," + by + ")");
        Log.Warn(Log.PHASE_TRACK, "[mapdump:" + label + "] legend 0-9=height ~=water ^=steep ==rail S=station r=road H=blocked A/B=ends *=marker");

        for (local y = y1; y <= y2; y += sy) {
            local row = "";
            for (local x = x1; x <= x2; x += sx) {
                row += MapDump._Cell(AIMap.GetTileIndex(x, y), ax, ay, bx, by, mset);
            }
            Log.Warn(Log.PHASE_TRACK, "[mapdump:" + label + "] " + row);
        }
    }

    // Render a square of `radius` tiles around `center` (e.g. around a stuck
    // train so the deadlocking junction/throat is visible). `here` is marked '@'
    // (the focus, e.g. the stalled train); other tiles in `markers` are '*'.
    static function Around(center, radius, markers, label) {
        if (!MapDump.ENABLED) return;
        if (!AIMap.IsValidTile(center)) return;
        local cx = AIMap.GetTileX(center); local cy = AIMap.GetTileY(center);
        local x1 = cx - radius; local y1 = cy - radius;
        local x2 = cx + radius; local y2 = cy + radius;
        if (x1 < 1) x1 = 1; if (y1 < 1) y1 = 1;
        if (x2 >= AIMap.GetMapSizeX() - 1) x2 = AIMap.GetMapSizeX() - 2;
        if (y2 >= AIMap.GetMapSizeY() - 1) y2 = AIMap.GetMapSizeY() - 2;

        local mset = {};
        if (markers != null) foreach (t in markers) mset[t] <- true;

        Log.Warn(Log.PHASE_LOOP, "[mapdump:" + label + "] around (" + cx + "," + cy
            + ") r=" + radius + "  @=focus *=marker " + MapDump._LEGEND);
        for (local y = y1; y <= y2; y++) {
            local row = "";
            for (local x = x1; x <= x2; x++) {
                local t = AIMap.GetTileIndex(x, y);
                if (t == center) { row += "@"; continue; }
                if (t in mset)   { row += "*"; continue; }
                row += MapDump._Cell(t, -1, -1, -1, -1, {});
            }
            Log.Warn(Log.PHASE_LOOP, "[mapdump:" + label + "] " + row);
        }
    }

    static _LEGEND = "0-9=height ~=water ^=steep ==rail S=station r=road H=blocked";

    // One character for a tile. Endpoints + markers win; then features; then a
    // height digit (with ^ for steep slopes).
    static function _Cell(t, ax, ay, bx, by, mset) {
        local tx = AIMap.GetTileX(t); local ty = AIMap.GetTileY(t);
        if (tx == ax && ty == ay) return "A";
        if (tx == bx && ty == by) return "B";
        if (t in mset) return "*";
        if (!AIMap.IsValidTile(t)) return " ";
        if (AITile.IsWaterTile(t)) return "~";
        if (AIRail.IsRailStationTile(t)) return "S";
        if (AIRail.IsRailTile(t)) return "=";
        if (AIRoad.IsRoadTile(t)) return "r";
        local slope = AITile.GetSlope(t);
        if (slope != AITile.SLOPE_FLAT && AITile.IsSteepSlope(slope)) return "^";
        if (!AITile.IsBuildable(t)) return "H";   // house/industry/object blocking
        local h = AITile.GetMaxHeight(t);
        if (h > 9) h = 9;
        return h.tostring();
    }
}
