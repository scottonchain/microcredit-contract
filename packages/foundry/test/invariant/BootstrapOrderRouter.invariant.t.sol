// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { BootstrapOrderRouter } from "../../contracts/BootstrapOrderRouter.sol";
import { StakeRouterBase } from "../../contracts/TransitiveStakeRouter.sol";
import { MicrocreditTestBase } from "../utils/MicrocreditTestBase.sol";
import { OrderRouterHandler } from "./OrderRouterHandler.sol";

/**
 * @dev Stateful fuzzing of the bootstrap router's two ledgers (Codex's repair spec, regression 6): roots deposit and
 *      withdraw, customers fund, refund and settle orders, anyone originates, repays, defaults and syncs, and strays
 *      are donated. After every call:
 *
 *      O1  the router holds exactly the roots' free USDC, the customers' escrow and what was donated to it;
 *      O2  the escrow held is the sum of the prices of the open (Funded or Bound) orders;
 *      O3  each root's deposits less withdrawals less attributed losses is its free plus locked balance, so root
 *          funds are never consumed by an order and escrow is never consumed by a root;
 *      O4  locked USDC (per root, and in total) is the sum of the open lots' paths, and free is what is left;
 *      O5  each shared root-to-mid edge's live exposure is the sum of the open paths over it, across all workers, and
 *          each mid-to-worker edge's is that worker's;
 *      O6  the pool lends out no more than the open lots hold, and lenders lose no principal: the worker's vault is
 *          the only backer, so a default is covered in full by the roots' stake;
 *      O7  every base unit the handler created sits with a known holder.
 */
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract BootstrapOrderRouterInvariantTest is MicrocreditTestBase {
    uint256 internal constant POOL = 10_000e6;

    BootstrapOrderRouter internal router;
    OrderRouterHandler internal handler;
    uint256 internal baseline;

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(address(0x1E4D), POOL);
        router = new BootstrapOrderRouter(credit);
        handler = new OrderRouterHandler(credit, usdc, router);
        router.setOfficer(vm.addr(handler.OFFICER_KEY()), 1);
        router.setOfficerAdmin(address(handler)); // the handler rotates and revokes the officer during the campaign
        baseline = handler.holders();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = OrderRouterHandler.rootDeposit.selector;
        selectors[1] = OrderRouterHandler.rootWithdraw.selector;
        selectors[2] = OrderRouterHandler.fund.selector;
        selectors[3] = OrderRouterHandler.originate.selector;
        selectors[4] = OrderRouterHandler.settle.selector;
        selectors[5] = OrderRouterHandler.refund.selector;
        selectors[6] = OrderRouterHandler.repay.selector;
        selectors[7] = OrderRouterHandler.warp.selector;
        selectors[8] = OrderRouterHandler.defaultOne.selector;
        selectors[9] = OrderRouterHandler.syncOne.selector;
        selectors[10] = OrderRouterHandler.rotateOfficer.selector;
        selectors[11] = OrderRouterHandler.reapprove.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_O1_routerHoldsExactlyFreeRootsPlusEscrowPlusStrays() public view {
        assertEq(
            usdc.balanceOf(address(router)),
            router.totalFree() + router.totalEscrowHeld() + handler.strayInRouter(),
            "router balance"
        );
    }

    function invariant_O2_escrowHeldIsTheOpenOrdersPrices() public view {
        assertEq(router.totalEscrowHeld(), handler.sumEscrow(), "escrow held");
    }

    function invariant_O3_eachRootConserves() public view {
        uint256 sumFree;
        uint256 sumLocked;
        for (uint256 i = 0; i < handler.NR(); i++) {
            address r = handler.roots(i);
            assertEq(
                handler.deposited(r) - handler.withdrawn(r) - router.lossOf(r),
                router.free(r) + router.locked(r),
                "deposits less withdrawals less losses"
            );
            sumFree += router.free(r);
            sumLocked += router.locked(r);
        }
        assertEq(router.totalFree(), sumFree, "totalFree");
        assertEq(router.totalLocked(), sumLocked, "totalLocked");
    }

    function invariant_O4_lockedFollowsTheOpenPaths() public view {
        assertEq(router.totalLocked(), handler.sumOpenLots(), "locked is the open lots");
        for (uint256 i = 0; i < handler.NR(); i++) {
            address r = handler.roots(i);
            assertEq(router.locked(r), handler.sumLockedOf(r), "a root's locked is its open paths");
        }
    }

    function invariant_O5_sharedEdgeExposureIsTheSumAcrossWorkers() public view {
        for (uint256 i = 0; i < handler.NR(); i++) {
            for (uint256 j = 0; j < handler.NM(); j++) {
                address r = handler.roots(i);
                address m = handler.mids(j);
                assertEq(
                    router.edgeUsed(router.edgeKey(r, m, address(0))),
                    handler.sumRootEdge(r, m),
                    "root edge: all workers together"
                );
            }
        }
        for (uint256 w = 0; w < handler.NW(); w++) {
            address worker = handler.workers(w);
            for (uint256 j = 0; j < handler.NM(); j++) {
                address m = handler.mids(j);
                assertEq(
                    router.edgeUsed(router.edgeKey(m, worker, worker)),
                    handler.sumMidEdge(m, w),
                    "mid edge: the worker's"
                );
            }
        }
    }

    function invariant_O6_poolExposureWithinTheLotsAndLendersLoseNothing() public view {
        assertLe(credit.totalLentOut(), handler.sumOpenLots(), "the pool lent no more than the open lots hold");
        assertGe(credit.totalAssets(), POOL, "a worker's vault is its only backer, so every loss is the roots'");
    }

    function invariant_O7_everyCreatedUnitHasAKnownHolder() public view {
        assertEq(handler.holders(), baseline + handler.created(), "attributed");
    }

    function afterInvariant() public {
        string memory line = string.concat(
            "order router funded=",
            vm.toString(handler.funded()),
            " originated=",
            vm.toString(handler.originated()),
            " multipath=",
            vm.toString(handler.multiPath()),
            " settled=",
            vm.toString(handler.settled()),
            " refunded=",
            vm.toString(handler.refunded()),
            " defaulted=",
            vm.toString(handler.defaulted())
        );
        console.log(line);
        string memory statsFile = vm.envOr("INVARIANT_STATS_FILE", string(""));
        if (bytes(statsFile).length != 0) vm.writeLine(statsFile, line);
    }
}
