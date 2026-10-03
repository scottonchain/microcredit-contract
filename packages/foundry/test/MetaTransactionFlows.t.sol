// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev State effects of each gasless (relayer-submitted) entry point.
contract MetaTransactionFlowsTest is MicrocreditTestBase {
    uint256 internal constant LOAN_APR = 933; // 4.33% EFFR + 5% premium
    uint256 internal constant POOL = 10_000e6;

    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    uint256 internal lenderPk = 0x1E4D;
    address internal lender = vm.addr(lenderPk);
    uint256 internal attesterPk = 0xA77E;
    address internal attester = vm.addr(attesterPk);
    address internal poolLender = makeAddr("poolLender");

    event MetaLoanCreated(
        address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate, uint256 repaymentPeriod
    );
    event MetaLoanDisbursed(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaDeposit(address indexed lender, uint256 amount, address indexed receiver, uint256 sharesMinted);
    event MetaWithdrawalRequested(address indexed lender, uint256 indexed queueId, uint256 amount, address indexed to);
    event MetaWithdrawalFilled(uint256 indexed queueId, uint256 amountFilled);
    event MetaAttested(address indexed attester, address indexed borrower, uint256 weight);
    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, address indexed to, uint256 assets, uint256 shares);
    event LoanRequested(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate);
    event LoanDisbursed(address indexed borrower, uint256 indexed loanId, address to, uint256 amount);
    event Attested(address indexed attester, address indexed borrower, uint256 weight);

    function setUp() public {
        _deploy(433, 500, 100e6);
        _relaxSybilGuards();
        _deposit(poolLender, POOL);
        vm.prank(owner);
        credit.setScoreOverride(borrower, 500_000); // 50% -> may borrow up to 50 USDC
        vm.prank(oracle);
        credit.markKYCVerified(attester); // trust anchor for attestations
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _borrowRequest(uint256 amount, uint256 maxApr)
        internal
        view
        returns (DecentralizedMicrocredit.BorrowAndDisburse memory)
    {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: amount,
            to: borrower,
            repaymentPeriod: 28 days,
            maxAprBps: maxApr,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
    }

    function _borrow(uint256 amount) internal returns (uint256 loanId) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(amount, LOAN_APR);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, sig);
        uint256[] memory ids = credit.getBorrowerLoanIds(borrower);
        loanId = ids[ids.length - 1];
    }

    function _repayRequest(uint256 loanId, uint256 amount)
        internal
        view
        returns (DecentralizedMicrocredit.RepayRequest memory)
    {
        return DecentralizedMicrocredit.RepayRequest({
            borrower: borrower, loanId: loanId, amount: amount, nonce: credit.nonces(borrower), deadline: _deadline()
        });
    }

    function _attest(address to, uint256 weight) internal {
        DecentralizedMicrocredit.AttestRequest memory req = DecentralizedMicrocredit.AttestRequest({
            attester: attester, borrower: to, weight: weight, nonce: credit.nonces(attester), deadline: _deadline()
        });
        bytes memory sig = _signAttestRequest(attesterPk, req);
        vm.prank(relayer);
        credit.attestMeta(req, sig);
    }

    function _depositPermitOnly(address depositor, uint256 depositorPk, uint256 amount) internal {
        usdc.mint(depositor, amount);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(depositorPk, amount, _deadline());
        vm.prank(relayer);
        credit.depositPermitOnlyMeta(depositor, permit);
    }

    // ───────────────────────────── borrowAndDisburseMeta ─────────────────────────────

    function testBorrowAndDisburseCreatesAndDisbursesLoan() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(40e6, LOAN_APR);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        vm.expectEmit(address(credit));
        emit MetaLoanCreated(borrower, 1, 40e6, LOAN_APR, 28 days);
        vm.expectEmit(address(credit));
        emit MetaLoanDisbursed(borrower, 1, 40e6);
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, sig);

        assertEq(usdc.balanceOf(borrower), 40e6);
        assertEq(credit.totalLentOut(), 40e6);
        assertEq(credit.reservedLiquidity(), 0);
        assertEq(credit.nonces(borrower), 1);
        (uint256 principal, uint256 outstanding, address loanBorrower, uint256 rate, bool active) = credit.getLoan(1);
        assertEq(principal, 40e6);
        assertEq(outstanding, 40e6);
        assertEq(loanBorrower, borrower);
        assertEq(rate, LOAN_APR);
        assertTrue(active);
    }

    function testBorrowAndDisburseLoansAreEnumerated() public {
        uint256 loanId = _borrow(40e6);
        assertEq(credit.getAllLoanIds().length, 1);
        assertEq(credit.getAllLoanIds()[0], loanId);
        assertEq(credit.getBorrowers().length, 1);
        assertEq(credit.getBorrowers()[0], borrower);
    }

    function testBorrowAndDisburseRevertsWhenAprAboveTolerance() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(40e6, LOAN_APR - 1);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert("APR changed");
        credit.borrowAndDisburseMeta(req, sig);
    }

    function testBorrowAndDisburseEnforcesScoreLimit() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(50e6 + 1, LOAN_APR);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert();
        credit.borrowAndDisburseMeta(req, sig);
    }

    function testBorrowAndDisburseCountsExistingLoans() public {
        _borrow(30e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(30e6, LOAN_APR);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert("Outstanding loans exceed max");
        credit.borrowAndDisburseMeta(req, sig);
    }

    function testBorrowAndDisburseEnforcesLiquidityBuffer() public {
        vm.startPrank(owner);
        credit.setMaxLoanAmount(POOL);
        credit.setScoreOverride(borrower, SCALE);
        credit.setLendingUtilizationCap(10_000); // only the 5% buffer should bind
        vm.stopPrank();

        DecentralizedMicrocredit.BorrowAndDisburse memory req = _borrowRequest(9_600e6, LOAN_APR);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.borrowAndDisburseMeta(req, sig);
    }

    // ───────────────────────────── attestMeta ─────────────────────────────

    function testAttestMetaRecordsAttestationAndScore() public {
        address newcomer = makeAddr("newcomer");
        vm.expectEmit(address(credit));
        emit MetaAttested(attester, newcomer, 800_000);
        _attest(newcomer, 800_000);

        DecentralizedMicrocredit.Attestation[] memory atts = credit.getBorrowerAttestations(newcomer);
        assertEq(atts.length, 1);
        assertEq(atts[0].attester, attester);
        assertEq(atts[0].weight, 800_000);
        assertEq(credit.nonces(attester), 1);
        assertEq(credit.getAttesters()[0], attester);
        assertGt(credit.getCreditScore(newcomer), 0, "PageRank recomputed on attestation");
    }

    function testAttestMetaUpdatesExistingWeight() public {
        address newcomer = makeAddr("newcomer");
        _attest(newcomer, 800_000);
        _attest(newcomer, 300_000);

        DecentralizedMicrocredit.Attestation[] memory atts = credit.getBorrowerAttestations(newcomer);
        assertEq(atts.length, 1);
        assertEq(atts[0].weight, 300_000);
        assertEq(credit.getAttesters().length, 1);
    }

    function testAttestMetaRejectsSelfAttestationAndOverweight() public {
        DecentralizedMicrocredit.AttestRequest memory req = DecentralizedMicrocredit.AttestRequest({
            attester: attester, borrower: attester, weight: 1, nonce: 0, deadline: _deadline()
        });
        bytes memory sig = _signAttestRequest(attesterPk, req);
        vm.prank(relayer);
        vm.expectRevert("Self-attestation");
        credit.attestMeta(req, sig);

        req.borrower = borrower;
        req.weight = SCALE + 1;
        sig = _signAttestRequest(attesterPk, req);
        vm.prank(relayer);
        vm.expectRevert("Weight too high");
        credit.attestMeta(req, sig);
    }

    // ───────────────────────────── deposits ─────────────────────────────

    function testDepositWithPermitMeta() public {
        usdc.mint(lender, 1_000e6);
        DecentralizedMicrocredit.DepositRequest memory req = DecentralizedMicrocredit.DepositRequest({
            lender: lender, amount: 1_000e6, receiver: lender, nonce: 0, deadline: _deadline()
        });
        bytes memory sig = _signDepositRequest(lenderPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(lenderPk, 1_000e6, _deadline());

        vm.expectEmit(address(credit));
        emit MetaDeposit(lender, 1_000e6, lender, credit.convertToShares(1_000e6));
        vm.prank(relayer);
        credit.depositWithPermitMeta(req, sig, permit);

        assertEq(credit.totalAssets(), POOL + 1_000e6);
        assertEq(credit.lenderBalance(lender), 1_000e6);
        assertEq(credit.lenderCount(), 2);
        assertEq(credit.getLenders()[1], lender);
        assertEq(credit.nonces(lender), 1);
    }

    function testDepositWithPermitMetaCreditsSignedReceiver() public {
        address receiver = makeAddr("receiver");
        usdc.mint(lender, 1_000e6);
        DecentralizedMicrocredit.DepositRequest memory req = DecentralizedMicrocredit.DepositRequest({
            lender: lender, amount: 1_000e6, receiver: receiver, nonce: 0, deadline: _deadline()
        });
        bytes memory sig = _signDepositRequest(lenderPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(lenderPk, 1_000e6, _deadline());

        vm.expectEmit(address(credit));
        emit Deposited(receiver, 1_000e6, credit.convertToShares(1_000e6));
        vm.prank(relayer);
        credit.depositWithPermitMeta(req, sig, permit);

        assertEq(credit.lenderBalance(receiver), 1_000e6);
        assertEq(credit.lenderBalance(lender), 0);
        assertEq(usdc.balanceOf(lender), 0, "funds come from the signer");
    }

    function testDepositWithPermitMetaRejectsShortPermit() public {
        usdc.mint(lender, 1_000e6);
        DecentralizedMicrocredit.DepositRequest memory req = DecentralizedMicrocredit.DepositRequest({
            lender: lender, amount: 1_000e6, receiver: lender, nonce: 0, deadline: _deadline()
        });
        bytes memory sig = _signDepositRequest(lenderPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(lenderPk, 999e6, _deadline());
        vm.prank(relayer);
        vm.expectRevert("Permit value too low");
        credit.depositWithPermitMeta(req, sig, permit);
    }

    function testDepositPermitOnlyMetaCountsLenderOnce() public {
        _depositPermitOnly(lender, lenderPk, 500e6);
        _depositPermitOnly(lender, lenderPk, 250e6);

        assertEq(credit.lenderBalance(lender), 750e6);
        assertEq(credit.totalAssets(), POOL + 750e6);
        assertEq(credit.lenderCount(), 2);
        assertEq(credit.getLenders().length, 2);
    }

    // ───────────────────────────── withdrawal queue ─────────────────────────────

    function _requestWithdrawal(uint256 amount, address to) internal {
        DecentralizedMicrocredit.RequestWithdrawal memory req = DecentralizedMicrocredit.RequestWithdrawal({
            lender: lender, amount: amount, to: to, nonce: credit.nonces(lender), deadline: _deadline()
        });
        bytes memory sig = _signRequestWithdrawal(lenderPk, req);
        vm.prank(relayer);
        credit.requestWithdrawalMeta(req, sig);
    }

    /// @dev Lends every deposited USDC to `borrower`, leaving nothing liquid.
    function _lendOutWholePool() internal returns (uint256 loanId) {
        uint256 pool = credit.totalAssets();
        vm.startPrank(owner);
        credit.setMaxLoanAmount(pool);
        credit.setScoreOverride(borrower, SCALE);
        credit.setLendingUtilizationCap(10_000);
        credit.setLiquidityLimits(0, 0);
        vm.stopPrank();
        vm.prank(borrower);
        loanId = credit.requestLoan(pool);
        credit.disburseLoan(loanId);
        assertEq(usdc.balanceOf(address(credit)), 0);
    }

    function testWithdrawalFillsImmediatelyWhenLiquid() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        address payout = makeAddr("payout");

        vm.expectEmit(address(credit));
        emit MetaWithdrawalRequested(lender, 0, 400e6, payout);
        vm.expectEmit(address(credit));
        emit MetaWithdrawalFilled(0, 400e6);
        _requestWithdrawal(400e6, payout);

        assertEq(usdc.balanceOf(payout), 400e6);
        assertEq(credit.lenderBalance(lender), 600e6);
        assertEq(credit.totalAssets(), POOL + 600e6);
    }

    function testWithdrawalQueuesUntilDepositsRestoreLiquidity() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();

        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);
        assertEq(usdc.balanceOf(payout), 0, "queued, not paid");
        assertEq(credit.lenderBalance(lender), 1_000e6);

        // A new deposit partially fills the head of the queue...
        address other = vm.addr(0x07E4);
        _depositPermitOnly(other, 0x07E4, 400e6);
        assertEq(usdc.balanceOf(payout), 400e6);
        assertEq(credit.lenderBalance(lender), 600e6);

        // ...and the next one completes it.
        _depositPermitOnly(other, 0x07E4, 1_000e6);
        assertEq(usdc.balanceOf(payout), 1_000e6);
        assertEq(credit.lenderBalance(lender), 0);
    }

    function testQueuedFundsCannotBeQueuedOrWithdrawnTwice() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();
        _requestWithdrawal(1_000e6, lender);
        assertEq(credit.queuedWithdrawals(lender), 1_000e6);

        DecentralizedMicrocredit.RequestWithdrawal memory again = DecentralizedMicrocredit.RequestWithdrawal({
            lender: lender, amount: 1_000e6, to: lender, nonce: credit.nonces(lender), deadline: _deadline()
        });
        bytes memory sig = _signRequestWithdrawal(lenderPk, again);
        vm.prank(relayer);
        vm.expectRevert("Insufficient balance");
        credit.requestWithdrawalMeta(again, sig);

        vm.prank(lender);
        vm.expectRevert("Insufficient balance");
        credit.withdrawFunds(1);
    }

    function testRepaymentFillsWithdrawalQueue() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        uint256 loanId = _lendOutWholePool();
        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);

        vm.startPrank(borrower);
        usdc.approve(address(credit), 1_000e6);
        credit.repayLoan(loanId, 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(payout), 1_000e6);
        assertEq(credit.lenderBalance(lender), 0);
        assertEq(credit.queuedWithdrawals(lender), 0);
    }

    function testDirectDepositFillsWithdrawalQueue() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();
        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);

        _deposit(makeAddr("newLender"), 1_000e6);
        assertEq(usdc.balanceOf(payout), 1_000e6);
    }

    function testStrayTransferIsNotPoolLiquidity() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();
        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);

        // USDC sent straight to the contract is not lenders' cash: it neither fills the queue
        // nor funds a direct withdrawal.
        usdc.mint(address(credit), 1_500e6);
        vm.prank(poolLender);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.withdrawFunds(1);
        assertEq(usdc.balanceOf(payout), 0);
    }

    function testDirectWithdrawalCannotJumpTheQueue() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();
        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);

        // A direct withdrawal only gets what is left after the queued request is paid.
        _deposit(makeAddr("newLender"), 1_500e6);
        vm.prank(poolLender);
        credit.withdrawFunds(500e6);
        assertEq(usdc.balanceOf(payout), 1_000e6);
        assertEq(usdc.balanceOf(poolLender), 500e6);

        vm.prank(poolLender);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.withdrawFunds(1);
    }

    /// @dev Queues `count` requests of 10 USDC against a drained pool, then deposits 500 USDC,
    ///      enough for all of them.
    function _queuedRequestsThenRefill(uint256 count) internal returns (address payout) {
        _depositPermitOnly(lender, lenderPk, count * 10e6);
        _lendOutWholePool();
        payout = makeAddr("payout");
        for (uint256 i = 0; i < count; i++) {
            _requestWithdrawal(10e6, payout);
        }
        _deposit(makeAddr("newLender"), 500e6);
    }

    function testQueueFillIsBoundedPerCall() public {
        address payout = _queuedRequestsThenRefill(11);
        assertEq(usdc.balanceOf(payout), 100e6, "one call fills at most 10 requests");
        assertEq(credit.totalQueuedWithdrawals(), 10e6);

        credit.processWithdrawalQueue(10);
        assertEq(usdc.balanceOf(payout), 110e6);
        assertEq(credit.totalQueuedWithdrawals(), 0);
        assertEq(credit.queuedWithdrawals(lender), 0);
    }

    function testLiquidityOwedToQueueIsNotLent() public {
        _queuedRequestsThenRefill(11); // 400 USDC liquid, 10 USDC of it still owed to the queue

        vm.prank(owner);
        credit.setMaxLoanAmount(type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.requestLoan(391e6);
        vm.prank(borrower);
        credit.requestLoan(390e6);

        (, uint256 available,,) = credit.getPoolInfo();
        assertEq(available, 0);
    }

    function testLiquidityOwedToQueueIsNotWithdrawn() public {
        // The deposit pays 10 requests and the withdrawal's own fill pays 10 more, so 10 USDC
        // is still queued out of the 300 USDC left.
        address payout = _queuedRequestsThenRefill(21);

        vm.prank(poolLender);
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.withdrawFunds(291e6);
        vm.prank(poolLender);
        credit.withdrawFunds(290e6);

        assertEq(usdc.balanceOf(payout), 200e6);
        assertEq(credit.totalQueuedWithdrawals(), 10e6);
        assertEq(usdc.balanceOf(address(credit)), 10e6);
    }

    function testPartialFillThenDirectWithdrawalKeepsQueueOrder() public {
        _depositPermitOnly(lender, lenderPk, 1_000e6);
        _lendOutWholePool();
        address payout = makeAddr("payout");
        _requestWithdrawal(1_000e6, payout);

        _deposit(makeAddr("newLender"), 400e6); // partial fill
        assertEq(usdc.balanceOf(payout), 400e6);

        vm.prank(makeAddr("newLender"));
        vm.expectRevert("LIQUIDITY_BELOW_THRESHOLD");
        credit.withdrawFunds(1e6);
        assertEq(credit.queuedWithdrawals(lender), 600e6);
    }

    function testWithdrawalRequestRejectsMoreThanDeposited() public {
        _depositPermitOnly(lender, lenderPk, 100e6);
        DecentralizedMicrocredit.RequestWithdrawal memory req = DecentralizedMicrocredit.RequestWithdrawal({
            lender: lender, amount: 100e6 + 1, to: lender, nonce: 0, deadline: _deadline()
        });
        bytes memory sig = _signRequestWithdrawal(lenderPk, req);
        vm.prank(relayer);
        vm.expectRevert("Insufficient balance");
        credit.requestWithdrawalMeta(req, sig);
    }

    // ───────────────────────────── repayLoanMeta ─────────────────────────────

    // ───────────────────────────── permit front-running ─────────────────────────────

    /// @dev Submitting a user's permit before the relayer does must not block the relayed call.
    function _frontRun(DecentralizedMicrocredit.PermitData memory p, address holder) internal {
        vm.prank(makeAddr("frontRunner"));
        usdc.permit(holder, address(credit), p.value, p.deadline, p.v, p.r, p.s);
    }

    function testDepositPermitOnlySurvivesFrontRunPermit() public {
        usdc.mint(lender, 500e6);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(lenderPk, 500e6, _deadline());
        _frontRun(permit, lender);

        vm.prank(relayer);
        credit.depositPermitOnlyMeta(lender, permit);
        assertEq(credit.lenderBalance(lender), 500e6);
    }

    function testRepayLoanMetaSurvivesFrontRunPermit() public {
        uint256 loanId = _borrow(40e6);
        DecentralizedMicrocredit.RepayRequest memory req = _repayRequest(loanId, 0);
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, 40e6, _deadline());
        _frontRun(permit, borrower);

        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, permit);
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
    }

    function testRepayWithPermitSurvivesFrontRunPermit() public {
        uint256 loanId = _borrow(40e6);
        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, 40e6, _deadline());
        _frontRun(p, borrower);

        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 0, p.value, p.deadline, p.v, p.r, p.s);
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
    }

    function testInvalidPermitWithoutAllowanceStillReverts() public {
        usdc.mint(lender, 500e6);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(lenderPk, 500e6, _deadline());
        permit.s = bytes32(uint256(permit.s) ^ 1);

        vm.prank(relayer);
        vm.expectRevert("Permit failed");
        credit.depositPermitOnlyMeta(lender, permit);
    }

    // ───────────────────────────── events ─────────────────────────────

    function testLifecycleEvents() public {
        vm.expectEmit(address(credit));
        emit Attested(attester, borrower, 700_000);
        _attest(borrower, 700_000);

        vm.expectEmit(address(credit));
        emit LoanRequested(borrower, 1, 40e6, LOAN_APR);
        vm.expectEmit(address(credit));
        emit LoanDisbursed(borrower, 1, borrower, 40e6);
        _borrow(40e6);

        vm.expectEmit(address(credit));
        emit Withdrawn(poolLender, poolLender, 100e6, credit.convertToShares(100e6));
        vm.prank(poolLender);
        credit.withdrawFunds(100e6);
    }

    function testRepayLoanMetaRepayAllPullsCurrentOutstanding() public {
        uint256 loanId = _borrow(40e6);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        assertGt(owed, 40e6, "interest accrued after grace period");
        usdc.mint(borrower, owed - 40e6);

        DecentralizedMicrocredit.RepayRequest memory req = _repayRequest(loanId, 0);
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, owed, _deadline());

        vm.expectEmit(address(credit));
        emit MetaLoanRepaid(borrower, loanId, owed);
        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, permit);

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(credit.totalLentOut(), 0);
    }

    function testRepayLoanMetaAfterPartialRepaymentPullsRemainder() public {
        uint256 loanId = _borrow(40e6);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.startPrank(borrower);
        usdc.approve(address(credit), type(uint256).max);
        credit.repayLoan(loanId, 15e6);
        vm.stopPrank();

        uint256 remainder = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, remainder - usdc.balanceOf(borrower));
        DecentralizedMicrocredit.RepayRequest memory req = _repayRequest(loanId, 0);
        bytes memory sig = _signRepayRequest(borrowerPk, req);

        vm.expectEmit(address(credit));
        emit MetaLoanRepaid(borrower, loanId, remainder);
        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, _noPermit());
        assertEq(usdc.balanceOf(borrower), 0);
    }

    function testRepayLoanMetaToleratesOneCentDrift() public {
        uint256 loanId = _borrow(40e6);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, owed - 40e6);
        vm.prank(borrower);
        usdc.approve(address(credit), owed);

        DecentralizedMicrocredit.RepayRequest memory stale = _repayRequest(loanId, owed - 20_000);
        bytes memory sig = _signRepayRequest(borrowerPk, stale);
        vm.prank(relayer);
        vm.expectRevert("OUTSTANDING_CHANGED");
        credit.repayLoanMeta(stale, sig, _noPermit());

        DecentralizedMicrocredit.RepayRequest memory close = _repayRequest(loanId, owed - 5_000);
        sig = _signRepayRequest(borrowerPk, close);
        vm.prank(relayer);
        credit.repayLoanMeta(close, sig, _noPermit());
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 0, "pulls the canonical outstanding");
    }

    function testRepayLoanMetaForgivesSubCentBalance() public {
        uint256 loanId = _borrow(5_000); // half a cent
        DecentralizedMicrocredit.RepayRequest memory req = _repayRequest(loanId, 0);
        bytes memory sig = _signRepayRequest(borrowerPk, req);

        vm.expectEmit(address(credit));
        emit MetaLoanRepaid(borrower, loanId, 0);
        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, _noPermit());

        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active);
        assertEq(usdc.balanceOf(borrower), 5_000, "nothing pulled");
        assertEq(credit.totalLentOut(), 0);
    }
}
