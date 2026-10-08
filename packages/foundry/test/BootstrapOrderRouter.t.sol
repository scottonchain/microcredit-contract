// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { BootstrapOrderRouter } from "../contracts/BootstrapOrderRouter.sol";
import { StakeRouterBase, TransitiveStakeRouter } from "../contracts/TransitiveStakeRouter.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev The bootstrap product on one manager: a customer's funded exact order, the roots' two-hop stake and the pool
 *      with the manager gate. The worker begins with no ETH, no USDC and no credit, names the router as its only
 *      manager before any backing exists, and every origination for it then goes through `originateOrder`. Local EVM,
 *      MockUSDC, synthetic time; none of this is a public-chain receipt.
 */
contract BootstrapOrderRouterTest is MicrocreditTestBase {
    uint256 internal constant LIQUIDITY = 5e6;
    uint256 internal constant INPUT_COST = 1e6; // the lot equals the loan and the pool's smallest backing is 1 USDC
    uint256 internal constant ORDER_PRICE = 1_500_000;
    uint256 internal constant CUSTOMER_BUDGET = 6_000_000;
    uint256 internal constant ROOT_FUND = 1_000_000;
    uint256 internal constant TERM = 30 days;

    BootstrapOrderRouter internal router;
    address internal lender = makeAddr("lender");
    address internal customer = makeAddr("customer");
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");
    address internal worker;
    uint256 internal workerKey;
    address internal worker2;
    uint256 internal worker2Key;
    address internal root1;
    uint256 internal root1Key;
    address internal root2;
    uint256 internal root2Key;
    address internal mid1;
    uint256 internal mid1Key;
    address internal officer;
    uint256 internal officerKey;
    uint256 internal minted; // USDC created after setUp through _mint
    uint256 internal baseline; // the known holders' total balance at the end of setUp

    function setUp() public virtual {
        (worker, workerKey) = makeAddrAndKey("worker");
        (worker2, worker2Key) = makeAddrAndKey("worker2");
        (root1, root1Key) = makeAddrAndKey("root1");
        (root2, root2Key) = makeAddrAndKey("root2");
        (mid1, mid1Key) = makeAddrAndKey("mid1");
        _deployProtocol();
        vm.prank(owner);
        credit.setReserveBps(4_500);
        router = new BootstrapOrderRouter(credit);
        (officer, officerKey) = makeAddrAndKey("officer");
        router.setOfficer(officer, 1); // this contract deployed the router, so it is the officer admin
        _give(lender, LIQUIDITY);
        vm.startPrank(lender);
        usdc.approve(address(credit), LIQUIDITY);
        credit.depositFunds(LIQUIDITY);
        vm.stopPrank();
        _give(customer, CUSTOMER_BUDGET);
        _rootFund(root1, ROOT_FUND);
        _rootFund(root2, ROOT_FUND);
        // order matters: the worker names its manager first; the router makes the backing at origination
        vm.prank(worker);
        credit.setManager(address(router));
        vm.prank(worker2);
        credit.setManager(address(router));
        assertEq(worker.balance, 0, "worker starts without ETH");
        assertEq(usdc.balanceOf(worker), 0, "worker starts without USDC");
        assertEq(credit.grantedCredit(worker), 0, "worker starts without credit");
        baseline = _holders();
    }

    // ───────────── helpers ─────────────

    /// @dev The fork suite overrides these two to run the same tests against Circle's USDC.
    function _deployProtocol() internal virtual {
        _deploy(433, 500, 100e6);
    }

    function _give(address who, uint256 amount) internal virtual {
        usdc.mint(who, amount);
    }

    /// @dev Create USDC for a test after setUp, so the conservation check can account for it.
    function _mint(address who, uint256 amount) internal {
        _give(who, amount);
        minted += amount;
    }

    function _rootFund(address root, uint256 amount) internal {
        _give(root, amount);
        vm.startPrank(root);
        usdc.approve(address(router), amount);
        router.deposit(amount);
        vm.stopPrank();
    }

    function _rootDeposit(address root, uint256 amount) internal {
        _mint(root, amount);
        vm.startPrank(root);
        usdc.approve(address(router), amount);
        router.deposit(amount);
        vm.stopPrank();
    }

    function _poolStake(address who, uint256 amount) internal {
        _give(who, amount);
        vm.startPrank(who);
        usdc.approve(address(credit), amount);
        credit.stake(amount);
        vm.stopPrank();
    }

    function _intent(address who, uint256 amount) internal view returns (BootstrapOrderRouter.Intent memory) {
        return BootstrapOrderRouter.Intent({
            worker: who,
            vendor: vendor,
            amount: amount,
            term: TERM,
            maxAprBps: 933,
            nonce: credit.nonces(who),
            deadline: _deadline(),
            jobHash: keccak256("job-1")
        });
    }

    /// @dev Funds an order and records the officer's approval for exactly its amount, as every order needs one.
    function _fund(BootstrapOrderRouter.Intent memory i, uint256 cap, uint256 settleIn) internal returns (uint256 id) {
        id = _fundUnapproved(i, cap, settleIn);
        _approve(id, i.amount);
    }

    function _fundUnapproved(BootstrapOrderRouter.Intent memory i, uint256 cap, uint256 settleIn)
        internal
        returns (uint256 id)
    {
        vm.startPrank(customer);
        usdc.approve(address(router), ORDER_PRICE);
        id = router.fund(i, ORDER_PRICE, cap, block.timestamp + settleIn);
        vm.stopPrank();
    }

    function _approval(uint256 id, uint256 maxAmount)
        internal
        view
        returns (BootstrapOrderRouter.JobApproval memory a, bytes memory sig)
    {
        (,,,, bytes32 ih,,) = router.orders(id);
        a = BootstrapOrderRouter.JobApproval({
            orderId: id,
            intentHash: ih,
            maxAmount: maxAmount,
            expiry: block.timestamp + 60 days,
            policyVersion: router.policyVersion(),
            officerEpoch: router.officerEpoch()
        });
        sig = _signDigest(officerKey, router.approvalDigest(a));
    }

    function _approve(uint256 id, uint256 maxAmount) internal {
        (BootstrapOrderRouter.JobApproval memory a, bytes memory sig) = _approval(id, maxAmount);
        router.approveOrder(a, sig);
    }

    function _req(BootstrapOrderRouter.Intent memory i)
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

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _orderSig(uint256 pk, uint256 id) internal view returns (bytes memory) {
        return _signDigest(pk, router.acceptanceDigest(id));
    }

    /// @dev A consent of the current version. A root consent's `scope` is zero (any borrower the mid vouches for) or
    ///      one borrower; a mid consent names its borrower.
    function _consent(address from, address to, address scope, bool rootEdge, uint256 limit)
        internal
        view
        returns (StakeRouterBase.Consent memory)
    {
        return StakeRouterBase.Consent({
            from: from,
            to: to,
            borrower: scope,
            limit: limit,
            maxTerm: TERM,
            version: router.edgeVersion(router.edgeKey(from, to, rootEdge ? address(0) : scope)),
            expiry: block.timestamp + 90 days
        });
    }

    function _path(uint256 rootPk, address root, address forWorker, uint256 amount, uint256 cap)
        internal
        view
        returns (StakeRouterBase.Path memory p)
    {
        StakeRouterBase.Consent memory re = _consent(root, mid1, address(0), true, cap);
        StakeRouterBase.Consent memory me = _consent(mid1, forWorker, forWorker, false, 100e6);
        p = StakeRouterBase.Path({
            amount: amount,
            rootEdge: re,
            rootSig: _signDigest(rootPk, router.consentDigest(re)),
            midEdge: me,
            midSig: _signDigest(mid1Key, router.consentDigest(me))
        });
    }

    function _one(StakeRouterBase.Path memory p) internal pure returns (StakeRouterBase.Path[] memory ps) {
        ps = new StakeRouterBase.Path[](1);
        ps[0] = p;
    }

    /// @dev Two roots split the lot: root1 takes `a`, root2 the rest.
    function _two(address forWorker, uint256 total, uint256 a)
        internal
        view
        returns (StakeRouterBase.Path[] memory ps)
    {
        ps = new StakeRouterBase.Path[](2);
        ps[0] = _path(root1Key, root1, forWorker, a, 100e6);
        ps[1] = _path(root2Key, root2, forWorker, total - a, 100e6);
    }

    /// @dev Funds an order for INPUT_COST and originates it through the router, as any relayer may.
    function _bound() internal returns (uint256 id, uint256 loanId) {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        loanId = router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    function _exit() internal {
        router.sync(worker);
        uint256 f1 = router.free(root1);
        uint256 f2 = router.free(root2);
        vm.prank(root1);
        router.withdraw(f1);
        vm.prank(root2);
        router.withdraw(f2);
        vm.prank(lender);
        credit.withdrawFunds(type(uint256).max);
        assertEq(credit.totalShares(), 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function _vault(address who) internal view returns (address) {
        return address(router.vaultOf(who));
    }

    function _holders() internal view returns (uint256) {
        return usdc.balanceOf(address(credit)) + usdc.balanceOf(lender) + usdc.balanceOf(root1) + usdc.balanceOf(root2)
            + usdc.balanceOf(customer) + usdc.balanceOf(vendor) + usdc.balanceOf(worker) + usdc.balanceOf(worker2)
            + usdc.balanceOf(stranger) + usdc.balanceOf(address(router)) + usdc.balanceOf(_vault(worker))
            + usdc.balanceOf(_vault(worker2));
    }

    /// @dev Every base unit created for the test sits with a known holder, and the router's balance is exactly the
    ///      roots' free USDC plus the customers' escrow: the two ledgers never mix.
    function _conserved() internal view {
        assertEq(_holders(), baseline + minted, "every base unit is attributed");
        assertEq(
            usdc.balanceOf(address(router)), router.totalFree() + router.totalEscrowHeld(), "two ledgers, one balance"
        );
    }

    function _repay(address payer, uint256 loanId, uint256 amount) internal {
        _mint(payer, amount);
        vm.startPrank(payer);
        usdc.approve(address(credit), amount);
        credit.repayLoan(loanId, amount);
        vm.stopPrank();
    }

    // ───────────── composed success ─────────────

    function testComposedFlowFundedOrderTwoHopStakeVendorPaymentDebtFirstSettlementAndFullExit() public {
        (uint256 id, uint256 loanId) = _bound();
        assertEq(usdc.balanceOf(vendor), INPUT_COST, "principal went to the signed vendor");
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(worker.balance, 0, "the relayer, not the worker, is the transaction caller");
        assertEq(router.loanOrder(loanId), id);
        // the roots' USDC, not the customer's, is the worker's secured backing
        assertEq(router.locked(root1), 600_000);
        assertEq(router.locked(root2), 400_000);
        assertEq(credit.stakeOf(_vault(worker)), INPUT_COST);
        (uint256 secured, uint256 unsecured) = credit.getBacking(_vault(worker), worker);
        assertEq(secured, INPUT_COST);
        assertEq(unsecured, 0);
        assertEq(router.totalEscrowHeld(), ORDER_PRICE, "the customer's escrow is held apart");
        _conserved();

        vm.prank(customer);
        router.settleOrder(id);
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "debt cleared");
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - INPUT_COST, "exact remainder");
        assertEq(router.totalEscrowHeld(), 0);
        assertEq(router.free(root1), ROOT_FUND, "settlement returned the roots' lot");
        assertEq(router.free(root2), ROOT_FUND);
        assertEq(usdc.allowance(address(router), address(credit)), 0);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY, "first-day repayment: zero interest, reported honestly");
        assertEq(usdc.balanceOf(root1), ROOT_FUND);
        assertEq(usdc.balanceOf(root2), ROOT_FUND);
        assertEq(usdc.balanceOf(address(router)), 0);
        _conserved();
    }

    function testSevenDaySettlementPaysInterestAndLeavesTheProtectedReserve() public {
        (uint256 id,) = _bound();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 interest = INPUT_COST * 933 * 7 days / (10_000 * 365 days);
        vm.prank(customer);
        router.settleOrder(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - INPUT_COST - interest);
        assertEq(credit.firstLossReserve(), interest * 4_500 / 10_000);
        _exit();
        _conserved();
    }

    // ───────────── composed rejection and default ─────────────

    function testRejectionThenDefaultChargesTheRootsExactlyAndLeavesLendersWhole() public {
        (uint256 id, uint256 loanId) = _bound();
        vm.prank(customer);
        router.refundOrder(id); // the customer rejects; the disbursed loan stays the worker's debt
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "escrow refunded in full");
        assertEq(router.totalEscrowHeld(), 0);
        (,,,, bool active) = credit.getLoan(loanId);
        assertTrue(active, "refund never forgives the debt");
        assertEq(router.locked(root1) + router.locked(root2), INPUT_COST, "and never releases the roots' exposure");

        // nobody cures the loan; it defaults after its term and the late period
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        router.sync(worker);

        // the vault's stake was slashed by the unpaid principal: the roots bear all of it, pro rata to their paths
        assertEq(router.lossOf(root1), 600_000);
        assertEq(router.lossOf(root2), 400_000);
        assertEq(
            router.free(root1) + router.free(root2), 2 * ROOT_FUND - INPUT_COST, "the roots keep what they did not lend"
        );
        assertEq(router.totalLocked(), 0);
        assertEq(credit.stakeOf(_vault(worker)), 0);
        assertEq(router.totalEscrowHeld(), 0);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY, "the lender is whole: the roots' stake covered the loss");
        assertEq(usdc.balanceOf(root1) + usdc.balanceOf(root2), 2 * ROOT_FUND - INPUT_COST);
        _conserved();
    }

    function testDefaultAfterPartialRepaymentChargesOnlyTheUnpaidPrincipal() public {
        (, uint256 loanId) = _bound();
        _repay(stranger, loanId, 250_000);
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        router.sync(worker);
        assertEq(router.lossOf(root1) + router.lossOf(root2), INPUT_COST - 250_000, "the loss is the unpaid principal");
        assertEq(router.lossOf(root1), 450_000, "pro rata 60/40 of 750,000");
        assertEq(router.lossOf(root2), 300_000);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY);
        _conserved();
    }

    function testAThirdPartyCuresTheLoanBeforeSettlementAndNothingIsReleasedTwice() public {
        (uint256 id, uint256 loanId) = _bound();
        _repay(stranger, loanId, credit.getCurrentOutstandingAmount(loanId));
        router.sync(worker); // the lot returns because the loan closed, whoever paid
        assertEq(router.free(root1), ROOT_FUND);
        vm.prank(customer);
        router.settleOrder(id); // nothing left to repay: the worker receives the whole price
        assertEq(usdc.balanceOf(worker), ORDER_PRICE);
        assertEq(router.free(root1), ROOT_FUND, "no second release");
        assertEq(router.free(root2), ROOT_FUND);
        _exit();
        _conserved();
    }

    // ───────────── no bypass ─────────────

    function testNoLoanCanExistBeforeTheOrderSoNoneCanBeBoundToIt() public {
        vm.prank(worker);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(INPUT_COST);

        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, poolSig);

        DecentralizedMicrocredit.LoanRequest memory lr = DecentralizedMicrocredit.LoanRequest({
            borrower: worker, amount: INPUT_COST, nonce: credit.nonces(worker), deadline: _deadline()
        });
        bytes memory lrSig = _signLoanRequest(workerKey, lr);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoanMeta(lr, lrSig);
    }

    function testTheRouterHasNoUnboundOriginationEntry() public {
        _rootDeposit(root1, 0 + 1); // keep the root funded; the call below must fail on selector, not on funds
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        (bool ok,) =
            address(router).call(abi.encodeWithSelector(TransitiveStakeRouter.originate.selector, req, poolSig, ps));
        assertFalse(ok, "the unbound router's entry does not exist on the bootstrap router");
        (,,,, bool open) = credit.getLoan(1);
        assertFalse(open);
        assertEq(usdc.balanceOf(vendor), 0);
    }

    function testRefundThenBroadcastTheSignedAdvanceFails() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);

        vm.prank(customer);
        router.refundOrder(id); // the customer rejects before anything is originated
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "refunded in full");

        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderRouter.InvalidOrder.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps); // the commitment is consumed

        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, poolSig); // and the pool refuses any other caller

        assertEq(usdc.balanceOf(vendor), 0, "the vendor was never paid");
        assertEq(router.totalLocked(), 0, "and no root was committed");
    }

    function testASecondOrderWaitsForTheFirstLotAndNeverAttachesTheFirstLoan() public {
        (uint256 first, uint256 loanId) = _bound();
        BootstrapOrderRouter.Intent memory j = _intent(worker, INPUT_COST);
        j.jobHash = keccak256("job-2");
        vm.startPrank(customer);
        usdc.approve(address(router), ORDER_PRICE);
        uint256 second = router.fund(j, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        _approve(second, j.amount);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(j);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, second);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.OpenLot.selector); // one open lot per worker: the first loan is still live
        router.originateOrder(second, req, poolSig, orderSig, ps);

        // the first order settles and returns its lot; only then can the second originate, and it binds its own new loan
        vm.prank(customer);
        router.settleOrder(first);
        vm.prank(relayer);
        uint256 secondLoan = router.originateOrder(second, req, poolSig, orderSig, ps);
        assertTrue(secondLoan != loanId);
        assertEq(router.loanOrder(loanId), first, "the first loan stays with the first order");
        assertEq(router.loanOrder(secondLoan), second, "the second loan binds to the second order");
    }

    // ───────────── exact-intent binding: every field ─────────────

    function _expectMismatch(
        BootstrapOrderRouter.Intent memory i,
        DecentralizedMicrocredit.BorrowAndDisburse memory bad,
        StakeRouterBase.Path[] memory ps
    ) internal {
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, bad);
        bytes memory orderSig = _orderSig(workerKey, id);
        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderRouter.IntentMismatch.selector);
        router.originateOrder(id, bad, poolSig, orderSig, ps);
    }

    function testWrongVendorAmountTermAprNonceDeadlineWorkerAreEachRejected() public {
        _mint(customer, 7 * ORDER_PRICE); // one funded order per tampered request
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        DecentralizedMicrocredit.BorrowAndDisburse memory r = _req(i);
        r.to = stranger;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.amount = INPUT_COST + 1;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.repaymentPeriod = 7 days;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.maxAprBps = 1_000;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.nonce = i.nonce + 1;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.deadline = i.deadline + 1;
        _expectMismatch(i, r, ps);
        r = _req(i);
        r.borrower = stranger;
        _expectMismatch(i, r, ps);
    }

    function testAWorkerAcceptanceOfAnotherJobIsRejected() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        BootstrapOrderRouter.Intent memory j = _intent(worker, INPUT_COST);
        j.jobHash = keccak256("job-2");
        vm.startPrank(customer);
        usdc.approve(address(router), ORDER_PRICE);
        uint256 other = router.fund(j, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        _approve(other, j.amount);
        bytes memory wrong = _orderSig(workerKey, other);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InvalidConsent.selector);
        router.originateOrder(id, req, poolSig, wrong, ps);
    }

    function testUnmanagedWorkerCannotBeOriginatedByTheRouter() public {
        (address other, uint256 otherKey) = makeAddrAndKey("other-worker");
        BootstrapOrderRouter.Intent memory i = _intent(other, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(otherKey, req);
        bytes memory orderSig = _orderSig(otherKey, id);
        StakeRouterBase.Path[] memory ps = _two(other, INPUT_COST, 600_000);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.NotManager.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    function testBackingBeforeTheManagerLocksTheChoiceAndLiveBackingFixesIt() public {
        (address late,) = makeAddrAndKey("late-worker");
        _poolStake(makeAddr("s3"), 1e6);
        vm.prank(makeAddr("s3"));
        credit.back(late, 1e6);
        vm.prank(late);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(router));

        _bound(); // and a live router lot fixes the worker's manager too
        vm.prank(worker);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0));
    }

    // ───────────── replay and duplicate execution ─────────────

    function testReplayAndDuplicateExecutionAreRejected() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        router.originateOrder(id, req, poolSig, orderSig, ps);

        vm.prank(relayer);
        vm.expectRevert(BootstrapOrderRouter.InvalidOrder.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps); // second execution of the same order

        vm.prank(customer);
        router.settleOrder(id);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderRouter.InvalidOrder.selector);
        router.settleOrder(id); // double settlement
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderRouter.InvalidOrder.selector);
        router.refundOrder(id); // refund after settlement
    }

    function testSignaturesDoNotReplayOnAnotherRouterOrChain() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);

        // another router: same pool, same signatures, funded the same way; the pool names only the first router
        BootstrapOrderRouter other = new BootstrapOrderRouter(credit);
        vm.startPrank(customer);
        usdc.approve(address(other), ORDER_PRICE);
        uint256 otherId = other.fund(i, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InvalidConsent.selector); // the worker's acceptance names the first router's domain
        other.originateOrder(otherId, req, poolSig, orderSig, ps);

        // another chain id: the router's domain binds it (acceptance and consents alike)
        vm.chainId(block.chainid + 1);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InvalidConsent.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    // ───────────── settlement edges ─────────────

    function testLateInterestAboveTheCapNeverReleasesWorkerMoney() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, INPUT_COST, 400 days); // cap = principal: any interest exceeds it
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        router.originateOrder(id, req, poolSig, orderSig, ps);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderRouter.DebtExceedsCap.selector);
        router.settleOrder(id);
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(router.totalEscrowHeld(), ORDER_PRICE, "funds stay escrowed");
    }

    function testPartialRepaymentByAnyoneReducesWhatSettleRepays() public {
        (uint256 id, uint256 loanId) = _bound();
        _repay(stranger, loanId, 50_000);
        vm.prank(customer);
        router.settleOrder(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - (INPUT_COST - 50_000));
        _exit();
        _conserved();
    }

    function testDefaultedLoanCannotBeSettled() public {
        (uint256 id, uint256 loanId) = _bound();
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
        vm.prank(customer);
        vm.expectRevert(BootstrapOrderRouter.InvalidLoan.selector);
        router.settleOrder(id);
        vm.prank(customer);
        router.refundOrder(id);
        router.sync(worker);
        _exit();
        _conserved();
    }

    function testExpiredOrderRefundsOnlyTheOriginalPayer() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 3 days);
        vm.prank(stranger);
        vm.expectRevert(BootstrapOrderRouter.Unauthorized.selector);
        router.refundOrder(id);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.prank(stranger);
        router.refundOrder(id);
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function testUnauthorizedSettlementCannotReleaseFunds() public {
        (uint256 id,) = _bound();
        vm.prank(worker);
        vm.expectRevert(BootstrapOrderRouter.Unauthorized.selector);
        router.settleOrder(id);
        assertEq(router.totalEscrowHeld(), ORDER_PRICE);
    }

    function testRelayerWhitelistMustNameTheRouter() public {
        vm.prank(owner);
        credit.setRelayerWhitelistEnabled(true);
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        vm.prank(relayer);
        vm.expectRevert(); // the pool refuses a relayer it has not whitelisted: the router itself
        router.originateOrder(id, req, poolSig, orderSig, ps);
        vm.prank(owner);
        credit.setRelayerWhitelisted(address(router), true);
        vm.prank(relayer);
        router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    // ───────────── shared root-to-mid budget across workers ─────────────

    function testTheSameRootToMidBudgetBindsTwoWorkersOrders() public {
        // root cash is not the limit (2 USDC free); the relationship cap is: 1.5 USDC live across all workers
        uint256 cap = 1_500_000;
        BootstrapOrderRouter.Intent memory i1 = _intent(worker, INPUT_COST);
        uint256 id1 = _fund(i1, ORDER_PRICE, 120 days);
        StakeRouterBase.Path[] memory p1 = _one(_path(root1Key, root1, worker, INPUT_COST, cap));
        DecentralizedMicrocredit.BorrowAndDisburse memory r1 = _req(i1);
        vm.prank(relayer);
        router.originateOrder(id1, r1, _signBorrowAndDisburse(workerKey, r1), _orderSig(workerKey, id1), p1);

        BootstrapOrderRouter.Intent memory i2 = _intent(worker2, INPUT_COST);
        uint256 id2 = _fund(i2, ORDER_PRICE, 120 days);
        _rootDeposit(root1, ROOT_FUND); // root1 now has plenty of free cash
        StakeRouterBase.Path[] memory p2 = _one(_path(root1Key, root1, worker2, INPUT_COST, cap));
        DecentralizedMicrocredit.BorrowAndDisburse memory r2 = _req(i2);
        bytes memory s2 = _signBorrowAndDisburse(worker2Key, r2);
        bytes memory o2 = _orderSig(worker2Key, id2);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.LimitExceeded.selector);
        router.originateOrder(id2, r2, s2, o2, p2); // 1.0 + 1.0 > 1.5 although root1 holds 1.0 free

        vm.prank(customer);
        router.settleOrder(id1); // the first loan closes and its lot is released
        vm.prank(relayer);
        router.originateOrder(id2, r2, s2, o2, p2);
        assertEq(router.edgeUsed(router.edgeKey(root1, mid1, address(0))), INPUT_COST);
    }

    // ───────────── ledger separation ─────────────

    function testRootsCannotWithdrawEscrowAndRefundsCannotTouchRootFunds() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        _fund(i, ORDER_PRICE, 120 days);
        address newRoot = makeAddr("newRoot");
        vm.prank(newRoot);
        vm.expectRevert(StakeRouterBase.InsufficientFree.selector);
        router.withdraw(1); // the router holds the customer's escrow, but a root with no free balance gets nothing
        vm.prank(root1);
        router.withdraw(ROOT_FUND);
        vm.prank(root1);
        vm.expectRevert(StakeRouterBase.InsufficientFree.selector);
        router.withdraw(1); // and a root cannot reach past its own free balance into the escrow
        _conserved();
        vm.prank(customer);
        router.refundOrder(1);
        assertEq(router.free(root2), ROOT_FUND, "a refund moves only the customer's escrow");
        _conserved();
    }

    function testEscrowIsNeverCountedAsBacking() public {
        // the customer's escrow is large; the roots' free cash is too small for the lot: origination fails
        // rather than borrowing against the escrow
        vm.prank(root1);
        router.withdraw(ROOT_FUND);
        vm.prank(root2);
        router.withdraw(ROOT_FUND - 100_000);
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _one(_path(root2Key, root2, worker, INPUT_COST, 100e6));
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InsufficientFree.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps);
        assertEq(router.totalEscrowHeld(), ORDER_PRICE);
    }

    // ───────────── conservation under any input size ─────────────

    function testFuzzEverySettledUnitIsConserved(uint256 input, uint256 split) public {
        input = bound(input, 1e6, ORDER_PRICE);
        split = bound(split, 1, input - 1);
        BootstrapOrderRouter.Intent memory i = _intent(worker, input);
        _rootDeposit(root1, ORDER_PRICE); // enough free cash for any split
        _rootDeposit(root2, ORDER_PRICE);
        vm.startPrank(customer);
        usdc.approve(address(router), ORDER_PRICE);
        uint256 id = router.fund(i, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        _approve(id, i.amount);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, input, split);
        vm.prank(relayer);
        router.originateOrder(id, req, poolSig, orderSig, ps);
        _conserved();
        vm.prank(customer);
        router.settleOrder(id);
        assertEq(usdc.balanceOf(worker), ORDER_PRICE - input);
        assertEq(usdc.balanceOf(vendor), input);
        _exit();
        _conserved();
    }

    // ───────────── the officer gate (second gate; the roots' consents and balances stay the first) ─────────────

    function _originateFor(uint256 id, BootstrapOrderRouter.Intent memory i, uint256 split) internal returns (uint256) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, i.amount, split);
        vm.prank(relayer);
        return router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    function testNoApprovalNoOrigination() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fundUnapproved(i, ORDER_PRICE, 120 days);
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        this.originateExternal(id, i, 600_000);
        assertEq(usdc.balanceOf(vendor), 0, "the vendor was never paid");
        assertEq(router.totalLocked(), 0, "and no root was committed");
        _approve(id, i.amount);
        _originateFor(id, i, 600_000); // with the approval, the same call succeeds
    }

    /// @dev External wrapper so vm.expectRevert sees one call (helper calls consume it).
    function originateExternal(uint256 id, BootstrapOrderRouter.Intent memory i, uint256 split) external {
        _originateFor(id, i, split);
    }

    function testRouterStartsWithoutAnOfficerAndFailsClosed() public {
        BootstrapOrderRouter fresh = new BootstrapOrderRouter(credit);
        assertEq(fresh.officer(), address(0));
        assertEq(fresh.officerAdmin(), address(this));
        // no officer: even a well-formed signature by anyone cannot be recorded
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        vm.startPrank(customer);
        usdc.approve(address(fresh), ORDER_PRICE);
        uint256 id = fresh.fund(i, ORDER_PRICE, ORDER_PRICE, block.timestamp + 120 days);
        vm.stopPrank();
        (,,,, bytes32 ih,,) = fresh.orders(id);
        BootstrapOrderRouter.JobApproval memory a = BootstrapOrderRouter.JobApproval(
            id, ih, i.amount, block.timestamp + 1 days, fresh.policyVersion(), fresh.officerEpoch()
        );
        bytes memory sig = _signDigest(officerKey, fresh.approvalDigest(a));
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        fresh.approveOrder(a, sig);
    }

    function testAnApprovalBelowTheAmountCannotOriginate() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fundUnapproved(i, ORDER_PRICE, 120 days);
        _approve(id, i.amount - 1); // the officer may approve less, which refuses this exact order
        vm.expectRevert(BootstrapOrderRouter.ApprovalTooSmall.selector);
        this.originateExternal(id, i, 600_000);
    }

    function testAValidApprovalNeverCreatesCapacity() public {
        // the approval allows a huge amount, but one root holds only ROOT_FUND free: capacity is re-derived at execution
        BootstrapOrderRouter.Intent memory i = _intent(worker, ORDER_PRICE);
        uint256 id = _fundUnapproved(i, ORDER_PRICE, 120 days);
        _approve(id, type(uint128).max);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _one(_path(root1Key, root1, worker, ORDER_PRICE, 100e6));
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InsufficientFree.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps);
        assertEq(router.totalLocked(), 0, "nothing was committed");
        assertEq(usdc.balanceOf(vendor), 0, "the vendor was never paid");
    }

    function testRevokingTheGraphDefeatsAValidApprovalWithoutTouchingIt() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000); // consents signed at the current version
        vm.prank(root1);
        router.revokeRootEdge(mid1); // the root withdraws its consent: the graph version moves
        (uint256 maxBefore,,,) = router.approvals(id);
        vm.prank(relayer);
        vm.expectRevert(StakeRouterBase.InvalidConsent.selector);
        router.originateOrder(id, req, poolSig, orderSig, ps);
        (uint256 maxAfter,,,) = router.approvals(id);
        assertEq(maxAfter, maxBefore, "the approval is untouched: the two gates are independent");
        assertEq(router.totalLocked(), 0);
    }

    function testRotatingOrRevokingTheOfficerVoidsUnusedApprovalsAndMovesNoMoney() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        uint256 free1 = router.free(root1);
        uint256 free2 = router.free(root2);
        uint256 held = router.totalEscrowHeld();
        uint256 routerCash = usdc.balanceOf(address(router));

        router.setOfficer(officer, 2); // same key, new policy version and epoch
        assertEq(router.free(root1), free1);
        assertEq(router.free(root2), free2);
        assertEq(router.totalEscrowHeld(), held);
        assertEq(usdc.balanceOf(address(router)), routerCash, "rotation moves no money");
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        this.originateExternal(id, i, 600_000); // the old approval is void under the new epoch and policy

        _approve(id, i.amount); // the officer signs again under the new version
        _originateFor(id, i, 600_000);

        // revoking by the officer itself stops new admissions at once
        BootstrapOrderRouter.Intent memory j = _intent(worker, INPUT_COST);
        j.jobHash = keccak256("job-2");
        uint256 id2 = _fund(j, ORDER_PRICE, 120 days);
        vm.prank(officer);
        router.revokeOfficer();
        assertEq(router.officer(), address(0));
        (BootstrapOrderRouter.JobApproval memory a, bytes memory sig) = _approval(id2, j.amount);
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        router.approveOrder(a, sig);
    }

    function testRotationWithTheSamePolicyStillVoidsOldApprovals() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        (BootstrapOrderRouter.JobApproval memory stale, bytes memory staleSig) = _approval(id, i.amount);
        router.setOfficer(officer, router.policyVersion()); // same key, same policy, new epoch
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        this.originateExternal(id, i, 600_000); // the approval recorded before the rotation is void
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        router.approveOrder(stale, staleSig); // and a signature made under the old epoch is not recorded either
        _approve(id, i.amount);
        _originateFor(id, i, 600_000);
    }

    function testOnlyTheAdminOrTheOfficerCanChangeTheOfficer() public {
        vm.prank(stranger);
        vm.expectRevert(BootstrapOrderRouter.NotOfficerAdmin.selector);
        router.setOfficer(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(BootstrapOrderRouter.NotOfficerAdmin.selector);
        router.revokeOfficer();
        vm.prank(stranger);
        vm.expectRevert(BootstrapOrderRouter.NotOfficerAdmin.selector);
        router.setOfficerAdmin(stranger);
        // the officer cannot name its successor or the admin
        vm.prank(officer);
        vm.expectRevert(BootstrapOrderRouter.NotOfficerAdmin.selector);
        router.setOfficer(officer, 9);
    }

    function testAnApprovalForOneOrderCannotBeUsedForAnother() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id1 = _fundUnapproved(i, ORDER_PRICE, 120 days);
        BootstrapOrderRouter.Intent memory j = _intent(worker, INPUT_COST);
        j.jobHash = keccak256("job-2");
        uint256 id2 = _fundUnapproved(j, ORDER_PRICE, 120 days);
        (BootstrapOrderRouter.JobApproval memory a, bytes memory sig) = _approval(id1, i.amount);
        a.orderId = id2; // the signature binds the order id and the intent hash
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector); // wrong intent hash for order 2
        router.approveOrder(a, sig);
        (,,,, bytes32 ih2,,) = router.orders(id2);
        a.intentHash = ih2; // the right intent for order 2, but the officer signed order 1
        vm.expectRevert(StakeRouterBase.InvalidConsent.selector);
        router.approveOrder(a, sig);
    }

    function testAnOutageStopsNewAdmissionsOnlyAndLeavesEveryExitWorking() public {
        (uint256 id, uint256 loanId) = _bound();
        BootstrapOrderRouter.Intent memory j = _intent(worker2, INPUT_COST);
        uint256 open = _fund(j, ORDER_PRICE, 120 days); // funded and approved, not yet originated
        // the officer vanishes and, worse, becomes a contract that reverts on every call
        router.setOfficer(address(new AlwaysReverts()), 2);

        // repayment by anyone, third-party cure and settlement read no officer state
        vm.startPrank(stranger);
        usdc.approve(address(credit), type(uint256).max);
        _mint(stranger, INPUT_COST);
        vm.stopPrank();
        uint256 debt = credit.getCurrentOutstandingAmount(loanId);
        vm.startPrank(stranger);
        usdc.approve(address(credit), debt);
        credit.repayLoan(loanId, debt);
        vm.stopPrank();
        vm.prank(customer);
        router.settleOrder(id);
        router.sync(worker);
        // the unoriginated order cannot be admitted, but its customer refunds at once
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        this.originateWorker2(open, j, 600_000);
        uint256 before = usdc.balanceOf(customer);
        vm.prank(customer);
        router.refundOrder(open);
        assertEq(usdc.balanceOf(customer) - before, ORDER_PRICE);
        // and a root withdraws its free cash
        uint256 f = router.free(root1);
        vm.prank(root1);
        router.withdraw(f);
        assertEq(router.free(root1), 0);
    }

    function originateWorker2(uint256 id, BootstrapOrderRouter.Intent memory i, uint256 split) external {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(worker2Key, req);
        bytes memory orderSig = _orderSig(worker2Key, id);
        StakeRouterBase.Path[] memory ps = _two(worker2, i.amount, split);
        vm.prank(relayer);
        router.originateOrder(id, req, poolSig, orderSig, ps);
    }

    function testGrantedCreditDoesNotLetAManagedWorkerSkipTheOfficer() public {
        // an owner override or oracle line is capacity the officer did not approve; the manager gate still
        // refuses every caller but the router, and the router refuses without an approval
        vm.prank(owner);
        credit.setScoreOverride(worker, 1e6);
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fundUnapproved(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, poolSig);
        vm.expectRevert(BootstrapOrderRouter.NoApproval.selector);
        this.originateExternal(id, i, 600_000);
    }
}

/// @dev A stand-in for a broken or hostile officer contract: every call reverts.
contract AlwaysReverts {
    fallback() external {
        revert("officer down");
    }
}
