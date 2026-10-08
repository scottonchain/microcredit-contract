// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Core lending: loan requests and limits, pool liquidity, utilisation and withdrawals.
contract DecentralizedMicrocreditTest is MicrocreditTestBase {
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    function setUp() public {
        _deploy(750, 250, 10_000e6); // 7.5% EFFR + 2.5% premium, $10k max loan at a 100% score
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(borrower, 1_000e6);
        usdc.mint(lender, 1_000_000e6);

        vm.startPrank(owner);
        usdc.approve(address(credit), type(uint256).max);
        credit.depositFunds(500_000e6);
        vm.stopPrank();

        // The oracle grants the borrower a 90% score: 9,000 USDC of credit at a 10,000 maxLoanAmount.
        _publishScore(borrower, 900_000);
    }

    function _ownerDeposit(uint256 amount) internal {
        vm.prank(owner);
        credit.depositFunds(amount);
    }

    function testRequestLoan() public {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(1_000e6);
        assertEq(loanId, 1);

        (uint256 principal,, address loanBorrower,, bool isActive) = credit.getLoan(loanId);
        assertEq(principal, 1_000e6);
        assertEq(loanBorrower, borrower);
        assertTrue(isActive);
        assertEq(credit.reservedLiquidity(), 1_000e6);
    }

    function testRepayLoan() public {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(1_000e6);
        credit.disburseLoan(loanId);

        vm.startPrank(borrower);
        usdc.approve(address(credit), 1_100e6);
        credit.repayLoan(loanId, 1_100e6);
        vm.stopPrank();

        (,,,, bool isActive) = credit.getLoan(loanId);
        assertFalse(isActive);
    }

    function testInterestRateIsPlatformRate() public {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(1_000e6);
        (,,, uint256 interestRate,) = credit.getLoan(loanId);
        assertEq(interestRate, credit.effrRate() + credit.riskPremium());
    }

    function testMaxLoanAmountEnforced() public {
        uint256 allowed = (credit.getCreditScore(borrower) * 10_000e6) / SCALE;

        vm.prank(borrower);
        credit.requestLoan(allowed);

        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.BorrowLimitExceeded.selector);
        credit.requestLoan(1e6);
    }

    function testDepositFunds() public {
        assertEq(usdc.balanceOf(address(credit)), 500_000e6);
        _ownerDeposit(100_000e6);
        assertEq(usdc.balanceOf(address(credit)), 600_000e6);
        assertEq(credit.totalAssets(), 600_000e6);
    }

    function testReservedLiquidityEnforced() public {
        _ownerDeposit(500_000e6); // 1,000,000 total
        vm.prank(owner);
        credit.setMaxLoanAmount(1_000_000e6);

        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(800_000e6);
        assertEq(credit.reservedLiquidity(), 800_000e6);

        // Only 200k is unreserved.
        vm.prank(borrower);
        vm.expectRevert();
        credit.requestLoan(300_000e6);

        vm.prank(owner);
        vm.expectRevert();
        credit.withdrawFunds(250_000e6);

        credit.disburseLoan(loanId);
        assertEq(credit.reservedLiquidity(), 0);
        assertEq(credit.totalLentOut(), 800_000e6);
    }

    function testSetEffrRateUpdatesRate() public {
        vm.prank(owner);
        credit.setEffrRate(900);
        assertEq(credit.effrRate(), 900);

        (uint256 rate,) = lens.previewLoanTerms(borrower, 1_000e6, 365 days);
        assertEq(rate, 900 + credit.riskPremium());
    }

    function testLenderWithdrawsSuccessfully() public {
        uint256 before = usdc.balanceOf(lender);
        vm.startPrank(lender);
        usdc.approve(address(credit), 200_000e6);
        credit.depositFunds(200_000e6);
        credit.withdrawFunds(50_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(lender), before - 150_000e6);
        assertEq(credit.lenderBalance(lender), 150_000e6);
    }

    function testLenderCannotWithdrawMoreThanAvailablePoolFunds() public {
        // Fresh pool funded by a single lender.
        vm.prank(owner);
        DecentralizedMicrocredit pool =
            new DecentralizedMicrocredit(750, 250, type(uint256).max, address(usdc), oracle, address(0));
        vm.startPrank(owner);
        pool.setScoreOverride(borrower, SCALE);
        vm.stopPrank();
        vm.startPrank(lender);
        usdc.approve(address(pool), 100_000e6);
        pool.depositFunds(100_000e6);
        vm.stopPrank();

        uint256 utilisationCap = (100_000e6 * pool.lendingUtilizationCap()) / pool.BASIS_POINTS();
        vm.prank(borrower);
        uint256 loanId = pool.requestLoan(utilisationCap);
        pool.disburseLoan(loanId);

        uint256 available = usdc.balanceOf(address(pool));
        assertEq(available, 100_000e6 - utilisationCap);

        vm.prank(lender);
        vm.expectRevert();
        pool.withdrawFunds(available + 1e6);
    }

    function testLenderPartialWithdrawals() public {
        vm.startPrank(lender);
        usdc.approve(address(credit), 100_000e6);
        credit.depositFunds(100_000e6);
        credit.withdrawFunds(40_000e6);
        credit.withdrawFunds(30_000e6);

        vm.expectRevert(DecentralizedMicrocredit.InsufficientBalance.selector);
        credit.withdrawFunds(40_000e6); // only 30k left
        vm.stopPrank();
    }

    function testUtilizationCapEnforced() public {
        _ownerDeposit(500_000e6); // 90% cap = 900k
        vm.prank(owner);
        credit.setMaxLoanAmount(type(uint256).max);

        vm.startPrank(borrower);
        credit.requestLoan(850_000e6);
        credit.requestLoan(50_000e6); // exactly at the cap

        vm.expectRevert(DecentralizedMicrocredit.UtilisationCapExceeded.selector);
        credit.requestLoan(1e6);
        vm.stopPrank();

        assertEq(credit.reservedLiquidity(), 900_000e6);
    }

    function testUtilizationCapLeavesUnreservedFundsWithdrawable() public {
        _ownerDeposit(500_000e6);
        vm.prank(owner);
        credit.setMaxLoanAmount(type(uint256).max);

        vm.prank(borrower);
        credit.requestLoan(900_000e6);

        // 100k stays unreserved, and all of it can leave: the 5% buffer only limits new loans.
        vm.startPrank(owner);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientLiquidity.selector);
        credit.withdrawFunds(100_000e6 + 1);
        credit.withdrawFunds(100_000e6);
        vm.stopPrank();
    }

    function testRepayReducesTotalLentOut() public {
        _ownerDeposit(500_000e6);
        vm.prank(owner);
        credit.setMaxLoanAmount(type(uint256).max);

        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(100_000e6);
        credit.disburseLoan(loanId);
        assertEq(credit.totalLentOut(), 100_000e6);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 payoff = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, payoff);
        vm.startPrank(borrower);
        usdc.approve(address(credit), payoff);
        credit.repayLoan(loanId, payoff);
        vm.stopPrank();

        assertEq(credit.totalLentOut(), 0);
    }
}
