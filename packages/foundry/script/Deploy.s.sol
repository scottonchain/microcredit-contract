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

        // Get USDC address from deployment config file or deploy new MockUSDC
        address usdcAddress;
        
        // Try to read USDC address from deployment config file
        string memory configPath = string.concat(vm.projectRoot(), "/deployment-config.json");
        string memory configContent = vm.readFile(configPath);
        
        // Parse JSON to find USDC address
        bool foundInFile = false;
        if (bytes(configContent).length > 0) {
            // Look for "usdcAddress": "0x..."
            string memory addressPattern = '"usdcAddress": "';
            uint256 addressIndex = vm.indexOf(configContent, addressPattern);
            if (addressIndex != type(uint256).max) {
                // Extract address (42 characters: 0x + 40 hex chars)
                uint256 addressStart = addressIndex + bytes(addressPattern).length;
                
                // Manual string extraction for address
                bytes memory contentBytes = bytes(configContent);
                bytes memory addressBytes = new bytes(42);
                for (uint i = 0; i < 42 && addressStart + i < contentBytes.length; i++) {
                    addressBytes[i] = contentBytes[addressStart + i];
                }
                string memory addressHex = string(addressBytes);
                
                // Convert hex string to address
                usdcAddress = vm.parseAddress(addressHex);
                foundInFile = true;
                console.logString(string.concat("Found USDC address in deployment config: ", vm.toString(usdcAddress)));
            }
        }
        
        if (!foundInFile) {
            // No USDC found in file, deploy new MockUSDC
            console.logString("No USDC found in deployment config. Deploying new MockUSDC...");
            MockUSDC usdc = new MockUSDC();
            usdcAddress = address(usdc);
            console.logString(string.concat("MockUSDC deployed at: ", vm.toString(usdcAddress)));
            
            // Update the deployment config file with the new address
            string memory newConfig = string.concat(
                '{\n',
                '  "usdcAddress": "', vm.toString(usdcAddress), '"\n',
                '}'
            );
            vm.writeFile(configPath, newConfig);
            console.logString("Updated deployment config with new USDC address");
        }

        // Deploy the Microcredit contract (oracle temporarily set to deployer)
        DecentralizedMicrocredit microcreditContract = new DecentralizedMicrocredit(
            433,     // effrRate 4.33% (scaled 1e4) – current market rate
            500,     // riskPremium 5.0% (scaled 1e4) – platform premium
            100 * 1e6, // maxLoanAmount 100 USDC (6 decimals) – matches personalization cap
            usdcAddress,
            vm.addr(deployerPrivateKey) // set deployer as oracle placeholder
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