// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Integrated tests of the existing pool primitives, not a settlement adapter, live execution,
///      independent demand, or transitive trust. All funding is minted once in setUp. Time is synthetic.
contract BootstrapReadinessTest is MicrocreditTestBase {
    uint256 internal constant LIQUIDITY = 5e6;
    uint256 internal constant STAKE = 1e6;
    uint256 internal constant CUSTOMER_BUDGET = 1_500_000;
    uint256 internal constant INPUT_COST = 200_000;
    uint256 internal constant ORDER_PRICE = 500_000;
    uint256 internal constant INITIAL_SUPPLY = LIQUIDITY + STAKE + CUSTOMER_BUDGET;

    address internal lender = makeAddr("bootstrap-lender");
    address internal sponsor = makeAddr("bootstrap-sponsor");
    address internal customer = makeAddr("bootstrap-test-customer");
    address internal vendor = makeAddr("bootstrap-input-vendor");
    address internal borrower;
    uint256 internal borrowerKey;

    function setUp() public virtual {
        (borrower, borrowerKey) = makeAddrAndKey("bootstrap-worker");
        _deploy(433, 500, 100e6);
        vm.prank(owner);
        credit.setReserveBps(4_500);
        _deposit(lender, LIQUIDITY);
        _stake(sponsor, STAKE);
        usdc.mint(customer, CUSTOMER_BUDGET);
        vm.prank(sponsor);
        credit.back(borrower, STAKE);
        assertEq(credit.grantedCredit(sponsor), 0);
        assertEq(credit.grantedCredit(borrower), 0);
        assertEq(borrower.balance, 0, "worker starts without ETH");
        assertEq(usdc.balanceOf(borrower), 0, "worker starts without USDC");
    }

    function _request(uint256 amount) internal view returns (DecentralizedMicrocredit.BorrowAndDisburse memory) {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: amount,
            to: vendor,
            repaymentPeriod: 30 days,
            maxAprBps: 933,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
    }

    function _open(uint256 amount) internal returns (uint256 loanId) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _request(amount);
        bytes memory sig = _signBorrowAndDisburse(borrowerKey, req);
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, sig);
        uint256[] memory ids = credit.getBorrowerLoanIds(borrower);
        return ids[ids.length - 1];
    }

    function _pay(uint256 loanId, uint256 amount) internal {
        vm.startPrank(customer);
        usdc.approve(address(credit), amount);
        credit.repayLoan(loanId, amount);
        vm.stopPrank();
    }

    /// The test customer voluntarily follows this order. It is deliberately NOT evidence of an
    /// atomic/consented production escrow. A production adapter needs independent acceptance tests.
    function _payTestOrder(uint256 loanId) internal returns (uint256 debt) {
        debt = credit.getCurrentOutstandingAmount(loanId);
        assertLe(debt, ORDER_PRICE);
        _pay(loanId, debt);
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "debt cleared before this fixture releases the worker remainder");
        vm.prank(customer);
        usdc.transfer(borrower, ORDER_PRICE - debt);
    }

    function _exit() internal {
        vm.startPrank(sponsor);
        credit.back(borrower, 0);
        credit.unstake(credit.stakeOf(sponsor));
        vm.stopPrank();
        vm.prank(lender);
        credit.withdrawFunds(type(uint256).max);
        assertEq(credit.totalShares(), 0);
        assertEq(credit.totalStaked(), 0);
        assertEq(credit.totalLentOut(), 0);
        assertEq(credit.reservedLiquidity(), 0);
    }

    function _conserved() internal view {
        uint256 balances = usdc.balanceOf(address(credit)) + usdc.balanceOf(lender) + usdc.balanceOf(sponsor)
            + usdc.balanceOf(customer) + usdc.balanceOf(vendor) + usdc.balanceOf(borrower);
        assertEq(usdc.totalSupply(), INITIAL_SUPPLY, "no repayment or cure funding was minted later");
        assertEq(balances, INITIAL_SUPPLY, "every base unit remains attributed");
    }

    function testZeroGrantZeroEthBorrowerPaysVendorAndCompletesFirstDayCycle() public {
        uint256 id = _open(INPUT_COST);
        assertEq(usdc.balanceOf(vendor), INPUT_COST);
        assertEq(usdc.balanceOf(borrower), 0, "principal went to signed vendor");
        assertEq(borrower.balance, 0, "relayer, not borrower, is transaction caller");
        assertEq(_payTestOrder(id), INPUT_COST);
        assertEq(usdc.balanceOf(borrower), ORDER_PRICE - INPUT_COST);
        assertEq(credit.duesPaid(borrower), 0, "first-day repayment creates no history credit");
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY, "zero first-day interest, reported honestly");
        assertEq(usdc.balanceOf(sponsor), STAKE);
        assertEq(usdc.balanceOf(address(credit)), 0);
        _conserved();
    }

    function testSevenDayCustomerPaymentFundsInterestAndLeavesProtectedReserve() public {
        uint256 id = _open(INPUT_COST);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 interest = INPUT_COST * 933 * 7 days / (10_000 * 365 days);
        assertEq(_payTestOrder(id), INPUT_COST + interest);
        uint256 reserve = interest * 4_500 / 10_000;
        assertEq(credit.firstLossReserve(), reserve);
        assertEq(credit.duesPaid(borrower), reserve);
        assertEq(credit.grantedCredit(sponsor), 0, "sponsor gains no history credit");
        _exit();
        uint256 lenderReturn = usdc.balanceOf(lender) - LIQUIDITY;
        uint256 rounding = usdc.balanceOf(address(credit)) - reserve;
        assertLe(rounding, 1, "share conversion dust remains attributed");
        assertEq(lenderReturn + reserve + rounding, interest);
        assertGt(lenderReturn, 0, "modelled gross interest, before real gas or default costs");
        emit log_named_uint("interest base units", interest);
        emit log_named_uint("lender gross return base units", lenderReturn);
        emit log_named_uint("protected reserve base units", reserve);
        emit log_named_uint("worker remainder base units", usdc.balanceOf(borrower));
        _conserved();
    }

    function testRejectedOrderUsesSponsorStakeWithoutCustomerOrOperatorCure() public {
        uint256 id = _open(INPUT_COST);
        (,,,, uint256 dueAt) = credit.getLoanTerms(id);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(id);
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "failed test order paid no revenue");
        assertEq(credit.stakeOf(sponsor), STAKE - INPUT_COST);
        assertEq(credit.creditLoss(sponsor), 0, "cash stake, not issued credit, bears this loss");
        assertEq(credit.firstLossReserve(), 0);
        assertEq(credit.defaultedLoans(borrower), 1);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY);
        assertEq(usdc.balanceOf(sponsor), STAKE - INPUT_COST);
        assertEq(usdc.balanceOf(borrower), 0);
        _conserved();
    }

    function testOneRootCannotDoubleAllocateItsStakeOrExitWhileLoansRemain() public {
        address second = makeAddr("second-worker");
        vm.prank(sponsor);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(second, STAKE);
        uint256 firstId = _open(INPUT_COST);
        uint256 secondId = _open(INPUT_COST);
        assertEq(credit.totalLentOut(), 2 * INPUT_COST);
        _pay(firstId, INPUT_COST);
        vm.prank(sponsor);
        vm.expectRevert(DecentralizedMicrocredit.BackingInUse.selector);
        credit.back(borrower, 0);
        vm.prank(sponsor);
        vm.expectRevert(DecentralizedMicrocredit.StakeCommitted.selector);
        credit.unstake(STAKE);
        _pay(secondId, INPUT_COST);
        _exit();
        _conserved();
    }

    function testPartialSubCentPrincipalCannotEscapeTheLoanOrBacking() public {
        uint256 id = _open(9_999);
        _pay(id, 1);
        (,,,, bool active) = credit.getLoan(id);
        assertTrue(active);
        assertEq(credit.totalLentOut(), 9_998);
        assertEq(credit.completedLoans(borrower), 0);
        vm.prank(sponsor);
        vm.expectRevert(DecentralizedMicrocredit.BackingInUse.selector);
        credit.back(borrower, 0);
        _pay(id, 9_998);
        _exit();
        assertEq(usdc.balanceOf(lender), LIQUIDITY);
        _conserved();
    }

    function testCancelledReservationReturnsCapacityWithoutPayingVendor() public {
        vm.prank(borrower);
        uint256 id = credit.requestLoan(INPUT_COST);
        assertEq(credit.reservedLiquidity(), INPUT_COST);
        (, uint256 available) = credit.getBorrowLimit(borrower);
        assertEq(available, STAKE - INPUT_COST);
        vm.prank(borrower);
        credit.cancelLoan(id);
        (, available) = credit.getBorrowLimit(borrower);
        assertEq(available, STAKE);
        assertEq(usdc.balanceOf(vendor), 0);
        _exit();
        _conserved();
    }

    function testSignedVendorCannotBeSubstitutedAndOriginationCannotReplay() public {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _request(INPUT_COST);
        bytes memory sig = _signBorrowAndDisburse(borrowerKey, req);
        req.to = customer;
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.InvalidSignature.selector);
        credit.borrowAndDisburseMeta(req, sig);
        assertEq(credit.nonces(borrower), 0);
        req.to = vendor;
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.InvalidNonce.selector);
        credit.borrowAndDisburseMeta(req, sig);
        assertEq(usdc.balanceOf(vendor), INPUT_COST);
        assertEq(credit.getBorrowerLoanIds(borrower).length, 1);
        _conserved();
    }

    function testSecondSettlementCannotPullCustomerFundsAgain() public {
        uint256 id = _open(INPUT_COST);
        _payTestOrder(id);
        uint256 balance = usdc.balanceOf(customer);
        vm.startPrank(customer);
        usdc.approve(address(credit), INPUT_COST);
        vm.expectRevert(DecentralizedMicrocredit.LoanNotActive.selector);
        credit.repayLoan(id, INPUT_COST);
        vm.stopPrank();
        assertEq(usdc.balanceOf(customer), balance);
        _exit();
        _conserved();
    }

    function testReceivedBackingIsNotAnImplementedTransitiveRoute() public {
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(makeAddr("next-hop-worker"), STAKE);
        _conserved();
    }
}
