// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Lightweight 6-decimals mock USDC token
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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
            750,     // effrRate 7.5% (scaled 1e4)
            250,     // riskPremium 2.5% (scaled 1e4)
            1_000_000 * 1e6, // maxLoanAmount 1,000,000 USDC (6 decimals)
            address(usdc),
            vm.addr(999) // set some address as oracle placeholder
        );

        // ----- Create a small ecosystem  -----
        address deployer = vm.addr(deployerPrivateKey);

        // Arrays of private keys (hard-coded for local demo). NEVER use in prod.
        uint256[3] memory lenderPKs = [uint256(1), uint256(2), uint256(3)];
        uint256[3] memory borrowerPKs = [uint256(11), uint256(12), uint256(13)];
        uint256 oraclePK = 999;

        // 1. Mint USDC to lenders and send them ETH for gas (on-chain transfers)
        for (uint256 i = 0; i < lenderPKs.length; i++) {
            address payable lender = payable(vm.addr(lenderPKs[i]));
            uint256 amountUSDC = (50_000 + (i * 25_000)) * 1e6; // 50k,75k,100k
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
            uint256 amount = (50_000 + (i * 25_000)) * 1e6;
            vm.startBroadcast(pk);
            console.logString(string.concat("Lender deposit broadcast: ", vm.toString(vm.addr(pk))));
            console.logUint(vm.addr(pk).balance);
            // already funded on-chain; no vm.deal needed
            usdc.approve(address(microcreditContract), amount);
            microcreditContract.depositFunds(amount);
            vm.stopBroadcast();
        }

        // 2. Create social attestations from lenders → borrowers
        uint256 weight = 80_000; // 80% confidence (basis points)
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
            uint256 requestAmount = (5_000 + j * 2_500) * 1e6; // 5k, 7.5k, 10k
            
            // Check credit score and calculate max allowed
            uint256 creditScore = microcreditContract.getCreditScore(borrowerAddr);
            uint256 maxAllowed = (creditScore * 10000 * 1e6) / 1e6; // maxLoanAmount = 10000 * 1e6
            
            console.logString(string.concat("Borrower ", vm.toString(borrowerAddr), " credit score: ", vm.toString(creditScore)));
            console.logString(string.concat("Max allowed loan: ", vm.toString(maxAllowed / 1e6), " USDC"));
            console.logString(string.concat("Requesting: ", vm.toString(requestAmount / 1e6), " USDC"));
            
            vm.startBroadcast(pk);
            console.logString(string.concat("Borrower loan broadcast: ", vm.toString(vm.addr(pk))));
            console.logUint(vm.addr(pk).balance);
            // already funded on-chain; no vm.deal needed
            microcreditContract.requestLoan(requestAmount);
            vm.stopBroadcast();
        }

        // Log summary
        console.logString(string.concat("MockUSDC deployed at: ", vm.toString(address(usdc))));
        console.logString(string.concat("DecentralizedMicrocredit deployed at: ", vm.toString(address(microcreditContract))));
        console.logString("--- Ecosystem seeded ---");
        console.logString("Lenders deposited: 50k, 75k, 100k USDC");
        console.logString("Borrowers created 3 loan requests (5k-10k USDC)");

        // Save deployment information
        string memory json = "{}";
        json = vm.serializeAddress(json, "DecentralizedMicrocredit", address(microcreditContract));
        json = vm.serializeAddress(json, "USDC", address(usdc));
        vm.writeFile("deployment.json", json);
    }

    function test() public {}
}
