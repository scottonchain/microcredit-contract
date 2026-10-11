// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../contracts/GuaranteeTrust.sol";

/**
 * @dev Conserved trust for the revolving first-job guarantee (docs/TRUST_NETWORK_DESIGN.md): where trust comes
 *      from, how far it moves, who must consent, what a claim consumes, and what a ring of fakes can take.
 */
contract GuaranteeTrustTest is Test {
    uint256 internal constant U = 1e6; // one USDC

    MockUSDC internal usdc;
    GuaranteeTrust internal gt;

    address internal owner = makeAddr("owner");
    address internal adj = makeAddr("adjudicator");
    address internal issuer = makeAddr("issuer");
    address internal sponsor = makeAddr("sponsor");
    address internal avery; // established member with stake
    address internal brighton; // second attester
    address internal nia; // newcomer
    address internal omar; // newcomer

    mapping(address => uint256) internal keyOf;
    uint256 internal nonce;

    function setUp() public {
        usdc = new MockUSDC();
        gt = new GuaranteeTrust(usdc, owner, adj, issuer, 100 * U, U);
        _fund(sponsor, 1000 * U);
        vm.prank(sponsor);
        gt.fundReserve(100 * U);
        avery = _person("avery");
        brighton = _person("brighton");
        nia = _person("nia");
        omar = _person("omar");
    }

    function _person(string memory name) internal returns (address who) {
        uint256 key;
        (who, key) = makeAddrAndKey(name);
        keyOf[who] = key;
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

    function _attest(address att, address m, uint256 amt) internal {
        vm.prank(m);
        gt.setConsent(att, true);
        vm.prank(att);
        gt.attest(m, amt);
    }

    function _terms(address worker, bytes32 client, bytes32 group, uint256 amt)
        internal
        returns (GuaranteeTrust.Acceptance memory a)
    {
        a = GuaranteeTrust.Acceptance({
            worker: worker,
            clientId: client,
            groupId: group,
            amount: amt,
            maxFromDues: amt,
            termsHash: keccak256("terms v1"),
            contributionBps: gt.contributionBps(),
            contributionCap: gt.contributionCap(),
            remitWindow: gt.remitWindow(),
            settleBy: uint64(block.timestamp + 30 days),
            nonce: ++nonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 key, GuaranteeTrust.Acceptance memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, gt.acceptanceDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The worker signs, the adjudicator submits.
    function _openWith(GuaranteeTrust.Acceptance memory a) internal returns (uint256) {
        bytes memory sig = _sign(keyOf[a.worker], a);
        vm.prank(adj);
        return gt.openGuarantee(a, sig);
    }

    function _open(address worker, string memory client, uint256 amt) internal returns (uint256) {
        return _openWith(_terms(worker, keccak256(bytes(client)), bytes32(0), amt));
    }

    function _expectOpenReverts(GuaranteeTrust.Acceptance memory a, bytes4 err) internal {
        bytes memory sig = _sign(keyOf[a.worker], a);
        vm.prank(adj);
        vm.expectRevert(err);
        gt.openGuarantee(a, sig);
    }

    // -------------------------------------------------------------- where trust comes from

    function testNewcomerWithNothingHasNoCapacity() public {
        assertEq(gt.capacity(nia), 0);
        _expectOpenReverts(_terms(nia, keccak256("c1"), 0, 10 * U), GuaranteeTrust.InsufficientCapacity.selector);
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
        vm.prank(omar);
        gt.setConsent(nia, true);
        vm.prank(nia);
        vm.expectRevert(GuaranteeTrust.InsufficientTrust.selector);
        gt.attest(omar, 1);
    }

    function testStakeBacksOthersButNotItself() public {
        _stake(avery, 50 * U);
        assertEq(gt.capacity(avery), 0, "stake gives no capacity for the staker's own guarantee");
        _attest(avery, nia, 20 * U);
        assertEq(gt.capacity(nia), 20 * U);
        assertEq(gt.freeToBack(avery), 30 * U);
    }

    function testReceivedBackingCannotBePassedOn() public {
        _stake(avery, 20 * U);
        _attest(avery, nia, 20 * U);
        assertEq(gt.freeToBack(nia), 0);
        vm.prank(omar);
        gt.setConsent(nia, true);
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

    // -------------------------------------------------------------- consent: nobody acts for the member

    function testAttestationNeedsTheMembersConsent() public {
        _stake(avery, 20 * U);
        vm.prank(avery);
        vm.expectRevert(GuaranteeTrust.NoConsent.selector);
        gt.attest(nia, 5 * U);
        // a newcomer with no gas signs; anyone may submit it
        uint256 deadline = block.timestamp + 1 hours;
        uint256 n = gt.consentNonce(nia, avery);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[nia], gt.consentDigest(nia, avery, true, n, deadline));
        vm.prank(issuer);
        gt.setConsentBySig(nia, avery, true, n, deadline, abi.encodePacked(r, s, v));
        vm.prank(avery);
        gt.attest(nia, 5 * U);
        assertEq(gt.capacity(nia), 5 * U);
    }

    function testNoRoleCanFabricateConsent() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = gt.consentDigest(nia, avery, true, 0, deadline);
        // the issuer signs for the newcomer: refused
        (, uint256 issuerKey) = makeAddrAndKey("issuer");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerKey, digest);
        vm.expectRevert(GuaranteeTrust.BadSignature.selector);
        gt.setConsentBySig(nia, avery, true, 0, deadline, abi.encodePacked(r, s, v));
        // the newcomer's real signature, replayed: refused
        (v, r, s) = vm.sign(keyOf[nia], digest);
        gt.setConsentBySig(nia, avery, true, 0, deadline, abi.encodePacked(r, s, v));
        vm.expectRevert(GuaranteeTrust.StaleNonce.selector);
        gt.setConsentBySig(nia, avery, true, 0, deadline, abi.encodePacked(r, s, v));
        // expired: refused
        vm.warp(deadline + 1);
        (v, r, s) = vm.sign(keyOf[nia], gt.consentDigest(nia, brighton, true, 0, deadline));
        vm.expectRevert(GuaranteeTrust.SignatureExpired.selector);
        gt.setConsentBySig(nia, brighton, true, 0, deadline, abi.encodePacked(r, s, v));
    }

    /// @dev Decisions apply in order: an earlier, unsubmitted "allowed" signature dies once the member revokes.
    function testALaterRevocationKillsAnEarlierUnsubmittedConsent() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[nia], gt.consentDigest(nia, avery, true, 0, deadline));
        bytes memory early = abi.encodePacked(r, s, v);
        vm.prank(nia);
        gt.setConsent(avery, false);
        vm.expectRevert(GuaranteeTrust.StaleNonce.selector);
        gt.setConsentBySig(nia, avery, true, 0, deadline, early);
        assertFalse(gt.consent(nia, avery));
        // a signed revocation also outranks an earlier signed approval
        (v, r, s) = vm.sign(keyOf[omar], gt.consentDigest(omar, avery, true, 0, deadline));
        bytes memory approve = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(keyOf[omar], gt.consentDigest(omar, avery, false, 0, deadline));
        gt.setConsentBySig(omar, avery, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.expectRevert(GuaranteeTrust.StaleNonce.selector);
        gt.setConsentBySig(omar, avery, true, 0, deadline, approve);
    }

    function testAMemberCanDropAnAttesterWithNothingLocked() public {
        _stake(avery, 20 * U);
        _stake(brighton, 20 * U);
        _attest(avery, nia, 1);
        _attest(brighton, nia, 10 * U);
        uint256 id = _open(nia, "c", 10 * U);
        vm.prank(nia);
        vm.expectRevert(GuaranteeTrust.BackingLocked.selector);
        gt.dropAttester(brighton);
        vm.prank(adj);
        gt.markPaid(id, 0, bytes32(0));
        vm.prank(nia);
        gt.dropAttester(avery);
        assertEq(gt.attestersOf(nia).length, 1);
        assertEq(gt.freeToBack(avery), 20 * U, "the dropped backing returns to the attester");
        assertFalse(gt.consent(nia, avery));
        vm.prank(avery);
        vm.expectRevert(GuaranteeTrust.NoConsent.selector);
        gt.attest(nia, 1);
    }

    // -------------------------------------------------------------- the worker accepts every guarantee

    function testAdjudicatorCannotOpenAGuaranteeTheWorkerDidNotSign() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("c"), 0, 10 * U);
        // the adjudicator signs in the worker's place
        (, uint256 adjKey) = makeAddrAndKey("adjudicator");
        bytes memory forged = _sign(adjKey, a);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.BadSignature.selector);
        gt.openGuarantee(a, forged);
        // the worker signed different terms (a larger amount)
        bytes memory sig = _sign(keyOf[nia], a);
        a.amount = 15 * U;
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.BadSignature.selector);
        gt.openGuarantee(a, sig);
        // nobody but the adjudicator submits
        a.amount = 10 * U;
        vm.expectRevert(GuaranteeTrust.NotAdjudicator.selector);
        gt.openGuarantee(a, sig);
        // the real acceptance opens once, and only once
        vm.prank(adj);
        gt.openGuarantee(a, sig);
        a.clientId = keccak256("c2");
        bytes memory sig2 = _sign(keyOf[nia], a); // same nonce, other client
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.NonceAlreadyUsed.selector);
        gt.openGuarantee(a, sig2);
    }

    function testWorkerCanWithdrawASignedAcceptanceAndSignaturesExpire() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("c"), 0, 10 * U);
        bytes memory sig = _sign(keyOf[nia], a);
        vm.prank(nia);
        gt.revokeNonce(a.nonce);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.NonceAlreadyUsed.selector);
        gt.openGuarantee(a, sig);
        GuaranteeTrust.Acceptance memory b = _terms(nia, keccak256("c"), 0, 10 * U);
        bytes memory sigB = _sign(keyOf[nia], b);
        vm.warp(b.deadline + 1);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.SignatureExpired.selector);
        gt.openGuarantee(b, sigB);
    }

    function testTheContributionPolicyIsTheOneTheWorkerSigned() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("c"), 0, 10 * U);
        a.contributionBps = 900; // terms the contract is not offering
        _expectOpenReverts(a, GuaranteeTrust.PolicyMismatch.selector);
        uint256 id = _open(nia, "c", 10 * U);
        // the owner raises the contribution afterwards; the open guarantee keeps 5%, cap 3
        vm.prank(owner);
        gt.setParams(2000, 2, 2000, 10 * U, 14 days, 20 * U, 20 * U, 5, 5);
        vm.prank(adj);
        gt.markPaid(id, 40 * U, bytes32(0));
        assertEq(gt.guarantee(id).contributionDue, 2 * U);
    }

    function testDuesAtRiskOnlyUpToTheWorkersPledge() public {
        vm.prank(issuer);
        gt.setLine(nia, 1 * U);
        uint256 id = _open(nia, "a", 1 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
        _fund(nia, 3 * U);
        vm.prank(nia);
        gt.remit(id);
        assertEq(gt.capacity(nia), 4 * U); // 1 line + 3 dues
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("b"), 0, 4 * U);
        a.maxFromDues = 0; // the worker does not pledge its dues
        _expectOpenReverts(a, GuaranteeTrust.InsufficientCapacity.selector);
        a = _terms(nia, keccak256("b"), 0, 4 * U);
        a.maxFromDues = 3 * U;
        uint256 id2 = _openWith(a);
        assertEq(gt.guarantee(id2).fromDues, 3 * U);
    }

    function testSettleByIsBoundedAndPassedGuaranteesExpireWithoutAClaim() public {
        _stake(avery, 20 * U);
        _attest(avery, nia, 10 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("c"), 0, 10 * U);
        a.settleBy = uint64(block.timestamp + 61 days);
        _expectOpenReverts(a, GuaranteeTrust.BadTerm.selector);
        a = _terms(nia, keccak256("c"), 0, 10 * U);
        a.settleBy = uint64(block.timestamp + 1 days - 1); // shorter than the minimum term
        _expectOpenReverts(a, GuaranteeTrust.BadTerm.selector);
        uint256 id = _open(nia, "c", 10 * U);
        vm.expectRevert(GuaranteeTrust.TooEarly.selector);
        gt.expireGuarantee(id);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.PastSettleBy.selector);
        gt.claim(id, bytes32(0));
        vm.prank(adj);
        vm.expectRevert(GuaranteeTrust.PastSettleBy.selector);
        gt.markPaid(id, 40 * U, bytes32(0));
        gt.expireGuarantee(id); // anyone
        assertEq(uint8(gt.guarantee(id).state), uint8(GuaranteeTrust.State.Expired));
        assertEq(gt.outstanding(), 0);
        assertEq(gt.capacity(nia), 10 * U);
        assertEq(gt.withdrawableBacking(avery, nia), 10 * U);
        assertEq(usdc.balanceOf(nia), 0, "no claim paid");
        assertEq(gt.memberOf(nia).unpaidContributions, 0, "no contribution due");
        assertFalse(gt.clientOpen(keccak256("c")));
    }

    // -------------------------------------------------------------- exposure rules

    function testGuaranteeIsAtMostAFifthOfTheReserve() public {
        _stake(avery, 50 * U);
        _attest(avery, nia, 20 * U);
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        _expectOpenReverts(_terms(nia, keccak256("c"), 0, 21 * U), GuaranteeTrust.ExposureCap.selector);
    }

    function testReserveFloorLimitsOpenExposure() public {
        // a 30% group cap per client would not bind here: each newcomer has its own client and group
        address[] memory n = new address[](4);
        for (uint256 i; i < 4; i++) {
            n[i] = _person(string.concat("n", vm.toString(i)));
            vm.prank(issuer);
            gt.setLine(n[i], 20 * U);
        }
        _open(n[0], "c0", 20 * U);
        _open(n[1], "c1", 20 * U);
        _open(n[2], "c2", 20 * U);
        _expectOpenReverts(_terms(n[3], keccak256("c3"), 0, 20 * U), GuaranteeTrust.ReserveFloor.selector);
    }

    function testOneOpenGuaranteePerClientAndNoneAfterDefault() public {
        vm.startPrank(issuer);
        gt.setLine(nia, 20 * U);
        gt.setLine(omar, 20 * U);
        vm.stopPrank();
        uint256 id = _open(nia, "acme", 10 * U);
        _expectOpenReverts(_terms(omar, keccak256("acme"), 0, 10 * U), GuaranteeTrust.ClientBlocked.selector);
        vm.prank(adj);
        gt.claim(id, keccak256("unpaid"));
        _expectOpenReverts(_terms(omar, keccak256("acme"), 0, 10 * U), GuaranteeTrust.ClientBlocked.selector);
    }

    /// @dev Aliases of one client bound to one canonical group share the group cap, and one default blocks them all.
    function testAliasesInOneGroupShareItsCapAndItsDefault() public {
        address[] memory n = new address[](4);
        for (uint256 i; i < 4; i++) {
            n[i] = _person(string.concat("g", vm.toString(i)));
            vm.prank(issuer);
            gt.setLine(n[i], 20 * U);
        }
        bytes32 parent = keccak256("parent-co");
        // reserve 100, group cap 30%: 20 + 10 fit, a further 5 does not
        uint256 id0 = _openWith(_terms(n[0], keccak256("parent-co/branch-1"), parent, 20 * U));
        _openWith(_terms(n[1], keccak256("parent-co/branch-2"), parent, 10 * U));
        assertEq(gt.groupExposure(parent), 30 * U);
        _expectOpenReverts(_terms(n[2], keccak256("parent-co/branch-3"), parent, 5 * U), GuaranteeTrust.GroupCap.selector);
        // one branch defaults: no branch of the group gets a new guarantee, even once exposure falls
        vm.prank(adj);
        gt.claim(id0, keccak256("branch 1 did not pay"));
        assertTrue(gt.groupDefaulted(parent));
        _expectOpenReverts(_terms(n[3], keccak256("parent-co/branch-4"), parent, 5 * U), GuaranteeTrust.ClientBlocked.selector);
    }

    /// @dev The limit: client identity is bound off chain by whoever writes the terms. An alias presented under a
    ///      different group is not linked by the contract; the worker-signed group is the only on-chain binding.
    /// @dev A client keeps the group it was first guaranteed under, so it cannot escape its group's default or cap.
    function testAKnownClientCannotChangeGroup() public {
        vm.startPrank(issuer);
        gt.setLine(nia, 20 * U);
        gt.setLine(omar, 20 * U);
        vm.stopPrank();
        uint256 id = _openWith(_terms(nia, keccak256("acme"), keccak256("acme-group"), 10 * U));
        vm.prank(adj);
        gt.cancelGuarantee(id);
        _expectOpenReverts(_terms(omar, keccak256("acme"), keccak256("other-group"), 10 * U), GuaranteeTrust.GroupMismatch.selector);
        _expectOpenReverts(_terms(omar, keccak256("acme"), 0, 10 * U), GuaranteeTrust.GroupMismatch.selector);
        _openWith(_terms(omar, keccak256("acme"), keccak256("acme-group"), 10 * U));
    }

    function testAnAliasUnderAnotherGroupIsNotCaughtOnChain() public {
        vm.startPrank(issuer);
        gt.setLine(nia, 20 * U);
        gt.setLine(omar, 20 * U);
        vm.stopPrank();
        uint256 id = _openWith(_terms(nia, keccak256("acme"), keccak256("acme-group"), 10 * U));
        vm.prank(adj);
        gt.claim(id, bytes32(0));
        _openWith(_terms(omar, keccak256("acme-renamed"), keccak256("other-group"), 10 * U));
        assertEq(gt.guaranteeCount(), 2);
    }

    // -------------------------------------------------------------- claims

    function testClaimPaysWorkerAndConsumesBackingFirstSlashingStake() public {
        _stake(avery, 30 * U);
        _stake(brighton, 10 * U);
        _attest(avery, nia, 15 * U);
        _attest(brighton, nia, 5 * U);
        uint256 id = _open(nia, "acme", 20 * U);
        uint256 reserveBefore = gt.reserve();
        vm.prank(adj);
        gt.claim(id, keccak256("unpaid"));
        // worker paid in full, owes nothing
        assertEq(usdc.balanceOf(nia), 20 * U);
        // attesters lose their fixed shares, 15 and 5, from stake; that cash returns to the reserve
        assertEq(gt.memberOf(avery).stake, 15 * U);
        assertEq(gt.memberOf(brighton).stake, 5 * U);
        assertEq(gt.reserve(), reserveBefore - 20 * U + 20 * U);
        assertEq(gt.capacity(nia), 0);
        assertEq(gt.score(avery).attesteeClaims, 1);
        assertTrue(gt.clientDefaulted(keccak256("acme")));
        _assertBooks();
    }

    /// @dev Shares are fixed when a guarantee opens: an attester who arrives later neither takes on the earlier
    ///      guarantee's risk nor lets an earlier attester withdraw its locked share.
    function testLateAttesterCannotUnlockAnEarlierAttestersShare() public {
        _stake(avery, 10 * U);
        _stake(brighton, 10 * U);
        _attest(avery, nia, 10 * U);
        uint256 id = _open(nia, "acme", 10 * U);
        assertEq(gt.lockedBacking(avery, nia), 10 * U);
        _attest(brighton, nia, 10 * U);
        assertEq(gt.withdrawableBacking(avery, nia), 0, "avery's share stays locked");
        assertEq(gt.withdrawableBacking(brighton, nia), 10 * U, "brighton backs nothing open");
        vm.prank(avery);
        vm.expectRevert(GuaranteeTrust.BackingLocked.selector);
        gt.withdrawBacking(nia, 1);
        vm.prank(adj);
        gt.claim(id, bytes32(0));
        assertEq(gt.memberOf(avery).stake, 0, "the earlier attester pays its own share");
        assertEq(gt.memberOf(brighton).stake, 10 * U, "the later attester pays nothing");
        _assertBooks();
    }

    function testSharesAreProRataAndCoverOddAmounts() public {
        _stake(avery, 30 * U);
        _stake(brighton, 30 * U);
        _attest(avery, nia, 7 * U);
        _attest(brighton, nia, 3 * U);
        uint256 id = _open(nia, "acme", 10 * U - 1);
        GuaranteeTrust.Share[] memory s = gt.sharesOf(id);
        uint256 sum;
        for (uint256 i; i < s.length; i++) {
            sum += s[i].amount;
        }
        assertEq(sum, 10 * U - 1);
        vm.prank(adj);
        gt.claim(id, bytes32(0));
        assertEq(gt.memberOf(avery).stake + gt.memberOf(brighton).stake, 60 * U - (10 * U - 1));
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
        _attest(avery, nia, 20 * U);
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
        _expectOpenReverts(_terms(nia, keccak256("b"), 0, 10 * U), GuaranteeTrust.ContributionOutstanding.selector);
        vm.expectRevert(GuaranteeTrust.TooEarly.selector);
        gt.markLapsed(id);
        vm.warp(block.timestamp + 14 days);
        gt.markLapsed(id);
        assertEq(gt.score(nia).contributionsLapsed, 1);
        // paying late still clears it
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
            vm.prank(ring[(i + 1) % ring.length]);
            gt.setConsent(ring[i], true); // the ring consents to itself freely
            vm.prank(ring[i]);
            vm.expectRevert(GuaranteeTrust.InsufficientTrust.selector);
            gt.attest(ring[(i + 1) % ring.length], 1);
            assertEq(gt.capacity(ring[i]), 0);
        }
    }

    /// @dev Farming dues with a colluding client: the ring pays the contribution to earn capacity, then claims. It
    ///      gets back at most what it paid in; the sponsor's reserve loses nothing beyond the issuer's line.
    function testDuesFarmingReturnsAtMostWhatWasPaid() public {
        address worker = _person("farmer");
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

    // -------------------------------------------------------------- sponsor capital

    function testReleaseOnlyToTheFunderAndNeverDuesOpenExposureOrLines() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "a", 20 * U);
        assertEq(gt.releasable(), 0, "nothing is released while a guarantee is open");
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseWhileOpen.selector);
        gt.releaseReserve(sponsor, 1);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
        _fund(nia, 3 * U);
        vm.prank(nia);
        gt.remit(id);
        assertEq(gt.releasable(), 80 * U, "the held line stays behind");
        vm.prank(issuer);
        gt.setLine(nia, 0);
        assertEq(gt.releasable(), 100 * U);
        // not to the owner, who funded nothing
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseTooLarge.selector);
        gt.releaseReserve(owner, 1);
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseTooLarge.selector);
        gt.releaseReserve(sponsor, 101 * U);
        uint256 before = usdc.balanceOf(sponsor);
        vm.prank(owner);
        gt.releaseReserve(sponsor, 100 * U);
        assertEq(usdc.balanceOf(sponsor), before + 100 * U);
        assertEq(gt.reserve(), 3 * U, "the worker's dues stay");
    }

    /// @dev Lines held plus lines spent never exceed the sponsor capital funded, so no line-backed claim is paid out
    ///      of members' dues, and capital behind lines cannot be released.
    function testLinesNeverExceedSponsorCapital() public {
        GuaranteeTrust gt2 = new GuaranteeTrust(usdc, owner, adj, issuer, 500 * U, U);
        vm.prank(sponsor);
        usdc.approve(address(gt2), type(uint256).max);
        vm.prank(sponsor);
        gt2.fundReserve(30 * U);
        vm.prank(issuer);
        gt2.setLine(nia, 20 * U);
        vm.prank(issuer);
        vm.expectRevert(GuaranteeTrust.SponsorCapital.selector);
        gt2.setLine(omar, 11 * U);
        vm.prank(issuer);
        gt2.setLine(omar, 10 * U);
        assertEq(gt2.releasable(), 0);
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseTooLarge.selector);
        gt2.releaseReserve(sponsor, 1);
    }

    /// @dev Codex's sequence: A funds, a line-backed claim takes 20, A takes back the rest, B funds 20. A cannot then
    ///      take B's deposit: the loss burned A's entitlement, not B's.
    function testALineLossBurnsTheFundersEntitlementNotALaterFunders() public {
        address funderA = makeAddr("funder-a");
        address funderB = makeAddr("funder-b");
        GuaranteeTrust g2 = new GuaranteeTrust(usdc, owner, adj, issuer, 100 * U, U);
        _fund(funderA, 100 * U);
        _fund(funderB, 20 * U);
        vm.prank(funderA);
        usdc.approve(address(g2), type(uint256).max);
        vm.prank(funderB);
        usdc.approve(address(g2), type(uint256).max);
        vm.prank(funderA);
        g2.fundReserve(100 * U);
        vm.prank(issuer);
        g2.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("x"), 0, 20 * U);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[nia], g2.acceptanceDigest(a));
        vm.prank(adj);
        uint256 id = g2.openGuarantee(a, abi.encodePacked(r, s, v));
        vm.prank(adj);
        g2.claim(id, bytes32(0));
        assertEq(g2.sponsorCapital(), 80 * U);
        assertApproxEqAbs(g2.sponsorValueOf(funderA), 80 * U, 1);
        vm.prank(owner);
        g2.releaseReserve(funderA, 80 * U);
        vm.prank(funderB);
        g2.fundReserve(20 * U);
        assertEq(g2.sponsorValueOf(funderB), 20 * U);
        assertEq(g2.sponsorValueOf(funderA), 0);
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.ReleaseTooLarge.selector);
        g2.releaseReserve(funderA, 20 * U);
        vm.prank(owner);
        g2.releaseReserve(funderB, 20 * U);
        assertEq(usdc.balanceOf(funderB), 20 * U);
    }

    function testTwoFundersShareALossProRata() public {
        address funderA = makeAddr("funder-a");
        GuaranteeTrust g2 = new GuaranteeTrust(usdc, owner, adj, issuer, 100 * U, U);
        _fund(funderA, 75 * U);
        vm.prank(funderA);
        usdc.approve(address(g2), type(uint256).max);
        vm.prank(sponsor);
        usdc.approve(address(g2), type(uint256).max);
        vm.prank(funderA);
        g2.fundReserve(75 * U);
        vm.prank(sponsor);
        g2.fundReserve(25 * U);
        vm.prank(issuer);
        g2.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("x"), 0, 20 * U);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[nia], g2.acceptanceDigest(a));
        vm.prank(adj);
        uint256 id = g2.openGuarantee(a, abi.encodePacked(r, s, v));
        vm.prank(adj);
        g2.claim(id, bytes32(0));
        assertApproxEqAbs(g2.sponsorValueOf(funderA), 60 * U, 1);
        assertApproxEqAbs(g2.sponsorValueOf(sponsor), 20 * U, 1);
    }

    function testTheRemitWindowIsTheOneTheWorkerSigned() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        GuaranteeTrust.Acceptance memory a = _terms(nia, keccak256("w"), 0, 10 * U);
        a.remitWindow = 1 days;
        _expectOpenReverts(a, GuaranteeTrust.PolicyMismatch.selector);
        uint256 id = _open(nia, "w", 10 * U);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
        // the owner shortens the window afterwards; the signed 14 days still hold
        vm.prank(owner);
        gt.setParams(2000, 2, 500, 3 * U, 1 days, 20 * U, 20 * U, 5, 5);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(GuaranteeTrust.TooEarly.selector);
        gt.markLapsed(id);
        vm.warp(block.timestamp + 12 days);
        gt.markLapsed(id);
    }

    function testGuardianPowerFollowsOwnership() public {
        address next = makeAddr("next-owner");
        vm.prank(owner);
        gt.transferOwnership(next);
        vm.prank(next);
        gt.acceptOwnership();
        assertEq(gt.guardian(), next);
        vm.prank(owner);
        vm.expectRevert(GuaranteeTrust.NotGuardian.selector);
        gt.setPaused(true);
        vm.prank(next);
        gt.setPaused(true);
        assertTrue(gt.paused());
    }

    function testPauseStopsOnlyNewGuarantees() public {
        vm.prank(issuer);
        gt.setLine(nia, 20 * U);
        uint256 id = _open(nia, "a", 10 * U);
        vm.prank(owner);
        gt.setPaused(true);
        _expectOpenReverts(_terms(nia, keccak256("b"), 0, 5 * U), GuaranteeTrust.IsPaused.selector);
        vm.prank(adj);
        gt.markPaid(id, 60 * U, bytes32(0));
    }

    function _assertBooks() internal view {
        assertEq(usdc.balanceOf(address(gt)), gt.reserve() + gt.totalStake(), "token = reserve + stake");
        assertLe(gt.outstanding(), gt.reserve(), "outstanding within reserve");
    }
}
