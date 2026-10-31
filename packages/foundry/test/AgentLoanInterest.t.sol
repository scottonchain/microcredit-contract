// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// New policy regressions. Test minting supplies fixtures, not economic evidence.
contract AgentLoanInterestTest is MicrocreditTestBase {
    address internal borrower = makeAddr("agentBorrower");
    uint256 internal constant PRINCIPAL = 1e6;

    function setUp() public {
        vm.warp(1_000);
        _deploy(750, 250, 100e6); // 10% APR
        _deposit(makeAddr("lender"), 1_000e6);
        vm.startPrank(owner);
        credit.setScoreOverride(borrower, SCALE);
        credit.setReserveBps(4_500);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 id) {
        vm.prank(borrower);
        id = credit.requestLoan(PRINCIPAL);
        credit.disburseLoan(id);
    }

    function _pay(uint256 id, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(credit), amount);
        credit.repayLoan(id, amount);
        vm.stopPrank();
    }

    function testOneHourSubCentInterestIsCollected() public {
        uint256 cashBefore = credit.lenderCash();
        uint256 id = _open();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 owed = credit.getCurrentOutstandingAmount(id);
        assertEq(owed - PRINCIPAL, 11); // 0.000011 USDC, representable and below one cent
        _pay(id, owed);
        (,,,, bool active) = credit.getLoan(id);
        assertFalse(active);
        assertEq(credit.totalLentOut(), 0);
        assertEq(credit.lenderCash() + credit.protocolFees(), cashBefore + 11);
        assertEq(credit.firstLossReserve(), 4);
        assertEq(credit.duesPaid(borrower), 4);
    }

    function testOneUnitShortRemainsOwedAndDoesNotCompleteLoan() public {
        uint256 id = _open();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 owed = credit.getCurrentOutstandingAmount(id);
        _pay(id, owed - 1);
        (,,,, bool active) = credit.getLoan(id);
        assertTrue(active);
        assertEq(credit.getCurrentOutstandingAmount(id), 1);
        assertEq(credit.completedLoans(borrower), 0);
        // Interest-first allocation leaves one unit of principal and its credit usage.
        assertEq(credit.totalLentOut(), 1);
        assertEq(credit.activeLoanCount(borrower), 1);
        _pay(id, 1);
        (,,,, active) = credit.getLoan(id);
        assertFalse(active);
        assertEq(credit.completedLoans(borrower), 1);
        assertEq(credit.totalLentOut(), 0);
    }

    function testPartialInterestThenPrincipalConservesPayments() public {
        uint256 id = _open();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _pay(id, 5);
        assertEq(credit.totalLentOut(), PRINCIPAL);
        assertEq(credit.getCurrentOutstandingAmount(id), PRINCIPAL + 6);
        _pay(id, PRINCIPAL + 6);
        assertEq(credit.getCurrentOutstandingAmount(id), 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function testNoFirstDayCliff() public {
        uint256 id = _open();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 elapsed = 1 days - 1; elapsed <= 1 days + 1; elapsed++) {
            vm.warp(start + elapsed);
            uint256 expected = (PRINCIPAL / 10) * elapsed / 365 days;
            assertGt(expected, 0);
            assertEq(credit.getCurrentOutstandingAmount(id), PRINCIPAL + expected);
        }
    }

    function testZeroElapsedAndSubAtomicInterestStillRoundToZero() public {
        uint256 id = _open();
        assertEq(credit.getCurrentOutstandingAmount(id), PRINCIPAL);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(credit.getCurrentOutstandingAmount(id), PRINCIPAL);
    }
}
