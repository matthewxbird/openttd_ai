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

    // Run the health pass over every built route.
    static function Tick(state, railtype) {
        foreach (key, r in state.routes) {
            if (r.status != "built") continue;
            Maintenance._CheckRoute(state, railtype, r);
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
