// src/money.nut
// Loan + cash helpers. The pure parts (ShouldRepay) live here too so tests
// can verify the thresholds without OpenTTD running.
//
// Strategy:
//  - On boot, take the maximum loan so we have build capital up front.
//  - Each loop tick, if cash is comfortably above the loan, repay one step.
//  - HasFunds(estimate) checks bank balance before kicking off a build.

require("src/logger.nut");

class Money {
    // -- PURE function (testable without AI* calls) -----------------------
    // Returns true if we have enough cash headroom to repay one loan step.
    // cash:        current bank balance (positive int)
    // loan:        current loan amount
    // step:        loan increment size (smallest repayable chunk)
    // headroom:    how many multiples of `step` cash must exceed loan by
    //              before we start paying down.
    static function ShouldRepay(cash, loan, step, headroom = 4) {
        if (loan <= 0) return false;
        if (step <= 0) return false;
        return cash - loan >= step * headroom;
    }

    // -- AI* wrappers below -----------------------------------------------

    // Take the maximum loan the bank will offer.
    static function TakeMaxLoan() {
        local max_loan = AICompany.GetMaxLoanAmount();
        if (AICompany.SetLoanAmount(max_loan)) {
            Log.Info(Log.PHASE_MONEY, "Loan set to max: " + max_loan);
        } else {
            Log.Warn(Log.PHASE_MONEY, "Failed to take max loan: " + AIError.GetLastErrorString());
        }
    }

    // Bank balance for our company.
    static function Cash() {
        return AICompany.GetBankBalance(AICompany.COMPANY_SELF);
    }

    // Current outstanding loan.
    static function Loan() {
        return AICompany.GetLoanAmount();
    }

    // If cash is well above the loan, repay one step's worth.
    // Returns true if we repaid, false otherwise.
    static function RepaySurplusIfAny() {
        local cash = Money.Cash();
        local loan = Money.Loan();
        local step = AICompany.GetLoanInterval();
        if (!Money.ShouldRepay(cash, loan, step)) return false;

        local new_loan = loan - step;
        if (new_loan < 0) new_loan = 0;
        if (AICompany.SetLoanAmount(new_loan)) {
            Log.Info(Log.PHASE_MONEY, "Repaid " + step + ". Loan now " + new_loan + ".");
            return true;
        }
        Log.Warn(Log.PHASE_MONEY, "Repay failed: " + AIError.GetLastErrorString());
        return false;
    }

    // Returns true if we have at least `estimate` in the bank.
    static function HasFunds(estimate) {
        return Money.Cash() >= estimate;
    }
}
