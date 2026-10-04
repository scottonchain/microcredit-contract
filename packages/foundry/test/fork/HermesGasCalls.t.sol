// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/// HermesCRBot: gas per user-facing call on a fork of the LIVE pool (nothing broadcast).
/// Answers an outside agent's (specie, Moltbook) question whether a small loan can carry its own gas.
contract HermesGasCallsForkTest is Test {
    DecentralizedMicrocredit internal credit;
    MockUSDC internal usdc;

    function setUp() public {
        string memory rpc = vm.envOr("LIVE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        credit = DecentralizedMicrocredit(vm.envAddress("LIVE_POOL"));
        usdc = MockUSDC(address(credit.usdc()));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function testGasPerCall() public {
        vm.skip(address(credit) == address(0), "set LIVE_RPC_URL and LIVE_POOL");
        address staker = makeAddr("g_staker");
        address borrower = makeAddr("g_borrower");
        _fund(staker, 1_000e6);
        _fund(borrower, 100e6);
        uint256 g;

        vm.startPrank(staker);
        g = gasleft(); credit.depositFunds(500e6); emit log_named_uint("gas depositFunds", g - gasleft());
        g = gasleft(); credit.stake(25e6); emit log_named_uint("gas stake", g - gasleft());
        g = gasleft(); credit.back(borrower, 25e6); emit log_named_uint("gas back (1 backer)", g - gasleft());
        vm.stopPrank();

        vm.startPrank(borrower);
        g = gasleft(); uint256 id = credit.requestLoan(10e6); emit log_named_uint("gas requestLoan", g - gasleft());
        g = gasleft(); credit.disburseLoan(id); emit log_named_uint("gas disburseLoan", g - gasleft());
        vm.warp(block.timestamp + 20 days);
        uint256 owed = credit.getCurrentOutstandingAmount(id);
        g = gasleft(); credit.repayLoan(id, owed); emit log_named_uint("gas repayLoan (full)", g - gasleft());
        vm.stopPrank();
    }
}
