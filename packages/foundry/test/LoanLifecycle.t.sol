// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Loan terms, due dates, cancellation and default. Hermes persona 4: a $100 loan left
 *      unpaid for three years stayed active forever, nothing was written down and lenders
 *      could only withdraw the unlent part. Brighton has no credit of his own: Avery backs him
 *      with 50 staked USDC, so every default here is charged to a known backer.
 */
contract LoanLifecycleTest is MicrocreditTestBase {
    uint256 internal constant POOL = 1_000e6;
    uint256 internal constant STAKE = 50e6;
    uint256 internal constant LOAN = 40e6; // within Avery's 50 USDC of backing

    uint256 internal brightonPk = 0xB417;
    address internal brighton = vm.addr(brightonPk);
    address internal avery = makeAddr("avery");
    address internal blake = makeAddr("blake");
    address internal carol = makeAddr("carol");
    address internal lender = makeAddr("lender");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(lender, POOL);
        _backWithStake(avery, brighton, STAKE);
    }

    function _backWithStake(address backer, address borrower, uint256 amount) internal {
        _stake(backer, amount);
        vm.prank(backer);
        credit.back(borrower, amount);
    }

    /// @dev Gives `backer` `amount` of granted credit (a score override) and backs `borrower` with it.
    function _backWithCredit(address backer, address borrower, uint256 amount) internal {
        uint256 score = (amount * SCALE) / credit.maxLoanAmount();
        vm.prank(owner);
        credit.setScoreOverride(backer, score);
        vm.prank(backer);
        credit.back(borrower, amount);
    }

    function _borrow(uint256 amount) internal returns (uint256 loanId) {
        vm.prank(brighton);
        loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
    }

    function _status(uint256 loanId) internal view returns (DecentralizedMicrocredit.LoanStatus status) {
        (status,,,,) = credit.getLoanTerms(loanId);
    }

    function _dueAt(uint256 loanId) internal view returns (uint256 dueAt) {
        (,,,, dueAt) = credit.getLoanTerms(loanId);
    }

    function _defaultableAt(uint256 loanId) internal view returns (uint256) {
        return _dueAt(loanId) + credit.LATE_PERIOD() + 1;
    }

    // ───────────────────────────── terms ─────────────────────────────

    function testInterestAccruesFromDisbursementNotRequest() public {
        vm.prank(brighton);
        uint256 loanId = credit.requestLoan(LOAN);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        assertEq(credit.getCurrentOutstandingAmount(loanId), LOAN, "no interest while undisbursed");

        credit.disburseLoan(loanId);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 yearInterest = (LOAN * 933) / 10_000;
        assertEq(credit.getCurrentOutstandingAmount(loanId), LOAN + yearInterest);
    }

    function testRequestLoanUsesDefaultTerm() public {
        uint256 loanId = _borrow(LOAN);
        (DecentralizedMicrocredit.LoanStatus status, uint256 term,, uint256 disbursedAt, uint256 dueAt) =
            credit.getLoanTerms(loanId);
        assertEq(uint256(status), uint256(DecentralizedMicrocredit.LoanStatus.Active));
        assertEq(term, credit.DEFAULT_LOAN_TERM());
        assertEq(disbursedAt, vm.getBlockTimestamp());
        assertEq(dueAt, disbursedAt + term);
    }

    function testBorrowAndDisburseUsesSignedTerm() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(28 days);
        credit.borrowAndDisburseMeta(req, _signBorrowAndDisburse(brightonPk, req));
        assertEq(_dueAt(1), vm.getBlockTimestamp() + 28 days);
    }

    function testBorrowAndDisburseRejectsTermsOutOfRange() public {
        uint256 maxTerm = credit.MAX_LOAN_TERM();
        uint256[2] memory badTerms = [uint256(0), maxTerm + 1];
        for (uint256 i = 0; i < badTerms.length; i++) {
            DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(badTerms[i]);
            bytes memory sig = _signBorrowAndDisburse(brightonPk, req);
            vm.expectRevert(DecentralizedMicrocredit.InvalidTerm.selector);
            credit.borrowAndDisburseMeta(req, sig);
        }
    }

    function _borrowRequest(uint256 term) internal view returns (DecentralizedMicrocredit.BorrowAndDisburse memory) {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: brighton,
            amount: LOAN,
            to: brighton,
            repaymentPeriod: term,
            maxAprBps: 933,
            nonce: credit.nonces(brighton),
            deadline: _deadline()
        });
    }

    // ───────────────────────────── cancellation ─────────────────────────────

    function testBorrowerCanCancelUndisbursedLoan() public {
        vm.startPrank(brighton);
        uint256 loanId = credit.requestLoan(LOAN);
        credit.cancelLoan(loanId);
        vm.stopPrank();

        assertEq(credit.reservedLiquidity(), 0);
        assertEq(credit.activeLoanCount(brighton), 0);
        assertEq(credit.completedLoans(brighton), 0, "a cancelled loan builds no history");
        assertEq(uint256(_status(loanId)), uint256(DecentralizedMicrocredit.LoanStatus.Cancelled));

        vm.expectRevert(DecentralizedMicrocredit.LoanNotRequested.selector);
        credit.disburseLoan(loanId);
    }

    function testAnyoneCanCancelAStaleReservation() public {
        vm.prank(brighton);
        uint256 loanId = credit.requestLoan(LOAN);

        vm.prank(lender);
        vm.expectRevert(DecentralizedMicrocredit.NotCancellableYet.selector);
        credit.cancelLoan(loanId);

        vm.warp(vm.getBlockTimestamp() + credit.RESERVATION_TTL() + 1);
        vm.prank(lender);
        credit.cancelLoan(loanId);
        assertEq(credit.reservedLiquidity(), 0);
    }

    function testDisbursedLoanCannotBeCancelled() public {
        uint256 loanId = _borrow(LOAN);
        vm.prank(brighton);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotRequested.selector);
        credit.cancelLoan(loanId);
    }

    // ───────────────────────────── default ─────────────────────────────

    function testLoanCannotDefaultBeforeLatePeriodEnds() public {
        uint256 loanId = _borrow(LOAN);
        vm.warp(_defaultableAt(loanId) - 1);
        vm.expectRevert(DecentralizedMicrocredit.NotYetDefaultable.selector);
        credit.markDefaulted(loanId);

        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);
        assertEq(uint256(_status(loanId)), uint256(DecentralizedMicrocredit.LoanStatus.Defaulted));
    }

    /// @dev Hermes persona 4. Avery's staked backing covers the whole loss: lenders lose nothing.
    function testDefaultSlashesSecuredBackingIntoThePool() public {
        uint256 loanId = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 3 * 365 days);
        credit.markDefaulted(loanId);

        assertEq(credit.totalLentOut(), 0);
        assertEq(credit.stakeOf(avery), STAKE - LOAN);
        assertEq(credit.totalStaked(), STAKE - LOAN);
        assertEq(credit.totalAssets(), POOL, "the slashed stake replaces the lost principal");
        assertApproxEqAbs(credit.lenderBalance(lender), POOL, 2);

        assertEq(credit.activeLoanCount(brighton), 0);
        assertEq(credit.defaultedLoans(brighton), 1);
        (uint256 limit, uint256 available) = credit.getBorrowLimit(brighton);
        assertEq(limit, 0);
        assertEq(available, 0);
        vm.prank(brighton);
        vm.expectRevert(DecentralizedMicrocredit.BorrowerInDefault.selector);
        credit.requestLoan(1e6);

        // Brighton has no open loans left, so the rest of Avery's backing is released.
        assertEq(credit.stakeCommitted(avery), 0);
        vm.prank(avery);
        credit.unstake(STAKE - LOAN);
        assertEq(usdc.balanceOf(avery), STAKE - LOAN);
    }

    function testUnsecuredBackingBurnsTheBackersCredit() public {
        address dana = makeAddr("dana");
        _backWithCredit(carol, dana, 30e6);
        vm.prank(dana);
        uint256 loanId = credit.requestLoan(30e6);
        credit.disburseLoan(loanId);

        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        assertEq(credit.creditLoss(carol), 30e6);
        assertEq(credit.grantedCredit(carol), 0, "Carol cannot back the same loss twice");
        assertEq(credit.creditCommitted(carol), 0);
        assertEq(credit.totalAssets(), POOL - 30e6, "unsecured backing recovers nothing: lenders absorb it");
    }

    function testStakeIsChargedBeforeCredit() public {
        _backWithCredit(carol, brighton, 30e6); // Brighton: 50 secured (Avery) + 30 unsecured (Carol)
        uint256 loanId = _borrow(60e6);
        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        assertEq(credit.stakeOf(avery), 0, "all 50 of Avery's stake first");
        assertEq(credit.creditLoss(carol), 10e6, "then 10 of Carol's credit");
        assertEq(credit.totalAssets(), POOL - 10e6);
    }

    function testChargesArePaidProRata() public {
        vm.prank(avery);
        credit.back(brighton, 30e6);
        _backWithStake(blake, brighton, 10e6);

        uint256 loanId = _borrow(LOAN);
        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        assertEq(credit.stakeOf(avery), STAKE - 30e6);
        assertEq(credit.stakeOf(blake), 0);
    }

    // ───────────────────────────── first-loss reserve ─────────────────────────────

    function _repayAll(uint256 loanId) internal {
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(brighton, owed);
        vm.startPrank(brighton);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
    }

    function testReserveTakesItsShareOfInterest() public {
        vm.startPrank(owner);
        credit.setProtocolFeeBps(1_000);
        credit.setReserveBps(2_000);
        vm.stopPrank();

        uint256 loanId = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - LOAN;
        _repayAll(loanId);

        uint256 fee = (interest * 1_000) / 10_000;
        uint256 reserve = (interest * 2_000) / 10_000;
        assertEq(credit.protocolFees(), fee);
        assertEq(credit.firstLossReserve(), reserve);
        assertEq(credit.totalAssets(), POOL + interest - fee - reserve);
        assertEq(credit.duesPaid(brighton), interest - fee, "the reserve share protects lenders, so it counts as dues");
    }

    /// @dev The reserve pays what stake does not recover, before the share price moves.
    function testReservePaysUncoveredLossBeforeLenders() public {
        vm.prank(owner);
        credit.setReserveBps(5_000);
        uint256 first = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repayAll(first);
        uint256 reserve = credit.firstLossReserve();
        uint256 assets = credit.totalAssets();
        assertGt(reserve, 0);

        // An unsecured loss larger than the reserve: the reserve is used up, lenders take the rest.
        address dana = makeAddr("dana");
        _backWithCredit(carol, dana, 30e6);
        vm.prank(dana);
        uint256 loanId = credit.requestLoan(30e6);
        credit.disburseLoan(loanId);
        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        assertEq(credit.firstLossReserve(), 0);
        assertEq(credit.totalAssets(), assets - (30e6 - reserve));
    }

    function testReserveSettersAreBoundedAndOwnerOnly() public {
        uint256 max = credit.MAX_RESERVE_BPS();
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.setReserveBps(1);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.releaseReserve(0);

        vm.startPrank(owner);
        vm.expectRevert(DecentralizedMicrocredit.ReserveTooHigh.selector);
        credit.setReserveBps(max + 1);
        credit.setReserveBps(max);
        vm.expectRevert(DecentralizedMicrocredit.ExceedsReserve.selector);
        credit.releaseReserve(1);
        vm.stopPrank();
    }

    function testReleasedReserveGoesToLenders() public {
        vm.prank(owner);
        credit.setReserveBps(5_000);
        uint256 loanId = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repayAll(loanId);
        uint256 reserve = credit.firstLossReserve();
        uint256 assets = credit.totalAssets();

        vm.prank(owner);
        credit.releaseReserve(reserve);
        assertEq(credit.firstLossReserve(), 0);
        assertEq(credit.totalAssets(), assets + reserve);
    }

    function testPartialRepaymentReducesTheCharge() public {
        uint256 loanId = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - LOAN;
        usdc.mint(brighton, interest + 15e6);
        vm.startPrank(brighton);
        usdc.approve(address(credit), interest + 15e6);
        credit.repayLoan(loanId, interest + 15e6); // all interest so far, then 15 principal
        vm.stopPrank();

        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);
        assertEq(credit.stakeOf(avery), STAKE - 25e6, "only unpaid principal is charged");
    }

    function testDefaultKeepsBackingForTheBorrowersOtherOpenLoans() public {
        uint256 first = _borrow(20e6);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        uint256 second = _borrow(20e6);

        vm.warp(_defaultableAt(first));
        credit.markDefaulted(first);
        assertEq(credit.stakeOf(avery), 30e6);
        assertEq(credit.stakeCommitted(avery), 30e6, "still backing the second loan");
        vm.prank(avery);
        vm.expectRevert(DecentralizedMicrocredit.StakeCommitted.selector);
        credit.unstake(1);

        vm.warp(_defaultableAt(second));
        credit.markDefaulted(second);
        assertEq(credit.stakeOf(avery), 10e6);
        assertEq(credit.stakeCommitted(avery), 0, "released with no open loans left");
    }

    function testClosedLoansCannotDefaultOrBeRepaid() public {
        uint256 loanId = _borrow(LOAN);
        usdc.mint(brighton, LOAN);
        vm.startPrank(brighton);
        usdc.approve(address(credit), LOAN);
        credit.repayLoan(loanId, LOAN);
        vm.stopPrank();
        assertEq(uint256(_status(loanId)), uint256(DecentralizedMicrocredit.LoanStatus.Repaid));

        vm.warp(_defaultableAt(loanId));
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.markDefaulted(loanId);

        uint256 second = _borrow(LOAN);
        vm.warp(_defaultableAt(second));
        credit.markDefaulted(second);
        vm.prank(brighton);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoan(second, 1);
    }

    function testBackersPerBorrowerAreBounded() public {
        uint256 max = credit.MAX_BACKERS_PER_BORROWER();
        for (uint256 i = 1; i < max; i++) {
            _backWithStake(makeAddr(string.concat("backer", vm.toString(i))), brighton, 1e6);
        }
        address oneTooMany = makeAddr("one too many");
        _stake(oneTooMany, 1e6);
        vm.prank(oneTooMany);
        vm.expectRevert(DecentralizedMicrocredit.TooManyBackers.selector);
        credit.back(brighton, 1e6);
    }
}
