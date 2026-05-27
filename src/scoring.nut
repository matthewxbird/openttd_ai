// src/scoring.nut
// PURE module - NO AI* calls. Tested via sq.exe in tests/.
//
// Job: turn raw numbers (production, distance, cargo income) into a
// single ROI score we can rank candidate routes by.

class Scoring {
    // Rough per-tile costs in pounds. Tuned later against actual game costs.
    static RAIL_COST_PER_TILE   = 500;
    static BRIDGE_TILE_PENALTY  = 1500;   // bridges cost extra per tile
    static STATION_COST         = 12000;  // 1x5 station, both ends => x2
    static DEPOT_COST           = 3000;
    static SIGNAL_COST          = 200;
    static SIGNAL_EVERY_N_TILES = 4;
    static AMORTIZE_YEARS       = 10;

    // Estimate total build cost for a double-track route of given length.
    // Pessimistic: assumes 10% of tiles need bridging.
    // dist:  manhattan distance in tiles between the two industries
    static function BuildCostEstimate(dist) {
        local rail_tiles_cost   = 2 * dist * Scoring.RAIL_COST_PER_TILE;     // x2 = double track
        local bridge_allowance  = (dist / 10) * Scoring.BRIDGE_TILE_PENALTY;
        local station_cost      = 2 * Scoring.STATION_COST;
        local depot_cost        = Scoring.DEPOT_COST;
        local signal_cost       = 2 * (dist / Scoring.SIGNAL_EVERY_N_TILES) * Scoring.SIGNAL_COST;
        return rail_tiles_cost + bridge_allowance + station_cost + depot_cost + signal_cost;
    }

    // ROI: revenue-per-year minus amortized build cost, divided by build
    // cost. Bigger is better. Negative means we lose money.
    //
    // prod_per_month:     producer's monthly output of the cargo
    // accept_per_month:   accepter's monthly demand for the cargo (cap)
    // payment_per_unit:   pounds per unit delivered (from AICargo.GetCargoIncome)
    // build_cost:         total estimated build cost
    // years:              over how many years to amortize the build cost
    static function EstimateROI(prod_per_month, accept_per_month, payment_per_unit, build_cost, years = null) {
        if (years == null) years = Scoring.AMORTIZE_YEARS;
        if (build_cost <= 0) return -1.0;

        local serviced = prod_per_month;
        if (accept_per_month > 0 && accept_per_month < serviced) {
            serviced = accept_per_month;
        }

        local revenue_per_year = serviced.tofloat() * 12.0 * payment_per_unit.tofloat();
        local amortized        = build_cost.tofloat() / years.tofloat();
        return (revenue_per_year - amortized) / build_cost.tofloat();
    }
}
