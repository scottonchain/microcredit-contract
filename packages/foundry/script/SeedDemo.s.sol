// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "../contracts/MockUSDC.sol";

contract SeedDemo is Script {
    //uint32 internal constant BASE_BLOCK_GAS_LIMIT = 30_000_000; // Base, not Eth L1
    uint16 internal constant BORROWER_COUNT_TARGET = 300; // BASE-tuned, single-tx limit
    uint256 internal constant ATTEST_WEIGHT = 75_000;
    uint256 public constant MAX_PER_RUN = 1;

    function seed(address creditAddr, address usdcAddr) external {
        DecentralizedMicrocredit credit = DecentralizedMicrocredit(creditAddr);
        MockUSDC usdc = MockUSDC(usdcAddr);

        console.logString(string.concat("MockUSDC deployed at: ", vm.toString(usdcAddr)));

        uint256[4] memory lenderPKs = [uint256(1), 2, 3, 4];
        uint256[4] memory depositUsd = [uint256(22_345), 31_280, 42_567, 27_909];

        uint256 borrowerCountTarget = BORROWER_COUNT_TARGET;
        uint256 weight = ATTEST_WEIGHT;
        address[] memory borrowerAddrs = new address[](borrowerCountTarget);

        // Create borrowers one by one in separate transactions
        for (uint256 idx = 0; idx < borrowerCountTarget; idx++) {
            uint256 pk = 11 + idx;
            address borrowerAddr = vm.addr(pk);
            borrowerAddrs[idx] = borrowerAddr;

            // Fund borrower gas so they can later borrow
            vm.deal(borrowerAddr, 1 ether);

            // Log borrower creation for debugging
            console.log("Creating borrower:", borrowerAddr);

            // Log gas usage before borrower creation
            uint256 gasBefore = gasleft();
            vm.startBroadcast(pk);
            // Any other operations like borrower creation can go here.
            vm.stopBroadcast();
            uint256 gasAfter = gasleft();
            console.log("Gas used for borrower creation:", gasBefore - gasAfter);

            // Simulate time passing to move to the next block
            vm.warp(block.timestamp + 1 minutes); // Advance time by 1 minute
        }

        // Attestations per lender–borrower pair executed one-at-a-time so the script can be re-run with START_INDEX to resume.
        uint256 totalAttestations = lenderPKs.length * borrowerAddrs.length;
        uint256 startIndex = vm.envOr("START_INDEX", uint256(0));
        require(startIndex < totalAttestations, "START_INDEX out of range");

        uint256 lenderIdx = startIndex / borrowerAddrs.length;
        uint256 borrowerIdx = startIndex % borrowerAddrs.length;

        uint256 lenderPk = lenderPKs[lenderIdx];
        address borrower = borrowerAddrs[borrowerIdx];

        uint256 gasBeforeAttest = gasleft();
        vm.startBroadcast(lenderPk);
        credit.recordAttestation(borrower, weight);
        vm.stopBroadcast();
        uint256 gasAfterAttest = gasleft();

        console.log("Attested borrower:", borrower);
        console.log("Lender index:", lenderIdx, "Global index:", startIndex);
        console.log("Gas used for attestation:", gasBeforeAttest - gasAfterAttest);

        // Execute the expensive post-attestation logic only after the very last attestation
        if (startIndex == totalAttestations - 1) {
            // Compute PageRank once after all attestations, done in separate transaction
            uint256 gasBeforePR = gasleft();
            vm.startBroadcast(lenderPKs[0]); // Just use one of the lenders for this
            credit.computePageRank();
            vm.stopBroadcast();
            uint256 gasAfterPR = gasleft();
            console.log("Gas used for PageRank computation:", gasBeforePR - gasAfterPR);

            // Simulate time passing after PageRank computation
            vm.warp(block.timestamp + 1 minutes);

            // Borrowers take loans one by one in separate transactions
            for (uint256 j = 0; j < borrowerAddrs.length; j++) {
                address borrowerAddr = borrowerAddrs[j];
                uint256 borrowerPk = 11 + j; // Corresponding private key

                uint256 score = credit.getCreditScore(borrowerAddr);
                uint256 maxLoan = (credit.maxLoanAmount() * score) / 1e6;

                // Log loan info
                console.log("Borrower", borrowerAddr, "credit score:", score);
                console.log("Taking max loan:", maxLoan);

                if (maxLoan == 0) {
                    continue; // Skip if no loan is possible
                }

                // Request loan in a separate transaction
                uint256 gasBeforeLoan = gasleft();
                vm.startBroadcast(borrowerPk);
                uint256 loanId = credit.requestLoan(maxLoan);
                console.log("Requested loan ID:", loanId);
                vm.stopBroadcast();
                uint256 gasAfterLoan = gasleft();
                console.log("Gas used for loan request:", gasBeforeLoan - gasAfterLoan);

                // Simulate time passing after loan request
                vm.warp(block.timestamp + 1 minutes); // Advance time by 1 minute

                // Disburse loan in a separate transaction
                uint256 gasBeforeDisburse = gasleft();
                vm.startBroadcast(borrowerPk);
                credit.disburseLoan(loanId);
                console.log("DisburseLoan completed for loan ID:", loanId);
                vm.stopBroadcast();
                uint256 gasAfterDisburse = gasleft();
                console.log("Gas used for loan disbursement:", gasBeforeDisburse - gasAfterDisburse);

                // Simulate time passing after loan disbursement
                vm.warp(block.timestamp + 1 minutes); // Advance time by 1 minute
            }
        }

        console.logString("--- Demo seeding complete ---");
    }
}
