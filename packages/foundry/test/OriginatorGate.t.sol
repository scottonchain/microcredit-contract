// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev The originator gate (CI-31, CI-32): the pool is built with the one caller that may originate any loan
 *      (`requestLoan`, `requestLoanMeta`, `borrowAndDisburseMeta`), fixed at construction, for every borrower and
 *      whatever supports it (an owner-granted line, an oracle score, ordinary backing, stake). That is what lets a
 *      router outside the pool bind every origination to its own rules: third-party repayment frees pool capacity
 *      at any time, so a rule that only lives outside the pool can be bypassed by a direct call. A zero originator
 *      is an open pool, as before.
 */
contract OriginatorGateTest is MicrocreditTestBase {
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal originator = makeAddr("originator");
    address internal sponsor = makeAddr("sponsor");
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployWithOriginator(433, 500, 100e6, originator);
        _deposit(makeAddr("poolLender"), 1_000e6);
    }

    // ───────────── helpers ─────────────

    function _backed(uint256 backing) internal {
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

    function _viaOriginator(uint256 amount) internal returns (uint256 loanId) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(amount);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(originator);
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

    function _refusesEveryRoute() internal {
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(1e6);

        DecentralizedMicrocredit.LoanRequest memory lr = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower, amount: 1e6, nonce: credit.nonces(borrower), deadline: _deadline()
        });
        bytes memory lsig = _signLoanRequest(borrowerPk, lr);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoanMeta(lr, lsig);

        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
    }

    // ───────────── the choice is the pool's, and final ─────────────

    function testTheOriginatorIsFixedAtConstructionAndThereIsNoWayToChangeIt() public {
        assertEq(credit.ORIGINATOR(), originator);
        // the per-borrower manager, its setter and every originator setter do not exist
        for (uint256 k = 0; k < 4; k++) {
            bytes memory data = k == 0
                ? abi.encodeWithSignature("setManager(address)", address(0))
                : k == 1
                    ? abi.encodeWithSignature("managerOf(address)", borrower)
                    : k == 2
                        ? abi.encodeWithSignature("setOriginator(address)", stranger)
                        : abi.encodeWithSignature("transferOriginator(address)", stranger);
            vm.prank(owner);
            (bool ok,) = address(credit).call(data);
            assertFalse(ok, "no such function, not even for the owner");
        }
        assertEq(credit.ORIGINATOR(), originator);
    }

    // ───────────── the gate on every origination path, for every kind of support ─────────────

    function testNothingSupportingABorrowerOpensAnotherDoor() public {
        _refusesEveryRoute(); // a borrower with nothing: refused on the originator before any limit is read

        vm.prank(owner);
        credit.setScoreOverride(borrower, 1e6); // an owner-granted line
        _refusesEveryRoute();

        _publishScore(borrower, 5e5); // an oracle score
        _refusesEveryRoute();

        _backed(5e6); // ordinary secured backing from a stranger's stake
        _refusesEveryRoute();
    }

    function testTheOriginatorOriginatesAndPaysTheVendor() public {
        _backed(5e6);
        uint256 loanId = _viaOriginator(2e6);
        assertEq(usdc.balanceOf(vendor), 2e6, "principal went to the signed vendor");
        (uint256 principal,, address debtor,,) = credit.getLoan(loanId);
        assertEq(principal, 2e6);
        assertEq(debtor, borrower);
    }

    function testTheOriginatorStillNeedsCredit() public {
        // the gate decides who may ask, not what is allowed: no limit means no loan even for the originator
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(originator);
        vm.expectRevert(DecentralizedMicrocredit.NoCredit.selector);
        credit.borrowAndDisburseMeta(req, sig);
    }

    function testDirectRepaymentFreesCapacityOnlyForTheOriginator() public {
        _backed(5e6);
        uint256 loanId = _viaOriginator(5e6);
        _repayAll(stranger, loanId); // anyone may repay: the pool's capacity for this borrower is free again
        _refusesEveryRoute(); // the bypass a router outside the pool could not stop: every other path stays closed

        _viaOriginator(1e6); // the originator can reopen it, under its own rules
        assertEq(usdc.balanceOf(vendor), 6e6);
    }

    function testSignatureMadeEarlierCanOnlyBeExecutedByTheOriginator() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        _backed(5e6);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(originator); // and it is still the borrower's own signature
        credit.borrowAndDisburseMeta(req, sig);
        assertEq(usdc.balanceOf(vendor), 2e6);
    }

    function testDefaultOfAnOriginatedLoanChargesTheSponsorStakeByTheUnpaidPrincipal() public {
        _backed(5e6);
        uint256 loanId = _viaOriginator(4e6);
        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(credit), 1e6);
        credit.repayLoan(loanId, 1e6); // inside the first day: all principal
        vm.stopPrank();

        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        assertEq(credit.stakeOf(sponsor), 2e6, "the sponsor's stake paid the 3 USDC unpaid principal");
        assertEq(credit.defaultedLoans(borrower), 1);
    }

    // ───────────── a zero originator is an open pool, as before ─────────────

    function testAnOpenPoolIsUnchanged() public {
        vm.startPrank(owner);
        DecentralizedMicrocredit open = new DecentralizedMicrocredit(433, 500, 100e6, address(usdc), oracle, address(0));
        open.setScoreOverride(borrower, 1e6);
        vm.stopPrank();
        assertEq(open.ORIGINATOR(), address(0));
        usdc.mint(address(this), 10e6);
        usdc.approve(address(open), 10e6);
        open.depositFunds(10e6);
        vm.prank(borrower);
        uint256 loanId = open.requestLoan(1e6); // no originator: the borrower may ask
        open.disburseLoan(loanId);
        assertEq(usdc.balanceOf(borrower), 1e6);
    }
}
