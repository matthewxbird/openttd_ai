// src/maintenance.nut
// Health pass over already-built routes, run every loop BEFORE we consider
// building new lines. It does three things:
//
//   1. Reports each route's health: cargo waiting at the source, station
//      ratings at both ends, and how many trains are running.
//   2. Detects STUCK trains - ones that haven't moved across consecutive
//      checks and aren't legitimately at a station or in a depot. A stuck
//      train usually means a broken/incomplete line; we flag it loudly.
//   3. Adds another train when cargo is piling up at the source AND the line
//      is healthy (no stuck trains) AND we can afford it - so a busy route
//      gets more capacity instead of leaving cargo to rot (which tanks the
//      station rating).
//
// State is kept on the Route record itself (it persists in memory across
// loop iterations), so we can compare a train's position tick-to-tick.


class Maintenance {

    static STUCK_LIMIT       = 2;    // unmoved checks before a train is "stuck"
    static WAITING_FOR_EXTRA = 150;  // source cargo waiting that warrants a train
    static MAX_TRAINS        = 4;    // cap trains per route
    static MIN_CASH_FOR_TRAIN = 40000;  // don't add a train if cash is tight
    static PROBATION_LIMIT   = 10;   // health passes to prove a line earns
    static CONDEMN_LIMIT     = 12;   // health passes to recall trains + tear down

    // Run the health pass over every route, dispatching by lifecycle status.
    static function Tick(state, railtype) {
        // Collect routes to delete after the loop (don't mutate while iterating).
        local condemned_done = [];
        foreach (key, r in state.routes) {
            if (r.status == "built") {
                Maintenance._CheckRoute(state, railtype, r);
            } else if (r.status == "probation") {
                Maintenance._CheckProbation(state, r);
            } else if (r.status == "condemning") {
                if (Maintenance._CheckCondemning(state, r)) condemned_done.push(r);
            }
        }
        foreach (r in condemned_done) state.RemoveRoute(r);
    }

    // PROBATION: a freshly built line must prove it works before we trust it.
    // We promote it to "built" once a train has made a full round trip (seen at
    // the destination, then back at the source) or is clearly turning a profit.
    // If a train gets stuck, or the line never earns within PROBATION_LIMIT
    // checks, we condemn it: recall the trains and tear the whole line down.
    static function _CheckProbation(state, r) {
        local name = AIIndustry.GetName(r.producer) + "->" + AIIndustry.GetName(r.accepter);
        local src_id = r.src_station.station_id;
        local dst_id = r.dst_station.station_id;

        if (r.trains == null) r.trains = (r.train_id != -1) ? [r.train_id] : [];
        local alive = [];
        local stuck = 0;
        local profit = false;
        foreach (v in r.trains) {
            if (!AIVehicle.IsValidVehicle(v)) continue;
            alive.push(v);
            if (Maintenance._IsStuck(r, v)) stuck++;
            if (AIVehicle.GetProfitThisYear(v) > 0) profit = true;

            // Track round-trip progress by which station the train is sitting at.
            local sid = AIStation.GetStationID(AIVehicle.GetLocation(v));
            if (sid == dst_id) r.reached_dst = true;
            if (sid == src_id && r.reached_dst) r.reached_src = true;
        }
        r.trains = alive;

        local round_trip = r.reached_dst && r.reached_src;
        Log.Info(Log.PHASE_LOOP,
            "[probation] " + name + " trains=" + alive.len()
            + (stuck > 0 ? (" STUCK=" + stuck) : "")
            + " reachedDst=" + r.reached_dst + " backAtSrc=" + r.reached_src
            + " check=" + r.probation_checks + "/" + Maintenance.PROBATION_LIMIT);

        if (alive.len() == 0) {
            Log.Err(Log.PHASE_LOOP, "[probation] " + name + ": no live train; condemning.");
            Maintenance._Condemn(state, r);
            return;
        }
        if (round_trip || profit) {
            r.status = "built";
            Log.Info(Log.PHASE_LOOP, "[probation] " + name + ": VERIFIED earning -> built.");
            return;
        }
        if (stuck > 0) {
            Log.Err(Log.PHASE_LOOP, "[probation] " + name + ": train stuck; condemning broken line.");
            Maintenance._Condemn(state, r);
            return;
        }
        r.probation_checks++;
        if (r.probation_checks >= Maintenance.PROBATION_LIMIT) {
            Log.Err(Log.PHASE_LOOP,
                "[probation] " + name + ": never completed a round trip; condemning.");
            Maintenance._Condemn(state, r);
        }
    }

