// src/backhaul.nut
// Phase 4 - native backhaul for RAIL. When the two endpoints of a route
// MUTUALLY produce AND accept the same cargo, the train can run loaded BOTH
// ways instead of returning empty - roughly doubling revenue for the same
// track. Air/road already shuttle loaded both ways (pax at both towns); this
// brings the same to rail freight.
//
// v1 is SAME-CARGO, no refit (the PLAN's stated starting point): we only flag
// backhaul when the accepter industry produces the SAME cargo the route hauls
// and the producer industry accepts it. Refit-aware multi-cargo backhaul is a
// later extension.

class Backhaul {
    // True if a rail route (cargo, producer->accepter) can load its return leg:
    // the accepter must also PRODUCE `cargo`, and the producer must also ACCEPT
    // it. Towns are never backhaul endpoints (they don't ship freight back).
    static function Mutual(cargo, producer, accepter, acc_is_town) {
        if (acc_is_town) return false;
        if (!AIIndustry.IsValidIndustry(producer) || !AIIndustry.IsValidIndustry(accepter)) {
            return false;
        }
        // Accepter produces the cargo (something to carry back)?
        local back_prod = AIIndustryList_CargoProducing(cargo);
        if (!back_prod.HasItem(accepter)) return false;
        // Producer accepts the cargo (somewhere to deliver it)?
        local back_acc = AIIndustryList_CargoAccepting(cargo);
        if (!back_acc.HasItem(producer)) return false;
        return true;
    }
}
