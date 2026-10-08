// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev The manager gate: a borrower names the only caller that may originate its loans, and cannot
 *      change that choice while it owes principal or holds backing. This is what lets an adapter
 *      or router bind every origination path (requestLoan, requestLoanMeta, borrowAndDisburseMeta)
 *      to its own rules: third-party repayment frees pool capacity at any time, so a rule that only
 *      lives outside the pool can be bypassed by a direct call.
 */
contract ManagerGateTest is MicrocreditTestBase {
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal manager = makeAddr("manager");
    address internal sponsor = makeAddr("sponsor");
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(makeAddr("poolLender"), 1_000e6);
    }

    // ───────────── helpers ─────────────

    function _managedAndBacked(uint256 backing) internal {
        vm.prank(borrower);
        credit.setManager(manager);
        _stake(sponsor, backing);
        vm.prank(sponsor);
        credit.back(borrower, backing);
    }

    function _req(uint256 amount) internal view returns (DecentralizedMicrocredit.BorrowAndDisburse memory) {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: amount,
            to: vendor,
            repaymentPeriod: 7 days,
            maxAprBps: 933,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
    }

    function _viaManager(uint256 amount) internal returns (uint256 loanId) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(amount);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(manager);
        credit.borrowAndDisburseMeta(req, sig);
        uint256[] memory ids = credit.getBorrowerLoanIds(borrower);
        loanId = ids[ids.length - 1];
    }

    function _repayAll(address payer, uint256 loanId) internal {
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(payer, owed);
        vm.startPrank(payer);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
    }

    // ───────────── the choice ─────────────

    function testNoManagerByDefaultAndOneCanBeSetOnAFreshAccount() public {
        assertEq(credit.managerOf(borrower), address(0));
        vm.prank(borrower);
        credit.setManager(manager);
        assertEq(credit.managerOf(borrower), manager);
    }

    function testManagerCannotBeChosenOnceBackingExists() public {
        _stake(sponsor, 5e6);
        vm.prank(sponsor);
        credit.back(borrower, 5e6);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(manager);
    }

    function testManagerCannotChangeWhileBackingOrPrincipalIsLive() public {
        _managedAndBacked(5e6);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0)); // backing is live

        uint256 loanId = _viaManager(2e6);
        // cut the backing to what is owed is not possible; the loan is open either way
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0));

        _repayAll(stranger, loanId);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0)); // loan closed, backing still live

        vm.prank(sponsor);
        credit.back(borrower, 0);
        vm.prank(borrower);
        credit.setManager(address(0)); // clean again: free to leave
        assertEq(credit.managerOf(borrower), address(0));
    }

    // ───────────── the gate on every origination path ─────────────

    function testManagedBorrowerCannotRequestDirectly() public {
        _managedAndBacked(5e6);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(1e6);
    }

    function testManagedBorrowerCannotUseAnotherRelayerForRequestMeta() public {
        _managedAndBacked(5e6);
        DecentralizedMicrocredit.LoanRequest memory req = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower, amount: 1e6, nonce: credit.nonces(borrower), deadline: _deadline()
        });
        bytes memory sig = _signLoanRequest(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoanMeta(req, sig);
    }

    function testManagedBorrowerCannotUseAnotherRelayerForBorrowAndDisburse() public {
        _managedAndBacked(5e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        // and a signed advance is not the manager's until the manager submits it: a stranger still cannot
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
    }

    function testManagerOriginatesAndPaysTheVendor() public {
        _managedAndBacked(5e6);
        uint256 loanId = _viaManager(2e6);
        assertEq(usdc.balanceOf(vendor), 2e6, "principal went to the signed vendor");
        (uint256 principal,, address debtor,,) = credit.getLoan(loanId);
        assertEq(principal, 2e6);
        assertEq(debtor, borrower);
    }

    function testDirectRepaymentFreesCapacityOnlyForTheManager() public {
        _managedAndBacked(5e6);
        uint256 loanId = _viaManager(5e6);
        _repayAll(stranger, loanId); // anyone may repay: the pool's capacity for this borrower is free again

        // the bypass a router outside the pool could not stop: every other path stays closed
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(1e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);

        // the manager can reopen it, under its own rules
        _viaManager(1e6);
        assertEq(usdc.balanceOf(vendor), 6e6);
    }

    function testUnmanagedBorrowerIsUnchanged() public {
        _stake(sponsor, 5e6);
        vm.prank(sponsor);
        credit.back(borrower, 5e6);
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(1e6); // no manager: as before
        credit.disburseLoan(loanId);
        assertEq(usdc.balanceOf(borrower), 1e6);
    }

    // ───────────── the repaid-principal view ─────────────

    function testPrincipalRepaidTracksPartialRepaymentAndSurvivesDefault() public {
        _managedAndBacked(5e6);
        uint256 loanId = _viaManager(4e6);
        assertEq(credit.principalRepaid(loanId), 0);

        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(credit), 1e6);
        credit.repayLoan(loanId, 1e6); // inside the first day: all principal
        vm.stopPrank();
        assertEq(credit.principalRepaid(loanId), 1e6);

        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        assertEq(credit.principalRepaid(loanId), 1e6, "a default leaves the record: written off = principal - repaid");
        (uint256 principal,,,,) = credit.getLoan(loanId);
        assertEq(principal - credit.principalRepaid(loanId), 3e6);
        assertEq(credit.stakeOf(sponsor), 2e6, "the sponsor's stake paid the 3 USDC loss");
    }
}
