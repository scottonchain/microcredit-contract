// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "../utils/MicrocreditTestBase.sol";
import { CreditHandler } from "./CreditHandler.sol";

/**
 * @dev Stateful fuzzing of the protocol's central claim (docs/CREDIT_INTEGRITY_ISSUES.md, CI-8):
 *      credit cannot be manufactured, so Sybil accounts add nothing. A fixed cast of credited
 *      accounts, stakers and sybils back, stake, borrow, repay, default and exit in arbitrary
 *      order (see CreditHandler); scores stay fixed, so each account's issued line I0(a) never
 *      changes and the only other source of granted credit is its dues: the share of the
 *      interest it pays that goes into the first-loss reserve.
 *
 *      Notation: G(a) = grantedCredit(a), C(a) = creditCommitted(a), SC(a) = stakeCommitted(a),
 *      line(a) = I0(a) + dues(a), P(a) = unpaid principal on a's open loans, E(a) = backing a
 *      receives (secured + unsecured, nominal), Limit(a) = getBorrowLimit(a).limit.
 *
 *      The inline settings below keep `forge test --match-path 'test/invariant/*'` at about half a
 *      minute. Inline config overrides FOUNDRY_INVARIANT_* variables, so for a deeper campaign
 *      raise runs and depth here (runs = 256, depth = 100 passes in a few minutes). Per-run
 *      coverage (loans, defaults, charges, slashes, sybil loans, how close Q and I2 come to
 *      binding) is logged by afterInvariant with -vv, and appended to INVARIANT_STATS_FILE when set.
 */
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract CreditConservationInvariantTest is MicrocreditTestBase {
    uint256 internal constant MAX_LOAN = 100e6;
    uint256 internal constant POOL = 100_000e6;
    uint256 internal constant PROTOCOL_FEE_BPS = 1_000;
    uint256 internal constant RESERVE_BPS = 2_000;

    CreditHandler internal handler;
    address internal poolLender = makeAddr("poolLender");
    address[] internal cast;
    mapping(address => uint256) internal indexOf;

    function setUp() public {
        _deploy(433, 500, MAX_LOAN);
        vm.startPrank(owner);
        credit.setProtocolFeeBps(PROTOCOL_FEE_BPS);
        credit.setReserveBps(RESERVE_BPS);
        vm.stopPrank();
        _deposit(poolLender, POOL);

        uint256[3] memory scores_ = [uint256(1_000_000), 600_000, 250_000];
        CreditHandler.Actor[] memory actors_ = new CreditHandler.Actor[](11);
        for (uint256 i = 0; i < 11; i++) {
            CreditHandler.Role role =
                i < 3 ? CreditHandler.Role.Credited : (i < 5 ? CreditHandler.Role.Staker : CreditHandler.Role.Sybil);
            string memory name = role == CreditHandler.Role.Credited
                ? "credited"
                : (role == CreditHandler.Role.Staker ? "staker" : "sybil");
            (address account, uint256 key) = makeAddrAndKey(string.concat(name, vm.toString(i)));
            uint256 score = i < 3 ? scores_[i] : 0;
            if (score != 0) {
                vm.prank(owner);
                credit.setScoreOverride(account, score);
            }
            actors_[i] = CreditHandler.Actor({ account: account, key: key, role: role, score: score });
            cast.push(account);
            indexOf[account] = i;
        }
        (address lender2, uint256 lender2Key) = makeAddrAndKey("lender2");
        handler = new CreditHandler(credit, usdc, owner, poolLender, POOL, lender2, lender2Key, actors_);

        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = CreditHandler.back.selector;
        selectors[1] = CreditHandler.stake.selector;
        selectors[2] = CreditHandler.unstake.selector;
        selectors[3] = CreditHandler.sybilRing.selector;
        selectors[4] = CreditHandler.borrow.selector;
        selectors[5] = CreditHandler.borrowWithTerm.selector;
        selectors[6] = CreditHandler.requestLoan.selector;
        selectors[7] = CreditHandler.disburseLoan.selector;
        selectors[8] = CreditHandler.cancelLoan.selector;
        selectors[9] = CreditHandler.repay.selector;
        selectors[10] = CreditHandler.markDefaulted.selector;
        selectors[11] = CreditHandler.warp.selector;
        selectors[12] = CreditHandler.deposit.selector;
        selectors[13] = CreditHandler.withdraw.selector;
        selectors[14] = CreditHandler.requestWithdrawal.selector;
        selectors[15] = CreditHandler.processQueue.selector;
        selectors[16] = CreditHandler.donate.selector;
        selectors[17] = CreditHandler.claimFees.selector;
        selectors[18] = CreditHandler.releaseReserve.selector;
        selectors[19] = CreditHandler.impairLoan.selector;
        selectors[20] = CreditHandler.fundReserve.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // ───────────────────────────── I1: capacity ─────────────────────────────

    /**
     * @dev Sum Limit(v) <= sum (G(a) + SC(a)). A limit is (G - C) plus backing received; secured
     *      backing received sums to the backers' SC, and unsecured backing counts at most what
     *      its backer committed (less when the backer's cover is short), so the sum telescopes
     *      to at most G + SC per account however the accounts back each other.
     */
    function invariant_I1_capacityBound() public view {
        uint256 capacity = 0;
        uint256 held = 0;
        for (uint256 i = 0; i < cast.length; i++) {
            capacity += _limit(cast[i]);
            held += credit.grantedCredit(cast[i]) + credit.stakeCommitted(cast[i]);
        }
        assertLe(capacity, held, "I1: borrowing capacity exceeds the credit and committed stake that exist");
    }

    /**
     * @dev Per borrower: Limit(v) <= (G(v) - C(v)) + secured received + unsecured received from
     *      backers that have not defaulted, and a defaulter's limit is 0. Credit a backer lost
     *      by defaulting backs nobody (CI-15).
     */
    function invariant_I1b_lostCreditBacksNobody() public view {
        for (uint256 i = 0; i < cast.length; i++) {
            address v = cast[i];
            uint256 limit = _limit(v);
            if (credit.defaultedLoans(v) != 0) {
                assertEq(limit, 0, "I1b: a defaulted borrower has a limit");
                continue;
            }
            uint256 granted = credit.grantedCredit(v);
            uint256 committed = credit.creditCommitted(v);
            uint256 bound_ = granted > committed ? granted - committed : 0;
            DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(v);
            for (uint256 j = 0; j < edges.length; j++) {
                bound_ += edges[j].secured;
                if (credit.defaultedLoans(edges[j].backer) == 0) bound_ += edges[j].unsecured;
            }
            assertLe(limit, bound_, "I1b: a limit counts credit its backer no longer holds");
        }
    }

    // ───────────────────────────── I2 / Q: losses ─────────────────────────────

    /**
     * @dev The main theorem. Lambda + U <= sum line(a) (+ pro-rata rounding dust), where Lambda is
     *      the loss realised before the first-loss reserve (sum of writtenOff - stake slashed)
     *      and U = sum over borrowers of max(0, disbursed unpaid principal - secured backing
     *      received), the further loss if every open loan defaulted now. Lenders can never lose
     *      more than the credit that was issued plus the dues borrowers paid in, however many
     *      accounts exist and whatever they do. It follows from Q summed over accounts.
     */
    function invariant_I2_lossBound() public view {
        uint256 issued = 0;
        uint256 exposure = 0;
        for (uint256 i = 0; i < cast.length; i++) {
            address a = cast[i];
            issued += handler.issuedLine(a) + handler.dues(a);
            (uint256 secured,) = _received(a);
            uint256 lent = handler.lentPrincipal(a);
            if (lent > secured) exposure += lent - secured;
        }
        assertLe(
            handler.lossBeforeReserve() + exposure,
            issued + handler.totalRoundingDust(),
            "I2: realised plus potential loss exceeds the credit issued plus dues paid"
        );
        assertLe(handler.realisedLoss(), handler.lossBeforeReserve(), "I2: the reserve added to lenders' loss");
    }

    /**
     * @dev Honest lenders never pay for dues-funded credit. Dues are exactly the reserve share of
     *      interest, so I2 gives lenders' loss (writtenOff - slashed - reserve used) plus U at
     *      most sum I0 + reserve on hand - reserve funded + reserve released: lenders' realised
     *      loss plus the potential loss the reserve on hand cannot absorb never exceeds the issued
     *      lines (plus reserve already handed to them). Credit earned from history is prepaid.
     */
    function invariant_I8_honestLendersPayOnlyForIssuedLines() public view {
        uint256 issued = 0;
        uint256 exposure = 0;
        for (uint256 i = 0; i < cast.length; i++) {
            address a = cast[i];
            issued += handler.issuedLine(a);
            (uint256 secured,) = _received(a);
            uint256 lent = handler.lentPrincipal(a);
            if (lent > secured) exposure += lent - secured;
        }
        uint256 reserve = credit.firstLossReserve();
        uint256 uncovered = exposure > reserve ? exposure - reserve : 0;
        assertLe(
            handler.realisedLoss() + uncovered,
            issued + handler.reserveReleased() + handler.reserveForgiven() + handler.totalRoundingDust(),
            "I8: lenders bear loss beyond the issued lines"
        );
    }

    /**
     * @dev Per account (the proof's potential): r(a) + C(a) + charged(a) + residual(a) <= line(a),
     *      with r(a) = max(0, P(a) - E(a)), charged(a) the credit charged to a as a backer and
     *      residual(a) what a's own defaults left after its backers paid. Each account can lose
     *      lenders at most its own line, once: committing, borrowing and cutting backing all
     *      require free credit, and a charge or a default only moves budget from C or r into
     *      charged or residual. The allowance is the mulDiv rounding of the pro-rata slash and
     *      charge at a's own defaults (a few wei).
     */
    function invariant_Q_perAccountCreditBudget() public view {
        for (uint256 i = 0; i < cast.length; i++) {
            address a = cast[i];
            (uint256 secured, uint256 unsecured) = _received(a);
            uint256 open = handler.openPrincipal(a);
            uint256 r = open > secured + unsecured ? open - secured - unsecured : 0;
            uint256 used = r + credit.creditCommitted(a) + handler.charged(a) + handler.residual(a);
            uint256 budget = handler.issuedLine(a) + handler.dues(a) + handler.roundingDust(a);
            assertLe(used, budget, string.concat("Q: account spent more credit than it held: ", vm.toString(a)));
        }
    }

    // ───────────────────────────── I3 / I4: sybils ─────────────────────────────

    /**
     * @dev Sum of sybil limits <= backing that credited accounts and stakers committed to sybils,
     *      plus dues sybils paid themselves; a sybil with no backing and no dues has limit 0.
     *      A sybil's G is only its dues, so everything else in its limit is someone else's credit.
     */
    function invariant_I3_sybilIndependence() public view {
        address[] memory sybils = handler.sybils();
        uint256 sybilCapacity = 0;
        uint256 fromOthers = 0;
        uint256 sybilDues = 0;
        for (uint256 i = 0; i < sybils.length; i++) {
            address s = sybils[i];
            uint256 limit = _limit(s);
            sybilCapacity += limit;
            sybilDues += handler.dues(s);
            uint256 received = 0;
            DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(s);
            for (uint256 j = 0; j < edges.length; j++) {
                uint256 amount = edges[j].secured + edges[j].unsecured;
                received += amount;
                if (handler.roleOf(edges[j].backer) != CreditHandler.Role.Sybil) fromOthers += amount;
            }
            if (received == 0 && handler.dues(s) == 0) assertEq(limit, 0, "I3: an unbacked sybil has a limit");
        }
        assertLe(sybilCapacity, fromOthers + sybilDues, "I3: sybils hold capacity nobody gave them");
    }

    /**
     * @dev Sybils never stake, so they commit no stake; they can commit credit only out of dues
     *      they paid (C + creditLoss <= dues), so a sybil that never paid interest commits nothing.
     */
    function invariant_I4_sybilsCommitNothingTheyDidNotPay() public view {
        address[] memory sybils = handler.sybils();
        for (uint256 i = 0; i < sybils.length; i++) {
            address s = sybils[i];
            assertEq(credit.stakeCommitted(s), 0, "I4: a sybil committed stake");
            assertEq(credit.stakeOf(s), 0, "I4: a sybil holds stake");
            uint256 paid = handler.dues(s);
            assertLe(credit.creditCommitted(s) + credit.creditLoss(s), paid, "I4: a sybil committed credit beyond dues");
            if (paid == 0) assertEq(credit.creditCommitted(s), 0, "I4: a sybil without dues committed credit");
        }
    }

    // ───────────────────────────── I5 / I6: money ─────────────────────────────

    /**
     * @dev Every USDC the contract owes is held: pool cash (the reserve's included), fees, stake
     *      and payouts held for refused recipients. The reserve is a junior claim inside the pool,
     *      so it never exceeds the pool.
     */
    function invariant_I5_solvency() public view {
        uint256 owed =
            credit.lenderCash() + credit.protocolFees() + credit.totalStaked() + credit.totalUnclaimedPayouts();
        uint256 balance = usdc.balanceOf(address(credit));
        assertGe(balance, owed, "I5: the contract owes more USDC than it holds");
        assertEq(balance, owed + handler.donated(), "I5: USDC unaccounted for beyond stray transfers");
        assertLe(
            credit.firstLossReserve(),
            credit.lenderCash() + credit.totalLentOut(),
            "I5: reserve claims more than the pool"
        );
    }

    /// @dev Lenders' shares never claim more than the pool's assets.
    function invariant_I6_lenderClaims() public view {
        assertLe(
            credit.convertToAssets(credit.totalShares()), credit.totalAssets(), "I6: shares claim more than assets"
        );
        assertGe(credit.lenderCash(), credit.reservedLiquidity(), "I6: reservations exceed lenders' cash");
    }

    /**
     * @dev Impairment only moves overdue principal out of totalAssets ahead of a default: the
     *      provision never exceeds what is lent out, and it equals the per-loan provisions
     *      (unpaid principal less incoming secured backing when last impaired, released by
     *      principal repaid, cleared on close or default).
     */
    function invariant_I7_impairment() public view {
        uint256 impaired = credit.totalImpaired();
        assertLe(impaired, credit.totalLentOut(), "I7: provision exceeds principal lent out");
        assertEq(impaired, handler.modelImpaired(), "I7: totalImpaired != sum of per-loan provisions");
    }

    // ───────────────────────────── ledgers ─────────────────────────────

    /**
     * @dev Credit bookkeeping matches the edges and the model: each backer's edges sum to its
     *      committed credit and stake, stake covers commitments, creditLoss / duesPaid equal the
     *      model's charges and dues, and grantedCredit follows its documented formula.
     */
    function invariant_creditLedgers() public view {
        uint256 n = cast.length;
        uint256[] memory securedOut = new uint256[](n);
        uint256[] memory unsecuredOut = new uint256[](n);
        uint256 stakes = 0;
        for (uint256 i = 0; i < n; i++) {
            DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(cast[i]);
            for (uint256 j = 0; j < edges.length; j++) {
                uint256 k = indexOf[edges[j].backer];
                securedOut[k] += edges[j].secured;
                unsecuredOut[k] += edges[j].unsecured;
            }
        }
        for (uint256 i = 0; i < n; i++) {
            address a = cast[i];
            assertEq(securedOut[i], credit.stakeCommitted(a), "ledger: secured edges != stakeCommitted");
            assertEq(unsecuredOut[i], credit.creditCommitted(a), "ledger: unsecured edges != creditCommitted");
            assertLe(credit.stakeCommitted(a), credit.stakeOf(a), "ledger: committed stake exceeds stake");
            stakes += credit.stakeOf(a);
            assertEq(credit.creditLoss(a), handler.charged(a), "ledger: creditLoss != pro-rata charges");
            assertEq(credit.duesPaid(a), handler.dues(a), "ledger: duesPaid != reserve share of interest paid");
            uint256 line = handler.issuedLine(a) + handler.dues(a);
            uint256 expected =
                credit.defaultedLoans(a) != 0 || line <= handler.charged(a) ? 0 : line - handler.charged(a);
            assertEq(credit.grantedCredit(a), expected, "ledger: grantedCredit != I0 + dues - creditLoss");
            if (credit.defaultedLoans(a) != 0) {
                (uint256 free,) = credit.getFreeCredit(a);
                assertEq(free, 0, "ledger: a defaulter can still back");
            }
        }
        assertEq(stakes, credit.totalStaked(), "ledger: stakes != totalStaked");
    }

    /**
     * @dev Pool bookkeeping matches the loan model: lent and reserved principal, loan states and
     *      balances, shares, fees, the reserve, and the pool's P&L identity
     *      lenderCash + totalLentOut + paid out + loss before reserve + forgiven
     *          = deposits + interest net of fee + reserve funded.
     */
    function invariant_poolLedgers() public view {
        uint256 lent = 0;
        uint256 reserved = 0;
        for (uint256 i = 0; i < handler.loanCount(); i++) {
            CreditHandler.LoanModel memory m = handler.loanAt(i);
            (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(m.id);
            assertEq(uint8(status), uint8(m.status), "ledger: loan status differs from the model");
            if (m.status == DecentralizedMicrocredit.LoanStatus.Requested) reserved += m.principal;
            if (m.status == DecentralizedMicrocredit.LoanStatus.Active) lent += m.principal - m.principalRepaid;
            else assertEq(m.impaired, 0, "ledger: a provision outlived its loan");
            assertLe(m.impaired, m.principal - m.principalRepaid, "ledger: provision exceeds the unpaid principal");
            if (
                m.status == DecentralizedMicrocredit.LoanStatus.Requested
                    || m.status == DecentralizedMicrocredit.LoanStatus.Active
            ) {
                assertEq(
                    credit.getCurrentOutstandingAmount(m.id),
                    m.principal + handler.accruedInterest(i) - m.repaid,
                    "ledger: outstanding differs from principal + simple interest - repaid"
                );
            }
        }
        assertEq(credit.totalLentOut(), lent, "ledger: totalLentOut != unpaid principal of active loans");
        assertEq(credit.reservedLiquidity(), reserved, "ledger: reservedLiquidity != requested principal");
        for (uint256 i = 0; i < cast.length; i++) {
            assertEq(credit.activeLoanCount(cast[i]), handler.openLoans(cast[i]), "ledger: activeLoanCount");
        }

        address lender2 = handler.lender();
        assertEq(credit.sharesOf(poolLender) + credit.sharesOf(lender2), credit.totalShares(), "ledger: shares");
        assertEq(
            credit.queuedShares(poolLender) + credit.queuedShares(lender2), credit.totalQueuedShares(), "ledger: queue"
        );
        assertLe(credit.queuedShares(lender2), credit.sharesOf(lender2), "ledger: queued more shares than held");

        assertEq(credit.protocolFees() + handler.feesClaimed(), handler.feesAccrued(), "ledger: protocol fees");
        assertEq(
            credit.firstLossReserve() + handler.reserveUsed() + handler.reserveReleased() + handler.reserveForgiven(),
            handler.reserveIn() + handler.reserveFunded(),
            "ledger: first-loss reserve"
        );
        uint256 pool = credit.lenderCash() + credit.totalLentOut();
        assertEq(
            pool + handler.paidOut() + handler.lossBeforeReserve() + handler.forgiven(),
            handler.deposited() + handler.poolInterest() + handler.reserveFunded(),
            "ledger: pool P&L identity"
        );
        uint256 junior =
            credit.totalImpaired() > credit.firstLossReserve() ? credit.totalImpaired() : credit.firstLossReserve();
        assertEq(credit.totalAssets(), pool - junior, "ledger: totalAssets != pool - max(provisions, reserve)");
    }

    /// @dev No panic or foreign revert, the contract always matched the model, exits never diluted stayers.
    function invariant_handlerHealth() public view {
        assertEq(
            handler.unexpectedReverts(),
            0,
            string.concat(
                "unexpected revert in ",
                handler.lastUnexpectedAction(),
                ": ",
                vm.toString(handler.lastUnexpectedReason())
            )
        );
        assertEq(handler.mismatches(), 0, string.concat("model mismatch: ", handler.lastMismatch()));
        assertEq(handler.sharePriceDrops(), 0, string.concat("share price fell in ", handler.lastSharePriceDrop()));
    }

    /**
     * @dev One summary line per run: what the campaign exercised and how close the loss bounds
     *      came to binding (Q and I2 in basis points of their budgets). Logged with -vv (forge
     *      shows the last run); with INVARIANT_STATS_FILE set, appended there for every run.
     */
    function afterInvariant() public {
        uint256 maxQ = 0;
        uint256 issued = 0;
        uint256 exposure = 0;
        for (uint256 i = 0; i < cast.length; i++) {
            address a = cast[i];
            (uint256 secured, uint256 unsecured) = _received(a);
            uint256 open = handler.openPrincipal(a);
            uint256 used = (open > secured + unsecured ? open - secured - unsecured : 0) + credit.creditCommitted(a)
                + handler.charged(a) + handler.residual(a);
            uint256 budget = handler.issuedLine(a) + handler.dues(a) + handler.roundingDust(a);
            if (budget != 0 && used * 10_000 / budget > maxQ) maxQ = used * 10_000 / budget;
            issued += handler.issuedLine(a) + handler.dues(a);
            uint256 lent = handler.lentPrincipal(a);
            if (lent > secured) exposure += lent - secured;
        }
        string memory line = string.concat(
            "loans=",
            vm.toString(handler.loanCount()),
            " defaults=",
            vm.toString(handler.defaults()),
            " slashing=",
            vm.toString(handler.defaultsSlashing()),
            " charging=",
            vm.toString(handler.defaultsCharging()),
            " residual=",
            vm.toString(handler.defaultsResidual()),
            " sybilDefaults=",
            vm.toString(handler.sybilDefaults()),
            " backerDefaults=",
            vm.toString(handler.backerDefaults()),
            " sybilLoans=",
            vm.toString(handler.sybilLoans())
        );
        line = string.concat(
            line,
            " sybilBacksOk=",
            vm.toString(handler.sybilBacksAccepted()),
            " sybilBacksRejected=",
            vm.toString(handler.sybilBacksRejected()),
            " impairments=",
            vm.toString(handler.impairments()),
            " disbursedAfterDefault=",
            vm.toString(handler.disbursedAfterDefault()),
            " lossBeforeReserve=",
            vm.toString(handler.lossBeforeReserve()),
            " realisedLoss=",
            vm.toString(handler.realisedLoss()),
            " maxQbps=",
            vm.toString(maxQ),
            " I2bps=",
            vm.toString(issued == 0 ? 0 : (handler.lossBeforeReserve() + exposure) * 10_000 / issued)
        );
        string[] memory names = handler.actionNames();
        for (uint256 i = 0; i < names.length; i++) {
            CreditHandler.Stat memory st = handler.stat(names[i]);
            line = string.concat(
                line,
                " ",
                names[i],
                "=",
                vm.toString(st.ok),
                "/",
                vm.toString(st.rejected),
                "/",
                vm.toString(st.skipped)
            );
        }
        console.log(line);
        string memory statsFile = vm.envOr("INVARIANT_STATS_FILE", string(""));
        if (bytes(statsFile).length != 0) vm.writeLine(statsFile, line);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _limit(address account) internal view returns (uint256 limit) {
        (limit,) = credit.getBorrowLimit(account);
    }

    function _received(address borrower) internal view returns (uint256 secured, uint256 unsecured) {
        DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(borrower);
        for (uint256 i = 0; i < edges.length; i++) {
            secured += edges[i].secured;
            unsecured += edges[i].unsecured;
        }
    }
}
