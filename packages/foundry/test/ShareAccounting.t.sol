// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Lender shares: repaid interest raises the share price, the protocol fee takes a cut of
///      interest only, the liquidity buffer gates lending but not exits, and stray transfers
///      cannot move the price.
contract ShareAccountingTest is MicrocreditTestBase {
    uint256 internal constant LOAN = 100e6;
    uint256 internal constant YEAR_INTEREST = 10e6; // 10% APR on LOAN for 365 days
    /// @dev Virtual shares keep a negligible slice of the pool; balances may round down by this much.
    uint256 internal constant DUST = 2;

    uint256 internal alicePk = 0xA11CE;
    address internal alice = vm.addr(alicePk);
    address internal bob = makeAddr("bob");
    address internal borrower = makeAddr("borrower");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _deploy(750, 250, 10_000e6); // 7.5% EFFR + 2.5% premium = 10% APR
        vm.prank(owner);
        credit.setScoreOverride(borrower, SCALE);
    }

    function _openLoan(uint256 amount) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
    }

    function _repay(uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(credit), amount);
        credit.repayLoan(loanId, amount);
        vm.stopPrank();
    }

    /// @dev Lends LOAN for a year, then repays LOAN + YEAR_INTEREST.
    function _borrowAndRepayAfterAYear() internal {
        uint256 loanId = _openLoan(LOAN);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repay(loanId, LOAN + YEAR_INTEREST);
        (,,,, bool isActive) = credit.getLoan(loanId);
        assertFalse(isActive);
    }

    // ───────────────────────────── interest ─────────────────────────────

    function testRepaidInterestAccruesToLender() public {
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();

        assertEq(credit.totalAssets(), 1_010e6);
        assertApproxEqAbs(credit.lenderBalance(alice), 1_010e6, DUST);
    }

    function testLenderPrincipalTracksCostBasis() public {
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();
        assertEq(credit.lenderPrincipal(alice), 1_000e6);

        vm.prank(alice);
        credit.withdrawFunds(505e6); // half the position
        assertApproxEqAbs(credit.lenderPrincipal(alice), 500e6, DUST);
        assertApproxEqAbs(credit.lenderBalance(alice), 505e6, DUST);

        vm.prank(alice);
        credit.withdrawFunds(type(uint256).max);
        assertEq(credit.lenderPrincipal(alice), 0);
    }

    function testInterestIsSharedProRata() public {
        _deposit(alice, 3_000e6);
        _deposit(bob, 1_000e6);
        _borrowAndRepayAfterAYear();

        assertApproxEqAbs(credit.lenderBalance(alice), 3_007_500_000, DUST);
        assertApproxEqAbs(credit.lenderBalance(bob), 1_002_500_000, DUST);
    }

    function testLateDepositorDoesNotCaptureEarlierInterest() public {
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();
        _deposit(bob, 1_010e6);

        assertApproxEqAbs(credit.lenderBalance(alice), 1_010e6, DUST);
        assertApproxEqAbs(credit.lenderBalance(bob), 1_010e6, DUST);
        assertApproxEqAbs(credit.sharesOf(bob), credit.sharesOf(alice), 1e6);
    }

    function testPartialRepaymentPaysInterestFirst() public {
        _deposit(alice, 1_000e6);
        uint256 loanId = _openLoan(LOAN);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        _repay(loanId, 4e6); // interest only
        assertEq(credit.totalLentOut(), LOAN);
        assertEq(credit.totalAssets(), 1_004e6);

        _repay(loanId, 56e6); // remaining 6 interest, then 50 principal
        assertEq(credit.totalLentOut(), 50e6);
        assertEq(credit.totalAssets(), 1_010e6);
        assertEq(credit.getCurrentOutstandingAmount(loanId), 50e6);
    }

    // ───────────────────────────── exits and the buffer ─────────────────────────────

    /// @dev Hermes persona 2: the 5% buffer used to trap the last lender's funds.
    function testLastLenderCanWithdrawEverything() public {
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();

        vm.prank(alice);
        credit.withdrawFunds(type(uint256).max);

        assertApproxEqAbs(usdc.balanceOf(alice), 1_010e6, DUST);
        assertEq(credit.sharesOf(alice), 0);
        assertLe(usdc.balanceOf(address(credit)), DUST);
    }

    function testWithdrawalsMayDrawOnTheBufferButLoansMayNot() public {
        _deposit(alice, 1_000e6);
        _openLoan(500e6);

        vm.prank(alice);
        credit.withdrawFunds(480e6); // leaves 20 liquid, under the 5% buffer (26 of 520)
        assertEq(usdc.balanceOf(address(credit)), 20e6);

        vm.prank(owner);
        credit.setLendingUtilizationCap(10_000); // so the 5% buffer is what binds
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientLiquidity.selector);
        credit.requestLoan(1e6);
    }

    function testQueuedSharesKeepEarningUntilPaid() public {
        _deposit(alice, 1_000e6);
        vm.startPrank(owner);
        credit.setLendingUtilizationCap(10_000);
        credit.setLiquidityLimits(0, 0);
        vm.stopPrank();
        uint256 loanId = _openLoan(1_000e6);

        address payout = makeAddr("payout");
        DecentralizedMicrocredit.RequestWithdrawal memory req = DecentralizedMicrocredit.RequestWithdrawal({
            lender: alice, amount: type(uint256).max, to: payout, nonce: credit.nonces(alice), deadline: _deadline()
        });
        credit.requestWithdrawalMeta(req, _signRequestWithdrawal(alicePk, req));
        assertEq(usdc.balanceOf(payout), 0);
        assertEq(credit.queuedWithdrawals(alice), 1_000e6);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        _repay(loanId, 1_100e6);

        assertApproxEqAbs(usdc.balanceOf(payout), 1_100e6, DUST);
        assertEq(credit.totalQueuedWithdrawals(), 0);
        assertEq(credit.sharesOf(alice), 0);
    }

    // ───────────────────────────── protocol fee ─────────────────────────────

    function testProtocolFeeTakesShareOfInterestOnly() public {
        vm.prank(owner);
        credit.setProtocolFeeBps(1_000); // 10% of interest
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();

        assertEq(credit.protocolFees(), 1e6);
        assertApproxEqAbs(credit.lenderBalance(alice), 1_009e6, DUST);
        assertEq(lens.getFundingPoolAPY(), 0, "nothing lent");

        vm.prank(owner);
        credit.claimProtocolFees(treasury, 1e6);
        assertEq(usdc.balanceOf(treasury), 1e6);
        assertEq(credit.protocolFees(), 0);
    }

    function testProtocolFeesAreNotLentOrWithdrawn() public {
        vm.prank(owner);
        credit.setProtocolFeeBps(1_000);
        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();

        vm.prank(alice);
        credit.withdrawFunds(type(uint256).max);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_009e6, DUST);
        assertGe(usdc.balanceOf(address(credit)), credit.protocolFees());

        (, uint256 available,,) = lens.getPoolInfo();
        assertLe(available, DUST);
    }

    function testProtocolFeeAdminIsOwnerOnlyAndBounded() public {
        vm.startPrank(owner);
        credit.setProtocolFeeBps(1_000);
        uint256 maxFee = credit.MAX_PROTOCOL_FEE_BPS();
        vm.expectRevert(DecentralizedMicrocredit.FeeTooHigh.selector);
        credit.setProtocolFeeBps(maxFee + 1);
        vm.stopPrank();

        _deposit(alice, 1_000e6);
        _borrowAndRepayAfterAYear();

        vm.prank(alice);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.claimProtocolFees(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.setProtocolFeeBps(0);

        vm.prank(owner);
        vm.expectRevert(DecentralizedMicrocredit.ExceedsAccruedFees.selector);
        credit.claimProtocolFees(treasury, 1e6 + 1);
    }

    function testFundingPoolApyIsNetOfFee() public {
        vm.prank(owner);
        credit.setProtocolFeeBps(1_000);
        _deposit(alice, 1_000e6);
        _openLoan(500e6); // 50% utilisation of a 10% APR pool = 5% gross
        assertEq(lens.getFundingPoolAPY(), 450);
    }

    // ───────────────────────────── impairment (run fairness) ─────────────────────────────

    /// @dev Hermes, PR #3 round 2: a default plus a run must not let the first exiter take more
    ///      than a pro-rata share. Without a provision the loan counts at full value for 30 days
    ///      after it is due, so Alice could exit at the old price and leave the loss to Bob.
    function testImpairmentStopsAnExitAheadOfAKnownLoss() public {
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);
        uint256 loanId = _openLoan(LOAN);
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);

        vm.expectRevert(DecentralizedMicrocredit.NotOverdue.selector);
        credit.impairLoan(loanId);
        vm.warp(dueAt + 1);
        credit.impairLoan(loanId); // anyone, e.g. Bob or a keeper
        assertEq(credit.totalImpaired(), LOAN);
        assertEq(credit.totalAssets(), 900e6);

        vm.prank(alice);
        credit.withdrawFunds(type(uint256).max);
        assertApproxEqAbs(usdc.balanceOf(alice), 450e6, DUST, "Alice exits with her share of the loss");

        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        assertEq(credit.totalImpaired(), 0);
        assertApproxEqAbs(credit.lenderBalance(bob), 450e6, DUST, "Bob bears the same loss, no more");
    }

    function testImpairmentIsReleasedAsTheBorrowerRepays() public {
        _deposit(alice, 1_000e6);
        uint256 loanId = _openLoan(LOAN);
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + 1);
        credit.impairLoan(loanId);

        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - LOAN;
        _repay(loanId, interest + 40e6);
        assertEq(credit.totalImpaired(), 60e6, "repaid principal leaves the provision");
        credit.impairLoan(loanId); // re-marking is idempotent
        assertEq(credit.totalImpaired(), 60e6);

        _repay(loanId, credit.getCurrentOutstandingAmount(loanId));
        assertEq(credit.totalImpaired(), 0);
        assertEq(credit.totalAssets(), 1_000e6 + interest, "the provision is fully reversed");
    }

    /// @dev Only what secured backing does not cover is provisioned: slashed stake will cover the rest.
    function testSecuredBackingIsNotProvisioned() public {
        _deposit(alice, 1_000e6);
        address dana = makeAddr("dana");
        _stake(bob, 30e6);
        vm.prank(bob);
        credit.back(dana, 30e6);
        vm.prank(owner);
        credit.setScoreOverride(dana, 20_000); // 200 USDC of her own at maxLoan 10,000
        vm.prank(dana);
        uint256 loanId = credit.requestLoan(50e6);
        credit.disburseLoan(loanId);

        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + 1);
        credit.impairLoan(loanId);
        assertEq(credit.totalImpaired(), 20e6);

        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        uint256 assets = credit.totalAssets();
        credit.markDefaulted(loanId);
        assertEq(credit.totalAssets(), assets, "the default only confirms what was provisioned");
    }

    // ───────────────────────────── lender views ─────────────────────────────

    /// @dev Hermes, PR #3 round 1: a lender could not see what was withdrawable.
    function testMaxWithdrawableIsWhatWithdrawFundsPays() public {
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);
        assertApproxEqAbs(lens.maxWithdrawable(alice), 500e6, DUST);

        _openLoan(900e6); // 100 USDC left in cash
        assertEq(lens.maxWithdrawable(alice), 100e6, "capped by the cash on hand");

        uint256 max = lens.maxWithdrawable(alice);
        vm.prank(alice);
        credit.withdrawFunds(max);
        assertEq(lens.maxWithdrawable(bob), 0);
        vm.prank(bob);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientLiquidity.selector);
        credit.withdrawFunds(1);
    }

    function testClosedLoansReadZeroOutstanding() public {
        _deposit(alice, 1_000e6);
        uint256 loanId = _openLoan(LOAN);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _repay(loanId, credit.getCurrentOutstandingAmount(loanId));
        assertEq(credit.getCurrentOutstandingAmount(loanId), 0);
        assertEq(lens.getOutstandingRoundedToCent(loanId), 0);
    }

    // ───────────────────────────── share price integrity ─────────────────────────────

    function testStrayTransferDoesNotMoveSharePrice() public {
        _deposit(alice, 1); // classic inflation setup: tiny first deposit, then a large donation
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        assertTrue(usdc.transfer(address(credit), 10_000e6));

        _deposit(bob, 1_000e6);
        assertEq(credit.totalAssets(), 1_000e6 + 1);
        assertApproxEqAbs(credit.lenderBalance(bob), 1_000e6, DUST);
    }
}
