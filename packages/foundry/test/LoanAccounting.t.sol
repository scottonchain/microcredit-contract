// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Interest accrual, repayment accounting, admin permissions and view helpers.
contract LoanAccountingTest is MicrocreditTestBase {
    uint256 internal constant RATE = 1_000; // 7.5% EFFR + 2.5% premium = 10% APR
    uint256 internal constant PRINCIPAL = 1_000e6;

    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal stranger = makeAddr("stranger");

    event DisplayNameSet(address indexed user, string name);

    function setUp() public {
        _deploy(750, 250, 10_000e6);
        _deposit(makeAddr("poolLender"), 100_000e6);
        vm.prank(owner);
        credit.setScoreOverride(borrower, SCALE);
    }

    function _openLoan(uint256 amount) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
    }

    // ───────────────────────────── interest ─────────────────────────────

    function testNoInterestDuringGracePeriod() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        assertEq(credit.getCurrentOutstandingAmount(loanId), PRINCIPAL);
    }

    function testSimpleInterestAccruesFromOrigination() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(credit.getCurrentOutstandingAmount(loanId), PRINCIPAL + (PRINCIPAL * RATE) / 10_000);

        (, uint256 outstanding,,,) = credit.getLoan(loanId);
        assertEq(outstanding, PRINCIPAL + (PRINCIPAL * RATE) / 10_000);
    }

    function testOutstandingRoundedToNearestCent() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 exact = credit.getCurrentOutstandingAmount(loanId);
        uint256 rounded = credit.getOutstandingRoundedToCent(loanId);
        assertEq(rounded % 10_000, 0);
        assertLe(rounded > exact ? rounded - exact : exact - rounded, 5_000);
    }

    function testRepayLoanInFullClosesLoan() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, owed - PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();

        (, uint256 outstanding,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(outstanding, 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function testRepayWithPermitRepaysAllWithinGracePeriod() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, PRINCIPAL, _deadline());
        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 0, p.value, p.deadline, p.v, p.r, p.s);

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 0);
    }

    function testPartialRepaymentReducesOutstanding() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);

        vm.startPrank(borrower);
        usdc.approve(address(credit), 400e6);
        credit.repayLoan(loanId, 400e6);
        vm.stopPrank();

        (, uint256 outstanding,,, bool active) = credit.getLoan(loanId);
        assertTrue(active);
        assertEq(outstanding, owed - 400e6);
        assertEq(credit.getCurrentOutstandingAmount(loanId), owed - 400e6);
    }

    function testPartialRepaymentsThenPayoffCloseLoan() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, owed - PRINCIPAL);

        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, 250e6);
        credit.repayLoan(loanId, 250e6);
        credit.repayLoan(loanId, credit.getCurrentOutstandingAmount(loanId));
        vm.stopPrank();

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 0, "paid exactly what was owed");
        assertEq(credit.totalLentOut(), 0);
    }

    function testRepayLoanNeverPullsMoreThanOwed() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(credit), PRINCIPAL + 100e6);
        credit.repayLoan(loanId, PRINCIPAL + 100e6);
        vm.stopPrank();

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 100e6, "overpayment stays with the borrower");
    }

    function testRepayWithPermitPartialReducesOutstanding() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);

        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, 300e6, _deadline());
        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 300e6, p.value, p.deadline, p.v, p.r, p.s);

        assertEq(credit.getCurrentOutstandingAmount(loanId), owed - 300e6);
        assertEq(usdc.balanceOf(borrower), PRINCIPAL - 300e6);
    }

    /// The borrower UI pays `getOutstandingRoundedToCent` with amount = 0. When that rounds
    /// down, the sub-cent remainder must be forgiven rather than leaving the loan open.
    function testRepayWithPermitCentRoundedPayoffClosesLoan() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        uint256 owed;
        for (uint256 day = 2; day < 60; day++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            owed = credit.getCurrentOutstandingAmount(loanId);
            if (owed % 10_000 != 0 && owed % 10_000 < 5_000) break;
        }
        uint256 rounded = credit.getOutstandingRoundedToCent(loanId);
        assertLt(rounded, owed, "fixture should round down");
        usdc.mint(borrower, rounded - PRINCIPAL);

        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, rounded, _deadline());
        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 0, p.value, p.deadline, p.v, p.r, p.s);

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function testRequestLoanEnforcesLiquidityBuffer() public {
        vm.startPrank(owner);
        credit.setMaxLoanAmount(100_000e6);
        credit.setLendingUtilizationCap(10_000); // only the 5% buffer should bind
        vm.stopPrank();

        vm.prank(borrower);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.requestLoan(96_000e6);

        vm.prank(borrower);
        credit.requestLoan(95_000e6);
    }

    function testLoanCannotBeDisbursedTwice() public {
        address other = makeAddr("other");
        vm.prank(owner);
        credit.setScoreOverride(other, SCALE);
        vm.prank(other);
        credit.requestLoan(PRINCIPAL); // keeps reservedLiquidity above one loan's principal

        uint256 loanId = _openLoan(PRINCIPAL);
        vm.expectRevert("Already disbursed");
        credit.disburseLoan(loanId);
        assertEq(usdc.balanceOf(borrower), PRINCIPAL);
        assertEq(credit.reservedLiquidity(), PRINCIPAL);
    }

    function testUndisbursedLoanCannotBeRepaid() public {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(PRINCIPAL);
        usdc.mint(borrower, PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(credit), PRINCIPAL);
        vm.expectRevert("Not disbursed");
        credit.repayLoan(loanId, PRINCIPAL);
        vm.stopPrank();
    }

    function testOnlyBorrowerCanRepayDirectly() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.prank(stranger);
        vm.expectRevert("Borrower only");
        credit.repayLoan(loanId, 1);
    }

    // ───────────────────────────── pool views ─────────────────────────────

    function testFundingPoolApyScalesWithUtilisation() public {
        assertEq(credit.getFundingPoolAPY(), 0, "nothing lent yet");
        vm.prank(owner);
        credit.setMaxLoanAmount(50_000e6);
        _openLoan(50_000e6); // 50% of the pool
        assertEq(credit.getFundingPoolAPY(), RATE / 2);
    }

    function testPoolInfoExcludesReservedFunds() public {
        vm.prank(borrower);
        credit.requestLoan(PRINCIPAL); // reserved, not yet disbursed
        (uint256 deposits, uint256 available, uint256 reserved, uint256 lenders) = credit.getPoolInfo();
        assertEq(deposits, 100_000e6);
        assertEq(reserved, PRINCIPAL);
        assertEq(available, 100_000e6 - PRINCIPAL);
        assertEq(lenders, 1);
    }

    function testPreviewLoanTermsUsesPlatformRate() public view {
        (uint256 rate, uint256 weekly) = credit.previewLoanTerms(borrower, 1_000e6, 28 days);
        assertEq(rate, RATE);
        uint256 interest = (1_000e6 * RATE * 28 days) / (10_000 * 365 days);
        assertEq(weekly, (1_000e6 + interest) / 4);
    }

    // ───────────────────────────── scores & identity ─────────────────────────────

    function testScoreOverrideTakesPrecedenceOverPageRank() public {
        assertEq(credit.getCreditScore(borrower), SCALE);

        vm.prank(owner);
        credit.setScoreOverride(borrower, 0);
        assertEq(credit.getCreditScore(borrower), 0, "falls back to PageRank (no attestations)");

        vm.prank(owner);
        vm.expectRevert("Score exceeds SCALE");
        credit.setScoreOverride(borrower, SCALE + 1);
    }

    function testRequestLoanRequiresScore() public {
        vm.prank(stranger);
        vm.expectRevert("Score > 0");
        credit.requestLoan(1e6);
    }

    function testDisplayNames() public {
        vm.expectEmit(address(credit));
        emit DisplayNameSet(borrower, "Brighton");
        vm.prank(borrower);
        credit.setDisplayName("Brighton");
        assertEq(credit.displayNames(borrower), "Brighton");

        vm.prank(borrower);
        vm.expectRevert("Name too long");
        credit.setDisplayName("this display name is far too long!");
    }

    function testKycVerificationIsOracleOnly() public {
        vm.prank(stranger);
        vm.expectRevert("Oracle only");
        credit.markKYCVerified(borrower);

        vm.prank(oracle);
        credit.markKYCVerified(borrower);
        assertTrue(credit.isKYCVerified(borrower));

        vm.prank(oracle);
        vm.expectRevert("Already verified");
        credit.markKYCVerified(borrower);
    }

    // ───────────────────────────── admin access ─────────────────────────────

    function testAdminSettersAreOwnerOnly() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeCall(credit.setOracle, (stranger));
        calls[1] = abi.encodeCall(credit.setKycBonus, (1));
        calls[2] = abi.encodeCall(credit.setBasePersonalization, (1));
        calls[3] = abi.encodeCall(credit.setPersonalizationCap, (1));
        calls[4] = abi.encodeCall(credit.setEffrRate, (1));
        calls[5] = abi.encodeCall(credit.setRiskPremium, (1));
        calls[6] = abi.encodeCall(credit.setMaxLoanAmount, (1));
        calls[7] = abi.encodeCall(credit.setLendingUtilizationCap, (1));
        calls[8] = abi.encodeCall(credit.setLiquidityLimits, (1, 1));
        calls[9] = abi.encodeCall(credit.setRelayerWhitelistEnabled, (true));
        calls[10] = abi.encodeCall(credit.setRelayerWhitelisted, (stranger, true));
        calls[11] = abi.encodeCall(credit.setScoreOverride, (stranger, 1));

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(credit).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSignature("Error(string)", "Owner only"));
        }
    }

    function testLimitSettersValidateBounds() public {
        vm.startPrank(owner);
        vm.expectRevert("Cap cannot exceed 100%");
        credit.setLendingUtilizationCap(10_001);
        vm.expectRevert("Buffer > 100%");
        credit.setLiquidityLimits(10_001, 0);
        vm.expectRevert("Invalid oracle");
        credit.setOracle(address(0));
        vm.stopPrank();
    }
}
