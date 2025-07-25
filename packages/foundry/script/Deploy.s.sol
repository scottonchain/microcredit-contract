// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "../contracts/MockUSDC.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 * To deploy with MockUSDC: DEPLOY_MOCK_USDC=true yarn deploy
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

        // Only deploy MockUSDC if DEPLOY_MOCK_USDC=true, otherwise do not deploy and do not print the address. Print a message about the flag if not set.
        bool deployMockUSDC = vm.envOr("DEPLOY_MOCK_USDC", false);
        address usdcAddress;
        if (deployMockUSDC) {
            MockUSDC usdc = new MockUSDC();
            usdcAddress = address(usdc);
            // No need to print the address
        } else {
            usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
            if (usdcAddress == address(0)) {
                console.log("USDC not deployed. To deploy a mock USDC contract, set DEPLOY_MOCK_USDC=true.");
            }
        }

        // Deploy the Microcredit contract (oracle temporarily set to deployer)
        DecentralizedMicrocredit microcreditContract = new DecentralizedMicrocredit(
            433,     // effrRate 4.33% (scaled 1e4) – current market rate
            500,     // riskPremium 5.0% (scaled 1e4) – platform premium
            100 * 1e6, // maxLoanAmount 100 USDC (6 decimals) – matches personalization cap
            usdcAddress,
            vm.addr(999) // set some address as oracle placeholder
        );

        // Log deployment information
        console.logString(string.concat("DecentralizedMicrocredit deployed at: ", vm.toString(address(microcreditContract))));
        console.logString("--- Contracts deployed successfully ---");
        console.logString("Use the web interface to populate test data (lenders, borrowers, attestations)");
 
        // Save deployment information
        string memory json = "{}";
        json = vm.serializeAddress(json, "DecentralizedMicrocredit", address(microcreditContract));
        json = vm.serializeAddress(json, "USDC", usdcAddress);
        vm.writeFile("deployment.json", json);
    }

    function test() public {}
}