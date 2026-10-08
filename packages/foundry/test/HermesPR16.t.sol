// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// HermesCRBot attack tests for PR #16 (anyone may repay a loan). Local, nothing broadcast.
contract HermesPR16Test is MicrocreditTestBase {
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal stranger = makeAddr("stranger");
    address internal poolLender = makeAddr("poolLender");
    address internal x = makeAddr("backerX");
    address internal y = makeAddr("backerY");
    address internal member = makeAddr("member");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(poolLender, 10_000e6);
        vm.startPrank(owner);
        credit.setReserveBps(5_000);
        credit.setScoreOverride(borrower, 500_000);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _borrow(address who, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(who);
        id = credit.requestLoan(amount);
        vm.stopPrank();
        credit.disburseLoan(id);
    }

    function _pastDue(uint256 id, uint256 extra) internal {
        (,,,, uint256 dueAt) = credit.getLoanTerms(id);
        vm.warp(dueAt + extra);
    }

    // ───────────── 1. griefing ─────────────

    /// A stranger closes the loan first: the borrower's own repay reverts and pulls nothing.
    function testFrontRunRepayRevertsBorrowerAndPullsNothing() public {
        uint256 id = _borrow(borrower, 40e6);
        vm.warp(block.timestamp + 10 days);
        uint256 owed = credit.getCurrentOutstandingAmount(id);
        _fund(stranger, owed);
        _fund(borrower, owed);
        vm.prank(stranger);
        credit.repayLoan(id, owed);

        uint256 before = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoan(id, owed);
        assertEq(usdc.balanceOf(borrower), before, "borrower USDC untouched");
        assertEq(credit.completedLoans(borrower), 1);
        assertGt(credit.duesPaid(borrower), 0, "borrower got the dues");
    }

    /// 30 one-wei repayments by a stranger leave the later provision and default loss unchanged.
    function testOneWeiRepaymentsDoNotChangeImpairmentOrDefaultLoss() public {
        uint256 s = vm.snapshotState();
        (uint256 provA, uint256 assetsA, uint256 reserveA) = _grief(false);
        vm.revertToState(s);
        (uint256 provB, uint256 assetsB, uint256 reserveB) = _grief(true);
        emit log_named_uint("provision, no grief", provA);
        emit log_named_uint("provision, 30 x 1 wei", provB);
        emit log_named_uint("totalAssets after default, no grief", assetsA);
        emit log_named_uint("totalAssets after default, 30 x 1 wei", assetsB);
        emit log_named_uint("reserve, no grief", reserveA);
        emit log_named_uint("reserve, 30 x 1 wei", reserveB);
        assertEq(provA, provB, "provision unchanged");
        assertLe(assetsB - assetsA, 30, "pool gains at most the 30 wei the stranger paid");
        assertEq(reserveA, reserveB);
    }

    function _grief(bool on) internal returns (uint256 prov, uint256 assets, uint256 reserve) {
        _stake(x, 20e6);
        vm.prank(x);
        credit.back(borrower, 20e6);
        uint256 id = _borrow(borrower, 50e6);
        vm.warp(block.timestamp + 10 days);
        if (on) {
            _fund(stranger, 1000);
            for (uint256 i = 0; i < 30; i++) {
                vm.prank(stranger);
                credit.repayLoan(id, 1);
            }
        }
        _pastDue(id, 1);
        credit.impairLoan(id);
        prov = credit.totalImpaired();
        _pastDue(id, credit.LATE_PERIOD() + 1);
        credit.markDefaulted(id);
        assets = credit.totalAssets();
        reserve = credit.firstLossReserve();
    }

    /// A stranger can close a loan up to 1 cent short of its interest; the forgiven sub-cent is
    /// interest that is never booked (no dues on it, no reserve debit), never principal. Measures
    /// what the pool gains from the repayment net of that forgiveness.
    function testStrangerCanTriggerSubCentForgivenessOnly() public {
        _stake(x, 20e6);
        vm.prank(x);
        credit.back(borrower, 20e6);
        uint256 id = _borrow(borrower, 50e6);
        vm.warp(block.timestamp + 10 days);
        uint256 owed = credit.getCurrentOutstandingAmount(id);
        uint256 assetsBefore = credit.totalAssets();
        _fund(stranger, owed);
        vm.prank(stranger);
        credit.repayLoan(id, owed - 9_999); // leaves 0.009999 USDC
        (,,,, bool active) = credit.getLoan(id);
        assertFalse(active, "loan closed with under a cent left");
        uint256 gain = credit.totalAssets() + 0 - assetsBefore;
        emit log_named_uint("pool totalAssets change", gain);
        emit log_named_uint("stranger paid", owed - 9_999);
        // the pool's accounting is the interest due minus what was forgiven (<1 cent), never a loss on principal
        assertEq(credit.totalLentOut(), 0);
        assertGe(credit.totalAssets(), assetsBefore, "the pool never loses on a close short of interest");
    }

    // ───────────── 2. early release ─────────────

    /// X repays loan A of a borrower with open loans A and B. X can free only as much backing as
    /// the principal it repaid; the default on B then falls on the remaining backers pro rata.
    function testBackerRepayingOneLoanFreesNoMoreThanItPaid() public {
        uint256 s = vm.snapshotState();
        (uint256 xLossBase, uint256 yLossBase) = _release(false);
        vm.revertToState(s);
        (uint256 xLossAtk, uint256 yLossAtk) = _release(true);
        emit log_named_uint("X total cost, passive (loss)", xLossBase);
        emit log_named_uint("Y loss, passive", yLossBase);
        emit log_named_uint("X total cost, repay A then cut (repay + loss)", xLossAtk);
        emit log_named_uint("Y loss, attack", yLossAtk);
        assertGe(xLossAtk, xLossBase, "X is never cheaper than passive");
    }

    function _release(bool attack) internal returns (uint256 xCost, uint256 yLoss) {
        vm.startPrank(owner);
        credit.setScoreOverride(member, 0);
        vm.stopPrank();
        _stake(x, 50e6);
        _stake(y, 50e6);
        vm.prank(x);
        credit.back(member, 50e6);
        vm.prank(y);
        credit.back(member, 50e6);
        uint256 a = _borrow(member, 10e6);
        uint256 b = _borrow(member, 90e6);
        uint256 xStart = usdc.balanceOf(x) + credit.stakeOf(x);
        uint256 yStart = usdc.balanceOf(y) + credit.stakeOf(y);

        if (attack) {
            vm.prank(x);
            vm.expectRevert(DecentralizedMicrocredit.BackingInUse.selector);
            credit.back(member, 0);
            _fund(x, 10e6);
            vm.prank(x);
            credit.repayLoan(a, 10e6);
            vm.prank(x);
            vm.expectRevert(DecentralizedMicrocredit.BackingInUse.selector);
            credit.back(member, 39e6); // would leave active 90 > limit 89
            vm.prank(x);
            credit.back(member, 40e6);
            vm.prank(x);
            credit.unstake(10e6);
        } else {
            _pastDue(a, credit.LATE_PERIOD() + 1);
            credit.markDefaulted(a);
        }
        _pastDue(b, credit.LATE_PERIOD() + 1);
        credit.markDefaulted(b);
        uint256 xEnd = usdc.balanceOf(x) + credit.stakeOf(x);
        uint256 yEnd = usdc.balanceOf(y) + credit.stakeOf(y);
        xCost = xStart - xEnd + (attack ? 10e6 : 0); // the 10 repaid is a cost, the unstaked 10 is not
        if (attack) xCost = 0 + (xStart + 10e6 - xEnd); // fund() minted 10 into x, count it as spent
        yLoss = yStart - yEnd;
    }

    // ───────────── 3. bought history ─────────────

    function _defaultOthers(uint256 n, uint256 each) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address d = makeAddr(string.concat("def", vm.toString(i)));
            uint256 sc = (each * credit.SCALE()) / credit.maxLoanAmount();
            vm.prank(owner);
            credit.setScoreOverride(d, sc);
            ids[i] = _borrow(d, each);
        }
        _pastDue(ids[0], credit.LATE_PERIOD() + 1);
        for (uint256 i = 0; i < n; i++) {
            credit.markDefaulted(ids[i]);
        }
    }

    /// Group = attacker (lender, backer) + payer + member. Compare with the same lender passive.
    function testBoughtHistoryGroupExcessVsPassiveLender() public {
        uint256 s = vm.snapshotState();
        (int256 net0, uint256 lena0,) = _bought(0);
        vm.revertToState(s);
        (int256 net1, uint256 lena1, uint256 dues) = _bought(1);
        emit log_named_uint("dues (reserve share of interest)", dues);
        emit log_named_int("group net, passive lender", net0);
        emit log_named_int("group net, attack", net1);
        emit log_named_int("excess over passive", net1 - net0);
        emit log_named_uint("poolLender balance, passive world", lena0);
        emit log_named_uint("poolLender balance, attack world", lena1);
        assertLe(int256(lena0) - int256(lena1), int256(dues), "honest lender loses at most the dues");
    }

    function _bought(uint256 world) internal returns (int256 net, uint256 lenaBal, uint256 dues) {
        address attacker = makeAddr("atk");
        address payer = makeAddr("payer");
        _fund(attacker, 10_000e6 + 100e6);
        _fund(payer, 1_000e6);
        _fund(member, 0);
        int256 start = int256(usdc.balanceOf(attacker) + usdc.balanceOf(payer) + usdc.balanceOf(member));
        vm.startPrank(attacker);
        credit.depositFunds(10_000e6);
        vm.stopPrank();
        if (world == 1) {
            vm.startPrank(attacker);
            credit.stake(100e6);
            credit.back(member, 100e6);
            vm.stopPrank();
            uint256 id = _borrow(member, 100e6);
            vm.warp(block.timestamp + 365 days);
            uint256 owed = credit.getCurrentOutstandingAmount(id);
            vm.prank(payer);
            credit.repayLoan(id, owed); // third party pays everything, member pays nothing
            vm.startPrank(attacker);
            credit.back(member, 0);
            credit.unstake(100e6);
            vm.stopPrank();
            dues = credit.duesPaid(member);
        } else {
            vm.warp(block.timestamp + 365 days);
        }
        _defaultOthers(2, 50e6);
        vm.prank(attacker);
        credit.withdrawFunds(type(uint256).max);
        if (world == 1 && dues > 0) {
            (, uint256 av) = credit.getBorrowLimit(member);
            uint256 take = dues < av ? dues : av;
            emit log_named_uint("member avail / take / reserve before dues-default", av);
            emit log_named_uint("take", take);
            emit log_named_uint("reserve", credit.firstLossReserve());
            uint256 id2 = _borrow(member, take);
            _pastDue(id2, credit.LATE_PERIOD() + 1);
            credit.markDefaulted(id2);
        }
        net = int256(usdc.balanceOf(attacker) + usdc.balanceOf(payer) + usdc.balanceOf(member)) - start;
        lenaBal = credit.lenderBalance(poolLender);
    }

    // ───────────── 4. permit / meta paths ─────────────

    function testPermitPathsAfterAStrangersPartialRepayment() public {
        uint256 id = _borrow(borrower, 40e6);
        _fund(stranger, 15e6);
        vm.prank(stranger);
        credit.repayLoan(id, 15e6);
        (, uint256 out,,,) = credit.getLoan(id);
        assertEq(out, 25e6);

        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, 25e6, _deadline());
        usdc.mint(borrower, 25e6);
        vm.prank(relayer);
        credit.repayWithPermit(borrower, id, 0, p.value, p.deadline, p.v, p.r, p.s);
        (,,,, bool active) = credit.getLoan(id);
        assertFalse(active);
        assertEq(credit.completedLoans(borrower), 1);
    }

    function testRepayLoanMetaAfterAStrangersPartialRepayment() public {
        uint256 id = _borrow(borrower, 40e6);
        DecentralizedMicrocredit.RepayRequest memory req = DecentralizedMicrocredit.RepayRequest({
            borrower: borrower, loanId: id, amount: 40e6, nonce: credit.nonces(borrower), deadline: _deadline()
        });
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, 40e6, _deadline());
        usdc.mint(borrower, 40e6);
        _fund(stranger, 1e6);
        vm.prank(stranger);
        credit.repayLoan(id, 1e6); // front-runs the relayed repay with a partial payment
        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, permit);
        (,,,, bool active) = credit.getLoan(id);
        assertFalse(active);
    }

    function testPermitAndMetaRevertCleanlyWhenAStrangerClosedTheLoan() public {
        uint256 id = _borrow(borrower, 40e6);
        DecentralizedMicrocredit.RepayRequest memory req = DecentralizedMicrocredit.RepayRequest({
            borrower: borrower, loanId: id, amount: 0, nonce: credit.nonces(borrower), deadline: _deadline()
        });
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, 40e6, _deadline());
        usdc.mint(borrower, 40e6);
        _fund(stranger, 40e6);
        vm.prank(stranger);
        credit.repayLoan(id, 40e6);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayWithPermit(borrower, id, 0, p.value, p.deadline, p.v, p.r, p.s);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoanMeta(req, sig, _noPermit());
        assertEq(usdc.balanceOf(borrower), 80e6, "borrower funds untouched: the 40 loan proceeds plus the 40 minted");
    }

    /// A defaulted loan cannot be repaid back to life by anyone.
    function testNoOneCanRepayADefaultedLoan() public {
        uint256 id = _borrow(borrower, 40e6);
        _pastDue(id, credit.LATE_PERIOD() + 1);
        credit.markDefaulted(id);
        _fund(stranger, 100e6);
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoan(id, 40e6);
    }
}
