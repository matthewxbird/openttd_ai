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
    // Rough vehicle prices for the affordability estimate (we buy a fleet of
    // full-length trains, so this can be a big slice of the up-front cost).
    static ENGINE_COST          = 12000;
    static WAGON_COST           = 1500;
    static WAGONS_PER_TRAIN_EST = 10;    // platforms are filled (~10 wagons)

    // Estimated cost of the initial fleet: num_trains full trains, each an
    // engine (allow for double-heading) plus a platform of wagons.
    static function FleetCostEstimate(num_trains) {
        if (num_trains < 1) num_trains = 1;
        local per_train = 2 * Scoring.ENGINE_COST          // allow a 2nd engine
                        + Scoring.WAGONS_PER_TRAIN_EST * Scoring.WAGON_COST;
        return num_trains * per_train;
    }

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

    // ABSOLUTE annual profit (pounds/year) = yearly revenue minus the amortized
    // build cost. This is the ranking score - NOT the ROI ratio. ROI% rewards
    // cheap short lines (small cost denominator); absolute profit rewards the
    // big earners, and because cargo payment rises with distance, LONGER routes
    // earn far more and rank higher. Distance is therefore the primary driver.
    static function AnnualProfit(prod_per_month, accept_per_month, payment_per_unit, build_cost, years = null) {
        if (years == null) years = Scoring.AMORTIZE_YEARS;
        local serviced = prod_per_month;
        if (accept_per_month > 0 && accept_per_month < serviced) serviced = accept_per_month;
        local revenue_per_year = serviced.tofloat() * 12.0 * payment_per_unit.tofloat();
        local amortized        = build_cost.tofloat() / years.tofloat();
        return revenue_per_year - amortized;
    }

    // Distance at which the distance weight reaches +100% (doubles the score).
    static DISTANCE_REFERENCE = 100.0;

    // Weight a profit figure FURTHER by route length, so longer lines are
    // favoured in the ranking beyond their natural profit. Sign is preserved
    // (a loss stays a loss), so unprofitable routes are still filtered out.
    static function DistanceWeighted(profit, dist) {
        return profit * (1.0 + dist.tofloat() / Scoring.DISTANCE_REFERENCE);
    }

    static CHAIN_BONUS = 4.0;   // multiplier for hauling the output of an industry we supply

    // Boost a score for a route that continues an industry chain we started
    // (its producer is something we already deliver to). Preserves sign so an
    // unprofitable route stays excluded.
    static function ChainBoost(score) {
        return score * Scoring.CHAIN_BONUS;
    }

    static CLUSTER_WEIGHT = 0.4;   // +40% per extra industry in the catchment

    // Favour routes whose stations sit in an industry cluster (one station can
    // then serve several cargoes). `cluster` counts industries in both
    // catchments (>=2: the producer + accepter themselves), so we credit the
    // EXTRAS beyond those two. Sign preserved.
    static function ClusterBoost(score, cluster) {
        local extra = cluster - 2;
        if (extra < 0) extra = 0;
        return score * (1.0 + extra.tofloat() * Scoring.CLUSTER_WEIGHT);
    }
}
