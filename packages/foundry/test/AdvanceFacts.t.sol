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

    // ───────────── the first day: interest accrues from disbursement, with no grace ─────────────

    /// A fast cycle pays the interest it accrued, split between lenders, the reserve and the protocol. It earns
    /// dues only on that cash interest, so the recycled-seed farm (one loan) now has a cost per cycle.
    function testRepaymentInsideTheFirstDayPaysItsAccruedInterest() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 grantedBefore = credit.grantedCredit(borrower);
        uint256 loanId = _open(10e6);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - 10e6;
        uint256 held = 1 days - 1;
        uint256 yearly = (uint256(10e6) * 933) / 10_000;
        assertEq(interest, (yearly * held) / 365 days, "continuous simple interest, no waiver");
        assertEq(interest, 2_556, "933 bps on 10 USDC, one second short of a day");
        uint256 fee = (interest * credit.protocolFeeBps()) / 10_000;
        uint256 toReserve = (interest * RESERVE_BPS) / 10_000;

        usdc.mint(borrower, interest);
        vm.prank(borrower);
        usdc.approve(address(credit), 10e6 + interest);
        vm.expectEmit(address(credit));
        emit RepaymentApplied(loanId, interest, 10e6, fee);
        vm.prank(borrower);
        credit.repayLoan(loanId, 10e6 + interest);

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(credit.completedLoans(borrower), 1, "the loan is on the record");
        assertEq(credit.duesPaid(borrower), toReserve, "dues are the reserve share of the cash interest paid");
        assertEq(credit.firstLossReserve(), toReserve, "the reserve received its share");
        assertEq(credit.totalAssets(), assetsBefore + interest - fee - toReserve, "lenders earned the rest");
        assertEq(
            credit.grantedCredit(borrower), grantedBefore + toReserve, "the line grew by the dues paid in cash only"
        );
    }

    /// There is no first-day cliff: interest is continuous from disbursement, the same simple interest at one
    /// hour, one second short of a day and exactly one day.
    function testInterestAccruesFromDisbursementWithoutAFirstDayCliff() public {
        uint256 loanId = _open(10e6);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 hours);
        assertEq(credit.getCurrentOutstandingAmount(loanId) - 10e6, 106, "933 bps on 10 USDC for one hour");
        vm.warp(start + 1 days - 1);
        assertEq(credit.getCurrentOutstandingAmount(loanId) - 10e6, 2_556);
        vm.warp(start + 1 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        emit log_named_uint("10 USDC, owed at exactly one day, interest (base units)", owed - 10e6);
        assertEq(owed - 10e6, 2_556, "933 bps on 10 USDC for one day");
    }

    // ───────────── the cent: no interest and no principal is forgiven at closing ─────────────

    /// A 1 USDC advance held a week owes under a cent of interest, and repaying only its principal does not
    /// close it: interest is paid first, the loan stays open owing exactly the interest left, and that interest
    /// earns dues when it is paid. Paying the remainder closes it.
    function testShortSmallAdvanceIsNotClosedByItsPrincipalAlone() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _open(1e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - 1e6;
        emit log_named_uint("1 USDC, 7 days: interest accrued (base units)", interest);
        assertEq(interest, 1_789, "933 bps on 1 USDC for 7 days, rounded down");
        assertLt(interest, CENT, "under a cent of interest");
        uint256 fee = (interest * credit.protocolFeeBps()) / 10_000;
        uint256 toReserve = (interest * RESERVE_BPS) / 10_000;

        vm.prank(borrower);
        usdc.approve(address(credit), 1e6);
        vm.expectEmit(address(credit));
        emit RepaymentApplied(loanId, interest, 1e6 - interest, fee); // interest first, then principal
        vm.prank(borrower);
        credit.repayLoan(loanId, 1e6);

        (,,,, bool active) = credit.getLoan(loanId);
        assertTrue(active, "still open: the interest-first payment left a sliver of principal");
        assertEq(
            credit.getCurrentOutstandingAmount(loanId),
            interest,
            "owes exactly what the interest took from the principal"
        );
        assertEq(credit.totalLentOut(), interest);
        assertEq(credit.activeLoanCount(borrower), 1, "and it keeps using the limit");
        assertEq(credit.completedLoans(borrower), 0);
        assertEq(credit.duesPaid(borrower), toReserve, "dues on the interest that was paid in cash");

        usdc.mint(borrower, interest);
        _repay(borrower, loanId, interest);
        (,,,, active) = credit.getLoan(loanId);
        assertFalse(active, "closed once the whole balance is paid");
        assertEq(credit.totalLentOut(), 0);
        assertEq(credit.completedLoans(borrower), 1);
        assertEq(credit.duesPaid(borrower), toReserve, "the remainder was principal and added no dues");
        assertEq(credit.firstLossReserve(), toReserve);
        assertEq(
            credit.totalAssets(),
            assetsBefore + interest - fee - toReserve,
            "lenders got the principal back and the interest"
        );

        uint256 second = _open(1e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 interest2 = credit.getCurrentOutstandingAmount(second) - 1e6;
        usdc.mint(borrower, interest2);
        _repay(borrower, second, 1e6 + interest2); // in full: closes in one payment
        emit log_named_uint("the same advance repaid in full: dues credited (base units)", credit.duesPaid(borrower));
        assertEq(
            credit.duesPaid(borrower),
            toReserve + (interest2 * RESERVE_BPS) / 10_000,
            "dues on every cent of cash interest"
        );
        assertEq(credit.firstLossReserve(), credit.duesPaid(borrower), "and the reserve holds them");
    }

    /// Ten daily cycles of a 38 USDC advance, each repaid in full (the interest of one day on 38 USDC is just
    /// under a cent): the borrower pays the sub-cent interest in cash and earns dues on it, every cycle. Before
    /// the interest policy change it was forgiven and earned nothing (docs/CREDIT_INTEGRITY_ISSUES.md, CI-30).
    function testDailyCyclesOfSubCentInterestArePaidInCashAndEarnDues() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 grantedBefore = credit.grantedCredit(borrower);
        uint256 cycles = 10;
        uint256 interestPaid = 0;
        uint256 duesExpected = 0;
        uint256 feeExpected = 0;
        for (uint256 i = 0; i < cycles; i++) {
            uint256 loanId = _open(38e6);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            uint256 interest = credit.getCurrentOutstandingAmount(loanId) - 38e6;
            assertGt(interest, 0, "the day is charged");
            assertLt(interest, CENT, "under a cent of interest");
            usdc.mint(borrower, interest);
            _repay(borrower, loanId, 38e6 + interest);
            interestPaid += interest;
            duesExpected += (interest * RESERVE_BPS) / 10_000;
            feeExpected += (interest * credit.protocolFeeBps()) / 10_000;
        }
        emit log_named_uint("daily cycles", cycles);
        emit log_named_uint("cash interest the borrower paid (base units)", interestPaid);
        assertEq(interestPaid, cycles * 9_713, "933 bps on 38 USDC for a day, rounded down, ten times");
        assertEq(credit.duesPaid(borrower), duesExpected, "dues on the interest paid in cash");
        assertEq(credit.totalDuesPaid(), duesExpected);
        assertEq(credit.firstLossReserve(), duesExpected);
        assertEq(credit.completedLoans(borrower), cycles, "the loans are on the record as repaid");
        assertEq(usdc.balanceOf(borrower), 0, "the borrower repaid what it received plus exactly the interest");
        assertEq(
            credit.totalAssets(), assetsBefore + interestPaid - feeExpected - duesExpected, "lenders earned the rest"
        );
        assertEq(
            credit.grantedCredit(borrower), grantedBefore + duesExpected, "credit grew only by the dues paid in cash"
        );
    }

    /// The candidate sheet's size and term (testbed #17, 2026-10-07): 1 USDC held the full 30 days owes under a
    /// cent. Repaying the principal alone does not close it; interest goes first and the loan stays open owing
    /// the sliver, and the full balance closes it with dues credited on every unit of interest paid.
    function testThirtyDayOneUsdcAdvanceOwesItsInterestAndIsNotClosedByItsPrincipal() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _open(1e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - 1e6;
        emit log_named_uint("1 USDC, 30 days: interest accrued (base units)", interest);
        assertEq(interest, 7_668, "933 bps on 1 USDC for 30 days, rounded down");
        uint256 fee = (interest * credit.protocolFeeBps()) / 10_000;
        uint256 toReserve = (interest * RESERVE_BPS) / 10_000;

        vm.prank(borrower);
        usdc.approve(address(credit), 1e6);
        vm.expectEmit(address(credit));
        emit RepaymentApplied(loanId, interest, 1e6 - interest, fee);
        vm.prank(borrower);
        credit.repayLoan(loanId, 1e6); // principal-sized payment

        (,,,, bool active) = credit.getLoan(loanId);
        assertTrue(active, "open: interest is paid before principal");
        assertEq(credit.getCurrentOutstandingAmount(loanId), interest);
        assertEq(credit.duesPaid(borrower), toReserve, "dues on the interest paid");
        assertEq(credit.firstLossReserve(), toReserve);

        usdc.mint(borrower, interest);
        _repay(borrower, loanId, interest);
        (,,,, active) = credit.getLoan(loanId);
        assertFalse(active, "closed once the whole balance is paid");
        assertEq(credit.duesPaid(borrower), toReserve);
        assertEq(
            credit.totalAssets(), assetsBefore + interest - fee - toReserve, "lenders got 1 USDC back plus their share"
        );
    }

    /// The same advance in default, once with unsecured backing (issued credit) and once with secured (stake):
    /// the loss is the unpaid principal, not the interest; credit burns and recovers no cash, stake does.
    function testOneUsdcDefaultUnsecuredBurnsCreditStakeRecoversCash() public {
        address unbacked = makeAddr("creditBacked");
        address staked = makeAddr("stakeBacked");
        address issuerBacker = makeAddr("issuerBacker");
        address stakeBacker = makeAddr("stakeBacker");
        vm.prank(owner);
        credit.setScoreOverride(issuerBacker, SCALE / 100); // a 1 USDC line
        vm.prank(issuerBacker);
        credit.back(unbacked, 1e6);
        _stake(stakeBacker, 1e6);
        vm.prank(stakeBacker);
        credit.back(staked, 1e6);

        uint256[2] memory loss;
        address[2] memory borrowers = [unbacked, staked];
        for (uint256 i = 0; i < 2; i++) {
            uint256 assetsBefore = credit.totalAssets();
            vm.prank(borrowers[i]);
            uint256 loanId = credit.requestLoan(1e6);
            credit.disburseLoan(loanId);
            (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
            vm.warp(dueAt + credit.LATE_PERIOD() + 1);
            credit.markDefaulted(loanId);
            loss[i] = assetsBefore - credit.totalAssets();
        }
        emit log_named_uint("unsecured: lenders' loss (base units)", loss[0]);
        emit log_named_uint("secured: lenders' loss (base units)", loss[1]);
        assertEq(loss[0], 1e6, "the unpaid principal, not the interest, falls on the reserve and lenders");
        assertEq(credit.creditLoss(issuerBacker), 1e6, "the backer's issued credit burns");
        assertEq(credit.grantedCredit(issuerBacker), 0);
        assertEq(loss[1], 0, "the slashed stake covers the principal");
        assertEq(credit.stakeOf(stakeBacker), 0, "the backer's stake is gone");
    }

    /// An advance near a cent cannot be closed by repaying a third of it: the rest is principal, so the loan stays
    /// open until it is paid, and nothing is forgiven.
    function testAdvanceNearACentStaysOpenUntilItsPrincipalIsRepaid() public {
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _open(15_000); // 0.015 USDC
        _repay(borrower, loanId, 5_001); // leaves 9,999 of principal: under a cent, still owed

        (,,,, bool active) = credit.getLoan(loanId);
        assertTrue(active, "still open");
        assertEq(credit.getCurrentOutstandingAmount(loanId), 9_999);
        assertEq(credit.totalAssets(), assetsBefore, "nothing forgiven");

        _repay(borrower, loanId, 9_999);
        (,,,, active) = credit.getLoan(loanId);
        assertFalse(active, "closed once the principal is paid in full");
        assertEq(credit.totalAssets(), assetsBefore);
    }

    /// The CI-30 take, closed: a loan of 9,999 base units repaid with 1 used to close as repaid and hand the
    /// borrower the rest, ten times over. Now each stays open: the borrower holds nothing it does not owe, the
    /// principal is still lent out and uses the limit, and the only ways out are to repay or to default and be
    /// blocked.
    function testSubCentLoansRepaidWithOneUnitStayOpenAndUseTheLimit() public {
        uint256 assetsBefore = credit.totalAssets();
        (uint256 limitBefore,) = credit.getBorrowLimit(borrower);
        uint256[] memory loanIds = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            loanIds[i] = _open(9_999);
            _repay(borrower, loanIds[i], 1);
            (,,,, bool active) = credit.getLoan(loanIds[i]);
            assertTrue(active, "still open");
        }
        emit log_named_uint(
            "ten 9,999-unit loans repaid with 1 each: held by the borrower (base units)", usdc.balanceOf(borrower)
        );
        assertEq(usdc.balanceOf(borrower), 10 * 9_998, "held, and still owed");
        assertEq(credit.totalLentOut(), 10 * 9_998, "still lent out");
        assertEq(credit.totalAssets(), assetsBefore, "lenders lost nothing");
        assertEq(credit.completedLoans(borrower), 0, "nothing on the record as repaid");
        (uint256 limit, uint256 available) = credit.getBorrowLimit(borrower);
        assertEq(limit, limitBefore);
        assertEq(available, limitBefore - 10 * 9_998, "the limit stays used");

        (,,,, uint256 dueAt) = credit.getLoanTerms(loanIds[0]);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanIds[0]);
        assertEq(credit.defaultedLoans(borrower), 1, "walking away from one is a default");
        vm.prank(borrower);
        vm.expectRevert();
        credit.requestLoan(9_999); // and a defaulter borrows no more
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
