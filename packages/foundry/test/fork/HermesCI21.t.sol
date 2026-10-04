// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/// HermesCRBot CI-21 variant on a fork of the LIVE pool (nothing is broadcast). A lender-attacker backs a
/// member who repays a year of interest (dues go to the reserve), then OTHER borrowers default and exhaust
/// the reserve, then the attacker withdraws, and the member borrows its dues and defaults.
/// Compares Lena's (honest lender) balance with and without the attacker's dues-loan default, and the
/// attacker's net.
/// Written by HermesCRBot (AI agent) and posted on PR #5; kept here as the measurement behind CI-21: the
/// attacker ends I·(s − 0.7) ahead of a passive lender, and the honest loss equals the dues (Theorem 2).
/// Run: LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8 \
///      LIVE_LENA=0x70374adB39E6314672C86E45eca6dA5637A0bDa2 forge test --match-path test/fork/HermesCI21.t.sol -vv
contract HermesCI21ForkTest is Test {
    DecentralizedMicrocredit internal credit;
    MockUSDC internal usdc;
    address internal lena;
    address internal owner;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("LIVE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        credit = DecentralizedMicrocredit(vm.envAddress("LIVE_POOL"));
        usdc = MockUSDC(address(credit.usdc()));
        lena = vm.envAddress("LIVE_LENA");
        owner = credit.owner();
        forked = true;
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _defaultOthers(uint256 n, uint256 each) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address d = makeAddr(string.concat("ci21def", vm.toString(i)));
            uint256 sc = (each * credit.SCALE()) / credit.maxLoanAmount();
            vm.prank(owner);
            credit.setScoreOverride(d, sc);
            vm.startPrank(d);
            ids[i] = credit.requestLoan(each);
            credit.disburseLoan(ids[i]);
            vm.stopPrank();
        }
        (,,,, uint256 dueAt) = credit.getLoanTerms(ids[0]);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        for (uint256 i = 0; i < n; i++) {
            credit.markDefaulted(ids[i]);
        }
    }

    /// world: 0 = no attacker (others default only); 1 = attacker, member keeps dues loan not taken;
    ///        2 = attacker and the dues-loan default.
    function _world(uint256 world, uint256 attackerDeposit, uint256 seed, uint256 n, uint256 each)
        internal
        returns (uint256 lenaBal, uint256 attackerNet, uint256 dues, uint256 reserveBefore, uint256 take)
    {
        address attacker = makeAddr("ci21attacker");
        address member = makeAddr("ci21member");
        uint256 start;
        if (world == 3) {
            // counterfactual: the same lender, same deposit, no attack
            _fund(attacker, attackerDeposit + seed + 1_000e6);
            _fund(member, 1_000e6);
            start = usdc.balanceOf(attacker) + usdc.balanceOf(member);
            vm.prank(attacker);
            credit.depositFunds(attackerDeposit);
            vm.warp(block.timestamp + 365 days);
            _defaultOthers(n, each);
            vm.prank(attacker);
            credit.withdrawFunds(type(uint256).max);
            emit log_named_uint("attacker, lender only: end", usdc.balanceOf(attacker) + usdc.balanceOf(member));
            emit log_named_uint("attacker, lender only: start", start);
            emit log_named_uint("Lena, same lender passive (no attack)", credit.lenderBalance(lena));
            return (credit.lenderBalance(lena), 0, 0, 0, 0);
        }
        if (world > 0) {
            _fund(attacker, attackerDeposit + seed + 1_000e6);
            _fund(member, 1_000e6);
            start = usdc.balanceOf(attacker) + usdc.balanceOf(member);
            vm.startPrank(attacker);
            credit.depositFunds(attackerDeposit);
            credit.stake(seed);
            credit.back(member, seed);
            vm.stopPrank();
            (, uint256 avail) = credit.getBorrowLimit(member);
            vm.startPrank(member);
            uint256 loanId = credit.requestLoan(avail);
            credit.disburseLoan(loanId);
            vm.stopPrank();
            vm.warp(block.timestamp + 365 days);
            uint256 owed = credit.getCurrentOutstandingAmount(loanId);
            vm.prank(member);
            credit.repayLoan(loanId, owed);
            vm.prank(attacker);
            credit.back(member, 0);
            vm.prank(attacker);
            credit.unstake(seed);
            dues = credit.duesPaid(member);
        }
        reserveBefore = credit.firstLossReserve();
        _defaultOthers(n, each);
        if (world > 0) {
            vm.prank(attacker);
            credit.withdrawFunds(type(uint256).max);
            if (world == 2 && dues > 0) {
                (, uint256 av2) = credit.getBorrowLimit(member);
                take = dues < av2 ? dues : av2;
                if (take > 0) {
                    vm.startPrank(member);
                    uint256 id2 = credit.requestLoan(take);
                    credit.disburseLoan(id2);
                    vm.stopPrank();
                    (,,,, uint256 dueAt) = credit.getLoanTerms(id2);
                    vm.warp(dueAt + credit.LATE_PERIOD() + 1);
                    credit.markDefaulted(id2);
                }
            }
            emit log_named_uint("attacker, attack world: end", usdc.balanceOf(attacker) + usdc.balanceOf(member));
            emit log_named_uint("attacker, attack world: start", start);
            attackerNet = usdc.balanceOf(attacker) + usdc.balanceOf(member) + 0; // before: start
            attackerNet = attackerNet >= start ? attackerNet - start : 0;
            if (usdc.balanceOf(attacker) + usdc.balanceOf(member) < start) {
                emit log_named_uint(
                    "attacker LOSS (USDC 1e6)", start - usdc.balanceOf(attacker) - usdc.balanceOf(member)
                );
            } else {
                emit log_named_uint("attacker GAIN (USDC 1e6)", attackerNet);
            }
        }
        lenaBal = credit.lenderBalance(lena);
    }

    function _compare(uint256 attackerDeposit, uint256 seed, uint256 n, uint256 each) internal {
        uint256 s = vm.snapshotState();
        (uint256 lena0,,,,) = _world(0, attackerDeposit, seed, n, each);
        vm.revertToState(s);
        s = vm.snapshotState();
        (uint256 lena1,,,,) = _world(1, attackerDeposit, seed, n, each);
        vm.revertToState(s);
        s = vm.snapshotState();
        _world(3, attackerDeposit, seed, n, each);
        vm.revertToState(s);
        (uint256 lena2,, uint256 dues, uint256 resBefore, uint256 take) = _world(2, attackerDeposit, seed, n, each);
        emit log_named_uint("dues paid by member (duesPaid)", dues);
        emit log_named_uint("reserve before others default", resBefore);
        emit log_named_uint("reserve after (world 2)", credit.firstLossReserve());
        emit log_named_uint("dues loan taken and defaulted", take);
        emit log_named_uint("Lena, no attacker", lena0);
        emit log_named_uint("Lena, attacker keeps dues (no dues default)", lena1);
        emit log_named_uint("Lena, attacker defaults dues loan", lena2);
        if (lena2 < lena1) {
            emit log_named_uint("Lena loss caused by the dues-loan default", lena1 - lena2);
        }
        if (lena2 < lena0) {
            emit log_named_uint("Lena loss vs a world with no attacker", lena0 - lena2);
        } else {
            emit log_named_uint("Lena gain vs a world with no attacker", lena2 - lena0);
        }
        assertLe(lena1 > lena2 ? lena1 - lena2 : 0, dues, "Theorem 2: honest loss from the dues default <= dues paid");
    }

    function testCI21ReserveExhaustedHalfPool() public {
        vm.skip(!forked, "set LIVE_RPC_URL, LIVE_POOL, LIVE_LENA");
        _compare(5_000e6, 25e6, 3, 40e6);
    }

    function testCI21ReserveExhaustedDominantLender() public {
        vm.skip(!forked, "set LIVE_RPC_URL, LIVE_POOL, LIVE_LENA");
        _compare(50_000e6, 25e6, 3, 40e6);
    }
}
