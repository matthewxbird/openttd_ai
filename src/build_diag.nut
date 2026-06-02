// src/build_diag.nut
// Phase 8 - track-build debuggability. Headless can't screenshot, so when a
// rail/bridge/tunnel piece won't build we must emit ONE structured line that
// explains WHY: the error, the tile's owner, and the tile's state. In
// particular AIError.GetLastErrorString() is often the useless "ERR_UNKNOWN" -
// we classify the real cause from the tile facts instead.
//
// The decision logic is PURE (no AI* calls) so it is unit-tested in tests/;
// the AI* wrapper (BuildDiag.Report) gathers the facts and logs the line.

class BuildDiag {

    // PURE: turn an error name + tile facts into a human cause + a recovery hint.
    // Returns { cause = <string>, recover = <"terraform"|"detour"|"none"> }.
    //   err_name     : AIError name, or "UNKNOWN" when the API gave us nothing
    //   owner_mine   : COMPANY_SELF owns the tile
    //   owner_none   : the tile is unowned (OWNER_NONE)
    //   is_rail/water/station/buildable : tile state booleans
    // The recovery hint tells the builder what to try next:
    //   "terraform" - flatten/clear and lay ground rail (or bridge over water)
    //   "detour"    - reroute around it (foreign property; can't build here)
    //   "none"      - nothing obvious; just report
    static function Classify(err_name, owner_mine, owner_none,
                             is_rail, is_water, is_station, is_buildable) {
        // Foreign property (rival rail/road/building/station) - we can neither
        // build on it nor demolish it. The only option is to route around.
        if (!owner_mine && !owner_none && (is_rail || is_station)) {
            return { cause = "rival-owned " + (is_station ? "station" : "rail")
                            + " (ERR_OWNED_BY_ANOTHER_COMPANY)", recover = "detour" };
        }
        // Our own rail/station in the way - a routing tangle, detour around it.
        if (owner_mine && (is_rail || is_station)) {
            return { cause = "our own " + (is_station ? "station" : "rail")
                            + " here", recover = "detour" };
        }
        // Water under a ground piece or a tunnel mouth: must be bridged.
        if (is_water || err_name == "ERR_TUNNEL_CANNOT_BUILD_ON_WATER") {
            return { cause = "water (needs a bridge, not ground/tunnel)",
                     recover = "terraform" };
        }
        // Something clearable is sitting on the tile (trees, object, slope).
        if (err_name == "ERR_AREA_NOT_CLEAR" || (!is_buildable && owner_none)) {
            return { cause = "area not clear (clearable obstacle / rough ground)",
                     recover = "terraform" };
        }
        // Genuinely unknown - report the raw facts so a human can see them.
        return { cause = (err_name == "UNKNOWN" || err_name == "ERR_UNKNOWN"
                            ? "unclassified" : err_name)
                        + " [rail=" + is_rail + " water=" + is_water
                        + " station=" + is_station + " buildable=" + is_buildable
                        + " mine=" + owner_mine + "]",
                 recover = "none" };
    }

    // AI* glue: map the LAST AIError to a name we classify on. Only the codes we
    // act on are named; everything else is "UNKNOWN" and gets classified from the
    // tile facts (which is the whole point - ERR_UNKNOWN alone tells us nothing).
    // MUST be called immediately after the failing build (AIError is volatile).
    static function _ErrName(err) {
        if (err == AIError.ERR_OWNED_BY_ANOTHER_COMPANY) return "ERR_OWNED_BY_ANOTHER_COMPANY";
        if (err == AIError.ERR_AREA_NOT_CLEAR)           return "ERR_AREA_NOT_CLEAR";
        if (err == AIError.ERR_NOT_ENOUGH_CASH)          return "ERR_NOT_ENOUGH_CASH";
        if (err == AIError.ERR_LAND_SLOPED_WRONG)        return "ERR_LAND_SLOPED_WRONG";
        if (err == AIError.ERR_VEHICLE_IN_THE_WAY)       return "ERR_VEHICLE_IN_THE_WAY";
        if (err == AIError.ERR_SITE_UNSUITABLE)          return "ERR_SITE_UNSUITABLE";
        // Tunnel-on-water surfaces as a site-unsuitable on a water tile; the
        // classifier picks that up from the water fact.
        return "UNKNOWN";
    }

    // AI* glue: classify a build failure at `tile` and emit ONE structured log
    // line (phase, context, tile + coords, error, owner, tile state, cause).
    // Returns the recovery hint ("terraform" / "detour" / "none") so the caller
    // can act. Call IMMEDIATELY after the failing build call.
    static function Report(tile, label, context) {
        local err   = AIError.GetLastError();
        local name  = BuildDiag._ErrName(err);
        local owner = AITile.GetOwner(tile);
        local mine  = AICompany.IsMine(owner);
        local none  = (owner == AICompany.COMPANY_INVALID) || (owner == -1);
        local diag  = BuildDiag.Classify(
            name, mine, none,
            AIRail.IsRailTile(tile), AITile.IsWaterTile(tile),
            AITile.IsStationTile(tile), AITile.IsBuildable(tile));
        Log.Warn(Log.PHASE_TRACK,
            "[" + label + "] BUILD FAIL " + context
            + " tile=" + tile + " (" + AIMap.GetTileX(tile) + "," + AIMap.GetTileY(tile) + ")"
            + " err=" + name + "(" + err + ") owner=" + owner
            + " cause=" + diag.cause + " -> recover=" + diag.recover);
        return diag.recover;
    }
}
