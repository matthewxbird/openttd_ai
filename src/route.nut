// src/route.nut
// Plain-table factory for "Route" records and helper to make keys.
// A Route is everything we need to know about one built connection.

class Route {
    // Returns a new Route record with sensible defaults.
    static function New(cargo, producer, accepter, distance) {
        return {
            cargo       = cargo,
            producer    = producer,
            accepter    = accepter,
            distance    = distance,
            // Filled in by the builder steps:
            src_station = null,   // table from StationBuilder.BuildAt
            dst_station = null,
            path_out    = null,   // array of tiles producer -> accepter
            path_back   = null,   // array of tiles accepter -> producer
            train_id    = -1,
            status      = "planned",  // planned | built | failed
        };
    }

    static function Key(cargo, producer, accepter) {
        return cargo + ":" + producer + ":" + accepter;
    }
}
