// MvBObserver - logs each company's value once per game year.
//
// Output lines (captured from OpenTTD's -d script log) look like:
//   [OBSERVE] year=1953 company=0 value=482911 cash=120345 name=MvB AI
//   [OBSERVE] END year=...                 <- emitted at shutdown-ish boundaries
// The external harness (tools/run_match.ps1) parses these to pick a winner.
class MvBObserver extends GSController {
    function Start();
}

function MvBObserver::Start() {
    GSLog.Warning("[OBSERVE] BEGIN observer started");
    local last_year = -1;

    while (true) {
        local cur  = GSDate.GetCurrentDate();
        local year = GSDate.GetYear(cur);

        if (year != last_year) {
            last_year = year;
            for (local c = 0; c < 15; c++) {
                local cid = GSCompany.ResolveCompanyID(c);
                if (cid == GSCompany.COMPANY_INVALID) continue;
                local value = GSCompany.GetQuarterlyCompanyValue(cid, GSCompany.CURRENT_QUARTER);
                local cash  = GSCompany.GetBankBalance(cid);
                local name  = GSCompany.GetName(cid);
                GSLog.Warning("[OBSERVE] year=" + year + " company=" + cid
                    + " value=" + value + " cash=" + cash + " name=" + name);
            }
        }
        GSController.Sleep(74);   // ~one in-game day
    }
}
