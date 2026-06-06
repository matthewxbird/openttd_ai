// src/state.nut
// In-memory session state: built routes + blacklist.
// One global instance lives on the AI controller; not persisted across
// save/load in v1.


class State {
    routes    = null;   // map: route_key -> Route record
    blacklist = null;   // Blacklist instance
    last_review_month = -100;  // month-index the capacity sweep last ran (mutable
                               // cross-tick state - lives here because a STATIC
                               // class slot can't be reassigned at runtime in
                               // OpenTTD Squirrel; the State instance persists)

    constructor() {
        this.routes    = {};
        this.blacklist = Blacklist();
        this.last_review_month = -100;
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

    // True if WE HAUL the OUTPUT of this industry (it's the producer of one of
    // our rail routes). Delivering this industry's INPUT cargo grows its
    // production - and hence the output we already haul (demand-driven supply
    // chains, Phase 4). Rail only (air/road producers are towns).
    function HaulsFrom(industry_id) {
        foreach (_, r in this.routes) {
            if (("air" in r) && r.air) continue;
            if (("road" in r) && r.road) continue;
            if (r.producer == industry_id) return true;
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

    // True if a ROAD route already starts at this producer. Road bus routes use
    // a town as producer; that town usually ALSO has an air pax route, so the
    // general ProducerServed (any mode) wrongly blocked every road route. Road is
    // gated on its OWN mode only - a town may run air pax AND local buses.
    function RoadServes(producer) {
        foreach (_, r in this.routes) {
            if (r.producer == producer && ("road" in r) && r.road) return true;
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

    // How many routes are currently on probation. The build loop allows a few
    // to prove concurrently rather than freezing all expansion on a single one
    // (one slow/broken line must not stop the company from growing).
    function CountProbation() {
        local n = 0;
        foreach (_, r in this.routes) {
            if (r.status == "probation") n++;
        }
        return n;
    }

    // How many routes are PROVEN (promoted past probation to "built"). Drives
    // the EARLY -> MID game-phase transition: the EARLY land-grab runs until we
    // have a half-dozen proven lines, then MID upgrades them.
    function CountBuilt() {
        local n = 0;
        foreach (_, r in this.routes) {
            if (r.status == "built") n++;
        }
        return n;
    }

    // Drop a route from the registry (after it has been torn down).
    function RemoveRoute(route) {
        // A forked junction spur depends on its trunk: releasing the spur frees the
        // trunk's lifecycle (junction_deps refcount) so the trunk can later condemn
        // normally once no spur runs over it.
        if (("junction" in route) && route.junction && ("trunk_key" in route)
            && route.trunk_key in this.routes) {
            local trunk = this.routes[route.trunk_key];
            if ("junction_deps" in trunk && trunk.junction_deps > 0) trunk.junction_deps--;
        }
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
            if (("air" in r) && r.air) continue;    // air manages its own airports
            if (("road" in r) && r.road) continue;  // road manages its own stops
            if (is_source && r.producer == id && r.src_station != null) return r.src_station;
            if (!is_source && r.accepter == id && r.dst_station != null) {
                local r_town = ("acc_is_town" in r) ? r.acc_is_town : false;
                if (r_town == is_town) return r.dst_station;
            }
        }
        return null;
    }
}
