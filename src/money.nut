// src/money.nut
// Loan + cash helpers. The pure parts (ShouldRepay) live here too so tests
// can verify the thresholds without OpenTTD running.
//
// Strategy:
//  - On boot, take the maximum loan so we have build capital up front.
//  - Each loop tick, if cash is comfortably above the loan, repay one step.
//  - HasFunds(estimate) checks bank balance before kicking off a build.


class Money {
    // Keep at least this much cash on hand for running costs + small capacity
    // buys (maintenance adds a train at >40k), so repaying the loan never
    // starves expansion. We repay only cash ABOVE this buffer.
    static OPERATING_BUFFER = 80000;

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

    // PURE: how much of the loan to repay this tick. We pay down as much as we
    // can while keeping `buffer` cash, rounded DOWN to whole loan steps, capped
    // at the outstanding loan. Returns 0 when nothing should be repaid.
    //   cash, loan, step: as above.   buffer: cash to retain.
    static function RepayAmount(cash, loan, step, buffer) {
        if (loan <= 0 || step <= 0) return 0;
        local spare = cash - buffer;          // cash free to repay
        if (spare < step) return 0;
        local repay = spare - (spare % step);  // whole steps only
        if (repay > loan) repay = loan;
        return repay;
    }

    // PURE: the new loan amount needed so that `cash` covers `need` (+ keep the
    // existing loan). Rounded UP to whole steps, clamped to maxloan. Returns the
    // current loan unchanged when cash already covers `need`.
    static function BorrowTarget(cash, loan, need, step, maxloan) {
        if (cash >= need) return loan;
        local shortfall = need - cash;
        local new_loan = loan + shortfall;
        if (step > 0 && new_loan % step != 0) new_loan += step - (new_loan % step);
        if (new_loan > maxloan) new_loan = maxloan;
        if (new_loan < loan) new_loan = loan;
        return new_loan;
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

    // Total spending power: cash on hand PLUS what we could still borrow. We
    // reason about this (not just cash) so a build that's affordable via a
    // just-in-time loan isn't skipped, while idle loan isn't held (interest).
    static function Usable() {
        return Money.Cash() + (AICompany.GetMaxLoanAmount() - Money.Loan());
    }

    // Pay down the loan as far as cash allows while keeping OPERATING_BUFFER on
    // hand. Aggressive repayment cuts interest AND directly lifts company value
    // (value counts -loan). Returns true if we repaid.
    static function RepayDownToBuffer() {
        local cash = Money.Cash();
        local loan = Money.Loan();
        local step = AICompany.GetLoanInterval();
        local repay = Money.RepayAmount(cash, loan, step, Money.OPERATING_BUFFER);
        if (repay <= 0) return false;
        local new_loan = loan - repay;
        if (AICompany.SetLoanAmount(new_loan)) {
            Log.Info(Log.PHASE_MONEY, "Repaid " + repay + ". Loan now " + new_loan + ".");
            return true;
        }
        Log.Warn(Log.PHASE_MONEY, "Repay failed: " + AIError.GetLastErrorString());
        return false;
    }

    // Borrow JUST enough that the bank balance covers `need`. Returns true if,
    // after any borrowing, cash >= need. Used right before a build we've decided
    // to make, so we never start one we can't finish.
    static function EnsureFunds(need) {
        local cash = Money.Cash();
        if (cash >= need) return true;
        local loan    = Money.Loan();
        local step    = AICompany.GetLoanInterval();
        local maxloan = AICompany.GetMaxLoanAmount();
        local target  = Money.BorrowTarget(cash, loan, need, step, maxloan);
        if (target > loan) {
            if (AICompany.SetLoanAmount(target)) {
                Log.Info(Log.PHASE_MONEY,
                    "Borrowed for build: loan " + loan + " -> " + target
                    + " (need " + need + ", had " + cash + ").");
            } else {
                Log.Warn(Log.PHASE_MONEY, "Borrow failed: " + AIError.GetLastErrorString());
            }
        }
        return Money.Cash() >= need;
    }

    // Returns true if we have at least `estimate` of spending power (cash we
    // could marshal via a just-in-time loan), NOT merely cash in hand.
    static function HasFunds(estimate) {
        return Money.Usable() >= estimate;
    }
}
