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
        uint256 poolSeed = 10_000_000_000; // 10,000 USDC (6 decimals)
        MockUSDC(usdcAddress).mint(vm.addr(deployerPrivateKey), poolSeed);
        MockUSDC(usdcAddress).approve(address(microcreditContract), poolSeed);
        microcreditContract.depositFunds(poolSeed);
        console.logString("Seeded lending pool with 10,000 USDC");

        // ── Background borrowers ───────────────────────────────────────────────
        // Diana + Eve together bring utilisation to ~89% — the highest we can
        // go while still leaving a $100 slot open for the Casey demo borrower
        // (90% cap = $9,000; $8,899 lent + $100 Casey = $8,999 ≤ $9,000).
        // Resulting lender APY ≈ 8.3% (= 9.33% loan rate × 89% utilisation).
        microcreditContract.setMaxLoanAmount(10_000 * 1e6); // raise cap for seeding

        // Diana — Anvil account 4
        uint256 dianaPrivateKey = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b;
        address diana = vm.addr(dianaPrivateKey); // 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
        microcreditContract.setScoreOverride(diana, 1_000_000); // 100%
        (bool sentDiana,) = payable(diana).call{value: 1 ether}("");
        require(sentDiana, "ETH transfer to Diana failed");
        vm.stopBroadcast();
        vm.startBroadcast(dianaPrivateKey);
        uint256 dianaLoanId = microcreditContract.requestLoan(6_500_000_000); // 6,500 USDC
        vm.stopBroadcast();
        vm.startBroadcast(deployerPrivateKey);
        microcreditContract.disburseLoan(dianaLoanId);

        // Eve — Anvil account 5
        uint256 evePrivateKey = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
        address eve = vm.addr(evePrivateKey); // 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
        microcreditContract.setScoreOverride(eve, 1_000_000); // 100%
        (bool sentEve,) = payable(eve).call{value: 1 ether}("");
        require(sentEve, "ETH transfer to Eve failed");
        vm.stopBroadcast();
        vm.startBroadcast(evePrivateKey);
        uint256 eveLoanId = microcreditContract.requestLoan(2_399_000_000); // 2,399 USDC
        vm.stopBroadcast();
        vm.startBroadcast(deployerPrivateKey);
        microcreditContract.disburseLoan(eveLoanId);

        microcreditContract.setMaxLoanAmount(100 * 1e6); // reset to normal 100 USDC cap
        console.logString("Background borrowers: Diana $6,500 + Eve $2,399 = $8,899 lent (89%, APY ~8.3%)");

        // ── Pre-establish demo persona credit scores ───────────────────────────
        // Avery (admin/deployer, account 9) — 95% as platform operator
        microcreditContract.setScoreOverride(vm.addr(deployerPrivateKey), 950000); // 95% (scaled 1e6)
        console.logString("Set Avery's credit score override to 95%");

        // Alexis (attester, account 2) — 92% so she can attest credibly
        uint256 alexisPrivateKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
        address alexis = vm.addr(alexisPrivateKey); // 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
        microcreditContract.setScoreOverride(alexis, 920000); // 92% (scaled 1e6)
        console.logString("Set Alexis's credit score override to 92%");

        // ── Set display names for demo personas ────────────────────────────────
        uint256 brightonPrivateKey = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
        address brighton = vm.addr(brightonPrivateKey); // 0x90F79bf6EB2c4f870365E785982E1f101E93b906
        vm.stopBroadcast();
        vm.startBroadcast(alexisPrivateKey);
        microcreditContract.setDisplayName("Alexis");
        vm.stopBroadcast();
        vm.startBroadcast(brightonPrivateKey);
        microcreditContract.setDisplayName("Brighton");
        vm.stopBroadcast();
        vm.startBroadcast(deployerPrivateKey);
        console.logString("Set display names: Alexis (attester), Brighton (borrower)");

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