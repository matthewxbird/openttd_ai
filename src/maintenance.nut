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
    static QUEUE_NEAR        = 5;    // tiles from a station counted as "queuing"
    static WAITING_FOR_EXTRA = 150;  // source cargo waiting that warrants a train
    static MAX_TRAINS        = 2;    // cap trains per route. The reversing-terminus
                                     // throat deadlocks with 3-4 trains (-> condemn ->
                                     // ~200k lost each); 2 trains barely deadlock, so
                                     // routes survive. Measured huge: solo mean @256
                                     // 658k (cap 3) -> 1.03M (cap 2). TUNE if the
                                     // terminus is ever made deadlock-proof (RoRo).
    static MIN_CASH_FOR_TRAIN = 40000;  // don't add a train if cash is tight
    static CONDEMN_LIMIT     = 12;   // health passes to recall trains + tear down
    static RETIRE_LOSS_YEARS = 2;    // consecutive losing years before retiring a built route
    static STUCK_RETIRE_LIMIT = 3;   // consecutive built-route passes with a stuck train -> condemn

    // DEMAND-DRIVEN single->double upgrade gate. OFF: the converted routes still
    // deadlock the reversing terminus (measured regressive, 867,991 vs 973,579),
    // so the parked feature (commit "wip: demand-driven single->double") stays
    // dormant until the terminus deadlock is fixed. Flip to true to re-enable.
    static ENABLE_DEMAND_UPGRADE = false;

    // -- PURE helpers (unit-tested) ---------------------------------------
    // Next consecutive-losing-years streak given last year's route profit.
    static function NextLossStreak(streak, profit_last_year) {
        return (profit_last_year < 0) ? streak + 1 : 0;
    }
    // Retire a built route that has lost money this many years running.
    static function ShouldRetire(loss_streak, limit) {
        return loss_streak >= limit;
    }
    // Next consecutive-stuck streak given this pass's stuck-train count. A built
    // route whose trains deadlock mid-line earns nothing yet still bleeds running
    // costs; we track how many passes in a row we've seen a stalled train.
    static function NextStuckStreak(streak, stuck_count) {
        return (stuck_count > 0) ? streak + 1 : 0;
    }
    // Condemn a built route whose trains have stayed deadlocked this many passes
    // running, to recover capital before the bleed compounds into bankruptcy.
    static function ShouldCondemnStuck(stuck_streak, limit) {
        return stuck_streak >= limit;
    }
    // Probation is bounded by GAME TIME, not health-pass count: a long route with
    // a full-load train can take MONTHS to complete its first round trip (fill at
    // source, then travel), far longer than a fixed number of quick health passes.
    // Condemning on a pass-count timer killed perfectly good lines before their
    // first delivery. Give each line a deadline scaled to its length; genuinely
    // broken lines are still caught immediately by the stuck detector.
    static PROBATION_BASE_DAYS = 400;  // grace even for a zero-distance line
    static PROBATION_PER_TILE  = 6;    // + this many days per tile of distance
    static REACH_NEAR          = 8;    // within this many tiles of a station = "reached" it
    // Fast-condemn deadline for a line that never even approaches its dest:
    // ~2x a one-way trip. Shorter than full probation so broken lines stop
    // bleeding sooner, but long enough that a slow full-load route still arrives.
    static FIRST_DELIVERY_BASE     = 200;
    static FIRST_DELIVERY_PER_TILE = 4;

    // Run the health pass over every route, dispatching by lifecycle status.
    static function Tick(state, railtype) {
        // Collect routes to delete after the loop (don't mutate while iterating).
        local condemned_done = [];
        foreach (key, r in state.routes) {
            // AIR routes (Phase 2) have a thin, separate lifecycle - no track,
            // no stuck/deadlock logic. Hand them to Air and skip the rail passes.
            if (("air" in r) && r.air) {
                if (r.status == "condemning") {
                    if (Air.CheckCondemning(state, r)) condemned_done.push(r);
                } else {
                    Air.MaintainRoute(state, r);
                }
                continue;
            }
            // ROAD routes (Phase 3): thin lifecycle, no rail track/stuck logic.
            if (("road" in r) && r.road) {
                if (r.status == "condemning") {
                    if (Road.CheckCondemning(state, r)) condemned_done.push(r);
                } else {
                    Road.MaintainRoute(state, r);
                }
                continue;
            }
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

    // EMERGENCY CONTRACTION (Phase 0 solvency). When cash-stressed (usable money
    // can't even cover the operating buffer), running costs are about to spiral us
    // into bankruptcy - a bankrupt company scores ZERO and is the dominant 1v1
    // loss. Shed the worst bleeder: condemn the BUILT route whose vehicles lost
    // the most last year (recovers its capital + stops its running-cost drain).
    // One per call; called every loop while stressed until solvent. Returns true
    // if it condemned something.
    static function EmergencyContraction(state) {
        if (!Money.Stressed()) return false;
        local worst = null;
        local worst_profit = 0;   // only condemn genuine LOSERS (profit < 0)
        foreach (_, r in state.routes) {
            if (r.status != "built") continue;
            if (r.trains == null) continue;
            local p = 0;
            foreach (v in r.trains) {
                if (AIVehicle.IsValidVehicle(v)) p += AIVehicle.GetProfitLastYear(v);
            }
            if (p < worst_profit) { worst_profit = p; worst = r; }
        }
        if (worst == null) return false;   // nothing losing money to shed
        local name = (("air" in worst) && worst.air) || (("road" in worst) && worst.road)
            ? (AITown.GetName(worst.producer) + "->" + Route.AccepterName(worst))
            : (AIIndustry.GetName(worst.producer) + "->" + Route.AccepterName(worst));
        Log.Err(Log.PHASE_MONEY,
            "[contraction] cash-stressed (usable=" + Money.Usable()
            + "); condemning worst bleeder " + name + " (lost " + worst_profit + " last yr).");
        if (("air" in worst) && worst.air)        Air._Condemn(state, worst);
        else if (("road" in worst) && worst.road) Road._Condemn(state, worst);
        else                                       Maintenance._Condemn(state, worst);
        return true;
    }

    // True if any BUILT route still has a cargo backlog AND room to grow (more
    // trains, or a train shorter than the platform). Used to hold off building
    // NEW routes until existing ones are scaled up to carry all their cargo.
    // A route already at the train cap with full-length trains is "maxed" and
    // does NOT block - we can't scale it further.
    static function NeedsMoreCapacity(state) {
        foreach (_, r in state.routes) {
            if (("air" in r) && r.air) continue;   // air scales itself (Air.MaintainRoute)
            if (("road" in r) && r.road) continue; // road scales itself (Road.MaintainRoute)
            if (r.status != "built" || r.depot_tile == null) continue;
            local waiting = AIStation.GetCargoWaiting(r.src_station.station_id, r.cargo);
            if (waiting < Maintenance.WAITING_FOR_EXTRA) continue;

            local n = 0;
            local under = false;
            if (r.trains != null) {
                foreach (v in r.trains) {
                    if (!AIVehicle.IsValidVehicle(v)) continue;
                    n++;
                    if (Trains.IsUnderLength(v)) under = true;
                }
            }
            // A single-track route is capped at ONE train (a second would meet
            // it head-on), so it can only "scale" by running a longer train.
            local single = ("single_track" in r) && r.single_track;
            local can_add_train = !single && n < Maintenance.MAX_TRAINS;
            if (can_add_train || under) return true;  // can still scale
        }
        return false;
    }

    // PROBATION: a freshly built line must prove it works before we trust it.
    // We promote it to "built" once a train has made a full round trip (seen at
    // the destination, then back at the source) or is clearly turning a profit.
    // If a train gets stuck, or the line never earns within PROBATION_LIMIT
    // checks, we condemn it: recall the trains and tear the whole line down.
    static function _CheckProbation(state, r) {
        local name = AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r);
        local src_id = r.src_station.station_id;
        local dst_id = r.dst_station.station_id;

        if (r.trains == null) r.trains = (r.train_id != -1) ? [r.train_id] : [];
        // Start the game-time probation clock on the first check.
        if (!("probation_date" in r) || r.probation_date == null) {
            r.probation_date = AIDate.GetCurrentDate();
        }
        local alive = [];
        local stuck = 0;
        local profit = false;
        foreach (v in r.trains) {
            if (!AIVehicle.IsValidVehicle(v)) continue;
            alive.push(v);
            if (Maintenance._IsStuck(r, v)) stuck++;
            if (AIVehicle.GetProfitThisYear(v) > 0) profit = true;

            // Track round-trip progress by PROXIMITY to each station, not an exact
            // station-tile hit: with infrequent health passes a fast train is
            // almost never sampled exactly on a station tile, so the exact-match
            // test never fired and good routes only ever promoted via the profit
            // fallback. Being within the station footprint (+margin) is enough.
            local loc = AIVehicle.GetLocation(v);
            if (AIMap.DistanceManhattan(loc, r.dst_station.tile) <= Maintenance.REACH_NEAR) {
                r.reached_dst = true;
            }
            if (r.reached_dst
                    && AIMap.DistanceManhattan(loc, r.src_station.tile) <= Maintenance.REACH_NEAR) {
                r.reached_src = true;
            }
        }
        r.trains = alive;

        local round_trip = r.reached_dst && r.reached_src;
        local deadline_days = Maintenance.PROBATION_BASE_DAYS
            + (("distance" in r) ? r.distance : 0) * Maintenance.PROBATION_PER_TILE;
        local elapsed = AIDate.GetCurrentDate() - r.probation_date;
        Log.Info(Log.PHASE_LOOP,
            "[probation] " + name + " trains=" + alive.len()
            + (stuck > 0 ? (" STUCK=" + stuck) : "")
            + " reachedDst=" + r.reached_dst + " backAtSrc=" + r.reached_src
            + " elapsed=" + elapsed + "/" + deadline_days + "d");

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
        // FAST CONDEMN of a non-functional line: if a train has never even got
        // NEAR the destination within a first-delivery deadline (~2x the one-way
        // trip) AND is not turning a profit, the line is broken - cut it now
        // instead of bleeding running costs until the full probation deadline.
        local first_delivery = Maintenance.FIRST_DELIVERY_BASE
            + (("distance" in r) ? r.distance : 0) * Maintenance.FIRST_DELIVERY_PER_TILE;
        if (!r.reached_dst && !profit && elapsed >= first_delivery) {
            Log.Err(Log.PHASE_LOOP,
                "[probation] " + name + ": never reached destination in " + first_delivery
                + " days and unprofitable; condemning broken line.");
            Maintenance._Condemn(state, r);
            return;
        }
        if (elapsed >= deadline_days) {
            Log.Err(Log.PHASE_LOOP,
                "[probation] " + name + ": no round trip / profit within " + deadline_days
                + " days; condemning.");
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
            "[condemn] " + AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r)
            + ": blacklisted, recalling trains to depot for teardown.");
    }

    // CONDEMNING: sell any train that has reached a depot. Once all trains are
    // gone, demolish the infrastructure and report the route as done (the caller
    // removes it).
    //
    // We NEVER give up while a train is still alive. The old code abandoned the
    // recall after CONDEMN_LIMIT passes and demolished the infra (depots
    // included) - which ORPHANED any train that hadn't parked yet. Orphaned
    // trains keep running money-losing orders forever, draining the company into
    // bankruptcy (this was the dominant solo-loss path). Instead we keep the
    // depots standing and keep recovering: a train physically blocked in a
    // deadlock can't path to a depot, so we REVERSE the stuck ones to break the
    // jam, then re-issue the depot order. As trains park we sell them, which
    // frees the line for the rest. Returns true only once every train is sold.
    static function _CheckCondemning(state, r) {
        local name = AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r);
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
        // Keep recovering every still-running train. A deadlocked train can't
        // reach a depot while blocked, so reverse it to break the jam first.
        foreach (v in remaining) {
            if (Maintenance._IsStuck(r, v)) AIVehicle.ReverseVehicle(v);
            AIVehicle.SendVehicleToDepot(v);
        }
        if (r.condemn_checks % 8 == 0) {
            Log.Warn(Log.PHASE_LOOP, "[condemn] " + name + ": still recovering "
                + remaining.len() + " train(s) to depot (no orphaning).");
        }
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

    // Periodic CAPACITY REVIEW of one running route. Every pass we report the
    // line's state to the console - cargo waiting, station ratings, how many
    // trains, their length vs the platform, and the engine in use - then adjust
    // capacity: add a train, or lengthen an existing (too-short) train, when
    // cargo is backing up. (Engine upgrades are handled separately by the
    // yearly autoreplace pass.)
    static function _CheckRoute(state, railtype, r) {
        local cargo_label = AICargo.GetCargoLabel(r.cargo);
        local name = AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r);

        local src_id = r.src_station.station_id;
        local dst_id = r.dst_station.station_id;
        local waiting    = AIStation.GetCargoWaiting(src_id, r.cargo);
        local src_rating = AIStation.GetCargoRating(src_id, r.cargo);
        local dst_rating = AIStation.GetCargoRating(dst_id, r.cargo);
        local plat       = Trains.PlatformUnits();

        // Prune dead vehicles; gather train metrics (count, length, engine).
        if (r.trains == null) r.trains = (r.train_id != -1) ? [r.train_id] : [];
        local alive = [];
        local stuck = 0;
        local stuck_loc = null;   // location of the first stalled train (for the dump)
        local sum_len = 0;
        local shortest = null;
        local shortest_len = 0x7FFFFFFF;
        local engine_name = "?";
        foreach (v in r.trains) {
            if (!AIVehicle.IsValidVehicle(v)) continue;
            alive.push(v);
            if (Maintenance._IsStuck(r, v)) {
                stuck++;
                if (stuck_loc == null) stuck_loc = AIVehicle.GetLocation(v);
            }
            local len = AIVehicle.GetLength(v);
            sum_len += len;
            if (len < shortest_len) { shortest_len = len; shortest = v; }
            engine_name = AIEngine.GetName(AIVehicle.GetEngineType(v));
        }
        r.trains = alive;
        local n = alive.len();
        local avg_len = (n > 0) ? sum_len / n : 0;

        Log.Info(Log.PHASE_LOOP,
            "[review] " + cargo_label + " " + name
            + " trains=" + n + "/" + Maintenance.MAX_TRAINS
            + (stuck > 0 ? (" STUCK=" + stuck) : "")
            + " waiting=" + waiting
            + " rating(src/dst)=" + src_rating + "/" + dst_rating
            + " len(avg/short)=" + avg_len + "/" + shortest_len + " of " + plat
            + " engine='" + engine_name + "'");

        // PROFITABILITY RETIREMENT: once per game-year, sample the route's
        // profit over the PRIOR full year (sum across its trains). A line that
        // loses money RETIRE_LOSS_YEARS years running is a capital drain - retire
        // it so the money funds better routes. (Sampling per-year, not per-tick,
        // and using last YEAR's figure, avoids reacting to a just-scaled line.)
        local year = AIDate.GetYear(AIDate.GetCurrentDate());
        if (year > r.last_profit_year) {
            r.last_profit_year = year;
            local route_profit = 0;
            foreach (v in alive) route_profit += AIVehicle.GetProfitLastYear(v);
            r.loss_streak = Maintenance.NextLossStreak(r.loss_streak, route_profit);
            if (Maintenance.ShouldRetire(r.loss_streak, Maintenance.RETIRE_LOSS_YEARS)) {
                Log.Err(Log.PHASE_LOOP,
                    "[review] " + name + ": lost money " + r.loss_streak
                    + " years running (last yr " + route_profit + "); retiring.");
                Maintenance._Condemn(state, r);
                return;
            }
        }

        // Periodic INTEGRITY check: the track should still be continuous end to
        // end. Build glitches, or later damage, can leave a gap. Repair if we
        // can; if the line is broken and unrepairable, condemn it. (A single-track
        // route has no back track - path_back is null - which IsConnected and
        // ValidateAndRepair now treat as "nothing to check".)
        if (!TrackBuilder.IsConnected(r.path_out) || !TrackBuilder.IsConnected(r.path_back)) {
            local ro = TrackBuilder.ValidateAndRepair(r.path_out,  "out");
            local rb = TrackBuilder.ValidateAndRepair(r.path_back, "back");
            if (!ro || !rb) {
                Log.Err(Log.PHASE_LOOP,
                    "[review] " + name + ": track broken and unrepairable; condemning.");
                Maintenance._Condemn(state, r);
                return;
            }
            Log.Info(Log.PHASE_LOOP, "[review] " + name + ": track gap repaired.");
        }

        if (stuck > 0) {
            r.stuck_streak = Maintenance.NextStuckStreak(
                ("stuck_streak" in r) ? r.stuck_streak : 0, stuck);
            Log.Err(Log.PHASE_LOOP,
                "[review] " + name + ": " + stuck + " train(s) not moving (streak "
                + r.stuck_streak + "/" + Maintenance.STUCK_RETIRE_LIMIT + ") - line may be broken.");
            // A persistently deadlocked line earns nothing yet keeps bleeding
            // running costs; left alone it eventually triggers the 2-year loss
            // retirement, by which point the trains are too tangled to recall and
            // get ORPHANED (the old bankruptcy path). Condemn now to recover the
            // capital while the depots still stand and trains can still be freed.
            if (Maintenance.ShouldCondemnStuck(r.stuck_streak, Maintenance.STUCK_RETIRE_LIMIT)) {
                Log.Err(Log.PHASE_LOOP,
                    "[review] " + name + ": deadlocked " + r.stuck_streak
                    + " passes; condemning to recover capital.");
                // Visual diagnosis: render the layout around the stalled train so
                // the jam (throat crossover, depot junction, opposing train) is
                // legible in the log.
                if (stuck_loc != null) {
                    MapDump.Around(stuck_loc, 10,
                        [r.src_station.tile, r.dst_station.tile], "stuck");
                }
                Maintenance._Condemn(state, r);
            }
            return;  // don't pile more trains onto a broken line
        }
        r.stuck_streak = 0;  // healthy this pass

        // A single-track line mid-upgrade: drive that state machine to completion
        // (park all trains -> convert -> redispatch) before any other capacity
        // action this pass.
        if (("upgrade_state" in r) && r.upgrade_state != null && r.upgrade_state != "failed") {
            Maintenance._UpgradeSingleToDouble(r, railtype, name);
            return;
        }

        // STATION SIZING BY OUTPUT: the source station's platform count tracks
        // the producer's monthly output (2 base, +1 per 100t over 200). As the
        // industry grows we add platforms to match. (AddPlatform self-reverts if
        // it can't connect, so this never leaves a broken station.)
        local output = AIIndustry.GetLastMonthProduction(r.producer, r.cargo);
        local added  = StationBuilder.GrowToMatch(r.src_station, output);
        if (added > 0) {
            Log.Info(Log.PHASE_LOOP,
                "[review] " + name + ": output " + output + "t -> grew station to "
                + r.src_station.num_platforms + " platforms (+" + added + ").");
            return;   // structural change this pass; reassess next time
        }

        // Finish any train we previously recalled to lengthen.
        if (r.lengthening != null) {
            Maintenance._FinishLengthening(r, railtype, name);
            return;  // one capacity action per pass
        }

        // Backlog at the source on a healthy line => we lack capacity. Prefer
        // adding a train; if we're already at the train cap, lengthen the
        // shortest train (more cargo per trip) instead.
        if (waiting >= Maintenance.WAITING_FOR_EXTRA && r.depot_tile != null) {
            // Single-track routes are capped at one train; grow them by length only.
            local single = ("single_track" in r) && r.single_track;
            if (!single && n < Maintenance.MAX_TRAINS
                    && Money.Cash() > Maintenance.MIN_CASH_FOR_TRAIN) {
                Log.Info(Log.PHASE_LOOP,
                    "[review] " + name + ": backlog " + waiting + " -> adding a train.");
                Maintenance._AddTrain(r, railtype);
            } else if (shortest != null && Trains.IsUnderLength(shortest)) {
                Log.Info(Log.PHASE_LOOP,
                    "[review] " + name + ": backlog " + waiting
                    + ", trains under-length -> recalling train " + shortest + " to lengthen.");
                AIVehicle.SendVehicleToDepot(shortest);
                r.lengthening = shortest;
            } else if (single && Maintenance._CanUpgrade(r)) {
                // DEMAND-DRIVEN UPGRADE: a single-track line whose lone (full
                // length) train can't clear the backlog. Convert to double track
                // so it can run a second train. The state machine parks all trains
                // first, so no track/signal edit happens with a train on the line.
                Log.Info(Log.PHASE_LOOP,
                    "[review] " + name + ": backlog " + waiting
                    + " maxed on single track -> upgrading to double (recalling trains).");
                r.upgrade_state <- "recall";
                Maintenance._UpgradeSingleToDouble(r, railtype, name);
            } else {
                Log.Info(Log.PHASE_LOOP,
                    "[review] " + name + ": backlog " + waiting
                    + " but at full capacity (trains and length maxed).");
            }
        }
    }

    // Eligible to attempt a single->double upgrade now: not already failed, has a
    // stored out path to run parallel to, and affordable (track + a 2nd train).
    static function _CanUpgrade(r) {
        if (!Maintenance.ENABLE_DEMAND_UPGRADE) return false;
        if (("upgrade_state" in r) && r.upgrade_state == "failed") return false;
        if (!("path_out" in r) || r.path_out == null) return false;
        local cost = Scoring.BuildCostEstimate(r.distance, true)
                   + Scoring.FleetCostEstimate(1);
        return Money.Usable() > cost + Money.OPERATING_BUFFER;
    }

    // DEMAND-DRIVEN single->double upgrade, across health passes. Crucially we
    // PARK EVERY TRAIN before touching any track or signal, so nothing crashes on
    // a half-converted layout.
    //   recall  -> send all trains to a depot; wait until EVERY one is parked.
    //   convert -> (line now clear) lay the parallel back track + back depot,
    //              swap two-way PBS for one-way on both tracks, mark double, then
    //              verify each train's orders and re-send them out.
    static function _UpgradeSingleToDouble(r, railtype, name) {
        if (r.upgrade_state == "recall") {
            local all_parked = true;
            if (r.trains != null) {
                foreach (v in r.trains) {
                    if (!AIVehicle.IsValidVehicle(v)) continue;
                    if (AIVehicle.GetState(v) == AIVehicle.VS_IN_DEPOT) continue;
                    all_parked = false;
                    AIVehicle.SendVehicleToDepot(v);   // (idempotent re-issue is fine)
                }
            }
            if (all_parked) {
                r.upgrade_state = "convert";
                Log.Info(Log.PHASE_LOOP, "[upgrade] " + name + ": all trains parked; converting.");
            }
            return;
        }

        if (r.upgrade_state == "convert") {
            // Pay for the work up front so a partial build can't strand us.
            Money.EnsureFunds(Scoring.BuildCostEstimate(r.distance, true)
                            + Scoring.FleetCostEstimate(1) + Money.OPERATING_BUFFER);

            TrackBuilder._touched.clear();
            local back = TrackBuilder.BuildBackTrack(r.src_station, r.dst_station, r.path_out);
            if (!("touched" in r) || r.touched == null) r.touched = [];
            foreach (t in TrackBuilder._touched) r.touched.push(t);

            if (back == null || !TrackBuilder.ValidateAndRepair(back, "back")) {
                // Couldn't lay a parallel track here; stay single-track and send
                // the parked train back out so the line keeps running.
                Log.Warn(Log.PHASE_LOOP, "[upgrade] " + name
                    + ": back track unbuildable; staying single-track.");
                r.upgrade_state = "failed";
                Maintenance._RedispatchParked(r);
                return;
            }
            r.path_back = back;
            local d_back = DepotBuilder.New(r.path_back, "back");
            if (d_back != null) foreach (t in d_back) r.depot_tiles.push(t);

            // Two-way PBS (single, reversing) -> one-way PBS on BOTH tracks
            // (double: out flows srcâ†’dst, back flows dstâ†’src). The crossover at
            // each throat keeps its own two-way PBS (the train still reverses in
            // the platform), so we only re-signal the open mainlines.
            Signals.RemoveAlong(r.path_out, "out");
            Signals.PlaceAlong(r.path_out,  true, "out");
            Signals.PlaceAlong(r.path_back, true, "back");
            r.single_track = false;

            // Line is now double track and clear: re-check each parked train's
            // orders and send them back out. The capacity pass adds the 2nd train.
            Maintenance._RedispatchParked(r);
            r.upgrade_state = null;
            Log.Info(Log.PHASE_LOOP, "[upgrade] " + name
                + ": now DOUBLE TRACK; trains redispatched, capacity pass will add a 2nd.");
            return;
        }
    }

    // Verify orders on every parked train of a route and send it back out.
    static function _RedispatchParked(r) {
        if (r.trains == null) return;
        foreach (v in r.trains) {
            if (AIVehicle.IsValidVehicle(v)) {
                Trains.EnsureOrders(v, r.src_station.tile, r.dst_station.tile);
            }
        }
    }

    // A train was recalled to a depot to be lengthened. If it has arrived, add
    // wagons up to the platform/power limit and send it back out.
    static function _FinishLengthening(r, railtype, name) {
        local v = r.lengthening;
        if (!AIVehicle.IsValidVehicle(v)) { r.lengthening = null; return; }
        if (AIVehicle.GetState(v) != AIVehicle.VS_IN_DEPOT) {
            Log.Info(Log.PHASE_LOOP, "[review] " + name + ": train " + v + " heading to depot to lengthen.");
            return;  // still travelling; check again next pass
        }
        local wagon = Trains.PickWagon(r.cargo, railtype);
        local added = (wagon != -1) ? Trains.GrowInDepot(v, wagon, r.cargo) : 0;
        AIVehicle.StartStopVehicle(v);
        r.lengthening = null;
        Log.Info(Log.PHASE_LOOP,
            "[review] " + name + ": lengthened train " + v + " by " + added
            + " wagon(s) (len now " + AIVehicle.GetLength(v) + "/" + Trains.PlatformUnits()
            + "), back in service.");
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
        // A train waiting NEAR a station is QUEUING for a platform, not stuck on
        // a broken line - don't condemn the route for it (we enlarge instead).
        if (Maintenance._NearStation(r, v)) {
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

    // True if a train is within QUEUE_NEAR tiles of either station.
    static function _NearStation(r, v) {
        local loc = AIVehicle.GetLocation(v);
        if (AIMap.DistanceManhattan(loc, r.src_station.tile) <= Maintenance.QUEUE_NEAR) return true;
        if (AIMap.DistanceManhattan(loc, r.dst_station.tile) <= Maintenance.QUEUE_NEAR) return true;
        return false;
    }

    // Count trains stopped on the line NEAR a station (waiting for a platform).
    static function _CountQueuing(r) {
        local q = 0;
        if (r.trains == null) return 0;
        foreach (v in r.trains) {
            if (!AIVehicle.IsValidVehicle(v)) continue;
            if (AIVehicle.GetState(v) != AIVehicle.VS_RUNNING) continue;  // not loading/in depot
            if (AIVehicle.GetCurrentSpeed(v) != 0) continue;
            if (Maintenance._NearStation(r, v)) q++;
        }
        return q;
    }

    // Buy and dispatch one more train on this route, built at its depot.
    static function _AddTrain(r, railtype) {
        local engine = Trains.PickEngine(r.cargo, railtype);
        local wagon  = Trains.PickWagon(r.cargo, railtype);
        if (engine == -1 || wagon == -1) return;

        local n  = Trains.PickNumWagons(r.distance, ("production" in r) ? r.production : null);
        local id = Trains.BuildTrain(r.depot_tile, engine, wagon, r.cargo, n);
        if (id == -1) return;

        local bh = ("backhaul" in r) ? r.backhaul : false;
        if (!Trains.DispatchTrain(id, r.src_station.tile, r.dst_station.tile, bh)) return;

        r.trains.push(id);
        Log.Info(Log.PHASE_LOOP,
            "[health] added train " + id + " to "
            + AIIndustry.GetName(r.producer) + "->" + Route.AccepterName(r)
            + " (now " + r.trains.len() + ")");
    }
}
