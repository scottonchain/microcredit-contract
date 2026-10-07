// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev What the pool does and does not do for a small advance against a cost gap, at the live Base Sepolia
 *      parameters (EFFR 433 + premium 500 = 933 bps, reserve share 45%). It pins behaviour a pilot of a
 *      revenue-linked advance would rely on; it says nothing about demand, repayment sources or any person.
 *      Run with `forge test --match-contract AdvanceFacts -vv` to print the figures.
 */
contract AdvanceFactsTest is MicrocreditTestBase {
    uint256 internal constant RESERVE_BPS = 4_500;
    uint256 internal constant CENT = 10_000;

    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");

    event RepaymentApplied(uint256 indexed loanId, uint256 interest, uint256 principal, uint256 fee);

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(makeAddr("poolLender"), 10_000e6);
        vm.startPrank(owner);
        credit.setReserveBps(RESERVE_BPS);
        credit.setScoreOverride(borrower, SCALE); // one full line: 100 USDC
        vm.stopPrank();
    }

    function _open(uint256 amount) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
    }

    function _repay(address payer, uint256 loanId, uint256 amount) internal {
        vm.startPrank(payer);
        usdc.approve(address(credit), amount);
        credit.repayLoan(loanId, amount);
        vm.stopPrank();
    }

    // ───────────── the first day: no interest, no dues, no history credit ─────────────

    /// A fast cycle pays lenders and the reserve nothing and earns no credit (the recycled-seed farm, one loan).
    function testRepaymentInsideTheFirstDayPaysNothingAndEarnsNothing() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 grantedBefore = credit.grantedCredit(borrower);
        uint256 loanId = _open(10e6);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);

        vm.prank(borrower);
        usdc.approve(address(credit), 10e6);
        vm.expectEmit(address(credit));
        emit RepaymentApplied(loanId, 0, 10e6, 0);
        vm.prank(borrower);
        credit.repayLoan(loanId, 10e6);

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(credit.completedLoans(borrower), 1, "the loan is on the record");
        assertEq(credit.duesPaid(borrower), 0, "but it paid no dues");
        assertEq(credit.firstLossReserve(), 0, "the reserve received nothing");
        assertEq(credit.totalAssets(), assetsBefore, "lenders earned nothing");
        assertEq(credit.grantedCredit(borrower), grantedBefore, "and the line did not grow");
    }

    /// The grace is a cliff: at one day the interest for the whole day appears, counted from disbursement.
    function testInterestAppearsInFullAtTheEndOfTheFirstDay() public {
        uint256 loanId = _open(10e6);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        assertEq(credit.getCurrentOutstandingAmount(loanId), 10e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        emit log_named_uint("10 USDC, owed at exactly one day, interest (base units)", owed - 10e6);
        assertEq(owed - 10e6, 2_556, "933 bps on 10 USDC for one day");
    }

    // ───────────── the cent: interest and balances under it are not collected ─────────────

    /// A 1 USDC advance held a week owes less than a cent of interest, so repaying only its principal closes it.
    function testShortSmallAdvanceIsClosedByRepayingItsPrincipalOnly() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _open(1e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        emit log_named_uint("1 USDC, 7 days: interest accrued (base units)", owed - 1e6);
        assertLt(owed - 1e6, CENT, "under a cent of interest");

        _repay(borrower, loanId, 1e6); // principal only

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "closed as repaid");
        assertEq(credit.totalLentOut(), 0);
        uint256 duesPaid = credit.duesPaid(borrower);
        emit log_named_uint("dues credited to the borrower", duesPaid);
        emit log_named_uint("reserve afterwards", credit.firstLossReserve());
        emit log_named_uint("lenders' totalAssets, before minus after", assetsBefore - credit.totalAssets());
        assertEq(duesPaid, (owed - 1e6) * RESERVE_BPS / 10_000, "dues are the reserve share of the interest applied");
        assertEq(credit.firstLossReserve(), 0, "the reserve share was absorbed by the forgiven balance");
        assertGt(credit.totalDuesPaid(), credit.firstLossReserve(), "so the dues credit is not held by reserve cash");
        assertEq(credit.totalAssets(), assetsBefore, "lenders got their principal back and earned nothing");
    }

    /// Ten daily cycles of a 38 USDC advance, each repaid with its principal only (the interest of one day on 38
    /// USDC is just under a cent). The borrower pays no cash interest, yet earns dues each time and the reserve
    /// holds none of it. CI-29 in docs/CREDIT_INTEGRITY_ISSUES.md.
    function testDailyCyclesOfSubCentInterestBuildDuesTheReserveDoesNotHold() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 cycles = 10;
        for (uint256 i = 0; i < cycles; i++) {
            uint256 loanId = _open(38e6);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            assertLt(credit.getCurrentOutstandingAmount(loanId) - 38e6, CENT, "under a cent of interest");
            _repay(borrower, loanId, 38e6);
        }
        uint256 dues = credit.duesPaid(borrower);
        emit log_named_uint("daily cycles", cycles);
        emit log_named_uint("dues credit earned (base units)", dues);
        emit log_named_uint("cash interest the borrower paid (base units)", usdc.balanceOf(borrower));
        emit log_named_uint("reserve (base units)", credit.firstLossReserve());
        assertGt(dues, 0);
        assertEq(credit.firstLossReserve(), 0);
        assertEq(credit.totalDuesPaid(), dues);
        assertEq(usdc.balanceOf(borrower), 0, "no cash interest: the borrower repaid exactly what it received");
        assertEq(credit.totalAssets(), assetsBefore, "lenders earned nothing");
    }

    /// An advance near a cent can be closed having repaid a third of it: the cent is forgiven, not collected.
    function testAdvanceNearACentIsMostlyForgivenAtClosing() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _open(15_000); // 0.015 USDC
        _repay(borrower, loanId, 5_001); // leaves 9,999: under a cent

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "closed as repaid");
        uint256 forgiven = assetsBefore - credit.totalAssets();
        emit log_named_uint("0.015 USDC advance, repaid (base units)", 5_001);
        emit log_named_uint("forgiven, borne by the reserve then lenders (base units)", forgiven);
        assertEq(forgiven, 9_999);
    }

    // ───────────── where principal goes, and who repays ─────────────

    /// The relayed borrow-and-disburse sends principal to the signed `to`; the wallet-direct and
    /// disburse-only paths send it to the borrower only (MetaTransactions.t.sol pins MustSendToBorrower).
    function testBorrowAndDisburseMetaCanPayAThirdPartyDirectly() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: 5e6,
            to: vendor,
            repaymentPeriod: 7 days,
            maxAprBps: 933,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, sig);

        assertEq(usdc.balanceOf(vendor), 5e6, "the vendor received the principal");
        assertEq(usdc.balanceOf(borrower), 0);
        (uint256 principal,, address debtor,,) = credit.getLoan(1);
        assertEq(principal, 5e6);
        assertEq(debtor, borrower, "the borrower still owes it");
    }

    /// The pool's own logs never name who repaid; the token's Transfer log does.
    function testPoolLogsDoNotRecordWhoRepaid() public {
        uint256 loanId = _open(10e6);
        usdc.mint(stranger, 10e6);

        vm.recordLogs();
        _repay(stranger, loanId, 10e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 strangerWord = bytes32(uint256(uint160(stranger)));
        bool poolNamesPayer = false;
        bool tokenNamesPayer = false;
        for (uint256 i = 0; i < logs.length; i++) {
            bool names = false;
            for (uint256 t = 0; t < logs[i].topics.length; t++) {
                if (logs[i].topics[t] == strangerWord) names = true;
            }
            // event data is 32-byte words; look for the address in any of them
            for (uint256 w = 0; w + 32 <= logs[i].data.length; w += 32) {
                bytes32 word;
                bytes memory d = logs[i].data;
                assembly {
                    word := mload(add(add(d, 32), w))
                }
                if (word == strangerWord) names = true;
            }
            if (logs[i].emitter == address(credit) && names) poolNamesPayer = true;
            if (logs[i].emitter == address(usdc) && names) tokenNamesPayer = true;
        }
        assertFalse(poolNamesPayer, "no pool event names the payer");
        assertTrue(tokenNamesPayer, "the token's Transfer log does");
        assertEq(credit.duesPaid(stranger), 0);
    }
}
