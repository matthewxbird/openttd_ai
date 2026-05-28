// main.nut
// Entry point for the AI. OpenTTD instantiates MvBAI and calls Start().
// Scan -> rank -> try to build the top route -> sleep -> repeat.
// Built routes are remembered in `state`; failed pairs go on the blacklist.

require("src/logger.nut");
require("src/money.nut");
require("src/railtype.nut");
require("src/scoring.nut");
require("src/candidates.nut");
require("src/cargo_scan.nut");
require("src/station_builder.nut");
require("src/depot_builder.nut");
require("src/aystar.nut");
require("src/rail_pf.nut");
require("src/track_builder.nut");
require("src/signals.nut");
require("src/trains.nut");
require("src/route.nut");
require("src/state.nut");
require("src/autoreplace.nut");

class MvBAI extends AIController {
    state        = null;
    railtype     = null;
    auto_replace = null;

    function Start();
    function Save();
    function Load(version, data);
    function TryBuildRoute(candidate);
}

function MvBAI::Start() {
    // Name the company so it is identifiable in the player list.
    if (!AICompany.SetName("MvB AI")) {
        local i = 2;
        while (!AICompany.SetName("MvB AI #" + i)) i++;
    }

    Log.Info(Log.PHASE_BOOT, "MvB AI starting. Hello, OpenTTD!");

    Money.TakeMaxLoan();
    this.railtype     = Railtype.PickAndSet();
    this.state        = State();
    this.auto_replace = AutoReplace();

    Log.Info(Log.PHASE_BOOT, "Boot complete. Entering scan/build loop.");

    while (true) {
        // 1. Scan + rank.
        local cands  = CargoScan.Scan();
        local ranked = Candidates.Rank(cands, this.state.blacklist);
        CargoScan.LogTop(ranked, 5);

        // 2. Try to build the best candidate we haven't already built.
        local built_one = false;
        foreach (c in ranked) {
            if (this.state.HasRoute(c.cargo, c.producer, c.accepter)) continue;
            if (c.score <= 0) {
                Log.Info(Log.PHASE_RANK, "Top remaining candidate has non-positive ROI; idle.");
                break;
            }
            local est = Scoring.BuildCostEstimate(c.distance);
            if (!Money.HasFunds(est / 2)) {
                Log.Info(Log.PHASE_MONEY, "Not enough cash (need ~" + (est/2) + "); waiting.");
                break;
            }
            if (this.TryBuildRoute(c)) {
                built_one = true;
                break;
            }
        }

        // 3. Yearly engine roster review.
        this.auto_replace.Tick(this.railtype, this.state);

        // 4. Surplus loan repay if cash is healthy.
        Money.RepaySurplusIfAny();

        Log.Info(Log.PHASE_LOOP,
            "Tick done. Routes=" + this.state.CountRoutes()
            + " Blacklist=" + this.state.blacklist.Size()
            + " Cash=" + Money.Cash());
        this.Sleep(built_one ? 500 : 2220);
    }
}

// Try to build the full route described by `c`.
// Reuses an existing station if we already serve that industry.
// Adds pair to blacklist on any failure.
function MvBAI::TryBuildRoute(c) {
    local cargo_label = AICargo.GetCargoLabel(c.cargo);
    Log.Info(Log.PHASE_RANK,
        "Attempting " + cargo_label
        + " " + AIIndustry.GetName(c.producer)
        + " -> " + AIIndustry.GetName(c.accepter)
        + " (dist=" + c.distance + ", ROI=" + c.score + ")");

    local route = Route.New(c.cargo, c.producer, c.accepter, c.distance);

    // Source station: reuse if we have one at this producer.
    route.src_station = this.state.FindExistingStation(c.producer, true);
    if (route.src_station == null) {
        route.src_station = StationBuilder.BuildAt(c.producer, c.cargo, true);
    } else {
        Log.Info(Log.PHASE_STATION, "Reusing existing source station id=" + route.src_station.station_id);
    }
    if (route.src_station == null) {
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }

    // Dest station.
    route.dst_station = this.state.FindExistingStation(c.accepter, false);
    if (route.dst_station == null) {
        route.dst_station = StationBuilder.BuildAt(c.accepter, c.cargo, false);
    } else {
        Log.Info(Log.PHASE_STATION, "Reusing existing dest station id=" + route.dst_station.station_id);
    }
    if (route.dst_station == null) {
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }

    // Track: two passes for double track.
    // front_tile is just outside the station exit; enter_tile is the
    // adjacent last-platform tile. Passing the adjacent pair gives the
    // pathfinder a length-1 first step (NOT the full platform length,
    // which would be mistaken for a bridge and fail to build).
    local tracks = TrackBuilder.BuildDoubleTracks(
        route.src_station.front_tile, route.src_station.enter_tile,
        route.dst_station.front_tile, route.dst_station.enter_tile);
    route.path_out  = tracks.out;
    route.path_back = tracks.back;
    if (route.path_out == null) {
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }

    // Signals on both tracks (back track may be null on very awkward terrain).
    Signals.PlaceAlong(route.path_out,  true,  "out");
    if (route.path_back != null) {
        Signals.PlaceAlong(route.path_back, true, "back");
    }

    // Spur depot off the out-track mainline (not at the station end).
    route.depot_tile = DepotBuilder.New(route.path_out);
    if (route.depot_tile == null) {
        Log.Err(Log.PHASE_DEPOT, "No depot could be built; abandoning route.");
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }

    // Trains.
    local engine = Trains.PickEngine(c.cargo, this.railtype);
    local wagon  = Trains.PickWagon(c.cargo, this.railtype);
    if (engine == -1 || wagon == -1) {
        Log.Err(Log.PHASE_TRAIN, "Cannot dispatch: missing engine/wagon.");
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }
    local n = Trains.PickNumWagons(c.distance);
    route.train_id = Trains.BuildTrain(route.depot_tile, engine, wagon, c.cargo, n);
    if (route.train_id == -1) {
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }
    if (!Trains.DispatchTrain(route.train_id, route.src_station.tile, route.dst_station.tile)) {
        this.state.blacklist.Add(c.cargo, c.producer, c.accepter);
        return false;
    }

    route.status = "built";
    this.state.AddRoute(route);
    Log.Info(Log.PHASE_RANK, "Route built and running. Total routes: " + this.state.CountRoutes());
    return true;
}

// Save/Load are stubbed in v1.
function MvBAI::Save() { return {}; }
function MvBAI::Load(version, data) { }
