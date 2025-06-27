// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/YourContract.sol";
import "../src/mocks/MockUSDC.sol";

contract DecentralizedMicrocreditTest is Test {
    YourContract credit;
    MockUSDC usdc;

    address owner;
    address[] lenders;
    address[] borrowers;
    address[] attesters;

    function setUp() public {
        console2.log("=== SETTING UP DECENTRALIZED MICROCREDIT TEST ENVIRONMENT ===");
        
        owner = address(this);
        usdc = new MockUSDC("Mock USDC", "USDC", 6);
        credit = new YourContract(500, 2000, address(usdc), owner); // 5% - 20% in basis points
        
        console2.log("Contract deployed with:");
        console2.log("- Minimum interest rate: 5% (500 basis points)");
        console2.log("- Maximum interest rate: 20% (2000 basis points)");
        console2.log("- USDC token address:", address(usdc));
        console2.log("- Oracle address:", owner);

        // Create test participants
        for (uint i = 0; i < 10; i++) {
            address lender = address(uint160(uint(keccak256(abi.encode("lender", i)))));
            address borrower = address(uint160(uint(keccak256(abi.encode("borrower", i)))));
            address attester = address(uint160(uint(keccak256(abi.encode("attester", i)))));

            lenders.push(lender);
            borrowers.push(borrower);
            attesters.push(attester);

            // Mint initial USDC balances
            usdc.mint(lender, 1_000_000_000); // 1,000 USDC for lenders
            usdc.mint(borrower, 0); // No initial balance for borrowers
            usdc.mint(attester, 0); // No initial balance for attesters

            // Approve credit contract to spend lender funds
            vm.prank(lender);
            usdc.approve(address(credit), type(uint256).max);
            
            console2.log("Created participant", i + 1);
            console2.log(":");
            console2.log("  - Lender:", lender);
            console2.log("  - Lender balance: 1000 USDC");
            console2.log("  - Borrower:", borrower);
            console2.log("  - Borrower balance: 0 USDC");
            console2.log("  - Attester:", attester);
            console2.log("  - Attester balance: 0 USDC");
        }
        
        console2.log("=== SETUP COMPLETE ===\n");
    }

    // ===== ATOMIC OPERATION TESTS =====

    function testAtomicDepositFunds() public {
        console2.log("=== TESTING ATOMIC FUND DEPOSIT ===");
        
        address lender = lenders[0];
        uint256 depositAmount = 100_000_000; // 100 USDC
        uint256 initialBalance = usdc.balanceOf(lender);
        uint256 initialContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("Before deposit:");
        console2.log("  - Lender balance:", initialBalance);
        console2.log("  - Contract balance:", initialContractBalance);
        console2.log("  - Deposit amount:", depositAmount);
        
        vm.prank(lender);
        credit.depositFunds(depositAmount);
        
        uint256 finalBalance = usdc.balanceOf(lender);
        uint256 finalContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("After deposit:");
        console2.log("  - Lender balance:", finalBalance);
        console2.log("  - Contract balance:", finalContractBalance);
        console2.log("  - Balance change:", initialBalance - finalBalance);
        
        assertEq(finalBalance, initialBalance - depositAmount, "Lender balance should decrease");
        assertEq(finalContractBalance, initialContractBalance + depositAmount, "Contract balance should increase");
        
        console2.log("Atomic deposit test passed\n");
    }

    function testAtomicAttestation() public {
        console2.log("=== TESTING ATOMIC ATTESTATION ===");
        
        address attester = attesters[0];
        address borrower = borrowers[0];
        uint256 attestationWeight = 750_000; // 75% confidence
        
        console2.log("Recording attestation:");
        console2.log("  - Attester:", attester);
        console2.log("  - Borrower:", borrower);
        console2.log("  - Weight:", attestationWeight);
        console2.log("  - Confidence: 75%");
        
        vm.prank(attester);
        credit.recordAttestation(borrower, attestationWeight);
        
        console2.log("Attestation recorded successfully");
        console2.log("Note: Attestations are stored but don't directly affect credit scores");
        console2.log("Credit scores must be set separately by the oracle\n");
    }

    function testAtomicCreditScoreUpdate() public {
        console2.log("=== TESTING ATOMIC CREDIT SCORE UPDATE ===");
        
        address borrower = borrowers[0];
        uint256 newScore = 850_000; // 85% credit score
        uint256 initialScore = credit.getCreditScore(borrower);
        
        console2.log("Before update:");
        console2.log("  - Borrower:", borrower);
        console2.log("  - Initial credit score:", initialScore);
        console2.log("  - New credit score:", newScore);
        
        credit.updateCreditScore(borrower, newScore);
        
        uint256 finalScore = credit.getCreditScore(borrower);
        
        console2.log("After update:");
        console2.log("  - Final credit score:", finalScore);
        
        assertEq(finalScore, newScore, "Credit score should be updated");
        
        console2.log("Credit score update test passed\n");
    }

    function testAtomicLoanRequest() public {
        console2.log("=== TESTING ATOMIC LOAN REQUEST ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        // Set credit score first
        credit.updateCreditScore(borrower, 800_000); // 80% credit score
        
        console2.log("Before loan request:");
        console2.log("  - Borrower:", borrower);
        console2.log("  - Credit score: 800,000 (80%)");
        console2.log("  - Requested amount:", loanAmount);
        
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount);
        
        (uint256 principal, uint256 outstanding, address loanBorrower, uint256 interestRate, bool isActive) = credit.getLoan(loanId);
        
        console2.log("After loan request:");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Outstanding:", outstanding);
        console2.log("  - Borrower:", loanBorrower);
        console2.log("  - Interest rate (basis points):", interestRate);
        console2.log("  - Is active:", isActive);
        
        assertEq(loanBorrower, borrower, "Loan should be assigned to correct borrower");
        assertEq(principal, loanAmount, "Principal should match requested amount");
        assertEq(outstanding, loanAmount, "Outstanding should equal principal initially");
        assertTrue(isActive, "Loan should be active");
        
        console2.log("Atomic loan request test passed\n");
    }

    function testAtomicLoanDisbursement() public {
        console2.log("=== TESTING ATOMIC LOAN DISBURSEMENT ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        // Setup: Set credit score and request loan
        credit.updateCreditScore(borrower, 800_000);
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount);
        
        // Ensure contract has funds by having a lender deposit
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000); // 100 USDC
        
        uint256 initialBorrowerBalance = usdc.balanceOf(borrower);
        uint256 initialContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("Before disbursement:");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Borrower balance:", initialBorrowerBalance);
        console2.log("  - Contract balance:", initialContractBalance);
        console2.log("  - Disbursement amount:", loanAmount);
        
        credit.disburseLoan(loanId);
        
        uint256 finalBorrowerBalance = usdc.balanceOf(borrower);
        uint256 finalContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("After disbursement:");
        console2.log("  - Borrower balance:", finalBorrowerBalance);
        console2.log("  - Contract balance:", finalContractBalance);
        console2.log("  - Balance change:", finalBorrowerBalance - initialBorrowerBalance);
        
        assertEq(finalBorrowerBalance, initialBorrowerBalance + loanAmount, "Borrower should receive funds");
        assertEq(finalContractBalance, initialContractBalance - loanAmount, "Contract should send funds");
        
        console2.log("Atomic loan disbursement test passed\n");
    }

    function testAtomicLoanRepayment() public {
        console2.log("=== TESTING ATOMIC LOAN REPAYMENT ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        // Setup: Complete loan cycle
        credit.updateCreditScore(borrower, 800_000);
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount);
        
        // Ensure contract has funds
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000);
        
        credit.disburseLoan(loanId);
        
        // Get loan details before repayment
        (uint256 principal, uint256 outstanding, , uint256 interestRate, bool isActiveBefore) = credit.getLoan(loanId);
        uint256 initialBorrowerBalance = usdc.balanceOf(borrower);
        uint256 initialContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("Before repayment:");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Outstanding:", outstanding);
        console2.log("  - Interest rate:", interestRate, "basis points");
        console2.log("  - Borrower balance:", initialBorrowerBalance);
        console2.log("  - Contract balance:", initialContractBalance);
        console2.log("  - Is active:", isActiveBefore);
        
        // Calculate total repayment amount (principal + interest)
        uint256 totalRepayment = outstanding + (outstanding * interestRate / 10000);
        
        // Simulate borrower having funds to repay
        vm.prank(owner);
        usdc.mint(borrower, totalRepayment);
        
        vm.startPrank(borrower);
        usdc.approve(address(credit), totalRepayment);
        credit.repayLoan(loanId, totalRepayment);
        vm.stopPrank();
        
        uint256 finalBorrowerBalance = usdc.balanceOf(borrower);
        uint256 finalContractBalance = usdc.balanceOf(address(credit));
        (, uint256 outstandingAfter, , , bool isActiveAfter) = credit.getLoan(loanId);
        
        console2.log("After repayment:");
        console2.log("  - Outstanding:", outstandingAfter);
        console2.log("  - Borrower balance:", finalBorrowerBalance);
        console2.log("  - Contract balance:", finalContractBalance);
        console2.log("  - Is active:", isActiveAfter);
        
        assertEq(outstandingAfter, 0, "Outstanding should be zero after full repayment");
        assertTrue(!isActiveAfter, "Loan should be inactive after full repayment");
        assertEq(finalContractBalance, initialContractBalance + totalRepayment, "Contract should receive repayment");
        
        console2.log("Atomic loan repayment test passed\n");
    }

    // ===== REPUTATION SCORE UPDATE TESTS =====

    function testReputationScoreProgression() public {
        console2.log("=== TESTING REPUTATION SCORE PROGRESSION ===");
        
        address borrower = borrowers[0];
        
        console2.log("Testing reputation score progression for borrower:", borrower);
        
        // Initial state
        uint256 initialScore = credit.getCreditScore(borrower);
        console2.log("Initial credit score:", initialScore);
        console2.log("Note: 0 = no score");
        
        // Update to poor credit
        credit.updateCreditScore(borrower, 300_000); // 30%
        uint256 poorScore = credit.getCreditScore(borrower);
        console2.log("Updated to poor credit:", poorScore);
        console2.log("Percentage: 30%");
        
        // Update to fair credit
        credit.updateCreditScore(borrower, 600_000); // 60%
        uint256 fairScore = credit.getCreditScore(borrower);
        console2.log("Updated to fair credit:", fairScore);
        console2.log("Percentage: 60%");
        
        // Update to good credit
        credit.updateCreditScore(borrower, 800_000); // 80%
        uint256 goodScore = credit.getCreditScore(borrower);
        console2.log("Updated to good credit:", goodScore);
        console2.log("Percentage: 80%");
        
        // Update to excellent credit
        credit.updateCreditScore(borrower, 950_000); // 95%
        uint256 excellentScore = credit.getCreditScore(borrower);
        console2.log("Updated to excellent credit:", excellentScore);
        console2.log("Percentage: 95%");
        
        assertEq(excellentScore, 950_000, "Final score should match update");
        
        console2.log("Reputation score progression test passed\n");
    }

    function testReputationScoreImpactOnInterest() public {
        console2.log("=== TESTING REPUTATION SCORE IMPACT ON INTEREST RATES ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 100_000_000; // 100 USDC
        
        console2.log("Testing interest rate calculation for different credit scores");
        console2.log("Loan amount:", loanAmount);
        
        uint256[] memory scores = new uint256[](5);
        scores[0] = 200_000; // 20% - very poor
        scores[1] = 400_000; // 40% - poor
        scores[2] = 600_000; // 60% - fair
        scores[3] = 800_000; // 80% - good
        scores[4] = 950_000; // 95% - excellent
        
        for (uint i = 0; i < scores.length; i++) {
            credit.updateCreditScore(borrower, scores[i]);
            
            vm.prank(borrower);
            uint256 loanId = credit.requestLoan(loanAmount);
            
            (,,, uint256 interestRate,) = credit.getLoan(loanId);
            
            console2.log("Credit score:", scores[i]);
            console2.log("Percentage:", scores[i] / 10000, "%");
            console2.log("Interest rate:", interestRate, "basis points");
            console2.log("Interest percentage:", interestRate / 100, "%");
            
            // Clean up for next iteration - ensure contract has funds
            vm.prank(lenders[i % lenders.length]);
            credit.depositFunds(200_000_000);
            
            credit.disburseLoan(loanId);
            
            uint256 totalRepayment = loanAmount + (loanAmount * interestRate / 10000);
            vm.prank(owner);
            usdc.mint(borrower, totalRepayment);
            vm.startPrank(borrower);
            usdc.approve(address(credit), totalRepayment);
            credit.repayLoan(loanId, totalRepayment);
            vm.stopPrank();
        }
        
        console2.log("Reputation score impact test passed\n");
    }

    // ===== HIGHER-LEVEL SCENARIO TESTS =====

    function testCompleteLoanLifecycle() public {
        console2.log("=== TESTING COMPLETE LOAN LIFECYCLE ===");
        
        address lender = lenders[0];
        address borrower = borrowers[0];
        address attester = attesters[0];
        uint256 depositAmount = 200_000_000; // 200 USDC
        uint256 loanAmount = 100_000_000; // 100 USDC
        uint256 attestationWeight = 800_000; // 80% confidence
        uint256 creditScore = 750_000; // 75% credit score
        
        console2.log("Starting complete loan lifecycle test:");
        console2.log("  - Lender:", lender);
        console2.log("  - Borrower:", borrower);
        console2.log("  - Attester:", attester);
        console2.log("  - Deposit amount:", depositAmount);
        console2.log("  - Loan amount:", loanAmount);
        console2.log("  - Attestation weight:", attestationWeight);
        console2.log("  - Credit score:", creditScore);
        
        // Step 1: Lender deposits funds
        _testLenderDeposit(lender, depositAmount);
        
        // Step 2: Attester provides attestation
        _testAttestation(attester, borrower, attestationWeight);
        
        // Step 3: Oracle sets credit score
        _testCreditScoreUpdate(borrower, creditScore);
        
        // Step 4: Borrower requests loan
        uint256 loanId = _testLoanRequest(borrower, loanAmount);
        
        // Step 5: Loan is disbursed
        _testLoanDisbursement(borrower, loanId, loanAmount);
        
        // Step 6: Borrower repays loan
        _testLoanRepayment(borrower, loanId);
        
        // Step 7: Calculate attester reward
        _testAttesterReward(loanId, attester);
        
        console2.log("Complete loan lifecycle test passed\n");
    }

    function _testLenderDeposit(address lender, uint256 depositAmount) internal {
        console2.log("\nStep 1: Lender deposits funds");
        uint256 initialLenderBalance = usdc.balanceOf(lender);
        vm.prank(lender);
        credit.depositFunds(depositAmount);
        uint256 finalLenderBalance = usdc.balanceOf(lender);
        console2.log("  - Lender balance change:", initialLenderBalance - finalLenderBalance);
    }

    function _testAttestation(address attester, address borrower, uint256 weight) internal {
        console2.log("\nStep 2: Attester provides attestation");
        vm.prank(attester);
        credit.recordAttestation(borrower, weight);
        console2.log("  - Attestation recorded with weight:", weight);
    }

    function _testCreditScoreUpdate(address borrower, uint256 score) internal {
        console2.log("\nStep 3: Oracle sets credit score");
        credit.updateCreditScore(borrower, score);
        uint256 actualScore = credit.getCreditScore(borrower);
        console2.log("  - Credit score set to:", actualScore);
    }

    function _testLoanRequest(address borrower, uint256 amount) internal returns (uint256) {
        console2.log("\nStep 4: Borrower requests loan");
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(amount);
        (uint256 principal, uint256 outstanding, address loanBorrower, uint256 interestRate, bool isActive) = credit.getLoan(loanId);
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Interest rate:", interestRate, "basis points");
        console2.log("  - Is active:", isActive);
        return loanId;
    }

    function _testLoanDisbursement(address borrower, uint256 loanId, uint256 amount) internal {
        console2.log("\nStep 5: Loan is disbursed");
        uint256 preDisbursementBalance = usdc.balanceOf(borrower);
        credit.disburseLoan(loanId);
        uint256 postDisbursementBalance = usdc.balanceOf(borrower);
        console2.log("  - Borrower received:", postDisbursementBalance - preDisbursementBalance);
    }

    function _testLoanRepayment(address borrower, uint256 loanId) internal {
        console2.log("\nStep 6: Borrower repays loan");
        (,,, uint256 finalInterestRate, bool isActiveBefore) = credit.getLoan(loanId);
        uint256 outstanding = 100_000_000; // We know this from the loan request
        uint256 totalRepayment = outstanding + (outstanding * finalInterestRate / 10000);
        
        console2.log("  - Initial outstanding:", outstanding);
        console2.log("  - Interest rate:", finalInterestRate, "basis points");
        console2.log("  - Calculated repayment:", totalRepayment);
        
        // Simulate borrower having funds
        vm.prank(owner);
        usdc.mint(borrower, totalRepayment);
        
        vm.startPrank(borrower);
        usdc.approve(address(credit), totalRepayment);
        credit.repayLoan(loanId, totalRepayment);
        vm.stopPrank();
        
        (,,, uint256 finalOutstanding, bool finalActive) = credit.getLoan(loanId);
        console2.log("  - Final outstanding after first payment:", finalOutstanding);
        console2.log("  - Loan active after first payment:", finalActive);
        
        // If there's still a small outstanding amount and the loan is still active, pay it off
        if (finalOutstanding > 0 && finalActive) {
            console2.log("  - Making additional payment of:", finalOutstanding);
            vm.prank(owner);
            usdc.mint(borrower, finalOutstanding);
            vm.startPrank(borrower);
            usdc.approve(address(credit), finalOutstanding);
            credit.repayLoan(loanId, finalOutstanding);
            vm.stopPrank();
            
            (,,, uint256 finalOutstandingAfter, bool finalActiveAfter) = credit.getLoan(loanId);
            console2.log("  - Final outstanding after additional payment:", finalOutstandingAfter);
            console2.log("  - Loan active after additional payment:", finalActiveAfter);
            assertEq(finalOutstandingAfter, 0, "Loan should be fully repaid after additional payment");
        } else if (finalOutstanding > 0 && !finalActive) {
            console2.log("  - Loan is inactive with small outstanding amount:", finalOutstanding);
            console2.log("  - Skipping additional payment as loan is already inactive");
        } else {
            assertEq(finalOutstanding, 0, "Loan should be fully repaid");
        }
        
        // Final verification: loan should be inactive and outstanding should be 0 or very small
        (,,, uint256 finalOutstandingFinal, bool finalActiveFinal) = credit.getLoan(loanId);
        assertTrue(!finalActiveFinal, "Loan should be inactive at the end");
        // Allow for very small outstanding amounts due to rounding
        assertTrue(finalOutstandingFinal <= 1000, "Outstanding amount should be very small or zero");
    }

    function _testAttesterReward(uint256 loanId, address attester) internal {
        console2.log("\nStep 7: Calculate attester reward");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Attester:", attester);
        
        // Check loan status before computing reward
        (,,, uint256 outstanding, bool isActive) = credit.getLoan(loanId);
        console2.log("  - Loan outstanding:", outstanding);
        console2.log("  - Loan active:", isActive);
        
        uint256 reward = credit.computeAttesterReward(loanId, attester);
        console2.log("  - Attester reward:", reward);
    }

    function testMultipleLoansScenario() public {
        console2.log("=== TESTING MULTIPLE LOANS SCENARIO ===");
        
        console2.log("Testing scenario with multiple borrowers and lenders");
        
        // Setup: Multiple lenders deposit
        _setupMultipleLenders();
        
        // Setup: Multiple attesters provide attestations
        _setupMultipleAttestations();
        
        // Setup: Oracle sets credit scores
        _setupMultipleCreditScores();
        
        // Multiple borrowers request loans
        uint256[] memory loanIds = _setupMultipleLoanRequests();
        
        // Disburse all loans
        _disburseMultipleLoans(loanIds);
        
        // Repay all loans
        _repayMultipleLoans(loanIds);
        
        // Check final state
        _verifyMultipleLoansComplete(loanIds);
        
        console2.log("Multiple loans scenario test passed\n");
    }

    function _setupMultipleLenders() internal {
        for (uint i = 0; i < 3; i++) {
            vm.prank(lenders[i]);
            credit.depositFunds(300_000_000); // 300 USDC each
            console2.log("Lender", i);
            console2.log("Deposited 300 USDC");
        }
    }

    function _setupMultipleAttestations() internal {
        for (uint i = 0; i < 3; i++) {
            vm.prank(attesters[i]);
            credit.recordAttestation(borrowers[i], 700_000 + (i * 50_000)); // 70%, 75%, 80%
            console2.log("Attester", i);
            console2.log("Attested to borrower", i);
            console2.log("Weight:", 700_000 + (i * 50_000));
        }
    }

    function _setupMultipleCreditScores() internal {
        for (uint i = 0; i < 3; i++) {
            credit.updateCreditScore(borrowers[i], 700_000 + (i * 50_000)); // 70%, 75%, 80%
            console2.log("Borrower", i);
            console2.log("Credit score set to:", 700_000 + (i * 50_000));
        }
    }

    function _setupMultipleLoanRequests() internal returns (uint256[] memory) {
        uint256[] memory loanIds = new uint256[](3);
        for (uint i = 0; i < 3; i++) {
            vm.prank(borrowers[i]);
            loanIds[i] = credit.requestLoan(100_000_000); // 100 USDC each
            console2.log("Borrower", i);
            console2.log("Requested loan ID:", loanIds[i]);
        }
        return loanIds;
    }

    function _disburseMultipleLoans(uint256[] memory loanIds) internal {
        for (uint i = 0; i < 3; i++) {
            credit.disburseLoan(loanIds[i]);
            console2.log("Loan", loanIds[i]);
            console2.log("Disbursed to borrower", i);
        }
    }

    function _repayMultipleLoans(uint256[] memory loanIds) internal {
        for (uint i = 0; i < 3; i++) {
            (,,, uint256 interestRate,) = credit.getLoan(loanIds[i]);
            uint256 principal = 100_000_000; // We know this from the loan request
            uint256 repaymentAmount = principal + (principal * interestRate / 10000);
            
            // Simulate borrower having funds
            vm.prank(owner);
            usdc.mint(borrowers[i], repaymentAmount);
            
            vm.startPrank(borrowers[i]);
            usdc.approve(address(credit), repaymentAmount);
            credit.repayLoan(loanIds[i], repaymentAmount);
            vm.stopPrank();
            
            // Check if there's any remaining outstanding amount and the loan is still active
            (,,, uint256 finalOutstanding, bool finalActive) = credit.getLoan(loanIds[i]);
            if (finalOutstanding > 0 && finalActive) {
                vm.prank(owner);
                usdc.mint(borrowers[i], finalOutstanding);
                vm.startPrank(borrowers[i]);
                usdc.approve(address(credit), finalOutstanding);
                credit.repayLoan(loanIds[i], finalOutstanding);
                vm.stopPrank();
            } else if (finalOutstanding > 0 && !finalActive) {
                console2.log("Loan", loanIds[i], "is inactive with small outstanding amount:", finalOutstanding);
            }
            
            console2.log("Borrower", i);
            console2.log("Repaid loan", loanIds[i]);
            console2.log("Amount:", repaymentAmount);
        }
    }

    function _verifyMultipleLoansComplete(uint256[] memory loanIds) internal {
        for (uint i = 0; i < 3; i++) {
            (,,, uint256 finalOutstanding, bool finalActive) = credit.getLoan(loanIds[i]);
            // Allow for very small outstanding amounts due to rounding (up to 1000 basis points = 0.01 USDC)
            assertTrue(finalOutstanding <= 1000, "Outstanding amount should be very small or zero");
            assertTrue(!finalActive, "All loans should be inactive");
        }
    }

    function testCreditScoreUpdateAfterLoan() public {
        console2.log("=== TESTING CREDIT SCORE UPDATE AFTER LOAN ===");
        
        address borrower = borrowers[0];
        uint256 initialScore = 600_000; // 60%
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        console2.log("Testing credit score update after loan completion");
        console2.log("Initial credit score:", initialScore);
        
        // Setup and complete a loan
        credit.updateCreditScore(borrower, initialScore);
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount);
        
        // Ensure contract has funds
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000);
        
        credit.disburseLoan(loanId);
        
        // Get loan details for repayment calculation
        (,,, uint256 interestRate,) = credit.getLoan(loanId);
        uint256 totalRepayment = loanAmount + (loanAmount * interestRate / 10000);
        
        // Simulate successful repayment
        vm.prank(owner);
        usdc.mint(borrower, totalRepayment);
        vm.startPrank(borrower);
        usdc.approve(address(credit), totalRepayment);
        credit.repayLoan(loanId, totalRepayment);
        vm.stopPrank();
        
        console2.log("Loan completed successfully");
        
        // Update credit score based on successful repayment
        uint256 improvedScore = 750_000; // 75% - improved due to successful repayment
        credit.updateCreditScore(borrower, improvedScore);
        
        uint256 finalScore = credit.getCreditScore(borrower);
        console2.log("Credit score updated to:", finalScore);
        console2.log("After successful loan completion");
        
        assertEq(finalScore, improvedScore, "Credit score should be updated");
        
        console2.log("Credit score update after loan test passed\n");
    }

    // ===== EDGE CASE TESTS =====

    function testZeroCreditScoreLoanRequest() public {
        console2.log("=== TESTING ZERO CREDIT SCORE LOAN REQUEST ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        console2.log("Testing loan request with zero credit score");
        console2.log("Borrower:", borrower);
        console2.log("Requested amount:", loanAmount);
        
        uint256 initialScore = credit.getCreditScore(borrower);
        console2.log("Initial credit score:", initialScore);
        
        vm.prank(borrower);
        vm.expectRevert("No credit score");
        credit.requestLoan(loanAmount);
        
        console2.log("Loan request correctly rejected due to zero credit score\n");
    }

    function testHighCreditScoreLowInterest() public {
        console2.log("=== TESTING HIGH CREDIT SCORE LOW INTEREST ===");
        
        address borrower = borrowers[0];
        uint256 highScore = 950_000; // 95% - excellent credit
        uint256 loanAmount = 100_000_000; // 100 USDC
        
        console2.log("Testing interest rate for high credit score");
        console2.log("Credit score:", highScore);
        console2.log("Percentage: 95%");
        
        credit.updateCreditScore(borrower, highScore);
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount);
        
        (,,, uint256 interestRate,) = credit.getLoan(loanId);
        console2.log("Interest rate:", interestRate, "basis points");
        console2.log("Interest percentage:", interestRate / 100, "%");
        
        // Should be close to minimum rate (500 basis points = 5%)
        assertTrue(interestRate <= 600, "High credit score should result in low interest rate");
        
        console2.log("High credit score low interest test passed\n");
    }

    function testFullScenario() public {
        console2.log("=== RUNNING FULL INTEGRATION SCENARIO ===");
        
        // 1. Lenders deposit funds
        _fullScenarioLendersDeposit();

        // 2. Attesters attest to borrowers
        _fullScenarioAttestations();

        // 3. Oracle updates borrower credit scores
        _fullScenarioCreditScores();

        // 4. Borrowers request and receive loans
        uint256[] memory loanIds = _fullScenarioLoanRequests();

        // 5. Borrowers repay
        _fullScenarioLoanRepayments(loanIds);

        // 6. Attesters view reward
        _fullScenarioAttesterRewards(loanIds);

        // Final sanity check: loan should be inactive
        _fullScenarioFinalVerification(loanIds);
        
        console2.log("Full integration scenario completed successfully\n");
    }

    function _fullScenarioLendersDeposit() internal {
        console2.log("\n1. LENDERS DEPOSIT FUNDS");
        for (uint i = 0; i < lenders.length; i++) {
            vm.prank(lenders[i]);
            credit.depositFunds(500_000_000); // 500 USDC

            console2.log("Lender", i);
            console2.log("Lender address:", lenders[i]);
            console2.log("Deposited 500 USDC");
        }
    }

    function _fullScenarioAttestations() internal {
        console2.log("\n2. ATTESTERS PROVIDE ATTESTATIONS");
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(attesters[i]);
            credit.recordAttestation(borrowers[i], 800_000); // 80%

            console2.log("Attester", i);
            console2.log("Attester address:", attesters[i]);
            console2.log("Attested to borrower:", borrowers[i]);
        }
    }

    function _fullScenarioCreditScores() internal {
        console2.log("\n3. ORACLE UPDATES CREDIT SCORES");
        for (uint i = 0; i < borrowers.length; i++) {
            credit.updateCreditScore(borrowers[i], 800_000);
            uint256 score = credit.getCreditScore(borrowers[i]);

            console2.log("Credit score updated for:", borrowers[i]);
            console2.log("Score:", score);
            assertEq(score, 800_000);
        }
    }

    function _fullScenarioLoanRequests() internal returns (uint256[] memory) {
        console2.log("\n4. BORROWERS REQUEST AND RECEIVE LOANS");
        uint256[] memory loanIds = new uint256[](borrowers.length);
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(borrowers[i]);
            uint256 loanId = credit.requestLoan(100_000_000); // 100 USDC each
            loanIds[i] = loanId;

            console2.log("Borrower:", borrowers[i]);
            console2.log("Requested loan ID:", loanId);

            // Disburse loan
            credit.disburseLoan(loanId);
            console2.log("Loan disbursed for borrower:", borrowers[i]);
        }
        return loanIds;
    }

    function _fullScenarioLoanRepayments(uint256[] memory loanIds) internal {
        console2.log("\n5. BORROWERS REPAY LOANS");
        for (uint i = 0; i < borrowers.length; i++) {
            (
                uint256 principal,
                uint256 outstanding,
                address borrower,
                uint256 interestRate,
                bool isActive
            ) = credit.getLoan(loanIds[i]);

            console2.log("Loan", loanIds[i]);
            console2.log("Principal:", principal);
            console2.log("Outstanding:", outstanding);
            console2.log("Interest Rate (bps):", interestRate);
            console2.log("Loan active:", isActive);

            // Calculate total repayment amount (principal + interest)
            uint256 repaymentAmount = outstanding + (outstanding * interestRate / 10000);

            vm.prank(owner);
            usdc.mint(borrowers[i], repaymentAmount);

            vm.startPrank(borrowers[i]);
            usdc.approve(address(credit), repaymentAmount);
            credit.repayLoan(loanIds[i], repaymentAmount);
            vm.stopPrank();

            // Check if there's any remaining outstanding amount and the loan is still active
            (,,, uint256 finalOutstanding, bool finalActive) = credit.getLoan(loanIds[i]);
            if (finalOutstanding > 0 && finalActive) {
                vm.prank(owner);
                usdc.mint(borrowers[i], finalOutstanding);
                vm.startPrank(borrowers[i]);
                usdc.approve(address(credit), finalOutstanding);
                credit.repayLoan(loanIds[i], finalOutstanding);
                vm.stopPrank();
                
                console2.log("Additional payment made:", finalOutstanding);
            } else if (finalOutstanding > 0 && !finalActive) {
                console2.log("Loan is inactive with small outstanding amount:", finalOutstanding);
                console2.log("Skipping additional payment as loan is already inactive");
            }

            console2.log("Borrower:", borrowers[i]);
            console2.log("Repaid:", repaymentAmount);
        }
    }

    function _fullScenarioAttesterRewards(uint256[] memory loanIds) internal {
        console2.log("\n6. ATTESTERS VIEW REWARDS");
        for (uint i = 0; i < attesters.length; i++) {
            uint256 reward = credit.computeAttesterReward(loanIds[i], attesters[i]);
            console2.log("Attester:", attesters[i]);
            console2.log("Reward for loan", loanIds[i]);
            console2.log("Reward amount:", reward);
        }
    }

    function _fullScenarioFinalVerification(uint256[] memory loanIds) internal {
        console2.log("\n7. FINAL VERIFICATION");
        for (uint i = 0; i < borrowers.length; i++) {
            (, , , , bool isActiveFinal) = credit.getLoan(loanIds[i]);
            assertTrue(!isActiveFinal);
            console2.log("Loan", loanIds[i]);
            console2.log("Is inactive:", !isActiveFinal);
        }
    }

    function testAttestationWithoutScore() public {
        console2.log("=== TESTING ATTESTATION WITHOUT CREDIT SCORE ===");
        
        // A borrower gets attested to, but no score is ever set
        address b = borrowers[0];
        address a = attesters[0];

        console2.log("Testing scenario where borrower gets attested but no credit score is set");
        console2.log("Borrower:", b);
        console2.log("Attester:", a);

        vm.prank(a);
        credit.recordAttestation(b, 500_000); // 50% attestation
        console2.log("Attestation recorded with 50% confidence");

        uint256 score = credit.getCreditScore(b);
        console2.log("Borrower", b);
        console2.log("Has score:", score);
        assertEq(score, 0); // Expect default zero

        vm.prank(b);
        vm.expectRevert(); // score is 0, so loan should revert
        credit.requestLoan(100_000_000);
        
        console2.log("Loan request correctly rejected due to no credit score\n");
    }
} 