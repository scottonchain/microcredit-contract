// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Attestation} from "../src/Attestation.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is Script {
    function run() external {
        // Get the private key from the environment variable
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy the contract
        Attestation attestation = new Attestation();
        
        // Log the deployment
        console.logString(string.concat("Attestation deployed at: ", vm.toString(address(attestation))));
        
        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Save deployment information
        string memory json = "{}";
        json = vm.serializeString(json, "networkName", "foundry");
        json = vm.serializeAddress(json, "Attestation", address(attestation));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/31337.json"));
    }

    function test() public {}
}
