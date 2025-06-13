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
        // Debug: Print the current working directory
        console.logString(string.concat("Current working directory: ", vm.projectRoot()));
        
        // Debug: Print the sender address
        console.logString(string.concat("Sender address: ", vm.toString(msg.sender)));
        
        // Use the default Anvil account for local deployment
        uint256 deployerPrivateKey = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
        console.logString("Using default Anvil account");
        
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
