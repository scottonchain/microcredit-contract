// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console } from "forge-std/console.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { StakeVault, TransitiveStakeRouter } from "../../contracts/TransitiveStakeRouter.sol";
import { MicrocreditTestBase } from "../utils/MicrocreditTestBase.sol";
import { RouterHandler } from "./RouterHandler.sol";

/**
 * @dev Stateful fuzzing of the two-hop router's allocation certificates (docs/TRANSITIVE_STAKE_ROUTER.md).
 *      Roots deposit, withdraw and revoke; borrowers (all managed by the router) borrow against certificates
 *      of one to four paths with tight or loose consent limits; strangers repay in part or in full; loans
 *      run past due and default; anyone syncs. After every call:
 *
 *      R1  the router holds exactly the free balances and what was donated to it;
 *      R2  each root's deposits less withdrawals less attributed losses is its free plus locked balance;
 *      R3  each root's locked balance is the sum of its open paths, each edge's live exposure the sum of the
 *          open paths over it, and a closed lot leaves no exposure and no stake in its vault;
 *      R4  an open lot's vault holds the whole lot as secured backing (and no unsecured backing) while its
 *          loan is active, so the pool's cover of a loan is the roots' USDC and nothing else;
 *      R5  lenders lose no principal beyond the pool's own rounding: every loan in this run is a router loan,
 *          so total assets never fall below the pool's deposit less the dust the pool leaves unslashed;
 *      R7  the pool's principal lent out equals the active lots' unpaid principal (managed pool exposure equals
 *          the router-recorded active principal);
 *      R6  the handler's own checks at every sync (loss attributed equals the unpaid principal, no root bears
 *          more than its own paths nor less than its pro rata floor, each root gets back what it put in less
 *          its share) and every refusal being one of the two documented ones.
 */
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract TransitiveStakeRouterInvariantTest is MicrocreditTestBase {
    uint256 internal constant POOL = 10_000e6;

    TransitiveStakeRouter internal router;
    RouterHandler internal handler;

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(makeAddr("poolLender"), POOL);
        router = new TransitiveStakeRouter(credit);
        handler = new RouterHandler(credit, usdc, router);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = RouterHandler.deposit.selector;
        selectors[1] = RouterHandler.withdraw.selector;
        selectors[2] = RouterHandler.revoke.selector;
        selectors[3] = RouterHandler.originate.selector;
        selectors[4] = RouterHandler.repay.selector;
        selectors[5] = RouterHandler.warp.selector;
        selectors[6] = RouterHandler.defaultOne.selector;
        selectors[7] = RouterHandler.syncOne.selector;
        selectors[8] = RouterHandler.thirdPartyBack.selector;
        selectors[9] = RouterHandler.thirdPartyUnback.selector;
        selectors[10] = RouterHandler.attemptDirect.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_R1_routerHoldsExactlyTheFreeBalancesAndStrayFunds() public view {
        uint256 sumFree;
        uint256 sumLocked;
        for (uint256 i = 0; i < handler.NR(); i++) {
            sumFree += router.free(handler.roots(i));
            sumLocked += router.locked(handler.roots(i));
        }
        assertEq(router.totalFree(), sumFree, "totalFree is the sum of free balances");
        assertEq(router.totalLocked(), sumLocked, "totalLocked is the sum of locked balances");
        assertEq(usdc.balanceOf(address(router)), sumFree + handler.strayInRouter(), "router balance");
    }

    function invariant_R2_eachRootConserves() public view {
        for (uint256 i = 0; i < handler.NR(); i++) {
            address r = handler.roots(i);
            assertEq(router.lossOf(r), handler.modelLoss(r), "attributed loss follows the model");
            assertEq(
                handler.deposited(r) - handler.withdrawn(r) - router.lossOf(r),
                router.free(r) + router.locked(r),
                "deposits less withdrawals less losses"
            );
        }
    }

    function invariant_R3_lockedAndEdgeExposureFollowTheOpenPaths() public view {
        for (uint256 i = 0; i < handler.NR(); i++) {
            address r = handler.roots(i);
            assertEq(router.locked(r), handler.expectedLocked(r), "locked is the sum of open paths");
            for (uint256 j = 0; j < handler.NM(); j++) {
                address m = handler.mids(j);
                for (uint256 k = 0; k < handler.NB(); k++) {
                    address b = handler.borrowers(k);
                    assertEq(
                        router.edgeUsed(router.edgeKey(r, m, b)),
                        handler.expectedEdgeUsed(r, m, b),
                        "root edge exposure"
                    );
                }
            }
        }
        for (uint256 j = 0; j < handler.NM(); j++) {
            for (uint256 k = 0; k < handler.NB(); k++) {
                address m = handler.mids(j);
                address b = handler.borrowers(k);
                assertEq(
                    router.edgeUsed(router.edgeKey(m, b, b)), handler.expectedEdgeUsed(m, b, b), "mid edge exposure"
                );
            }
        }
    }

    function invariant_R4_openLotsAreSecuredByTheVaultAndClosedOnesLeaveNothing() public view {
        for (uint256 k = 0; k < handler.NB(); k++) {
            address b = handler.borrowers(k);
            StakeVault vault = router.vaultOf(b);
            (bool open, uint256 loanId, uint256 amount,) = router.lotOf(b);
            assertEq(open, handler.lotOpen(b), "lot openness follows the model");
            if (address(vault) == address(0)) {
                assertFalse(open);
                continue;
            }
            (uint256 secured, uint256 unsecured) = credit.getBacking(address(vault), b);
            assertEq(unsecured, 0, "never unsecured backing");
            if (!open) {
                assertEq(credit.stakeOf(address(vault)), 0, "a closed lot leaves no stake in the vault");
                assertEq(secured, 0);
                continue;
            }
            assertEq(loanId, handler.lotLoan(b));
            assertEq(amount, handler.lotAmount(b));
            (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(loanId);
            if (status == DecentralizedMicrocredit.LoanStatus.Active) {
                assertEq(credit.stakeOf(address(vault)), amount, "the vault stakes the whole lot");
                assertEq(secured, amount, "and backs the borrower with all of it");
            } else {
                assertLe(credit.stakeOf(address(vault)), amount);
            }
        }
    }

    function invariant_R5_lendersLosePrincipalOnlyToThePoolsRounding() public view {
        // every loan is a router loan, covered by the vault's stake alone: the only shortfall is the dust the
        // pool leaves unslashed when it splits a default pro rata among backers (at most backers - 1 units each)
        assertGe(credit.totalAssets() + handler.dust(), POOL, "every loan is covered by the roots' stake");
    }

    function invariant_R7_managedPoolExposureEqualsRouterRecordedActivePrincipal() public view {
        // every loan is a router loan, so the pool's principal lent out is exactly the active lots' unpaid principal
        assertEq(credit.totalLentOut(), handler.expectedLentOut(), "pool exposure equals the router's active principal");
    }

    function invariant_R6_handlerChecksHold() public view {
        assertEq(handler.violations(), 0, "a sync or a withdrawal broke a documented rule");
        assertEq(handler.unexpectedReverts(), 0, "a call reverted for a reason other than the two documented ones");
    }

    /// @dev One summary line per run, appended to INVARIANT_STATS_FILE when set (forge shows only the last run).
    function afterInvariant() public {
        string memory line = string.concat(
            "router originations=",
            vm.toString(handler.originations()),
            " refusals=",
            vm.toString(handler.refusals()),
            " repaid=",
            vm.toString(handler.repaidLots()),
            " defaulted=",
            vm.toString(handler.defaultedLots()),
            " partial_repay_defaults=",
            vm.toString(handler.partialRepayDefaults()),
            " multipath=",
            vm.toString(handler.multiPathLots()),
            " loss=",
            vm.toString(handler.totalLossAttributed()),
            " revocations=",
            vm.toString(handler.revocations()),
            " third_party_backings=",
            vm.toString(handler.thirdPartyBackings()),
            " shared_slash_defaults=",
            vm.toString(handler.sharedSlashDefaults()),
            " bypass_attempts=",
            vm.toString(handler.bypassAttempts()),
            " dust=",
            vm.toString(handler.dust())
        );
        console.log(line);
        string memory statsFile = vm.envOr("INVARIANT_STATS_FILE", string(""));
        if (bytes(statsFile).length != 0) vm.writeLine(statsFile, line);
    }
}
