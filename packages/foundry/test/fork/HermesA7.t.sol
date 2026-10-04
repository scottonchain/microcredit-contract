// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/// HermesCRBot A7 on a fork of the LIVE pool (nothing is broadcast): an attacker who is also a
/// large lender stakes a seed, backs a fresh member, lets the member borrow and repay with interest
/// (the attacker recaptures its share as a lender), withdraws, then has the member borrow the dues
/// and default. Claim under test: the attacker cannot end with more than it put in, and the
/// honest lender (Lena, 5,000 USDC on the live pool) loses nothing.
/// Written by HermesCRBot (AI agent) and posted on PR #5; kept here as a regression test (CI-21).
/// Run: LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8 \
///      LIVE_LENA=0x70374adB39E6314672C86E45eca6dA5637A0bDa2 forge test --match-path test/fork/HermesA7.t.sol -vv
contract HermesA7ForkTest is Test {
    DecentralizedMicrocredit internal credit;
    MockUSDC internal usdc;
    address internal lena;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("LIVE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        credit = DecentralizedMicrocredit(vm.envAddress("LIVE_POOL"));
        usdc = MockUSDC(address(credit.usdc()));
        lena = vm.envAddress("LIVE_LENA");
        forked = true;
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _run(uint256 attackerDeposit, uint256 seed) internal {
        address attacker = makeAddr("a7attacker");
        address member = makeAddr("a7member");
        _fund(attacker, attackerDeposit + seed + 1_000e6);
        _fund(member, 1_000e6); // the attacker funds whatever interest is due

        uint256 lenaBefore = credit.lenderBalance(lena);
        uint256 attackerStart = usdc.balanceOf(attacker) + usdc.balanceOf(member);

        vm.startPrank(attacker);
        credit.depositFunds(attackerDeposit);
        credit.stake(seed);
        credit.back(member, seed);
        vm.stopPrank();

        (, uint256 avail) = credit.getBorrowLimit(member);
        assertEq(avail, seed, "the member can borrow exactly the seed");
        vm.startPrank(member);
        uint256 loanId = credit.requestLoan(avail);
        credit.disburseLoan(loanId);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        vm.startPrank(member);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();

        vm.prank(attacker);
        credit.back(member, 0);
        vm.prank(attacker);
        credit.unstake(seed);

        vm.prank(attacker);
        credit.withdrawFunds(type(uint256).max);

        uint256 dues = credit.duesPaid(member);
        uint256 kept;
        if (dues > 0) {
            (, uint256 av2) = credit.getBorrowLimit(member);
            uint256 take = dues < av2 ? dues : av2;
            if (take > 0) {
                vm.startPrank(member);
                uint256 id2 = credit.requestLoan(take);
                credit.disburseLoan(id2);
                vm.stopPrank();
                (,,,, uint256 dueAt) = credit.getLoanTerms(id2);
                vm.warp(dueAt + credit.LATE_PERIOD() + 1);
                credit.markDefaulted(id2);
                kept = take;
            }
        }

        uint256 attackerEnd = usdc.balanceOf(attacker) + usdc.balanceOf(member);
        emit log_named_uint("attacker start (USDC 1e6)", attackerStart);
        emit log_named_uint("attacker end   (USDC 1e6)", attackerEnd);
        emit log_named_uint("dues paid by member", dues);
        emit log_named_uint("loan kept after default", kept);
        emit log_named_uint("Lena before", lenaBefore);
        emit log_named_uint("Lena after ", credit.lenderBalance(lena));
        assertLe(attackerEnd, attackerStart, "the attacker cannot profit");
        assertGe(credit.lenderBalance(lena), lenaBefore, "the honest lender loses nothing");
    }

    function testA7LargeLenderSeedFarmOnLivePool() public {
        vm.skip(!forked, "set LIVE_RPC_URL, LIVE_POOL, LIVE_LENA");
        _run(5_000e6, 25e6);
    }

    function testA7LenderDominatesPool() public {
        vm.skip(!forked, "set LIVE_RPC_URL, LIVE_POOL, LIVE_LENA");
        _run(50_000e6, 25e6); // about 90% of the pool
    }
}
