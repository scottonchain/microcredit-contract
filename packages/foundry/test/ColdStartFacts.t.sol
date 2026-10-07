// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Each step of a proposed cold start, checked against the pool at the live Base Sepolia parameters
 *      (EFFR 433 + premium 500 = 933 bps, reserve share 45%, maxLoanAmount 100 USDC): a staker with no
 *      line stakes test USDC, backs a fresh borrower, the borrower borrows and repays, and the borrower
 *      then backs someone else. It pins what each step yields and what it does not; it says nothing about
 *      demand, repayment sources or any person. Run with `forge test --match-contract ColdStartFacts -vv`
 *      to print the figures.
 */
contract ColdStartFactsTest is MicrocreditTestBase {
    uint256 internal constant RESERVE_BPS = 4_500;
    uint256 internal constant STAKE = 100e6;
    uint256 internal constant MIN_BACKING = 1e6; // the pool's MIN_BACKING, checked in setUp

    address internal staker = makeAddr("staker");
    address internal borrower = makeAddr("borrower");
    address internal next = makeAddr("next");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(makeAddr("poolLender"), 10_000e6);
        vm.prank(owner);
        credit.setReserveBps(RESERVE_BPS);
        assertEq(credit.MIN_BACKING(), MIN_BACKING);
    }

    function _stakeAndBack(uint256 amount) internal {
        _stake(staker, amount);
        vm.prank(staker);
        credit.back(borrower, amount);
    }

    /// Opens a loan of `amount`, lets `elapsed` pass and repays it in full; returns the interest paid.
    function _cycle(uint256 amount, uint256 elapsed) internal returns (uint256 interest) {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        interest = owed - amount;
        usdc.mint(borrower, interest);
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
        (,,,, bool active) = credit.getLoan(loanId);
        assertFalse(active, "repaid in full");
    }

    // ───────────── step 1: staking is not the staker's own credit ─────────────

    /// Stake can back others (as secured backing) but gives the staker no line and no limit of its own.
    function testStakeGivesTheStakerNoLimitOfItsOwn() public {
        _stake(staker, STAKE);

        assertEq(credit.grantedCredit(staker), 0, "no granted credit");
        (uint256 limit, uint256 available) = credit.getBorrowLimit(staker);
        assertEq(limit, 0, "no limit");
        assertEq(available, 0);
        (uint256 freeCredit, uint256 freeStake) = credit.getFreeCredit(staker);
        assertEq(freeCredit, 0, "nothing unsecured to commit");
        assertEq(freeStake, STAKE, "only stake to commit");

        vm.prank(staker);
        vm.expectRevert(DecentralizedMicrocredit.NoCredit.selector);
        credit.requestLoan(1e6);
    }

    // ───────────── step 2: the stake backs a fresh borrower, secured ─────────────

    /// Backing with stake gives the borrower a limit equal to the stake committed, as a secured edge,
    /// and locks that stake while it backs.
    function testStakeBacksAFreshBorrowerAsSecuredBacking() public {
        _stakeAndBack(STAKE);

        (uint256 secured, uint256 unsecured) = credit.getBacking(staker, borrower);
        assertEq(secured, STAKE, "the edge is secured");
        assertEq(unsecured, 0);
        assertEq(credit.grantedCredit(borrower), 0, "the borrower holds no credit of its own");
        (uint256 limit,) = credit.getBorrowLimit(borrower);
        assertEq(limit, STAKE, "its limit is the backing received");
        assertEq(credit.stakeCommitted(staker), STAKE);

        vm.prank(staker);
        vm.expectRevert(DecentralizedMicrocredit.StakeCommitted.selector);
        credit.unstake(1);
    }

    /// Backing received is not the borrower's to pass on: with no credit of its own it cannot back anyone.
    function testBackingReceivedCannotBePassedOn() public {
        _stakeAndBack(STAKE);

        (uint256 freeCredit, uint256 freeStake) = credit.getFreeCredit(borrower);
        assertEq(freeCredit, 0);
        assertEq(freeStake, 0);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(next, MIN_BACKING);
    }

    // ───────────── step 3: repayment earns the borrower its dues, and the staker nothing ─────────────

    /// A 30-day, 100 USDC loan repaid in full: the borrower's credit grows by the reserve share of the
    /// interest it paid (its dues) and by nothing else; the staker's credit does not grow at all.
    function testRepaymentEarnsTheBorrowerItsDuesAndTheStakerNothing() public {
        _stakeAndBack(STAKE);
        uint256 interest = _cycle(100e6, 30 days);
        uint256 dues = credit.duesPaid(borrower);

        emit log_named_uint("100 USDC for 30 days, interest paid (base units)", interest);
        emit log_named_uint("borrower's dues, its credit earned (base units)", dues);
        assertEq(interest, 766_849, "933 bps on 100 USDC for 30 days");
        assertEq(dues, (interest * RESERVE_BPS) / 10_000, "dues are 45% of the interest");
        assertEq(dues, 345_082);
        assertEq(credit.grantedCredit(borrower), dues, "the borrower's own credit is its dues");

        assertEq(credit.grantedCredit(staker), 0, "the staker gains no credit");
        (uint256 limit,) = credit.getBorrowLimit(staker);
        assertEq(limit, 0, "and still has no limit");
        assertEq(credit.stakeOf(staker), STAKE, "its stake is intact and still committed");
    }

    /// Once the staker withdraws its backing, the borrower keeps only its dues, and the stake is free.
    function testAfterTheBackingIsWithdrawnTheBorrowerKeepsOnlyItsDues() public {
        _stakeAndBack(STAKE);
        _cycle(100e6, 30 days);
        uint256 dues = credit.duesPaid(borrower);

        vm.prank(staker);
        credit.back(borrower, 0);
        (uint256 limit,) = credit.getBorrowLimit(borrower);
        assertEq(limit, dues, "the borrower's limit is its dues");

        vm.prank(staker);
        credit.unstake(STAKE);
        assertEq(usdc.balanceOf(staker), STAKE, "the staker gets its stake back, and nothing more");
    }

    // ───────────── step 4: the borrower backs someone else ─────────────

    /// One 30-day cycle of 100 USDC earns less than MIN_BACKING (1 USDC), so the borrower cannot back anyone.
    function testOneThirtyDayCycleIsNotEnoughToBackAnyone() public {
        _stakeAndBack(STAKE);
        _cycle(100e6, 30 days);
        uint256 dues = credit.duesPaid(borrower);
        assertLt(dues, MIN_BACKING, "below the smallest backing");

        vm.startPrank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.BackingTooSmall.selector);
        credit.back(next, dues);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(next, MIN_BACKING);
        vm.stopPrank();
    }

    /// Three 30-day cycles of 100 USDC (90 days, all repaid) are the fewest that reach MIN_BACKING; then the
    /// borrower can back the next account with 1 USDC of unsecured credit, and that is all it can pass on.
    function testThreeCyclesReachTheSmallestBacking() public {
        _stakeAndBack(STAKE);
        uint256 cycles;
        uint256 interestPaid;
        while (credit.duesPaid(borrower) < MIN_BACKING) {
            interestPaid += _cycle(100e6, 30 days);
            cycles++;
        }
        uint256 dues = credit.duesPaid(borrower);
        emit log_named_uint("30-day cycles of 100 USDC to reach 1 USDC of dues", cycles);
        emit log_named_uint("interest the borrower paid over them (base units)", interestPaid);
        emit log_named_uint("borrower's dues after them (base units)", dues);
        assertEq(cycles, 3);
        assertEq(interestPaid, 3 * 766_849);
        assertEq(dues, 3 * 345_082);

        vm.prank(staker);
        credit.back(borrower, 0);
        vm.prank(borrower);
        credit.back(next, MIN_BACKING);
        (uint256 secured, uint256 unsecured) = credit.getBacking(borrower, next);
        assertEq(secured, 0);
        assertEq(unsecured, MIN_BACKING, "the next account receives unsecured backing");
        (uint256 limit,) = credit.getBorrowLimit(next);
        assertEq(limit, MIN_BACKING, "a 1 USDC limit");

        (uint256 freeCredit,) = credit.getFreeCredit(borrower);
        assertEq(freeCredit, dues - MIN_BACKING, "what is left is below another backing");
        assertLt(freeCredit, MIN_BACKING);
    }

    // ───────────── the conserving alternative: an issued line ─────────────

    /// A line issued within the oracle's budget is credit at once: the holder can borrow against it and
    /// back the next account with it. It is charged to the issuance budget and goes stale after
    /// maxScoreAge unless the issuer reports again.
    function testAnIssuedLineIsCreditAtOnce() public {
        _publishScore(borrower, SCALE / 10);

        assertEq(credit.grantedCredit(borrower), 10e6, "a tenth of a full line: 10 USDC");
        assertEq(scores.budgetHeld(borrower), SCALE / 10, "charged to the issuance budget");

        vm.prank(borrower);
        credit.back(next, 5e6);
        (uint256 nextLimit,) = credit.getBorrowLimit(next);
        assertEq(nextLimit, 5e6, "the next account can borrow 5 USDC");
        (uint256 ownLimit,) = credit.getBorrowLimit(borrower);
        assertEq(ownLimit, 5e6, "the holder's own limit fell by what it passed on");

        vm.warp(vm.getBlockTimestamp() + MAX_SCORE_AGE + 1);
        assertEq(credit.grantedCredit(borrower), 0, "a stale line is no credit");
    }
}
