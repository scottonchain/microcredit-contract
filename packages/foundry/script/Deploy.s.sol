// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../contracts/YourContract.sol";

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
        
        // Deploy the main contract
        YourContract yourContract = new YourContract(
            msg.sender, // initialOwner
            50000,      // rMin (5%)
            200000,     // rMax (20%)
            msg.sender, // _usdc (using sender address as placeholder)
            msg.sender  // _oracle
        );
        
        // Log the deployment
        console.logString(string.concat("YourContract deployed at: ", vm.toString(address(yourContract))));
        
        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Save deployment information
        string memory json = "{}";
        json = vm.serializeAddress(json, "YourContract", address(yourContract));
        vm.writeFile("deployment.json", json);
    }

    function test() public {}
}
