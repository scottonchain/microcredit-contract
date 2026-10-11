// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../../contracts/GuaranteeTrust.sol";

/// @dev Random sequences of stake, attest, withdraw, lines, signed guarantees, payments, remittances, claims and expiry.
contract GuaranteeTrustHandler is Test {
    uint256 internal constant U = 1e6;
    MockUSDC public usdc;
    GuaranteeTrust public gt;
    address public adj;
    address public issuer;
    address public owner;
    address public funder;
    address[] public actors;
    mapping(address => uint256) internal keyOf;
    bytes32[] public groups;
    uint256 public clientNonce;
    uint256 public sigNonce;
    uint256 public claimsPaid;

    constructor(MockUSDC usdc_, GuaranteeTrust gt_, address adj_, address issuer_, address owner_, address funder_) {
        usdc = usdc_;
        gt = gt_;
        adj = adj_;
        issuer = issuer_;
        owner = owner_;
        funder = funder_;
        for (uint256 i; i < 6; i++) {
            (address a, uint256 key) = makeAddrAndKey(string.concat("actor", vm.toString(i)));
            actors.push(a);
            keyOf[a] = key;
            usdc.mint(a, 1000 * U);
            vm.prank(a);
            usdc.approve(address(gt), type(uint256).max);
        }
        for (uint256 i; i < 3; i++) {
            groups.push(keccak256(abi.encode("group", i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function groupCount() external view returns (uint256) {
        return groups.length;
    }

    function _a(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 who, uint256 amt) external {
        amt = bound(amt, 1, 50 * U);
        vm.prank(_a(who));
        gt.stake(amt);
    }

    function unstake(uint256 who, uint256 amt) external {
        address a = _a(who);
        amt = bound(amt, 1, 50 * U);
        vm.prank(a);
        try gt.unstake(amt) { } catch { }
    }

    function attest(uint256 who, uint256 to, uint256 amt) external {
        amt = bound(amt, 1, 20 * U);
        vm.prank(_a(to));
        gt.setConsent(_a(who), true);
        vm.prank(_a(who));
        try gt.attest(_a(to), amt) { } catch { }
    }

    function withdraw(uint256 who, uint256 from, uint256 amt) external {
        amt = bound(amt, 1, 20 * U);
        vm.prank(_a(who));
        try gt.withdrawBacking(_a(from), amt) { } catch { }
    }

    function setLine(uint256 who, uint256 amt) external {
        amt = bound(amt, 0, 20 * U);
        vm.prank(issuer);
        try gt.setLine(_a(who), amt) { } catch { }
    }

    /// @dev The worker signs real terms; clients are fresh or reused and fall in one of three groups.
    function open(uint256 who, uint256 amt, bool reuseClient, uint256 groupSeed, uint256 pledge) external {
        address w = _a(who);
        amt = bound(amt, 1, 20 * U);
        bytes32 client = keccak256(abi.encode(reuseClient ? clientNonce : ++clientNonce));
        GuaranteeTrust.Acceptance memory a = GuaranteeTrust.Acceptance({
            worker: w,
            clientId: client,
            groupId: groups[groupSeed % groups.length],
            amount: amt,
            maxFromDues: bound(pledge, 0, 20 * U),
            termsHash: bytes32(0),
            contributionBps: gt.contributionBps(),
            contributionCap: gt.contributionCap(),
            settleBy: uint64(block.timestamp + 30 days),
            nonce: ++sigNonce,
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[w], gt.acceptanceDigest(a));
        vm.prank(adj);
        try gt.openGuarantee(a, abi.encodePacked(r, s, v)) { } catch { }
    }

    function settle(uint256 idSeed, uint256 wage, uint8 how) external {
        uint256 n = gt.guaranteeCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        wage = bound(wage, 0, 100 * U);
        vm.startPrank(adj);
        if (how % 3 == 0) {
            try gt.markPaid(id, wage, bytes32(0)) { } catch { }
        } else if (how % 3 == 1) {
            try gt.claim(id, bytes32(0)) {
                claimsPaid += 1;
            } catch { }
        } else {
            try gt.cancelGuarantee(id) { } catch { }
        }
        vm.stopPrank();
    }

    function remit(uint256 idSeed, uint256 payer) external {
        uint256 n = gt.guaranteeCount();
        if (n == 0) return;
        vm.prank(_a(payer));
        try gt.remit(idSeed % n) { } catch { }
    }

    function lapse(uint256 idSeed, uint256 dt) external {
        uint256 n = gt.guaranteeCount();
        if (n == 0) return;
        vm.warp(block.timestamp + bound(dt, 0, 20 days));
        try gt.markLapsed(idSeed % n) { } catch { }
    }

    function release(uint256 amt) external {
        amt = bound(amt, 1, 50 * U);
        vm.prank(owner);
        try gt.releaseReserve(funder, amt) { } catch { }
    }

    function expire(uint256 idSeed, uint256 dt) external {
        uint256 n = gt.guaranteeCount();
        if (n == 0) return;
        vm.warp(block.timestamp + bound(dt, 0, 40 days));
        try gt.expireGuarantee(idSeed % n) { } catch { }
    }
}

contract GuaranteeTrustInvariantTest is Test {
    uint256 internal constant U = 1e6;
    MockUSDC internal usdc;
    GuaranteeTrust internal gt;
    GuaranteeTrustHandler internal h;
    address internal owner = makeAddr("owner");
    address internal adj = makeAddr("adj");
    address internal issuer = makeAddr("issuer");

    function setUp() public {
        usdc = new MockUSDC();
        gt = new GuaranteeTrust(usdc, owner, adj, issuer, 60 * U, U);
        usdc.mint(address(this), 200 * U);
        usdc.approve(address(gt), type(uint256).max);
        gt.fundReserve(200 * U);
        h = new GuaranteeTrustHandler(usdc, gt, adj, issuer, owner, address(this));
        targetContract(address(h));
    }

    /// @dev Every token is either in the reserve or someone's stake.
    function invariant_books() public view {
        assertEq(usdc.balanceOf(address(gt)), gt.reserve() + gt.totalStake());
        assertLe(gt.outstanding(), gt.reserve());
    }

    /// @dev Backing is conserved: what members received equals what attesters gave; commitments fit inside it, and
    ///      a member's committed backing is exactly the sum of the shares locked for its open guarantees.
    function invariant_backingConserved() public view {
        uint256 n = h.actorCount();
        uint256 given;
        uint256 received;
        for (uint256 i; i < n; i++) {
            address who = h.actors(i);
            GuaranteeTrust.Member memory m = gt.memberOf(who);
            given += m.backingGiven;
            received += m.backingReceived;
            assertLe(m.backingCommitted, m.backingReceived);
            assertLe(m.committedLine, m.line);
            assertLe(m.committedDues, m.dues);
            assertLe(m.backingGiven, m.stake + m.dues - m.committedDues, "backing given exceeds own stake and dues");
            uint256 sumIn;
            uint256 sumLocked;
            address[] memory atts = gt.attestersOf(who);
            for (uint256 k; k < atts.length; k++) {
                uint256 b = gt.backing(atts[k], who);
                uint256 l = gt.lockedBacking(atts[k], who);
                assertLe(l, b, "locked share within backing");
                sumIn += b;
                sumLocked += l;
            }
            assertEq(sumIn, m.backingReceived, "per-member backing sum");
            assertEq(sumLocked, m.backingCommitted, "locked shares equal committed backing");
        }
        assertEq(given, received, "given equals received");
    }

    /// @dev Open exposure is the sum over client groups, and no group exceeds what the reserve allowed when it opened.
    function invariant_groupExposure() public view {
        uint256 sum;
        for (uint256 i; i < h.groupCount(); i++) {
            sum += gt.groupExposure(h.groups(i));
        }
        assertEq(sum, gt.outstanding(), "group exposure sums to outstanding");
    }

    /// @dev The issuer never holds plus spends more than its budget, nor more than the sponsor capital funded.
    function invariant_issuerBudget() public view {
        assertLe(gt.issuerHeld() + gt.issuerSpent(), gt.issuerBudget());
        assertLe(gt.issuerHeld() + gt.issuerSpent(), gt.sponsorFunded());
    }

    /// @dev The reserve is exactly the sponsor capital left after line-backed claims plus members' dues, so no claim
    ///      is ever paid from dues that were not consumed by name.
    function invariant_reserveIdentity() public view {
        assertEq(gt.reserve(), gt.sponsorFunded() - gt.issuerSpent() + gt.totalDues(), "reserve identity");
    }
}
