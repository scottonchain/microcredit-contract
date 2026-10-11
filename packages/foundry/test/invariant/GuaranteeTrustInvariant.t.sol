// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../../contracts/GuaranteeTrust.sol";

/// @dev Random sequences of stake, attest, withdraw, lines, guarantees, payments, remittances and claims.
contract GuaranteeTrustHandler is Test {
    uint256 internal constant U = 1e6;
    MockUSDC public usdc;
    GuaranteeTrust public gt;
    address public adj;
    address public issuer;
    address[] public actors;
    uint256 public clientNonce;
    uint256 public claimsPaid;

    constructor(MockUSDC usdc_, GuaranteeTrust gt_, address adj_, address issuer_) {
        usdc = usdc_;
        gt = gt_;
        adj = adj_;
        issuer = issuer_;
        for (uint256 i; i < 6; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, 1000 * U);
            vm.prank(a);
            usdc.approve(address(gt), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
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

    function open(uint256 who, uint256 amt, bool reuseClient) external {
        amt = bound(amt, 1, 20 * U);
        bytes32 client = keccak256(abi.encode(reuseClient ? clientNonce : ++clientNonce));
        vm.prank(adj);
        try gt.openGuarantee(_a(who), client, amt, bytes32(0)) { } catch { }
    }

    function settle(uint256 idSeed, uint256 wage, uint8 how) external {
        uint256 n = gt.guaranteeCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        wage = bound(wage, 0, 100 * U);
        vm.startPrank(adj);
        if (how % 3 == 0) try gt.markPaid(id, wage, bytes32(0)) { } catch { }
        else if (how % 3 == 1) {
            uint256 before = gt.reserve();
            try gt.claim(id, bytes32(0)) {
                claimsPaid += 1;
                before;
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
        h = new GuaranteeTrustHandler(usdc, gt, adj, issuer);
        targetContract(address(h));
    }

    /// @dev Every token is either in the reserve or someone's stake.
    function invariant_books() public view {
        assertEq(usdc.balanceOf(address(gt)), gt.reserve() + gt.totalStake());
        assertLe(gt.outstanding(), gt.reserve());
    }

    /// @dev Backing is conserved: what members received equals what attesters gave; commitments fit inside it.
    function invariant_backingConserved() public view {
        uint256 n = h.actorCount();
        uint256 given;
        uint256 received;
        for (uint256 i; i < n; i++) {
            GuaranteeTrust.Member memory m = gt.memberOf(h.actors(i));
            given += m.backingGiven;
            received += m.backingReceived;
            assertLe(m.backingCommitted, m.backingReceived);
            assertLe(m.committedLine, m.line);
            assertLe(m.committedDues, m.dues);
            assertLe(m.backingGiven, m.stake + m.dues - m.committedDues, "backing given exceeds own stake and dues");
            uint256 sumIn;
            address[] memory atts = gt.attestersOf(h.actors(i));
            for (uint256 k; k < atts.length; k++) {
                sumIn += gt.backing(atts[k], h.actors(i));
            }
            assertEq(sumIn, m.backingReceived, "per-member backing sum");
        }
        assertEq(given, received, "given equals received");
    }

    /// @dev The issuer never holds plus spends more than its budget.
    function invariant_issuerBudget() public view {
        assertLe(gt.issuerHeld() + gt.issuerSpent(), gt.issuerBudget());
    }
}
