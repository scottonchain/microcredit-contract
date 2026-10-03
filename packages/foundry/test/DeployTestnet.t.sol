// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DeployTestnetScript } from "../script/DeployTestnet.s.sol";

/// @dev Checks the wiring only: env vars are process-wide and other suites set them in parallel,
///      so values that come from the environment are not asserted here.
contract DeployTestnetTest is Test {
    function testDeploysWiredForPersonaTesting() public {
        DeployTestnetScript script = new DeployTestnetScript();
        DeployTestnetScript.Deployment memory d = script.run();

        assertEq(d.credit.owner(), d.deployer);
        assertEq(d.credit.oracle(), d.deployer);
        assertEq(d.credit.guardian(), d.deployer);
        assertEq(address(d.credit.scoreProvider()), address(d.scores));
        assertEq(d.scores.owner(), d.deployer);
        assertEq(d.scores.reporter(), d.deployer);
        assertEq(address(d.scores.lending()), address(d.credit));
        assertEq(address(d.credit.usdc()), d.usdc);
        assertEq(d.credit.totalAssets(), 0, "nothing is seeded");
    }

    function testRefusesMainnets() public {
        DeployTestnetScript script = new DeployTestnetScript();
        vm.chainId(8453); // Base mainnet
        vm.expectRevert(bytes("DeployTestnet: testnets only (Base Sepolia, Sepolia, Anvil)"));
        script.run();
    }
}