    // Begin tearing a broken line down: blacklist the pair so we never rebuild
    // it, recall every train to a depot, and flip to the "condemning" state
    // where _CheckCondemning finishes the job once the trains are parked.
    static function _Condemn(state, r) {
        state.blacklist.Add(r.cargo, r.producer, r.accepter);
        r.status = "condemning";
        r.condemn_checks = 0;
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (AIVehicle.IsValidVehicle(v)) AIVehicle.SendVehicleToDepot(v);
            }
        }
        Log.Err(Log.PHASE_LOOP,
            "[condemn] " + AIIndustry.GetName(r.producer) + "->" + AIIndustry.GetName(r.accepter)
            + ": blacklisted, recalling trains to depot for teardown.");
    }

    // CONDEMNING: sell any train that has reached a depot. Once all trains are
    // gone, demolish the infrastructure and report the route as done (the
    // caller removes it). If trains can't reach a depot (truly stuck) within
    // CONDEMN_LIMIT checks, demolish what we can and abandon the rest.
    // Returns true when this route is finished and should be removed.
    static function _CheckCondemning(state, r) {
        local name = AIIndustry.GetName(r.producer) + "->" + AIIndustry.GetName(r.accepter);
        local remaining = [];
        if (r.trains != null) {
            foreach (v in r.trains) {
                if (!AIVehicle.IsValidVehicle(v)) continue;
                if (AIVehicle.GetState(v) == AIVehicle.VS_IN_DEPOT) {
                    AIVehicle.SellWagonChain(v, 0);  // sell the whole train
                    if (!AIVehicle.IsValidVehicle(v)) continue;
                }
                remaining.push(v);
            }
        }
        r.trains = remaining;
        r.condemn_checks++;

        if (remaining.len() == 0) {
            Maintenance._DemolishInfra(r);
            Log.Info(Log.PHASE_LOOP, "[condemn] " + name + ": torn down and removed.");
            return true;
        }
        if (r.condemn_checks >= Maintenance.CONDEMN_LIMIT) {
            Log.Err(Log.PHASE_LOOP,
                "[condemn] " + name + ": " + remaining.len()
                + " train(s) never reached a depot; abandoning (infra may remain).");
            Maintenance._DemolishInfra(r);  // best effort; tiles under trains stay
            return true;
        }
        // Re-issue the depot order in case the first attempt was refused.
        foreach (v in remaining) AIVehicle.SendVehicleToDepot(v);
        return false;
    }

    // Remove a condemned route's rails, depots and crossovers. Stations are
    // left in place (cheap, and may be reused by another route). Tiles still
    // occupied by a vehicle silently fail to demolish - that's fine.
    static function _DemolishInfra(r) {
        if (r.depot_tiles != null) {
            foreach (d in r.depot_tiles) {
                if (AIMap.IsValidTile(d)) AITile.DemolishTile(d);
            }
        }
        Maintenance._DemolishPath(r.path_out);
        Maintenance._DemolishPath(r.path_back);
    }

    static function _DemolishPath(path) {
        if (path == null) return;
        foreach (t in path) {
            if (AIMap.IsValidTile(t)) AITile.DemolishTile(t);
        }
    }

    // Inspect and (if warranted) top up one route.
    static function _CheckRoute(state, railtype, r) {
        local cargo_label = AICargo.GetCargoLabel(r.cargo);
        local name = AIIndustry.GetName(r.producer) + "->" + AIIndustry.GetName(r.accepter);

        local src_id = r.src_station.station_id;
        local dst_id = r.dst_station.station_id;
        local waiting    = AIStation.GetCargoWaiting(src_id, r.cargo);
        local src_rating = AIStation.GetCargoRating(src_id, r.cargo);
        local dst_rating = AIStation.GetCargoRating(dst_id, r.cargo);

        // Prune dead vehicles, count live ones, detect stuck ones.
        if (r.trains == null) r.trains = (r.train_id != -1) ? [r.train_id] : [];
        local alive = [];
        local stuck = 0;
        foreach (v in r.trains) {
            if (!AIVehicle.IsValidVehicle(v)) continue;
            alive.push(v);
            if (Maintenance._IsStuck(r, v)) stuck++;
        }
        r.trains = alive;

        Log.Info(Log.PHASE_LOOP,
            "[health] " + cargo_label + " " + name
            + " trains=" + alive.len() + (stuck > 0 ? (" STUCK=" + stuck) : "")
            + " waiting=" + waiting
            + " rating(src/dst)=" + src_rating + "/" + dst_rating);

        if (stuck > 0) {
            Log.Err(Log.PHASE_LOOP,
                "[health] " + name + ": " + stuck + " train(s) not moving - line may be broken.");
            return;  // don't pile more trains onto a broken line
        }

        // Demand-driven capacity: a backlog at the source with a healthy line
        // means we need more trains.
        if (waiting >= Maintenance.WAITING_FOR_EXTRA
                && alive.len() < Maintenance.MAX_TRAINS
                && r.depot_tile != null
                && Money.Cash() > Maintenance.MIN_CASH_FOR_TRAIN) {
            Maintenance._AddTrain(r, railtype);
        }
    }

    // True if this train hasn't moved since the last check and isn't at a
    // station or in a depot (i.e. genuinely stalled on the line). Per-train
    // position/counter is remembered on the route record.
    static function _IsStuck(r, v) {
        local st = AIVehicle.GetState(v);
        // Legitimate non-moving states: loading at a station, sitting in a
        // depot, or broken down (temporary). None of these are "stuck".
        if (st == AIVehicle.VS_AT_STATION
                || st == AIVehicle.VS_IN_DEPOT
                || st == AIVehicle.VS_BROKEN
                || st == AIVehicle.VS_INVALID) {
            // reset any counter
            if (("stuck_meta" in r) && (v in r.stuck_meta)) r.stuck_meta[v].count = 0;
            return false;
        }

        if (!("stuck_meta" in r)) r.stuck_meta <- {};
        local loc = AIVehicle.GetLocation(v);
        local spd = AIVehicle.GetCurrentSpeed(v);

        if (!(v in r.stuck_meta)) {
            r.stuck_meta[v] <- { loc = loc, count = 0 };
            return false;
        }
        local m = r.stuck_meta[v];
        if (loc == m.loc && spd == 0) {
            m.count++;
        } else {
            m.loc = loc;
            m.count = 0;
        }
        return m.count >= Maintenance.STUCK_LIMIT;
    }

    // Buy and dispatch one more train on this route, built at its depot.
    static function _AddTrain(r, railtype) {
        local engine = Trains.PickEngine(r.cargo, railtype);
        local wagon  = Trains.PickWagon(r.cargo, railtype);
        if (engine == -1 || wagon == -1) return;

        local n  = Trains.PickNumWagons(r.distance);
        local id = Trains.BuildTrain(r.depot_tile, engine, wagon, r.cargo, n);
        if (id == -1) return;

        if (!Trains.DispatchTrain(id, r.src_station.tile, r.dst_station.tile)) return;

        r.trains.push(id);
        Log.Info(Log.PHASE_LOOP,
            "[health] added train " + id + " to "
            + AIIndustry.GetName(r.producer) + "->" + AIIndustry.GetName(r.accepter)
            + " (now " + r.trains.len() + ")");
    }
}
