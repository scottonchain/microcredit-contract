// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "../contracts/MockUSDC.sol";
import "./SeedDemo.s.sol";

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

        // Deploy mock USDC and mint initial supply
        MockUSDC usdc = new MockUSDC();

        // Deploy the Microcredit contract (oracle temporarily set to deployer)
        DecentralizedMicrocredit microcreditContract = new DecentralizedMicrocredit(
            550,     // effrRate 5.5% (scaled 1e4) – closer to historical Fed funds
            350,     // riskPremium 3.5% (scaled 1e4) – platform premium
            100 * 1e6, // maxLoanAmount 100 USDC (6 decimals) – matches personalization cap
            address(usdc),
            vm.addr(999) // set some address as oracle placeholder
        );

        // ----- Create a small ecosystem  -----
        address deployer = vm.addr(deployerPrivateKey);

        // Arrays of private keys (hard-coded for local demo). NEVER use in prod.
        uint256[4] memory lenderPKs = [uint256(1), uint256(2), uint256(3), uint256(4)];
        uint256[8] memory borrowerPKs = [uint256(11), uint256(12), uint256(13), uint256(14), uint256(15), uint256(16), uint256(17), uint256(18)];
        uint256 oraclePK = 999;

        // Lender seed funding tuned for Base gas-limit demo (≈78 % utilisation)
        uint256[4] memory depositUsd = [uint256(3_000), 3_000, 3_000, 3_000]; // 12k total

        // 1. Mint USDC to lenders and send them ETH for gas (on-chain transfers)
        for (uint256 i = 0; i < lenderPKs.length; i++) {
            address payable lender = payable(vm.addr(lenderPKs[i]));

            uint256 amountUSDC = depositUsd[i] * 1e6;

            usdc.mint(lender, amountUSDC);

            // send 1 ether for gas – uses deployer's balance
            (bool ok,) = lender.call{value: 1 ether}("");
            require(ok, "ETH transfer to lender failed");
        }

        // Fund borrowers and oracle with 1 ether each
        for (uint256 i = 0; i < borrowerPKs.length; i++) {
            address payable b = payable(vm.addr(borrowerPKs[i]));
            (bool ok,) = b.call{value: 1 ether}("");
            require(ok, "ETH transfer to borrower failed");
        }
        (bool okOr,) = payable(vm.addr(oraclePK)).call{value: 1 ether}("");
        require(okOr, "ETH transfer to oracle failed");

        // Close deployer broadcast before opening others
        vm.stopBroadcast();

        // Deposit funds (each lender broadcasts individually)
        for (uint256 i = 0; i < lenderPKs.length; i++) {
            uint256 pk = lenderPKs[i];
            uint256 amount = depositUsd[i] * 1e6; // match minted amounts
            vm.startBroadcast(pk);
            console.logString(string.concat("Lender deposit broadcast: ", vm.toString(vm.addr(pk))));
            console.logUint(vm.addr(pk).balance);
            // already funded on-chain; no vm.deal needed
            usdc.approve(address(microcreditContract), amount);
            microcreditContract.depositFunds(amount);
            vm.stopBroadcast();
        }

        // 2. Create social attestations from lenders → borrowers
        uint256 weight = 75_000; // 75% confidence (basis points) average
        for (uint256 i = 0; i < lenderPKs.length; i++) {
            uint256 pk = lenderPKs[i];
            vm.startBroadcast(pk);
            console.logString(string.concat("Attestation broadcast by: ", vm.toString(vm.addr(pk))));
            console.logUint(vm.addr(pk).balance);
            // already funded on-chain; no vm.deal needed
            for (uint256 j = 0; j < borrowerPKs.length; j++) {
                address borrowerAddr = vm.addr(borrowerPKs[j]);
                microcreditContract.recordAttestation(borrowerAddr, weight);
            }
            vm.stopBroadcast();
        }

        // 3. Compute PageRank scores on-chain
        vm.startBroadcast(deployerPrivateKey);
        console.logString("Compute PageRank broadcast by deployer");
        console.logUint(vm.addr(deployerPrivateKey).balance);
        // already funded on-chain; no vm.deal needed
        microcreditContract.computePageRank();
        vm.stopBroadcast();

        // 4. Display borrower PageRank scores (no manual credit score setting required)
        console.logString("Borrower PageRank scores (for reference):");
        for (uint256 j = 0; j < borrowerPKs.length; j++) {
            address borrowerAddr = vm.addr(borrowerPKs[j]);
            uint256 score = microcreditContract.getPageRankScore(borrowerAddr);
            console.logString(string.concat("  ", vm.toString(borrowerAddr), " => ", vm.toString(score)));
        }

        // 5. Borrowers request sample loans
        for (uint256 j = 0; j < borrowerPKs.length; j++) {
            uint256 pk = borrowerPKs[j];
            address borrowerAddr = vm.addr(pk);
            // Compute borrower credit parameters
            uint256 creditScore = microcreditContract.getCreditScore(borrowerAddr);
            uint256 maxAllowed = (microcreditContract.maxLoanAmount() * creditScore) / 1e6;

            // Borrow full credit-based allowance to maximise utilisation
            uint256 requestAmount = maxAllowed;
            
            console.logString(string.concat("Borrower ", vm.toString(borrowerAddr), " credit score: ", vm.toString(creditScore)));
            console.logString(string.concat("Taking max loan: ", vm.toString(requestAmount / 1e6), " USDC"));
            
            vm.startBroadcast(pk);
            console.logString(string.concat("Borrower loan broadcast: ", vm.toString(vm.addr(pk))));
            console.logUint(vm.addr(pk).balance);
            // already funded on-chain; no vm.deal needed
            uint256 newLoanId = microcreditContract.requestLoan(requestAmount);
            // Immediately disburse to mark principal as lent-out
            microcreditContract.disburseLoan(newLoanId);
            vm.stopBroadcast();
        }

        // Log summary
        console.logString(string.concat("DecentralizedMicrocredit deployed at: ", vm.toString(address(microcreditContract))));
        console.logString("--- Ecosystem seeded ---");
        console.logString("Lenders deposited 3k USDC each (total 12k)");
        console.logString("Borrowers drew max loans (~47 USDC each)");
 
        // OPTIONAL: populate demo data (deposits, attestations, loans) – comment out for production
        new SeedDemo().seed(address(microcreditContract), address(usdc));
 
        // Save deployment information
        string memory json = "{}";
        json = vm.serializeAddress(json, "DecentralizedMicrocredit", address(microcreditContract));
        json = vm.serializeAddress(json, "USDC", address(usdc));
        vm.writeFile("deployment.json", json);
    }

    function test() public {}
}
