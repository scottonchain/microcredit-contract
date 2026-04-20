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
            // Ensure code exists on-chain (broadcast must have succeeded)
            if (usdcAddress.code.length == 0) {
                console.logString("ERROR: MockUSDC bytecode missing on-chain after deployment. Aborting.");
                revert("MockUSDC deployment failed (no code)");
            }
            
            // Update the deployment config file with the new address
            string memory newConfig = string.concat(
                '{\n',
                '  "usdcAddress": "', vm.toString(usdcAddress), '"\n',
                '}'
            );
            vm.writeFile(configPath, newConfig);
            console.logString("Updated deployment config with new USDC address");
        } else {
            // We found an address in file; double-check that a contract actually exists there.
            if (usdcAddress.code.length == 0) {
                console.logString("USDC address from config has no code. Deploying fresh MockUSDC and updating config...");
                MockUSDC usdc = new MockUSDC();
                usdcAddress = address(usdc);
                console.logString(string.concat("MockUSDC freshly deployed at: ", vm.toString(usdcAddress)));
                if (usdcAddress.code.length == 0) {
                    console.logString("ERROR: MockUSDC bytecode missing on-chain after re-deployment. Aborting.");
                    revert("MockUSDC deployment failed (no code)");
                }
                // Overwrite the deployment config with the new valid address
                string memory updatedConfig = string.concat(
                    '{\n',
                    '  "usdcAddress": "', vm.toString(usdcAddress), '"\n',
                    '}'
                );
                vm.writeFile(configPath, updatedConfig);
                console.logString("Deployment config updated with freshly deployed USDC address");
            }
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
        if (address(microcreditContract).code.length == 0) {
            console.logString("ERROR: DecentralizedMicrocredit bytecode missing on-chain after deployment. Aborting.");
            revert("DecentralizedMicrocredit deployment failed (no code)");
        }
        
        // Set basePersonalization to 0 as requested
        microcreditContract.setBasePersonalization(0);
        console.logString("Set basePersonalization to 0");

        // ── Seed the lending pool ──────────────────────────────────────────────
        // Use a non-round amount so the pool looks like real-world state.
        // 11,247.50 USDC total deposited.
        uint256 poolSeed = 11_247_500_000; // 11,247.50 USDC (6 decimals)
        MockUSDC(usdcAddress).mint(vm.addr(deployerPrivateKey), poolSeed);
        MockUSDC(usdcAddress).approve(address(microcreditContract), poolSeed);
        microcreditContract.depositFunds(poolSeed);
        console.logString("Seeded lending pool with 11,247.50 USDC");

        // ── Background borrower "Diana" ────────────────────────────────────────
        // Create an active loan of 9,150 USDC so the pool shows realistic
        // utilisation (~81 %) and a non-zero lender APY (~7.6 %) from the start.
        // Steps:
        //   1. Temporarily raise maxLoanAmount so Diana can borrow the full amount.
        //   2. Give Diana a 100 % score override.
        //   3. Prank Diana to request the loan.
        //   4. Admin disburses the loan (no access control on disburseLoan).
        //   5. Reset maxLoanAmount back to 100 USDC for the normal demo flow.
        // Anvil account 4 — address deterministic from default mnemonic
        uint256 dianaPrivateKey = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b;
        address diana = vm.addr(dianaPrivateKey); // 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
        uint256 dianaLoan = 9_150_000_000; // 9,150 USDC
        microcreditContract.setMaxLoanAmount(10_000 * 1e6); // raise cap temporarily
        microcreditContract.setScoreOverride(diana, 1_000_000); // 100 %
        vm.stopBroadcast();
        vm.startBroadcast(dianaPrivateKey); // broadcast as Diana
        uint256 dianaLoanId = microcreditContract.requestLoan(dianaLoan);
        vm.stopBroadcast();
        vm.startBroadcast(deployerPrivateKey); // back to deployer
        microcreditContract.disburseLoan(dianaLoanId); // disburse Diana's loan
        microcreditContract.setMaxLoanAmount(100 * 1e6); // reset to normal 100 USDC cap
        console.logString("Background borrower Diana: 9,150 USDC loan active (utilisation ~81%, APY ~7.6%)");

        // ── Pre-establish Brighton (Bob) ───────────────────────────────────────
        // Brighton already has a 92 % credit score so he can attest credibly.
        address bob = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Anvil account 2
        microcreditContract.setScoreOverride(bob, 920000); // 92% (scaled 1e6)
        console.logString("Set Brighton's credit score override to 92%");

        // Provision ETH to demo addresses (excluding admin addresses that can fund themselves)
        console.logString("--- Provisioning ETH to demo addresses ---");
        
        address[] memory demoAddresses = new address[](3);
        demoAddresses[0] = 0x455EB67473a5f8Da69dbFde7eDe1d1c008C31274;
        demoAddresses[1] = 0xE51a60126dF85801D4C76bDAf58D6F9E81Cc26cA;
        demoAddresses[2] = 0xC9E2518013169a09dfE47Da38b8DA092AB68d66A;
        
        uint256 ethAmount = 10 * 1e18; // 10 ETH in wei
        
        for (uint256 i = 0; i < demoAddresses.length; i++) {
            // Use vm.deal() to set the balance directly
            vm.deal(demoAddresses[i], ethAmount);
            console.logString(string.concat("Provisioned 10 ETH to: ", vm.toString(demoAddresses[i])));
        }
        
        console.logString("Note: Admin addresses can fund themselves using the /fund page");
        
        console.logString("--- Contracts deployed and demo addresses funded successfully ---");
        console.logString("Use the web interface to populate test data (lenders, borrowers, attestations)");
 
        // Save deployment information (use a stable object key and writeJson)
        string memory obj = "deploy";
        vm.serializeAddress(obj, "DecentralizedMicrocredit", address(microcreditContract));
        string memory jsonOut = vm.serializeAddress(obj, "USDC", usdcAddress);
        vm.writeJson(jsonOut, "deployment.json");
    }

    function test() public {}
}