// src/state.nut
// In-memory session state: built routes + blacklist.
// One global instance lives on the AI controller; not persisted across
// save/load in v1.


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

    // True if WE deliver cargo TO this industry (it's the accepter of one of
    // our routes). Such an industry is being supplied, so it produces a product
    // we should haul onward to the next stage of the industry chain.
    function SuppliesIndustry(industry_id) {
        foreach (_, r in this.routes) {
            local r_town = ("acc_is_town" in r) ? r.acc_is_town : false;
            if (!r_town && r.accepter == industry_id) return true;   // industry accepters only
        }
        return false;
    }

    // True if this producer is ALREADY feeding a route. A producer's output is
    // finite and captured by its one station, so a second route from the same
    // producer just splits the same cargo onto a worse line. (Serving the same
    // ACCEPTER from several different producers is fine - that's not blocked.)
    function ProducerServed(producer) {
        foreach (_, r in this.routes) {
            if (r.producer == producer) return true;
        }
        return false;
    }

    // True if any route is still on probation (built but not yet proven to
    // earn). Used to hold off starting new lines until the current one works.
    function HasProbation() {
        foreach (_, r in this.routes) {
            if (r.status == "probation") return true;
        }
        return false;
    }

    // Drop a route from the registry (after it has been torn down).
    function RemoveRoute(route) {
        local k = Route.Key(route.cargo, route.producer, route.accepter);
        if (k in this.routes) delete this.routes[k];
    }

    // Return existing station record built at this (industry, is_source)
    // pair so we can reuse it instead of building another. v1: looks
    // through all routes and returns the first match.
    // `is_town` matters only for the accepter side: a TownID and an IndustryID
    // can be the same integer, so we also match the accepter's type to avoid
    // reusing an industry station for a same-numbered town (or vice versa).
    function FindExistingStation(id, is_source, is_town = false) {
        foreach (_, r in this.routes) {
            if (is_source && r.producer == id && r.src_station != null) return r.src_station;
            if (!is_source && r.accepter == id && r.dst_station != null) {
                local r_town = ("acc_is_town" in r) ? r.acc_is_town : false;
                if (r_town == is_town) return r.dst_station;
            }
        }
        return null;
    }
}
