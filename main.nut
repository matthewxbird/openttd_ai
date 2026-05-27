// main.nut
// Entry point for the AI. OpenTTD instantiates MvBAI and calls Start().
// v1 scaffold: set the company name, log a hello, sleep forever.
// Real logic gets layered in commit-by-commit.

require("src/logger.nut");
require("src/money.nut");
require("src/railtype.nut");
require("src/scoring.nut");
require("src/candidates.nut");
require("src/cargo_scan.nut");

class MvBAI extends AIController {
    function Start();
    function Save();
    function Load(version, data);
}

function MvBAI::Start() {
    // Name the company so it is identifiable in the player list.
    if (!AICompany.SetName("MvB AI")) {
        // Fallback if another AI already claimed the name.
        local i = 2;
        while (!AICompany.SetName("MvB AI #" + i)) i++;
    }

    Log.Info(Log.PHASE_BOOT, "MvB AI starting. Hello, OpenTTD!");

    Money.TakeMaxLoan();
    Railtype.PickAndSet();

    Log.Info(Log.PHASE_BOOT, "Boot complete. Entering scan loop.");

    local blacklist = Blacklist();

    while (true) {
        local cands  = CargoScan.Scan();
        local ranked = Candidates.Rank(cands, blacklist);
        CargoScan.LogTop(ranked, 5);

        Log.Info(Log.PHASE_LOOP, "Sleeping ~1 month. (build logic not wired yet)");
        this.Sleep(2220);  // ~30 game days
    }
}

// Save/Load are stubbed in v1. OpenTTD calls Save() before saving
// and Load() when a saved game with this AI is resumed.
function MvBAI::Save() {
    return {};
}

function MvBAI::Load(version, data) {
    // No persistent state yet.
}
