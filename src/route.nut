// src/route.nut
// Plain-table factory for "Route" records and helper to make keys.
// A Route is everything we need to know about one built connection.

class Route {
    // Returns a new Route record with sensible defaults.
    static function New(cargo, producer, accepter, distance, production = 0, acc_is_town = false) {
        return {
            cargo       = cargo,
            producer    = producer,
            accepter    = accepter,
            acc_is_town = acc_is_town,   // accepter is a TOWN (not an industry)
            distance    = distance,
            production  = production,   // producer's monthly output (train sizing)
            // Filled in by the builder steps:
            src_station = null,   // table from StationBuilder.BuildAt
            dst_station = null,
            path_out    = null,   // array of tiles producer -> accepter
            path_back   = null,   // array of tiles accepter -> producer
            depot_tiles = null,   // array of spur depots off the out-track mainline
            depot_tile  = null,   // primary depot (where trains are built)
            train_id    = -1,
            trains      = null,   // array of all vehicle ids on this route
            // Lifecycle: planned -> probation -> built, or -> condemning -> gone.
            //   probation : just built; not yet proven to earn money.
            //   built     : a train completed a full round trip / turned a profit.
            //   condemning: confirmed broken; trains recalled, infra being removed.
            status          = "planned",
            reached_dst     = false,  // a train has been seen at the destination
            reached_src     = false,  // ...and then back at the source (full loop)
            probation_checks = 0,     // (legacy) health passes spent waiting for proof
            probation_date   = null,  // game date probation began (deadline clock)
            condemn_checks   = 0,     // health passes spent tearing the line down
            lengthening      = null,  // train currently recalled to grow longer
        };
    }

    static function Key(cargo, producer, accepter) {
        return cargo + ":" + producer + ":" + accepter;
    }

    // Name of an accepter that may be a town OR an industry. `x` is any table
    // with `.accepter` and `.acc_is_town` (a candidate or a route record).
    static function AccepterName(x) {
        local t = ("acc_is_town" in x) ? x.acc_is_town : false;
        return t ? AITown.GetName(x.accepter) : AIIndustry.GetName(x.accepter);
    }

    // Map location of such an accepter.
    static function AccepterLocation(x) {
        local t = ("acc_is_town" in x) ? x.acc_is_town : false;
        return t ? AITown.GetLocation(x.accepter) : AIIndustry.GetLocation(x.accepter);
    }
}
