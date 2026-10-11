// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../contracts/GuaranteeTrust.sol";

/**
 * @dev Conserved trust for the revolving first-job guarantee (docs/TRUST_NETWORK_DESIGN.md): where trust comes
 *      from, how far it moves, what a claim consumes, and what a ring of fakes can take.
 */
contract GuaranteeTrustTest is Test {
    uint256 internal constant U = 1e6; // one USDC

    MockUSDC internal usdc;
    GuaranteeTrust internal gt;

    address internal owner = makeAddr("owner");
    address internal adj = makeAddr("adjudicator");
    address internal issuer = makeAddr("issuer");
    address internal sponsor = makeAddr("sponsor");
    address internal avery = makeAddr("avery"); // established member with stake
    address internal brighton = makeAddr("brighton"); // second attester
    address internal nia = makeAddr("nia"); // newcomer
    address internal omar = makeAddr("omar"); // newcomer

    function setUp() public {
        usdc = new MockUSDC();
        gt = new GuaranteeTrust(usdc, owner, adj, issuer, 100 * U, U);
        _fund(sponsor, 1000 * U);
        vm.prank(sponsor);
        gt.fundReserve(100 * U);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(gt), type(uint256).max);
    }

    function _stake(address who, uint256 amt) internal {
        _fund(who, amt);
        vm.prank(who);
        gt.stake(amt);
    }

    function _open(address worker, string memory client, uint256 amt) internal returns (uint256) {
        vm.prank(adj);
        return gt.openGuarantee(worker, keccak256(bytes(client)), amt, keccak256("terms"));
    }

    // -------------------------------------------------------------- where trust comes from

    function testNewcomerWithNothingHasNoCapacity() public {
        assertEq(gt.capacity(nia), 0);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.InsufficientCapacity.selector);
        gt.openGuarantee(nia, keccak256("c1"), 10 * U, bytes32(0));
    }

    function testIssuerLineGivesCapacityWithinBudget() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        assertEq(gt.capacity(nia), 20 * U);
        // the budget holds every line
        for (uint256 i; i < 4; i++) {
            vm.prank(issuer);
            gt.setLine(makeAddr(string.concat("n", vm.toString(i))), 20 * U);
        }
        vm.prank(issuer);
        vm.expectRevert(GuaranteeTrust.BudgetExceeded.selector);
        gt.setLine(omar, 1);
    }

    function testIssuerLineCannotBeAttestedOnward() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        assertEq(gt.freeToBack(nia), 0);
        vm.prank(nia);
        vm.expectRevert(GuaranteeTrust.InsufficientTrust.selector);
        gt.attest(omar, 1);
    }

    function testStakeBacksOthersButNotItself() public {
        _stake(avery, 50 * U);
        assertEq(gt.capacity(avery), 0, "stake gives no capacity for the staker's own guarantee");
        vm.prank(avery);
        gt.attest(nia, 20 * U);
        assertEq(gt.capacity(nia), 20 * U);
        assertEq(gt.freeToBack(avery), 30 * U);
    }

    function testReceivedBackingCannotBePassedOn() public {
        _stake(avery, 20 * U);
        vm.prank(avery);
        gt.attest(nia, 20 * U);
        assertEq(gt.freeToBack(nia), 0);
        vm.prank(nia);
        vm.expectRevert(GuaranteeTrust.InsufficientTrust.selector);
        gt.attest(omar, 1);
    }

    function testCommissionBecomesDuesOneForOne() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "client-a", 20 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, keccak256("paid"));
        // 5% of 60 = 3, the cap
        _fund(nia, 3 * U);
        vm.prank(nia);
        gt.remit(id);
        GuaranteeTrust.Member memory m = gt.memberOf(nia);
        assertEq(m.dues, 3 * U);
        assertEq(gt.capacity(nia), 23 * U);
        assertEq(gt.reserve(), 103 * U);
    }

    function testHistoryRaisesScoreNotCapacity() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        for (uint256 i; i < 3; i++) {
            uint256 id = _open(nia, string.concat("client-", vm.toString(i)), 10 * U);
            vm.prank(adj);
            gt.markPaid(id, 10 * U, bytes32(0)); // 5% of 10 = 0.5
            _fund(nia, U / 2);
            vm.prank(nia);
            gt.remit(id);
        }
        GuaranteeTrust.Score memory s = gt.score(nia);
        assertEq(s.guaranteesPaid, 3);
        assertEq(s.composite, 45);
        // capacity rose only by the dues paid: 3 x 0.5
        assertEq(gt.capacity(nia), 20 * U + 3 * (U / 2));
    }

    // -------------------------------------------------------------- exposure rules

    function testGuaranteeIsAtMostAFifthOfTheReserve() public {
        _stake(avery, 50 * U);
        vm.prank(avery);
        gt.attest(nia, 20 * U);
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.ExposureCap.selector);
        gt.openGuarantee(nia, keccak256("c"), 21 * U, bytes32(0));
    }

    function testReserveFloorLimitsOpenExposure() public {
        // four newcomers with 20 each: the reserve of 100 can hold three open guarantees of 20 with 2G left
        for (uint256 i; i < 4; i++) {
            vm.prank(issuer);
            gt.setLine(makeAddr(string.concat("n", vm.toString(i))), 20 * U);
        }
        _open(makeAddr("n0"), "c0", 20 * U);
        _open(makeAddr("n1"), "c1", 20 * U);
        _open(makeAddr("n2"), "c2", 20 * U);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.ReserveFloor.selector);
        gt.openGuarantee(makeAddr("n3"), keccak256("c3"), 20 * U, bytes32(0));
    }

    function testOneOpenGuaranteePerClientAndNoneAfterDefault() public {
        vm.startPrank(issuer);
        gt.setLine(nia, 20 * U);
        gt.setLine(omar, 20 * U);
        vm.stopPrank();
        uint256 id = _open(nia, "acme", 10 * U);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.ClientBlocked.selector);
        gt.openGuarantee(omar, keccak256("acme"), 10 * U, bytes32(0));
        vm.prank(adj);
        gt.claim(id, keccak256("unpaid"));
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.ClientBlocked.selector);
        gt.openGuarantee(omar, keccak256("acme"), 10 * U, bytes32(0));
    }

    // -------------------------------------------------------------- claims

    function testClaimPaysWorkerAndConsumesBackingFirstSlashingStake() public {
        _stake(avery, 30 * U);
        _stake(brighton, 10 * U);
        vm.prank(avery);
        gt.attest(nia, 15 * U);
        vm.prank(brighton);
        gt.attest(nia, 5 * U);
        uint256 id = _open(nia, "acme", 20 * U);
        uint256 reserveBefore = gt.reserve();
        vm.prank(adj);
        gt.claim(id, keccak256("unpaid"));
        // worker paid in full, owes nothing
        assertEq(usdc.balanceOf(nia), 20 * U);
        // attesters lose pro rata 15 and 5, from stake; that cash returns to the reserve
        assertEq(gt.memberOf(avery).stake, 15 * U);
        assertEq(gt.memberOf(brighton).stake, 5 * U);
        assertEq(gt.reserve(), reserveBefore - 20 * U + 20 * U);
        assertEq(gt.capacity(nia), 0);
        assertEq(gt.score(avery).attesteeClaims, 1);
        assertTrue(gt.clientDefaulted(keccak256("acme")));
        _assertBooks();
    }

    function testClaimSpendsIssuerBudgetForLineCapacity() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "acme", 20 * U);
        vm.prank(adj);
        gt.claim(id, bytes32(0));
        assertEq(gt.issuerSpent(), 20 * U);
        assertEq(gt.issuerHeld(), 0);
        assertEq(gt.memberOf(nia).line, 0);
        assertEq(gt.reserve(), 80 * U);
        _assertBooks();
    }

    function testPaidGuaranteeReleasesBackingForWithdrawal() public {
        _stake(avery, 20 * U);
        vm.prank(avery);
        gt.attest(nia, 20 * U);
        uint256 id = _open(nia, "acme", 20 * U);
        vm.prank(avery);
        vm.expectRevert(GuaranteeTrust.BackingLocked.selector);
        gt.withdrawBacking(nia, 1);
        vm.prank(adj);
        gt.markPaid(id, 40 * U, bytes32(0));
        vm.prank(avery);
        gt.withdrawBacking(nia, 20 * U);
        vm.prank(avery);
        gt.unstake(20 * U);
        assertEq(usdc.balanceOf(avery), 20 * U);
    }

    // -------------------------------------------------------------- contributions

    function testUnpaidContributionBlocksNextGuaranteeButIsNotPursued() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "a", 10 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.ContributionOutstanding.selector);
        gt.openGuarantee(nia, keccak256("b"), 10 * U, bytes32(0));
        vm.expectRevert(GuaranteeTrust.TooEarly.selector);
        gt.markLapsed(id);
        vm.warp(block.timestamp + 14 days);
        gt.markLapsed(id);
        assertEq(gt.score(nia).contributionsLapsed, 1);
        // paying late still clears it
        _fund(sponsor, 0);
        vm.prank(sponsor);
        gt.remit(id);
        assertEq(gt.memberOf(nia).dues, 3 * U);
        _open(nia, "b", 10 * U);
    }

    // -------------------------------------------------------------- what a ring can take

    /// @dev A ring of fake workers, fake clients and fake attesters with no stake, no dues and no line gets zero
    ///      capacity however many accounts it creates.
    function testRingWithNoRootedTrustGetsNothing() public {
        address[] memory ring = new address[](8);
        for (uint256 i; i < ring.length; i++) {
            ring[i] = makeAddr(string.concat("sybil", vm.toString(i)));
        }
        for (uint256 i; i < ring.length; i++) {
            vm.prank(ring[i]);
            vm.expectRevert(GuaranteeTrust.InsufficientTrust.selector);
            gt.attest(ring[(i + 1) % ring.length], 1);
            assertEq(gt.capacity(ring[i]), 0);
        }
    }

    /// @dev Farming dues with a colluding client: the ring pays the contribution to earn capacity, then claims. It
    ///      gets back at most what it paid in; the sponsor's reserve loses nothing.
    function testDuesFarmingReturnsAtMostWhatWasPaid() public {
        address worker = makeAddr("farmer");
        vm.prank(issuer);
        gt.setLine(worker, 1 * U); // a small vetted line to get the first job
        uint256 id = _open(worker, "fake-client-1", 1 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0)); // the fake client "paid" 60
        _fund(worker, 3 * U);
        vm.prank(worker);
        gt.remit(id); // 3 of dues
        uint256 capacityNow = gt.capacity(worker); // 1 line + 3 dues
        assertEq(capacityNow, 4 * U);
        uint256 id2 = _open(worker, "fake-client-2", capacityNow);
        vm.prank(adj);
        gt.claim(id2, bytes32(0)); // the fake client "defaults"
        // the ring extracted 4: 3 it paid in itself, 1 the issuer's budget (accountable) allowed
        assertEq(usdc.balanceOf(worker), 4 * U);
        assertEq(gt.issuerSpent(), 1 * U);
        assertEq(gt.capacity(worker), 0);
        assertEq(gt.reserve(), 100 * U + 3 * U - 4 * U);
        _assertBooks();
    }

    function testReleaseNeverTouchesDuesOrOpenExposure() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "a", 20 * U);
        assertEq(gt.releasable(), 80 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
        _fund(nia, 3 * U);
        vm.prank(nia);
        gt.remit(id);
        assertEq(gt.releasable(), 100 * U);
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseTooLarge.selector);
        gt.releaseReserve(owner, 101 * U);
        vm.prank(owner);
        gt.releaseReserve(owner, 100 * U);
        assertEq(gt.reserve(), 3 * U);
    }

    function testPauseStopsOnlyNewGuarantees() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "a", 10 * U);
        vm.prank(owner);
        gt.setPaused(true);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.IsPaused.selector);
        gt.openGuarantee(nia, keccak256("b"), 5 * U, bytes32(0));
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
    }

    function _assertBooks() internal view {
        assertEq(usdc.balanceOf(address(gt)), gt.reserve() + gt.totalStake(), "token = reserve + stake");
        assertLe(gt.outstanding(), gt.reserve(), "outstanding within reserve");
    }
}
