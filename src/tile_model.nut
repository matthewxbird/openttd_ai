// src/tile_model.nut
// PER-TILE PATHABILITY MODEL for A*. Classifies any map tile into one mode so the
// pathfinder can PRUNE the impossible (no expensive test-BuildRail probe) and price
// the rest. Model agreed with the user (every OpenTTD MP_* tile class):
//
//   GROUND - build rail on the ground here. Flat/rough/farm/snow/desert, gentle &
//            steep slopes, trees (auto-clear), plain road (level crossing), our
//            owned land, ground under our bridges. Cost handled by _Cost (slopes).
//   JOIN   - our OWN rail/bridge/tunnel: join & run along it (reuse the corridor).
//   BRIDGE - can't ground; must span OVER: water (sea/river/canal/coast), our
//            non-track infra (station/depot/dock/lock/buoy/airport/HQ), ALL rival
//            infrastructure. (The bridge/tunnel jump generator handles these.)
//   AVOID  - never path here, no ground, no bridge-over: HOUSES, INDUSTRY,
//            unclearable objects (transmitter/lighthouse/statue), void/map-edge.
//
// NoAI exposes no tile-type enum, so HOUSE vs trees/rocks is inferred: a clearable
// (test-DemolishTile ok) non-buildable tile that ACCEPTS PASSENGERS is a town house.

class TileModel {
    static GROUND = 0;
    static JOIN   = 1;
    static BRIDGE = 2;
    static AVOID  = 3;

    // Lazy pax-cargo id, cached in a TABLE (mutating a static table is allowed;
    // reassigning a static slot is not).
    static _cache = { pax = -2 };   // -2 = not looked up yet, -1 = none found
    static function _PaxCargo() {
        if (TileModel._cache.pax == -2) {
            TileModel._cache.pax = -1;
            foreach (c, _ in AICargoList()) {
                if (AICargo.HasCargoClass(c, AICargo.CC_PASSENGERS)) { TileModel._cache.pax = c; break; }
            }
        }
        return TileModel._cache.pax;
    }

    // Classify a tile. Fast path first (buildable ground is the common case).
    static function Classify(tile) {
        if (!AIMap.IsValidTile(tile)) return TileModel.AVOID;       // void / edge
        // Common case: flat / gentle clear land -> ground, no further probing.
        if (AITile.IsBuildable(tile)) return TileModel.GROUND;
        // Not directly buildable: water, rail, station/depot, industry, steep,
        // rough, trees, house, object.
        if (AITile.IsWaterTile(tile)) return TileModel.BRIDGE;       // sea/river/canal/coast
        if (AIRail.IsRailTile(tile)) {
            return AICompany.IsMine(AITile.GetOwner(tile)) ? TileModel.JOIN : TileModel.BRIDGE;
        }
        if (AITile.IsStationTile(tile)
            || AIRail.IsRailDepotTile(tile) || AIRoad.IsRoadDepotTile(tile)
            || AIRoad.IsRoadStationTile(tile)
            || AIMarine.IsWaterDepotTile(tile) || AIMarine.IsDockTile(tile)) {
            return TileModel.BRIDGE;                                  // our/rival infra -> bridge over
        }
        if (AIIndustry.IsValidIndustry(AIIndustry.GetIndustryID(tile))) return TileModel.AVOID;
        // Remaining: steep-clear / rough / trees / house / unclearable object.
        local tm = AITestMode();
        if (!AITile.DemolishTile(tile)) return TileModel.AVOID;      // can't clear -> object (transmitter/lighthouse/statue)
        local pax = TileModel._PaxCargo();
        if (pax != -1 && AITile.GetCargoAcceptance(tile, pax, 1, 1, 0) > 0) {
            return TileModel.AVOID;                                   // accepts pax -> town HOUSE
        }
        return TileModel.GROUND;                                      // trees / rocks / steep clear
    }
}
