// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Vm } from "forge-std/Vm.sol";

/// @dev One fork selector for the Circle-USDC test suites. Evidence runs set a block explicitly;
///      an interactive test without that setting retains the latest-block behavior.
library BaseSepoliaFork {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function select(string memory rpc) internal {
        uint256 forkBlock = vm.envOr("BASE_SEPOLIA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 84532, "expected Base Sepolia fork");
    }
}
