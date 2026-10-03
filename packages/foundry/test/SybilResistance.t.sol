// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Credit cannot be manufactured (docs/CREDIT_INTEGRITY_ISSUES.md, CI-1 to CI-3). An account
 *      can borrow only against credit it holds (granted credit or stake) or credit that someone
 *      who holds credit backs it with from their own. HermesCRBot's attack on #3: four fresh
 *      accounts vouch for each other in a ring and all for Sam, then borrow with nothing behind
 *      them.
 */
contract SybilResistanceTest is MicrocreditTestBase {
    uint256 internal constant RING_SIZE = 4;
    uint256 internal constant AVERY_CREDIT = 92e6; // 92% score x 100 USDC maxLoanAmount
    uint256 internal constant BRIGHTON_CREDIT = 25e6; // Brighton has a small line of his own

    address internal avery = makeAddr("avery");
    address internal brighton = makeAddr("brighton");
    address internal carlos = makeAddr("carlos");
    address internal sam = makeAddr("sam"); // the ring's beneficiary
    address internal poolLender = makeAddr("poolLender");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(poolLender, 10_000e6);
        vm.startPrank(owner);
        credit.setScoreOverride(avery, 920_000);
        credit.setScoreOverride(brighton, 250_000);
        vm.stopPrank();
    }

    function _ring() internal returns (address[] memory members) {
        members = new address[](RING_SIZE);
        for (uint256 i = 0; i < RING_SIZE; i++) {
            members[i] = makeAddr(string.concat("sybil", vm.toString(i)));
        }
    }

    function _limit(address account) internal view returns (uint256 limit) {
        (limit,) = credit.getBorrowLimit(account);
    }

    function _borrow(address borrower, uint256 amount) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = credit.requestLoan(amount);
        credit.disburseLoan(loanId);
    }

    function _default(uint256 loanId) internal {
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
    }

    // ───────────────────────────── the ring ─────────────────────────────

    /// @dev Hermes's exact scenario: no credit anywhere, so there is nothing to back with.
    function testRingOfFreshAccountsCannotBackOrBorrow() public {
        address[] memory ring = _ring();
        for (uint256 i = 0; i < RING_SIZE; i++) {
            vm.startPrank(ring[i]);
            vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
            credit.back(ring[(i + 1) % RING_SIZE], 10e6);
            vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
            credit.back(sam, 10e6);
            vm.stopPrank();
        }
        assertEq(_limit(sam), 0);
        vm.prank(sam);
        vm.expectRevert(DecentralizedMicrocredit.NoCredit.selector);
        credit.requestLoan(1e6);
    }

    /// @dev With money at stake the ring can borrow only what it staked, and lenders get it back.
    function testStakedRingBorrowsNoMoreThanItsStakeAndLendersLoseNothing() public {
        address[] memory ring = _ring();
        for (uint256 i = 0; i < RING_SIZE; i++) {
            _stake(ring[i], 10e6);
            vm.startPrank(ring[i]);
            credit.back(ring[(i + 1) % RING_SIZE], 5e6);
            credit.back(sam, 5e6);
            vm.stopPrank();
        }

        uint256 totalCapacity = _limit(sam);
        for (uint256 i = 0; i < RING_SIZE; i++) {
            totalCapacity += _limit(ring[i]);
        }
        assertEq(totalCapacity, RING_SIZE * 10e6, "backing in circles creates no capacity");

        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _borrow(sam, _limit(sam));
        _default(loanId);
        assertEq(credit.totalAssets(), assetsBefore, "slashed stake repays the lenders in full");
    }

    /// @dev One real line of credit in the ring is all the ring can ever borrow, once.
    function testRingCannotMultiplyOneMembersCredit() public {
        address[] memory ring = _ring();
        vm.prank(owner);
        credit.setScoreOverride(ring[0], 500_000); // 50 USDC of granted credit

        vm.prank(ring[0]);
        credit.back(ring[1], 50e6);
        // ring[1] received credit but holds none of its own, so it has nothing to pass on.
        vm.prank(ring[1]);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(sam, 1e6);

        assertEq(_limit(ring[0]) + _limit(ring[1]) + _limit(sam), 50e6);

        uint256 loanId = _borrow(ring[1], 50e6);
        _default(loanId);
        assertEq(credit.grantedCredit(ring[0]), 0, "the guarantor's credit is burned");
        vm.prank(ring[0]);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(ring[2], 1e6);
    }

    // ───────────────────────────── conservation ─────────────────────────────

    function testBackingMovesCreditItDoesNotCopyIt() public {
        assertEq(_limit(brighton), BRIGHTON_CREDIT, "Brighton already has credit of his own");

        vm.prank(avery);
        credit.back(brighton, 50e6);
        assertEq(_limit(brighton), BRIGHTON_CREDIT + 50e6);
        assertEq(_limit(avery), AVERY_CREDIT - 50e6);

        vm.startPrank(avery);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(carlos, AVERY_CREDIT - 50e6 + 1);
        credit.back(carlos, AVERY_CREDIT - 50e6);
        vm.stopPrank();
        assertEq(_limit(avery), 0);
    }

    function testOwnLoansReduceWhatYouCanBack() public {
        _borrow(avery, 60e6);
        (uint256 free,) = credit.getFreeCredit(avery);
        assertEq(free, AVERY_CREDIT - 60e6);
        vm.prank(avery);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(brighton, free + 1);
    }

    function testReceivedBackingCannotBePassedOn() public {
        vm.prank(avery);
        credit.back(carlos, 40e6);
        vm.prank(carlos);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientCredit.selector);
        credit.back(sam, 1e6);
    }

    function testBackingCannotBeCutBelowWhatTheBorrowerOwes() public {
        vm.prank(avery);
        credit.back(brighton, 50e6);
        _borrow(brighton, 70e6); // 25 of his own + 45 of Avery's

        vm.startPrank(avery);
        vm.expectRevert(DecentralizedMicrocredit.BackingInUse.selector);
        credit.back(brighton, 44e6);
        credit.back(brighton, 45e6);
        vm.stopPrank();
        assertEq(_limit(brighton), 70e6);
    }

    function testCommittedStakeCannotBeWithdrawn() public {
        _stake(carlos, 30e6);
        vm.prank(carlos);
        credit.back(sam, 30e6);
        (uint256 secured, uint256 unsecured) = credit.getBacking(carlos, sam);
        assertEq(secured, 30e6);
        assertEq(unsecured, 0);

        vm.startPrank(carlos);
        vm.expectRevert(DecentralizedMicrocredit.StakeCommitted.selector);
        credit.unstake(1);
        credit.back(sam, 0); // Sam owes nothing, so the backing can be withdrawn
        credit.unstake(30e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(carlos), 30e6);
    }

    /// @dev If a backer's own credit shrinks, its unsecured backing shrinks with it.
    function testLostCreditStopsBackingOthers() public {
        vm.startPrank(avery);
        credit.back(brighton, 46e6);
        credit.back(carlos, 46e6);
        vm.stopPrank();
        assertEq(_limit(carlos), 46e6);

        vm.prank(owner);
        credit.setScoreOverride(avery, 460_000); // Avery's granted credit falls to 46
        assertEq(_limit(carlos), 23e6, "half of Avery's commitments are still covered");
        assertEq(_limit(brighton), BRIGHTON_CREDIT + 23e6);
    }

    function testDefaulterLosesTheCreditItGaveOthers() public {
        vm.prank(avery);
        credit.back(carlos, 40e6);
        uint256 loanId = _borrow(avery, AVERY_CREDIT - 40e6);
        _default(loanId);

        assertEq(credit.grantedCredit(avery), 0);
        assertEq(_limit(carlos), 0, "credit from a defaulted backer backs nothing");
    }

    // ───────────────────────────── history (Theorem 3) ─────────────────────────────

    function _repayInFull(address borrower, uint256 loanId) internal {
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        uint256 held = usdc.balanceOf(borrower);
        if (held < owed) usdc.mint(borrower, owed - held); // the attacker funds whatever interest is due
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
    }

    /// @dev docs/CREDIT_MODEL.md, Theorem 3. One stake is recycled through fresh accounts, each of
    ///      which borrows and repays inside the interest-free first day. That history costs nothing,
    ///      so it must earn nothing: a rule such as "capacity rises by 25% of repaid principal"
    ///      would hand each account 100 here and the attacker 100 per account, with the seed never
    ///      at risk.
    function testRecycledSeedBuildsHistoryThatEarnsNoCredit() public {
        _stake(carlos, 100e6);
        address[] memory members = _ring();
        for (uint256 i = 0; i < RING_SIZE; i++) {
            vm.prank(carlos);
            credit.back(members[i], 100e6);
            for (uint256 cycle = 0; cycle < 4; cycle++) {
                _repayInFull(members[i], _borrow(members[i], 100e6));
            }
            vm.prank(carlos);
            credit.back(members[i], 0);

            assertEq(credit.completedLoans(members[i]), 4);
            assertEq(credit.duesPaid(members[i]), 0);
            assertEq(_limit(members[i]), 0, "history that cost nothing earns nothing");
        }
        assertEq(credit.stakeOf(carlos), 100e6, "the seed was never at risk");
    }

    /// @dev The same farm with 30-day loans: an account earns exactly the interest it paid, net
    ///      of the protocol fee. Borrowing that credit and defaulting hands lenders back only what
    ///      they were paid, so they end exactly where they started.
    function testHistoryEarnsOnlyTheDuesItPaid() public {
        vm.prank(owner);
        credit.setProtocolFeeBps(1_000);
        uint256 assetsBefore = credit.totalAssets();
        _stake(carlos, 100e6);
        address member = _ring()[0];

        vm.prank(carlos);
        credit.back(member, 100e6);
        uint256 loanId = _borrow(member, 100e6);
        vm.warp(block.timestamp + 30 days);
        uint256 interest = credit.getCurrentOutstandingAmount(loanId) - 100e6;
        _repayInFull(member, loanId);
        vm.prank(carlos);
        credit.back(member, 0);

        uint256 dues = interest - (interest * 1_000) / 10_000;
        assertGt(dues, 0);
        assertEq(credit.duesPaid(member), dues);
        assertEq(credit.grantedCredit(member), dues);
        assertEq(_limit(member), dues);

        _default(_borrow(member, dues));
        assertEq(credit.grantedCredit(member), 0, "dues are forfeited on default");
        assertEq(credit.totalAssets(), assetsBefore, "lenders lost exactly the dues they had been paid");
    }

    /// @dev Dues are credit like any other: they can back someone, which moves them.
    function testDuesCanBackOthers() public {
        vm.prank(avery);
        credit.back(carlos, AVERY_CREDIT);
        uint256 loanId = _borrow(carlos, 50e6);
        vm.warp(block.timestamp + 90 days);
        _repayInFull(carlos, loanId);

        uint256 dues = credit.duesPaid(carlos);
        assertGt(dues, 0);
        vm.prank(carlos);
        credit.back(sam, dues);
        assertEq(_limit(sam), dues);
        assertEq(_limit(carlos), AVERY_CREDIT, "Carlos keeps Avery's backing and has committed his dues");
    }

    // ───────────────────────────── stake ─────────────────────────────

    function testStakeIsNotPoolLiquidity() public {
        uint256 assetsBefore = credit.totalAssets();
        _stake(carlos, 50e6);
        assertEq(credit.totalAssets(), assetsBefore);
        assertEq(credit.totalStaked(), 50e6);
        assertEq(usdc.balanceOf(address(credit)), assetsBefore + 50e6);
    }

    function testUnstakeRejectsMoreThanStaked() public {
        _stake(carlos, 50e6);
        vm.prank(carlos);
        vm.expectRevert(DecentralizedMicrocredit.InsufficientStake.selector);
        credit.unstake(50e6 + 1);
    }
}
