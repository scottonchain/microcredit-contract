// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { IScoreProvider } from "../contracts/interfaces/IScoreProvider.sol";
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
        vm.expectRevert(DecentralizedMicrocredit.InsufficientLiquidity.selector);
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
        vm.expectRevert(DecentralizedMicrocredit.LoanNotRequested.selector);
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
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoan(loanId, PRINCIPAL);
        vm.stopPrank();
    }

    function testOnlyBorrowerCanRepayDirectly() public {
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotBorrower.selector);
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

    function testPreviewLoanTermsUnderOneWeekIsOnePayment() public view {
        (, uint256 payment) = credit.previewLoanTerms(borrower, 1_000e6, 3 days);
        uint256 interest = (1_000e6 * RATE * 3 days) / (10_000 * 365 days);
        assertEq(payment, 1_000e6 + interest);
    }

    function testPreviewLoanTermsUsesPlatformRate() public view {
        (uint256 rate, uint256 weekly) = credit.previewLoanTerms(borrower, 1_000e6, 28 days);
        assertEq(rate, RATE);
        uint256 interest = (1_000e6 * RATE * 28 days) / (10_000 * 365 days);
        assertEq(weekly, (1_000e6 + interest) / 4);
    }

    // ───────────────────────────── scores & identity ─────────────────────────────

    function testScoreOverrideTakesPrecedenceOverProvider() public {
        _publishScore(borrower, 300_000);
        assertEq(credit.getCreditScore(borrower), SCALE);

        vm.prank(owner);
        credit.setScoreOverride(borrower, 0);
        assertEq(credit.getCreditScore(borrower), 300_000, "falls back to the published score");

        vm.warp(vm.getBlockTimestamp() + MAX_SCORE_AGE + 1);
        assertEq(credit.getCreditScore(borrower), 0, "stale published scores back nothing");

        vm.prank(owner);
        credit.setScoreProvider(IScoreProvider(address(0)));
        assertEq(credit.getCreditScore(borrower), 0, "no provider: overrides only");

        vm.prank(owner);
        vm.expectRevert(DecentralizedMicrocredit.ScoreTooHigh.selector);
        credit.setScoreOverride(borrower, SCALE + 1);
    }

    function testRequestLoanRequiresCredit() public {
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NoCredit.selector);
        credit.requestLoan(1e6);
    }

    function testDisplayNames() public {
        vm.expectEmit(address(credit));
        emit DisplayNameSet(borrower, "Brighton");
        vm.prank(borrower);
        credit.setDisplayName("Brighton");
        assertEq(credit.displayNames(borrower), "Brighton");

        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NameTooLong.selector);
        credit.setDisplayName("this display name is far too long!");
    }

    function testKycVerificationIsOracleOnly() public {
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotOracle.selector);
        credit.markKYCVerified(borrower);

        vm.prank(oracle);
        credit.markKYCVerified(borrower);
        assertTrue(credit.isKYCVerified(borrower));

        vm.prank(oracle);
        vm.expectRevert(DecentralizedMicrocredit.AlreadyVerified.selector);
        credit.markKYCVerified(borrower);
    }

    // ───────────────────────────── admin access ─────────────────────────────

    event ParameterUpdated(bytes32 indexed parameter, uint256 value);
    event ScoreOverrideSet(address indexed user, uint256 score);
    event OracleUpdated(address oracle);

    function testAdminChangesEmitEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(address(credit));
        emit ParameterUpdated("effrRate", 450);
        credit.setEffrRate(450);
        vm.expectEmit(address(credit));
        emit ParameterUpdated("maxLoanAmount", 5e6);
        credit.setMaxLoanAmount(5e6);
        vm.expectEmit(address(credit));
        emit ScoreOverrideSet(stranger, 1);
        credit.setScoreOverride(stranger, 1);
        vm.expectEmit(address(credit));
        emit OracleUpdated(stranger);
        credit.setOracle(stranger);
        vm.stopPrank();
    }

    function testAdminSettersAreOwnerOnly() public {
        bytes[] memory calls = new bytes[](19);
        calls[0] = abi.encodeCall(credit.setOracle, (stranger));
        calls[1] = abi.encodeCall(credit.setScoreProvider, (IScoreProvider(stranger)));
        calls[2] = abi.encodeCall(credit.setEffrRate, (1));
        calls[3] = abi.encodeCall(credit.setRiskPremium, (1));
        calls[4] = abi.encodeCall(credit.setMaxLoanAmount, (1));
        calls[5] = abi.encodeCall(credit.setLendingUtilizationCap, (1));
        calls[6] = abi.encodeCall(credit.setLiquidityLimits, (1, 1));
        calls[7] = abi.encodeCall(credit.setRelayerWhitelistEnabled, (true));
        calls[8] = abi.encodeCall(credit.setRelayerWhitelisted, (stranger, true));
        calls[9] = abi.encodeCall(credit.setScoreOverride, (stranger, 1));
        calls[10] = abi.encodeCall(credit.setProtocolFeeBps, (1));
        calls[11] = abi.encodeCall(credit.claimProtocolFees, (stranger, 0));
        calls[12] = abi.encodeCall(credit.setReserveBps, (1));
        calls[13] = abi.encodeCall(credit.releaseReserve, (0));
        calls[14] = abi.encodeCall(credit.transferOwnership, (stranger));
        calls[15] = abi.encodeCall(credit.acceptOwnership, ());
        calls[16] = abi.encodeCall(credit.setGuardian, (stranger));
        calls[17] = abi.encodeCall(credit.pause, ());
        calls[18] = abi.encodeCall(credit.unpause, ());

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(credit).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(DecentralizedMicrocredit.NotOwner.selector));
        }
    }

    /// @dev The guardian stops new lending at once (an owner behind a timelock cannot); repayments
    ///      and exits continue, and only the owner resumes lending.
    function testGuardianPausesNewLendingOnly() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        credit.setGuardian(guardian);
        uint256 loanId = _openLoan(PRINCIPAL);
        vm.prank(borrower);
        uint256 reserved = credit.requestLoan(1e6);

        vm.prank(guardian);
        credit.pause();
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.LendingPaused.selector);
        credit.requestLoan(1e6);
        vm.expectRevert(DecentralizedMicrocredit.LendingPaused.selector);
        credit.disburseLoan(reserved);

        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, owed);
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.unpause();
        vm.prank(owner);
        credit.unpause();
        credit.disburseLoan(reserved);
    }

    /// @dev Production hands the protocol to a timelock or multisig; the handover takes two steps.
    function testOwnershipTransferNeedsAcceptance() public {
        address timelock = makeAddr("timelock");
        vm.prank(owner);
        credit.transferOwnership(timelock);
        assertEq(credit.owner(), owner, "pending until accepted");
        assertEq(credit.pendingOwner(), timelock);

        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.acceptOwnership();

        vm.prank(timelock);
        credit.acceptOwnership();
        assertEq(credit.owner(), timelock);
        assertEq(credit.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.setRiskPremium(1);
    }

    function testLimitSettersValidateBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(DecentralizedMicrocredit.AboveOneHundredPercent.selector);
        credit.setLendingUtilizationCap(10_001);
        vm.expectRevert(DecentralizedMicrocredit.AboveOneHundredPercent.selector);
        credit.setLiquidityLimits(10_001, 0);
        vm.expectRevert(DecentralizedMicrocredit.ZeroAddress.selector);
        credit.setOracle(address(0));
        vm.stopPrank();
    }
}
