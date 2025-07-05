// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/YourContract.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title ParticipantsArrayTests
 * @dev Tests specifically focused on updating the getAllParticipants array
 * These tests are designed to be run against the yarn chain instance to populate
 * the participants array with various scenarios
 */
contract ParticipantsArrayTests is Test {
    YourContract credit;
    MockUSDC usdc;

    address owner;
    address[] testParticipants;
    address[] lenders;
    address[] borrowers;
    address[] attesters;

    function setUp() public {
        console2.log("=== SETTING UP PARTICIPANTS ARRAY TEST ENVIRONMENT ===");
        
        owner = address(this);
        usdc = new MockUSDC("Mock USDC", "USDC", 6);
        credit = new YourContract(500, 2000, address(usdc), owner); // 5% - 20% in basis points
        
        console2.log("Contract deployed with:");
        console2.log("- Minimum interest rate: 5% (500 basis points)");
        console2.log("- Maximum interest rate: 20% (2000 basis points)");
        console2.log("- USDC token address:", address(usdc));
        console2.log("- Oracle address:", owner);

        // Create a larger set of test participants for comprehensive testing
        _createTestParticipants();
        
        console2.log("=== SETUP COMPLETE ===\n");
    }

    function _createTestParticipants() internal {
        // Create 20 participants for comprehensive testing
        for (uint i = 0; i < 20; i++) {
            address participant = address(uint160(uint(keccak256(abi.encode("participant", i)))));
            testParticipants.push(participant);
            
            // Categorize participants
            if (i < 7) {
                lenders.push(participant);
                // Mint USDC for lenders
                usdc.mint(participant, 1_000_000_000); // 1,000 USDC
                vm.prank(participant);
                usdc.approve(address(credit), type(uint256).max);
            } else if (i < 14) {
                borrowers.push(participant);
                // No initial balance for borrowers
                usdc.mint(participant, 0);
            } else {
                attesters.push(participant);
                // No initial balance for attesters
                usdc.mint(participant, 0);
            }
        }
        
        console2.log("Created 20 test participants:");
        console2.log("- 7 lenders (with 1000 USDC each)");
        console2.log("- 7 borrowers (no initial balance)");
        console2.log("- 6 attesters (no initial balance)");
    }

    // ===== PARTICIPANTS ARRAY UPDATE TESTS =====

    function testAddParticipantsViaDeposits() public {
        console2.log("=== TESTING ADDING PARTICIPANTS VIA DEPOSITS ===");
        
        address[] memory initialParticipants = credit.getAllParticipants();
        console2.log("Initial participants count:", initialParticipants.length);
        
        // Add participants through deposits
        for (uint i = 0; i < lenders.length; i++) {
            address lender = lenders[i];
            uint256 depositAmount = 100_000_000; // 100 USDC
            
            console2.log("Depositing funds for lender", i + 1, ":", lender);
            
            vm.prank(lender);
            credit.depositFunds(depositAmount);
            
            address[] memory currentParticipants = credit.getAllParticipants();
            console2.log("Participants after deposit", i + 1, ":", currentParticipants.length);
            
            // Verify the lender was added
            bool found = false;
            for (uint j = 0; j < currentParticipants.length; j++) {
                if (currentParticipants[j] == lender) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Lender should be in participants array");
        }
        
        address[] memory finalParticipants = credit.getAllParticipants();
        console2.log("Final participants count:", finalParticipants.length);
        console2.log("Expected participants count:", lenders.length);
        
        assertEq(finalParticipants.length, lenders.length, "All lenders should be in participants array");
        console2.log("Add participants via deposits test passed\n");
    }

    function testAddParticipantsViaAttestations() public {
        console2.log("=== TESTING ADDING PARTICIPANTS VIA ATTESTATIONS ===");
        
        address[] memory initialParticipants = credit.getAllParticipants();
        console2.log("Initial participants count:", initialParticipants.length);
        
        // Add participants through attestations
        for (uint i = 0; i < attesters.length && i < borrowers.length; i++) {
            address attester = attesters[i];
            address borrower = borrowers[i];
            uint256 attestationWeight = 500_000 + (i * 50_000); // 50% to 95% confidence
            
            console2.log("Recording attestation", i + 1, ":");
            console2.log("  - Attester:", attester);
            console2.log("  - Borrower:", borrower);
            console2.log("  - Weight:", attestationWeight);
            
            vm.prank(attester);
            credit.recordAttestation(borrower, attestationWeight);
            
            address[] memory currentParticipants = credit.getAllParticipants();
            console2.log("Participants after attestation", i + 1, ":", currentParticipants.length);
            
            // Verify both attester and borrower were added
            bool attesterFound = false;
            bool borrowerFound = false;
            for (uint j = 0; j < currentParticipants.length; j++) {
                if (currentParticipants[j] == attester) attesterFound = true;
                if (currentParticipants[j] == borrower) borrowerFound = true;
            }
            assertTrue(attesterFound, "Attester should be in participants array");
            assertTrue(borrowerFound, "Borrower should be in participants array");
        }
        
        address[] memory finalParticipants = credit.getAllParticipants();
        uint256 expectedCount = initialParticipants.length + (attesters.length * 2); // attesters + borrowers
        console2.log("Final participants count:", finalParticipants.length);
        console2.log("Expected participants count:", expectedCount);
        
        assertEq(finalParticipants.length, expectedCount, "All attesters and borrowers should be in participants array");
        console2.log("Add participants via attestations test passed\n");
    }

    function testAddParticipantsViaCreditScoreUpdates() public {
        console2.log("=== TESTING ADDING PARTICIPANTS VIA CREDIT SCORE UPDATES ===");
        
        address[] memory initialParticipants = credit.getAllParticipants();
        console2.log("Initial participants count:", initialParticipants.length);
        
        // Add participants through credit score updates (oracle function)
        for (uint i = 0; i < borrowers.length; i++) {
            address borrower = borrowers[i];
            uint256 creditScore = 300_000 + (i * 100_000); // 30% to 90% credit score
            
            console2.log("Updating credit score for borrower", i + 1, ":");
            console2.log("  - Borrower:", borrower);
            console2.log("  - Credit score:", creditScore);
            
            credit.updateCreditScore(borrower, creditScore);
            
            address[] memory currentParticipants = credit.getAllParticipants();
            console2.log("Participants after credit score update", i + 1, ":", currentParticipants.length);
            
            // Verify the borrower was added
            bool found = false;
            for (uint j = 0; j < currentParticipants.length; j++) {
                if (currentParticipants[j] == borrower) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Borrower should be in participants array");
        }
        
        address[] memory finalParticipants = credit.getAllParticipants();
        uint256 expectedCount = initialParticipants.length + borrowers.length;
        console2.log("Final participants count:", finalParticipants.length);
        console2.log("Expected participants count:", expectedCount);
        
        assertEq(finalParticipants.length, expectedCount, "All borrowers should be in participants array");
        console2.log("Add participants via credit score updates test passed\n");
    }

    function testBatchAddParticipants() public {
        console2.log("=== TESTING BATCH ADDING PARTICIPANTS ===");
        
        address[] memory initialParticipants = credit.getAllParticipants();
        console2.log("Initial participants count:", initialParticipants.length);
        
        // Create batch arrays for credit score updates
        address[] memory batchUsers = new address[](borrowers.length);
        uint256[] memory batchScores = new uint256[](borrowers.length);
        
        for (uint i = 0; i < borrowers.length; i++) {
            batchUsers[i] = borrowers[i];
            batchScores[i] = 400_000 + (i * 50_000); // 40% to 85% credit score
        }
        
        console2.log("Batch updating credit scores for", batchUsers.length, "borrowers");
        
        credit.updateCreditScores(batchUsers, batchScores);
        
        address[] memory finalParticipants = credit.getAllParticipants();
        uint256 expectedCount = initialParticipants.length + borrowers.length;
        console2.log("Final participants count:", finalParticipants.length);
        console2.log("Expected participants count:", expectedCount);
        
        assertEq(finalParticipants.length, expectedCount, "All borrowers should be in participants array");
        
        // Verify all borrowers are in the array
        for (uint i = 0; i < borrowers.length; i++) {
            bool found = false;
            for (uint j = 0; j < finalParticipants.length; j++) {
                if (finalParticipants[j] == borrowers[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "All borrowers should be in participants array");
        }
        
        console2.log("Batch add participants test passed\n");
    }

    function testComplexParticipantNetwork() public {
        console2.log("=== TESTING COMPLEX PARTICIPANT NETWORK ===");
        
        // Create a complex network of participants with multiple interactions
        console2.log("Creating complex participant network...");
        
        // Step 1: Add lenders through deposits
        for (uint i = 0; i < 3; i++) {
            vm.prank(lenders[i]);
            credit.depositFunds(200_000_000); // 200 USDC
        }
        
        // Step 2: Add borrowers through credit score updates
        for (uint i = 0; i < 4; i++) {
            credit.updateCreditScore(borrowers[i], 600_000 + (i * 50_000)); // 60% to 75%
        }
        
        // Step 3: Create attestation network
        // Borrower 0 gets attested by Attester 0 and 1
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[0], 800_000);
        vm.prank(attesters[1]);
        credit.recordAttestation(borrowers[0], 700_000);
        
        // Borrower 1 gets attested by Attester 1 and 2
        vm.prank(attesters[1]);
        credit.recordAttestation(borrowers[1], 750_000);
        vm.prank(attesters[2]);
        credit.recordAttestation(borrowers[1], 650_000);
        
        // Borrower 2 gets attested by Attester 0 and 2
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[2], 900_000);
        vm.prank(attesters[2]);
        credit.recordAttestation(borrowers[2], 850_000);
        
        // Borrower 3 gets attested by Attester 3
        vm.prank(attesters[3]);
        credit.recordAttestation(borrowers[3], 950_000);
        
        address[] memory finalParticipants = credit.getAllParticipants();
        console2.log("Complex network participants count:", finalParticipants.length);
        
        // Expected: 3 lenders + 4 borrowers + 4 attesters = 11 participants
        assertEq(finalParticipants.length, 11, "Should have 11 participants in complex network");
        
        // Verify all expected participants are present
        address[] memory expectedParticipants = new address[](11);
        expectedParticipants[0] = lenders[0];
        expectedParticipants[1] = lenders[1];
        expectedParticipants[2] = lenders[2];
        expectedParticipants[3] = borrowers[0];
        expectedParticipants[4] = borrowers[1];
        expectedParticipants[5] = borrowers[2];
        expectedParticipants[6] = borrowers[3];
        expectedParticipants[7] = attesters[0];
        expectedParticipants[8] = attesters[1];
        expectedParticipants[9] = attesters[2];
        expectedParticipants[10] = attesters[3];
        
        for (uint i = 0; i < expectedParticipants.length; i++) {
            bool found = false;
            for (uint j = 0; j < finalParticipants.length; j++) {
                if (finalParticipants[j] == expectedParticipants[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "All expected participants should be in array");
        }
        
        console2.log("Complex participant network test passed\n");
    }

    function testParticipantArrayPersistence() public {
        console2.log("=== TESTING PARTICIPANT ARRAY PERSISTENCE ===");
        
        // Add participants through various methods
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000);
        
        credit.updateCreditScore(borrowers[0], 700_000);
        
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[1], 800_000);
        
        address[] memory participantsAfterSetup = credit.getAllParticipants();
        console2.log("Participants after setup:", participantsAfterSetup.length);
        
        // Perform some operations that should not affect the participants array
        vm.prank(lenders[0]);
        credit.depositFunds(50_000_000); // Additional deposit
        
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[0], 600_000); // Additional attestation
        
        credit.updateCreditScore(borrowers[0], 750_000); // Update existing score
        
        address[] memory participantsAfterOperations = credit.getAllParticipants();
        console2.log("Participants after operations:", participantsAfterOperations.length);
        
        // The count should remain the same (no new participants added)
        assertEq(participantsAfterOperations.length, participantsAfterSetup.length, 
                "Participant count should remain the same after operations on existing participants");
        
        console2.log("Participant array persistence test passed\n");
    }

    function testParticipantArrayWithLoanLifecycle() public {
        console2.log("=== TESTING PARTICIPANT ARRAY WITH LOAN LIFECYCLE ===");
        
        // Setup initial participants
        vm.prank(lenders[0]);
        credit.depositFunds(500_000_000); // 500 USDC
        
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[0], 800_000);
        
        address[] memory initialParticipants = credit.getAllParticipants();
        console2.log("Initial participants:", initialParticipants.length);
        
        // Complete loan lifecycle
        vm.prank(borrowers[0]);
        uint256 loanId = credit.requestLoan(100_000_000); // 100 USDC
        
        credit.disburseLoan(loanId);
        
        // Simulate repayment
        (,,, uint256 outstanding,) = credit.getLoan(loanId);
        vm.prank(owner);
        usdc.mint(borrowers[0], outstanding);
        
        vm.startPrank(borrowers[0]);
        usdc.approve(address(credit), outstanding);
        credit.repayLoan(loanId, outstanding);
        vm.stopPrank();
        
        address[] memory finalParticipants = credit.getAllParticipants();
        console2.log("Final participants:", finalParticipants.length);
        
        // Participant count should remain the same through loan lifecycle
        assertEq(finalParticipants.length, initialParticipants.length, 
                "Participant count should remain the same through loan lifecycle");
        
        console2.log("Participant array with loan lifecycle test passed\n");
    }

    function testGetAllParticipantsFunctionality() public {
        console2.log("=== TESTING GETALLPARTICIPANTS FUNCTIONALITY ===");
        
        // Add participants through different methods
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000);
        
        credit.updateCreditScore(borrowers[0], 700_000);
        
        vm.prank(attesters[0]);
        credit.recordAttestation(borrowers[1], 800_000);
        
        address[] memory participants = credit.getAllParticipants();
        console2.log("Total participants:", participants.length);
        
        // Verify the array contains the expected participants
        bool lenderFound = false;
        bool borrower0Found = false;
        bool borrower1Found = false;
        bool attesterFound = false;
        
        for (uint i = 0; i < participants.length; i++) {
            if (participants[i] == lenders[0]) lenderFound = true;
            if (participants[i] == borrowers[0]) borrower0Found = true;
            if (participants[i] == borrowers[1]) borrower1Found = true;
            if (participants[i] == attesters[0]) attesterFound = true;
        }
        
        assertTrue(lenderFound, "Lender should be in participants array");
        assertTrue(borrower0Found, "Borrower 0 should be in participants array");
        assertTrue(borrower1Found, "Borrower 1 should be in participants array");
        assertTrue(attesterFound, "Attester should be in participants array");
        
        // Verify no duplicates
        for (uint i = 0; i < participants.length; i++) {
            for (uint j = i + 1; j < participants.length; j++) {
                assertTrue(participants[i] != participants[j], "No duplicate participants should exist");
            }
        }
        
        console2.log("GetAllParticipants functionality test passed\n");
    }

    // ===== UTILITY FUNCTIONS FOR DEBUGGING =====

    function logParticipantArray() public view {
        address[] memory participants = credit.getAllParticipants();
        console2.log("=== CURRENT PARTICIPANTS ARRAY ===");
        console2.log("Total participants:", participants.length);
        
        for (uint i = 0; i < participants.length; i++) {
            uint256 creditScore = credit.getCreditScore(participants[i]);
            uint256 personalization = credit.getPersonalizationVector(participants[i]);
            console2.log("Participant", i + 1, ":", participants[i]);
            console2.log("  - Credit score:", creditScore);
            console2.log("  - Personalization vector:", personalization);
        }
        console2.log("=== END PARTICIPANTS ARRAY ===\n");
    }

    function testMaxParticipantsScenario() public {
        console2.log("=== TESTING MAX PARTICIPANTS SCENARIO ===");
        
        // Add all available participants
        for (uint i = 0; i < testParticipants.length; i++) {
            if (i < lenders.length) {
                // Add lenders through deposits
                vm.prank(lenders[i]);
                credit.depositFunds(100_000_000);
            } else if (i < lenders.length + borrowers.length) {
                // Add borrowers through credit score updates
                uint256 borrowerIndex = i - lenders.length;
                credit.updateCreditScore(borrowers[borrowerIndex], 500_000 + (borrowerIndex * 50_000));
            } else {
                // Add attesters through attestations
                uint256 attesterIndex = i - lenders.length - borrowers.length;
                uint256 borrowerIndex = attesterIndex % borrowers.length;
                vm.prank(attesters[attesterIndex]);
                credit.recordAttestation(borrowers[borrowerIndex], 600_000 + (attesterIndex * 25_000));
            }
        }
        
        address[] memory finalParticipants = credit.getAllParticipants();
        console2.log("Max participants scenario - Total participants:", finalParticipants.length);
        console2.log("Expected participants:", testParticipants.length);
        
        assertEq(finalParticipants.length, testParticipants.length, 
                "All test participants should be in the array");
        
        console2.log("Max participants scenario test passed\n");
    }
} 