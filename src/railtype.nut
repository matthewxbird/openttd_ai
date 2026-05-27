// src/railtype.nut
// Pick the best rail type available right now and make it "current"
// so subsequent AIRail builds use it.
//
// "Best" = highest max speed among rail types we can actually build.
// Falls back to first available if speeds are all zero/unknown.


class Railtype {
    // Pick the best available rail type. Returns the RailType id, or
    // AIRail.RAILTYPE_INVALID if none available.
    static function PickBest() {
        local list = AIRailTypeList();
        if (list.IsEmpty()) {
            Log.Err(Log.PHASE_BOOT, "No rail types available at all.");
            return AIRail.RAILTYPE_INVALID;
        }

        local best = AIRail.RAILTYPE_INVALID;
        local best_speed = -1;
        foreach (rt, _ in list) {
            if (!AIRail.IsRailTypeAvailable(rt)) continue;
            local speed = AIRail.GetMaxSpeed(rt);
            if (speed > best_speed) {
                best = rt;
                best_speed = speed;
            }
        }

        if (best == AIRail.RAILTYPE_INVALID) {
            Log.Err(Log.PHASE_BOOT, "No buildable rail type found.");
            return best;
        }

        Log.Info(Log.PHASE_BOOT, "Rail type chosen (id=" + best + ", max_speed=" + best_speed + ").");
        return best;
    }

    // Convenience: pick + set current. Returns the chosen rail type id.
    static function PickAndSet() {
        local rt = Railtype.PickBest();
        if (rt != AIRail.RAILTYPE_INVALID) {
            AIRail.SetCurrentRailType(rt);
        }
        return rt;
    }
}
