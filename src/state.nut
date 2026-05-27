// src/state.nut
// In-memory session state: built routes + blacklist.
// One global instance lives on the AI controller; not persisted across
// save/load in v1.

require("src/route.nut");
require("src/candidates.nut");

class State {
    routes    = null;   // map: route_key -> Route record
    blacklist = null;   // Blacklist instance

    constructor() {
        this.routes    = {};
        this.blacklist = Blacklist();
    }

    function HasRoute(cargo, producer, accepter) {
        return Route.Key(cargo, producer, accepter) in this.routes;
    }

    function AddRoute(route) {
        this.routes[Route.Key(route.cargo, route.producer, route.accepter)] <- route;
    }

    function CountRoutes() {
        local n = 0;
        foreach (_ in this.routes) n++;
        return n;
    }

    // Return existing station record built at this (industry, is_source)
    // pair so we can reuse it instead of building another. v1: looks
    // through all routes and returns the first match.
    function FindExistingStation(industry_id, is_source) {
        foreach (_, r in this.routes) {
            if (is_source && r.producer == industry_id && r.src_station != null) return r.src_station;
            if (!is_source && r.accepter == industry_id && r.dst_station != null) return r.dst_station;
        }
        return null;
    }
}
