// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Loan terms, due dates, cancellation and default. Hermes persona 4: a $100 loan left
 *      unpaid for three years stayed active forever, nothing was written down and lenders
 *      could only withdraw the unlent part. Runs on the default guard settings.
 */
contract LoanLifecycleTest is MicrocreditTestBase {
    uint256 internal constant POOL = 1_000e6;
    uint256 internal constant STAKE = 50e6;
    uint256 internal constant LOAN = 40e6; // under the 50 USDC first-loan cap

    uint256 internal brightonPk = 0xB417;
    address internal brighton = vm.addr(brightonPk);
    address internal avery = makeAddr("avery");
    address internal blake = makeAddr("blake");
    address internal lender = makeAddr("lender");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(lender, POOL);
        vm.startPrank(oracle);
        credit.markKYCVerified(avery);
        credit.markKYCVerified(blake);
        vm.stopPrank();
        _vouchWithStake(avery, STAKE, SCALE);
    }

    function _vouchWithStake(address attester, uint256 stakeAmount, uint256 weight) internal {
        usdc.mint(attester, stakeAmount);
        vm.startPrank(attester);
        usdc.approve(address(credit), stakeAmount);
        credit.stake(stakeAmount);
        credit.recordAttestation(brighton, weight);
        vm.stopPrank();
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

    /// @dev Hermes persona 4, fully covered by the voucher's stake: lenders lose nothing.
    function testDefaultWritesDownPrincipalAndSlashesVoucher() public {
        uint256 loanId = _borrow(LOAN);
        vm.warp(vm.getBlockTimestamp() + 3 * 365 days);
        credit.markDefaulted(loanId);

        assertEq(credit.totalLentOut(), 0);
        assertEq(credit.attesterStake(avery), STAKE - LOAN);
        assertEq(credit.totalAttesterStake(), STAKE - LOAN);
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

        // The vouch is no longer locked by a loan.
        vm.prank(avery);
        credit.recordAttestation(brighton, 0);
    }

    function testUncoveredLossLowersSharePrice() public {
        vm.prank(owner);
        credit.setMinVouchStake(10e6);
        address thin = makeAddr("thin");
        vm.prank(oracle);
        credit.markKYCVerified(thin);
        _vouchWithStake(thin, 10e6, SCALE);
        vm.prank(avery);
        credit.recordAttestation(brighton, 1); // Avery's share of the loss is negligible

        uint256 loanId = _borrow(LOAN);
        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        // `thin` covers at most its 10 USDC stake; lenders absorb the rest.
        assertEq(credit.attesterStake(thin), 0);
        uint256 averySlash = STAKE - credit.attesterStake(avery);
        assertEq(credit.totalAssets(), POOL - LOAN + 10e6 + averySlash);
        assertLt(credit.lenderBalance(lender), POOL);
    }

    function testSlashingIsProportionalToVouchWeight() public {
        vm.prank(avery);
        credit.recordAttestation(brighton, 750_000);
        _vouchWithStake(blake, STAKE, 250_000);

        uint256 loanId = _borrow(LOAN);
        vm.warp(_defaultableAt(loanId));
        credit.markDefaulted(loanId);

        assertEq(credit.attesterStake(avery), STAKE - 30e6);
        assertEq(credit.attesterStake(blake), STAKE - 10e6);
    }

    function testPartialRepaymentReducesTheWriteDown() public {
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
        assertEq(credit.attesterStake(avery), STAKE - 25e6, "only unpaid principal is slashed");
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

    function testVouchersPerBorrowerAreBounded() public {
        vm.prank(owner);
        credit.setMinVouchStake(0);
        uint256 max = credit.MAX_VOUCHERS_PER_BORROWER();
        for (uint256 i = 1; i < max; i++) {
            vm.prank(makeAddr(string.concat("voucher", vm.toString(i))));
            credit.recordAttestation(brighton, SCALE);
        }
        vm.prank(makeAddr("one too many"));
        vm.expectRevert(DecentralizedMicrocredit.TooManyVouchers.selector);
        credit.recordAttestation(brighton, SCALE);
    }
}
