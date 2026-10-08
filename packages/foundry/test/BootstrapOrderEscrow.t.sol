// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { BootstrapOrderEscrow } from "../contracts/BootstrapOrderEscrow.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev The funded-order adapter against the pool with the manager gate. The worker begins with no ETH and no
 *      USDC, names the adapter as its manager before any backing exists, and every origination for it then goes
 *      through `originate`. Local EVM, MockUSDC, synthetic time; none of this is a public-chain receipt.
 */
contract BootstrapOrderEscrowTest is MicrocreditTestBase {
    uint256 internal constant LIQUIDITY = 5e6;
    uint256 internal constant STAKE = 1e6;
    uint256 internal constant CUSTOMER_BUDGET = 1_500_000;
    uint256 internal constant INPUT_COST = 200_000;
    uint256 internal constant ORDER_PRICE = 500_000;
    uint256 internal constant SUPPLY = LIQUIDITY + STAKE + CUSTOMER_BUDGET;

    BootstrapOrderEscrow internal escrow;
    address internal lender = makeAddr("lender");
    address internal sponsor = makeAddr("sponsor");
    address internal customer = makeAddr("customer");
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");
    address internal worker;
    uint256 internal workerKey;

    function setUp() public {
        (worker, workerKey) = makeAddrAndKey("worker");
        _deploy(433, 500, 100e6);
        vm.prank(owner);
        credit.setReserveBps(4_500);
        escrow = new BootstrapOrderEscrow(credit);
        _deposit(lender, LIQUIDITY);
        usdc.mint(customer, CUSTOMER_BUDGET);
        // order matters: the worker names its manager first, then the sponsor backs it
        vm.prank(worker);
        credit.setManager(address(escrow));
        _stake(sponsor, STAKE);
        vm.prank(sponsor);
        credit.back(worker, STAKE);
        assertEq(worker.balance, 0, "worker starts without ETH");
        assertEq(usdc.balanceOf(worker), 0, "worker starts without USDC");
    }

    // ───────────── helpers ─────────────

    function _intent(uint256 amount) internal view returns (BootstrapOrderEscrow.Intent memory) {
        return BootstrapOrderEscrow.Intent({
            worker: worker,
            vendor: vendor,
            amount: amount,
            term: 30 days,
            maxAprBps: 933,
            nonce: credit.nonces(worker),
            deadline: _deadline(),
            jobHash: keccak256("job-1")
        });
    }

    function _fund(BootstrapOrderEscrow.Intent memory i, uint256 cap, uint256 settleIn) internal returns (uint256 id) {
        vm.startPrank(customer);
        usdc.approve(address(escrow), ORDER_PRICE);
        id = escrow.fund(i, ORDER_PRICE, cap, block.timestamp + settleIn);
        vm.stopPrank();
    }

    function _req(BootstrapOrderEscrow.Intent memory i)
        internal
        pure
        returns (DecentralizedMicrocredit.BorrowAndDisburse memory)
    {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: i.worker,
            amount: i.amount,
            to: i.vendor,
            repaymentPeriod: i.term,
            maxAprBps: i.maxAprBps,
            nonce: i.nonce,
            deadline: i.deadline
        });
    }

    function _orderSig(BootstrapOrderEscrow target, uint256 id) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(workerKey, target.acceptanceDigest(id));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Funds, signs both consents and originates through the adapter, as any relayer may.
    function _bound() internal returns (uint256 id, uint256 loanId) {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        loanId = escrow.originate(id, req, poolSig, orderSig);
    }

    function _exit() internal {
        vm.startPrank(sponsor);
        credit.back(worker, 0);
        credit.unstake(credit.stakeOf(sponsor));
        vm.stopPrank();
        vm.prank(lender);
        credit.withdrawFunds(type(uint256).max);
        assertEq(credit.totalShares(), 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function _conserved() internal view {
        uint256 balances = usdc.balanceOf(address(credit)) + usdc.balanceOf(lender) + usdc.balanceOf(sponsor)
            + usdc.balanceOf(customer) + usdc.balanceOf(vendor) + usdc.balanceOf(worker)
            + usdc.balanceOf(address(escrow));
        assertEq(usdc.totalSupply(), SUPPLY, "nothing was minted after setUp");
        assertEq(balances, SUPPLY, "every base unit is attributed");
    }

    // ───────────── the flow ─────────────

    function testOriginatePaysTheVendorAndSettleClearsDebtBeforeTheWorker() public {
        (uint256 id, uint256 loanId) = _bound();
        assertEq(usdc.balanceOf(vendor), INPUT_COST, "principal went to the signed vendor");
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(worker.balance, 0, "the relayer, not the worker, is the transaction caller");
        assertEq(escrow.loanOrder(loanId), id);
        (,,, uint256 settleBy,,,) = escrow.orders(id);
        assertGt(settleBy, block.timestamp);

        vm.prank(customer);
        escrow.settle(id);
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "debt cleared");
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - INPUT_COST, "exact remainder");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.allowance(address(escrow), address(credit)), 0);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY, "first-day repayment: zero interest, reported honestly");
        _conserved();
    }

    function testSevenDaySettlementPaysInterestAndLeavesTheProtectedReserve() public {
        (uint256 id,) = _bound();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 interest = INPUT_COST * 933 * 7 days / (10_000 * 365 days);
        vm.prank(customer);
        escrow.settle(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - INPUT_COST - interest);
        assertEq(credit.firstLossReserve(), interest * 4_500 / 10_000);
        _exit();
        _conserved();
    }

    // ───────────── the two admission races (Codex's counterexamples) ─────────────

    function testNoLoanCanExistBeforeTheOrderSoNoneCanBeBoundToIt() public {
        // the worker cannot borrow outside an order: direct, request-meta and borrow-and-disburse are all closed
        vm.prank(worker);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(INPUT_COST);

        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, poolSig);
    }

    function testRefundThenBroadcastTheSignedAdvanceFails() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);

        vm.prank(customer);
        escrow.refund(id); // the customer rejects before anything is originated
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "refunded in full");

        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidOrder.selector);
        escrow.originate(id, req, poolSig, orderSig); // the commitment is consumed

        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, poolSig); // and the pool refuses any other caller

        assertEq(usdc.balanceOf(vendor), 0, "the vendor was never paid");
    }

    function testASecondOrderCannotAttachTheFirstLoan() public {
        (uint256 first, uint256 loanId) = _bound();
        BootstrapOrderEscrow.Intent memory j = _intent(INPUT_COST);
        j.jobHash = keccak256("job-2");
        vm.startPrank(customer);
        usdc.approve(address(escrow), ORDER_PRICE);
        uint256 second = escrow.fund(j, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        // the only way to bind is to originate a new loan under the pool's own nonce rule: the first request's nonce is spent
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(j);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, second);
        vm.prank(relayer);
        escrow.originate(second, req, poolSig, orderSig);
        assertEq(escrow.loanOrder(loanId), first, "the first loan stays with the first order");
        (,,,,, uint256 secondLoan,) = escrow.orders(second);
        assertTrue(secondLoan != loanId && secondLoan != 0);
    }

    // ───────────── exact-intent binding: every field ─────────────

    function _expectMismatch(
        BootstrapOrderEscrow.Intent memory i,
        DecentralizedMicrocredit.BorrowAndDisburse memory bad
    ) internal {
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, bad);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.IntentMismatch.selector);
        escrow.originate(id, bad, poolSig, orderSig);
    }

    function testWrongVendorAmountTermAprNonceDeadlineAreEachRejected() public {
        usdc.mint(customer, 7 * ORDER_PRICE); // one funded order per tampered request
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        DecentralizedMicrocredit.BorrowAndDisburse memory r = _req(i);
        r.to = stranger;
        _expectMismatch(i, r);
        r = _req(i);
        r.amount = INPUT_COST + 1;
        _expectMismatch(i, r);
        r = _req(i);
        r.repaymentPeriod = 7 days;
        _expectMismatch(i, r);
        r = _req(i);
        r.maxAprBps = 1_000;
        _expectMismatch(i, r);
        r = _req(i);
        r.nonce = i.nonce + 1;
        _expectMismatch(i, r);
        r = _req(i);
        r.deadline = i.deadline + 1;
        _expectMismatch(i, r);
        r = _req(i);
        r.borrower = stranger;
        _expectMismatch(i, r);
    }

    function testAWorkerAcceptanceOfAnotherJobIsRejected() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        // a second order with a different job hash: the worker signs acceptance of THAT one, then it is presented for the first
        BootstrapOrderEscrow.Intent memory j = _intent(INPUT_COST);
        j.jobHash = keccak256("job-2");
        vm.startPrank(customer);
        usdc.approve(address(escrow), ORDER_PRICE);
        uint256 other = escrow.fund(j, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        bytes memory wrong = _orderSig(escrow, other);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidConsent.selector);
        escrow.originate(id, req, poolSig, wrong);
    }

    function testUnmanagedWorkerCannotBeOriginatedByTheAdapter() public {
        (address other, uint256 otherKey) = makeAddrAndKey("other-worker");
        _stake(makeAddr("s2"), 1e6);
        vm.prank(makeAddr("s2"));
        credit.back(other, 1e6);
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        i.worker = other;
        i.nonce = credit.nonces(other);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(otherKey, req);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, escrow.acceptanceDigest(id));
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.NotManager.selector);
        escrow.originate(id, req, poolSig, abi.encodePacked(r, s, v));
    }

    function testBackingBeforeTheManagerLocksTheChoice() public {
        (address late,) = makeAddrAndKey("late-worker");
        _stake(makeAddr("s3"), 1e6);
        vm.prank(makeAddr("s3"));
        credit.back(late, 1e6);
        vm.prank(late);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(escrow));
    }

    // ───────────── replay and duplicate execution ─────────────

    function testReplayAndDuplicateExecutionAreRejected() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        escrow.originate(id, req, poolSig, orderSig);

        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidOrder.selector);
        escrow.originate(id, req, poolSig, orderSig); // second execution of the same order

        vm.prank(customer);
        escrow.settle(id);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidOrder.selector);
        escrow.settle(id); // double settlement
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidOrder.selector);
        escrow.refund(id); // refund after settlement
    }

    function testSignaturesDoNotReplayOnAnotherChainOrAnotherAdapter() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);

        // another adapter: same pool, same signatures, funded the same way; the domain differs
        BootstrapOrderEscrow other = new BootstrapOrderEscrow(credit);
        vm.startPrank(customer);
        usdc.approve(address(other), ORDER_PRICE);
        uint256 otherId = other.fund(i, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.NotManager.selector); // the pool names only the first adapter
        other.originate(otherId, req, poolSig, orderSig);

        // another chain id: the adapter's domain binds it
        vm.chainId(block.chainid + 1);
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidConsent.selector);
        escrow.originate(id, req, poolSig, orderSig);
    }

    // ───────────── settlement edges ─────────────

    function testLateInterestAboveTheCapNeverReleasesWorkerMoney() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, INPUT_COST, 400 days); // cap = principal: any interest exceeds it
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        escrow.originate(id, req, poolSig, orderSig);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderEscrow.DebtExceedsCap.selector);
        escrow.settle(id);
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(usdc.balanceOf(address(escrow)), ORDER_PRICE, "funds stay escrowed");
    }

    function testPartialRepaymentByAnyoneReducesWhatSettleRepays() public {
        (uint256 id, uint256 loanId) = _bound();
        usdc.mint(stranger, 50_000);
        vm.startPrank(stranger);
        usdc.approve(address(credit), 50_000);
        credit.repayLoan(loanId, 50_000);
        vm.stopPrank();
        vm.prank(customer);
        escrow.settle(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - (INPUT_COST - 50_000));
    }

    function testRepaidLoanPaysTheWholePriceAndDefaultDoesNotSettle() public {
        (uint256 id, uint256 loanId) = _bound();
        usdc.mint(stranger, INPUT_COST);
        vm.startPrank(stranger);
        usdc.approve(address(credit), INPUT_COST);
        credit.repayLoan(loanId, INPUT_COST);
        vm.stopPrank();
        vm.prank(customer);
        escrow.settle(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE, "debt already cleared: the worker receives the whole price");

        // a second order whose loan defaults
        BootstrapOrderEscrow.Intent memory j = _intent(INPUT_COST);
        j.jobHash = keccak256("job-3");
        vm.startPrank(customer);
        usdc.approve(address(escrow), ORDER_PRICE);
        uint256 id2 = escrow.fund(j, ORDER_PRICE, ORDER_PRICE, block.timestamp + 400 days);
        vm.stopPrank();
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(j);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id2);
        vm.prank(relayer);
        uint256 loan2 = escrow.originate(id2, req, poolSig, orderSig);
        (,,,, uint256 dueAt) = credit.getLoanTerms(loan2);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loan2);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderEscrow.InvalidLoan.selector);
        escrow.settle(id2);
        assertEq(credit.stakeOf(sponsor), STAKE - INPUT_COST, "the sponsor's stake took the loss, nobody else");
        vm.prank(customer);
        escrow.refund(id2);
    }

    function testRejectionRefundsTheCustomerAndLeavesTheDisbursedDebt() public {
        (uint256 id, uint256 loanId) = _bound();
        vm.prank(customer);
        escrow.refund(id);
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "refunded");
        (,,,, bool active) = credit.getLoan(loanId);
        assertTrue(active, "the disbursed loan stays the worker's debt: refund never forgives it");
    }

    function testExpiredOrderRefundsOnlyTheOriginalPayer() public {
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 3 days);
        vm.prank(stranger);
        vm.expectRevert(BootstrapOrderEscrow.Unauthorized.selector);
        escrow.refund(id);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.prank(stranger);
        escrow.refund(id);
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function testUnauthorizedSettlementCannotReleaseFunds() public {
        (uint256 id,) = _bound();
        vm.prank(worker);
        vm.expectRevert(BootstrapOrderEscrow.Unauthorized.selector);
        escrow.settle(id);
        assertEq(usdc.balanceOf(address(escrow)), ORDER_PRICE);
    }

    function testRelayerWhitelistMustNameTheAdapter() public {
        vm.prank(owner);
        credit.setRelayerWhitelistEnabled(true);
        BootstrapOrderEscrow.Intent memory i = _intent(INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        vm.expectRevert(); // the pool refuses a relayer it has not whitelisted: the adapter itself
        escrow.originate(id, req, poolSig, orderSig);
        vm.prank(owner);
        credit.setRelayerWhitelisted(address(escrow), true);
        vm.prank(relayer);
        escrow.originate(id, req, poolSig, orderSig);
    }

    // ───────────── conservation under any input size ─────────────

    function testFuzzEverySettledUnitIsConserved(uint256 input) public {
        input = bound(input, 1, ORDER_PRICE);
        BootstrapOrderEscrow.Intent memory i = _intent(input);
        vm.startPrank(customer);
        usdc.approve(address(escrow), ORDER_PRICE);
        uint256 id = escrow.fund(i, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(escrow, id);
        vm.prank(relayer);
        escrow.originate(id, req, poolSig, orderSig);
        vm.prank(customer);
        escrow.settle(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - input);
        assertEq(usdc.balanceOf(vendor), input);
        _exit();
        _conserved();
    }
}
