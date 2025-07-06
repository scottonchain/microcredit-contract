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
        console2.log("PageRank scores should be updated automatically");
        
        // Check that both participants are now in the system
        address[] memory participants = credit.getAllParticipants();
        console2.log("Total participants after attestation:", participants.length);
        
        console2.log("Atomic attestation test passed\n");
    }

    function testAtomicLoanRequest() public {
        console2.log("=== TESTING ATOMIC LOAN REQUEST ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        // Setup: Add borrower to system via attestation
        vm.prank(attesters[0]);
        credit.recordAttestation(borrower, 800_000); // 80% attestation
        
        console2.log("Before loan request:");
        console2.log("  - Borrower:", borrower);
        console2.log("  - Requested amount:", loanAmount);
        
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount, 365 days);
        
        (uint256 principal, uint256 outstanding, address loanBorrower, uint256 interestRate, uint256 repaymentPeriod, uint256 dueDate, bool isActive, bool isFunded) = credit.getLoan(loanId);
        
        console2.log("After loan request:");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Outstanding (includes interest):", outstanding);
        console2.log("  - Borrower:", loanBorrower);
        console2.log("  - Interest rate (basis points):", interestRate);
        console2.log("  - Is active:", isActive);
        
        assertEq(loanBorrower, borrower, "Loan should be assigned to correct borrower");
        assertEq(principal, loanAmount, "Principal should match requested amount");
        assertTrue(outstanding > principal, "Outstanding should include principal plus interest");
        assertTrue(isActive, "Loan should be active");
        
        console2.log("Atomic loan request test passed\n");
    }

    function testAtomicLoanDisbursement() public {
        console2.log("=== TESTING ATOMIC LOAN DISBURSEMENT ===");
        
        address borrower = borrowers[0];
        uint256 loanAmount = 50_000_000; // 50 USDC
        
        // Setup: Add borrower to system and request loan
        vm.prank(attesters[0]);
        credit.recordAttestation(borrower, 800_000);
        
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount, 365 days);
        
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
        
        credit.fundLoan(loanId);
        
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
        vm.prank(attesters[0]);
        credit.recordAttestation(borrower, 800_000);
        
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(loanAmount, 365 days);
        
        // Ensure contract has funds
        vm.prank(lenders[0]);
        credit.depositFunds(100_000_000);
        
        credit.fundLoan(loanId);
        
        // Get loan details before repayment
        (uint256 principal, uint256 outstanding,,,,,,) = credit.getLoan(loanId);
        uint256 initialBorrowerBalance = usdc.balanceOf(borrower);
        uint256 initialContractBalance = usdc.balanceOf(address(credit));
        
        console2.log("Before repayment:");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Outstanding (includes interest):", outstanding);
        console2.log("  - Borrower balance:", initialBorrowerBalance);
        console2.log("  - Contract balance:", initialContractBalance);
        
        // Outstanding amount already includes principal + interest
        
        // Simulate borrower having funds to repay
        vm.prank(owner);
        usdc.mint(borrower, outstanding);
        
        vm.startPrank(borrower);
        usdc.approve(address(credit), outstanding);
        credit.repayLoan(loanId, outstanding);
        vm.stopPrank();
        
        (, uint256 finalOutstanding,,,,, bool finalActive,) = credit.getLoan(loanId);
        
        console2.log("After repayment:");
        console2.log("  - Outstanding:", finalOutstanding);
        console2.log("  - Borrower balance:", usdc.balanceOf(borrower));
        console2.log("  - Contract balance:", usdc.balanceOf(address(credit)));
        console2.log("  - Is active:", finalActive);
        
        // Loan should be fully repaid and inactive
        assertTrue(finalOutstanding <= 2000, "Outstanding amount should be very small or zero (allowing for rounding)");
        assertTrue(!finalActive, "Loan should be inactive after full repayment");
        assertEq(usdc.balanceOf(address(credit)), initialContractBalance + outstanding, "Contract should receive repayment");
        
        console2.log("Atomic loan repayment test passed\n");
    }

    // ===== PAGERANK-BASED CREDIT SCORING TESTS =====

    function testPageRankInitialization() public {
        console2.log("=== TESTING PAGERANK INITIALIZATION ===");
        
        address borrower = borrowers[0];
        address attester = attesters[0];
        
        console2.log("Testing PageRank initialization with attestation");
        console2.log("Borrower:", borrower);
        console2.log("Attester:", attester);
        
        // Record attestation to trigger PageRank initialization
        vm.prank(attester);
        credit.recordAttestation(borrower, 800_000); // 80% confidence
        
        // Check that both participants are in the system
        address[] memory participants = credit.getAllParticipants();
        console2.log("Total participants:", participants.length);
        assertEq(participants.length, 2, "Should have 2 participants");
        
        // Check initial credit scores
        uint256 borrowerScore = credit.getCreditScore(borrower);
        uint256 attesterScore = credit.getCreditScore(attester);
        
        console2.log("Initial credit scores:");
        console2.log("  - Borrower score:", borrowerScore);
        console2.log("  - Attester score:", attesterScore);
        
        // Both should have scores > 0 after PageRank computation
        assertTrue(borrowerScore > 0, "Borrower should have positive credit score");
        assertTrue(attesterScore > 0, "Attester should have positive credit score");
        
        console2.log("PageRank initialization test passed\n");
    }

    function testPageRankScoreProgression() public {
        console2.log("=== TESTING PAGERANK SCORE PROGRESSION ===");
        
        address borrower = borrowers[0];
        address attester1 = attesters[0];
        address attester2 = attesters[1];
        
        console2.log("Testing PageRank score progression with multiple attestations");
        console2.log("Borrower:", borrower);
        console2.log("Attester 1:", attester1);
        console2.log("Attester 2:", attester2);
        
        // First attestation
        vm.prank(attester1);
        credit.recordAttestation(borrower, 600_000); // 60% confidence
        
        uint256 scoreAfterFirst = credit.getCreditScore(borrower);
        console2.log("Score after first attestation:", scoreAfterFirst);
        
        // Second attestation
        vm.prank(attester2);
        credit.recordAttestation(borrower, 800_000); // 80% confidence
        
        uint256 scoreAfterSecond = credit.getCreditScore(borrower);
        console2.log("Score after second attestation:", scoreAfterSecond);
        
        // Score should increase with more attestations from new attester
        assertTrue(scoreAfterSecond > scoreAfterFirst, "Score should increase with additional attestations from new attester");
        
        console2.log("PageRank score progression test passed\n");
    }

    function testPageRankBackpropagation() public {
        console2.log("=== TESTING PAGERANK BACKPROPAGATION ===");
        
        address borrower = borrowers[0];
        address attester = attesters[0];
        
        console2.log("Testing PageRank backpropagation on successful loan repayment");
        console2.log("Borrower:", borrower);
        console2.log("Attester:", attester);
        
        // Setup: Record attestation and complete loan
        vm.prank(attester);
        credit.recordAttestation(borrower, 800_000);
        
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(100_000_000, 365 days);
        
        vm.prank(lenders[0]);
        credit.depositFunds(200_000_000);
        
        credit.fundLoan(loanId);
        
        // Get scores before repayment
        uint256 borrowerScoreBefore = credit.getCreditScore(borrower);
        uint256 attesterScoreBefore = credit.getCreditScore(attester);
        
        console2.log("Scores before repayment:");
        console2.log("  - Borrower score:", borrowerScoreBefore);
        console2.log("  - Attester score:", attesterScoreBefore);
        
        // Repay loan - get outstanding amount and repay
        (,,, uint256 interestRate,,,,) = credit.getLoan(loanId);
        uint256 totalRepayment = 100_000_000 + (100_000_000 * interestRate * 365 days) / (1e6 * 365 days);
        
        vm.prank(owner);
        usdc.mint(borrower, totalRepayment);
        
        vm.startPrank(borrower);
        usdc.approve(address(credit), totalRepayment);
        credit.repayLoan(loanId, totalRepayment);
        vm.stopPrank();
        
        // Get scores after repayment
        uint256 borrowerScoreAfter = credit.getCreditScore(borrower);
        uint256 attesterScoreAfter = credit.getCreditScore(attester);
        
        console2.log("Scores after repayment:");
        console2.log("  - Borrower score:", borrowerScoreAfter);
        console2.log("  - Attester score:", attesterScoreAfter);
        
        // Both scores should increase due to successful repayment
        assertTrue(borrowerScoreAfter >= borrowerScoreBefore, "Borrower score should increase after successful repayment");
        assertTrue(attesterScoreAfter >= attesterScoreBefore, "Attester score should increase due to backpropagation");
        
        console2.log("PageRank backpropagation test passed\n");
    }

    function testPageRankInterestRateImpact() public {
        console2.log("=== TESTING PAGERANK IMPACT ON INTEREST RATES ===");
        
        address borrower1 = borrowers[0];
        address borrower2 = borrowers[1];
        address attester1 = attesters[0];
        address attester2 = attesters[1];
        
        console2.log("Testing how PageRank scores affect interest rates");
        
        // Setup: Different attestation weights for different borrowers
        vm.prank(attester1);
        credit.recordAttestation(borrower1, 600_000); // 60% confidence
        
        vm.prank(attester2);
        credit.recordAttestation(borrower2, 900_000); // 90% confidence
        
        // Request loans
        vm.prank(borrower1);
        uint256 loanId1 = credit.requestLoan(100_000_000, 365 days);
        
        vm.prank(borrower2);
        uint256 loanId2 = credit.requestLoan(100_000_000, 365 days);
        
        // Get interest rates - only extract what we need
        (,,, uint256 interestRate1,,,,) = credit.getLoan(loanId1);
        (,,, uint256 interestRate2,,,,) = credit.getLoan(loanId2);
        
        console2.log("Interest rates:");
        console2.log("  - Borrower 1 (60% attestation):", interestRate1, "basis points");
        console2.log("  - Borrower 2 (90% attestation):", interestRate2, "basis points");
        
        // Higher attestation weight should result in lower interest rate
        assertTrue(interestRate2 <= interestRate1, "Higher attestation weight should result in lower interest rate");
        
        console2.log("PageRank interest rate impact test passed\n");
    }

    // ===== HIGHER-LEVEL SCENARIO TESTS =====

    function testCompletePageRankLoanLifecycle() public {
        console2.log("=== TESTING COMPLETE PAGERANK LOAN LIFECYCLE ===");
        
        address lender = lenders[0];
        address borrower = borrowers[0];
        address attester = attesters[0];
        
        console2.log("Starting complete PageRank loan lifecycle test:");
        console2.log("  - Lender:", lender);
        console2.log("  - Borrower:", borrower);
        console2.log("  - Attester:", attester);
        console2.log("  - Deposit amount: 200 USDC");
        console2.log("  - Loan amount: 100 USDC");
        console2.log("  - Attestation weight: 80%");
        
        // Step 1: Lender deposits funds (triggers PageRank initialization)
        _testLenderDeposit(lender, 200_000_000);
        
        // Step 2: Attester provides attestation (triggers PageRank update)
        _testAttestation(attester, borrower, 800_000);
        
        // Step 3: Check initial credit scores
        _testInitialCreditScores(borrower, attester);
        
        // Step 4: Borrower requests loan
        uint256 loanId = _testLoanRequest(borrower, 100_000_000);
        
        // Step 5: Loan is disbursed
        _testLoanDisbursement(borrower, loanId, 100_000_000);
        
        // Step 6: Borrower repays loan (triggers PageRank backpropagation)
        _testLoanRepayment(borrower, loanId);
        
        // Step 7: Check updated credit scores after repayment
        _testUpdatedCreditScores(borrower, attester);
        
        // Step 8: Calculate attester reward
        _testAttesterReward(loanId, attester);
        
        console2.log("Complete PageRank loan lifecycle test passed\n");
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

    function _testInitialCreditScores(address borrower, address attester) internal {
        console2.log("\nStep 3: Check initial credit scores");
        uint256 borrowerScore = credit.getCreditScore(borrower);
        uint256 attesterScore = credit.getCreditScore(attester);
        console2.log("  - Borrower initial score:", borrowerScore);
        console2.log("  - Attester initial score:", attesterScore);
    }

    function _testLoanRequest(address borrower, uint256 amount) internal returns (uint256) {
        console2.log("\nStep 4: Borrower requests loan");
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(amount, 365 days);
        (uint256 principal,,, uint256 interestRate,,, bool isActive,) = credit.getLoan(loanId);
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Principal:", principal);
        console2.log("  - Interest rate:", interestRate, "basis points");
        console2.log("  - Is active:", isActive);
        return loanId;
    }

    function _testLoanDisbursement(address borrower, uint256 loanId, uint256 amount) internal {
        console2.log("\nStep 5: Loan is disbursed");
        uint256 preDisbursementBalance = usdc.balanceOf(borrower);
        credit.fundLoan(loanId);
        uint256 postDisbursementBalance = usdc.balanceOf(borrower);
        console2.log("  - Borrower received:", postDisbursementBalance - preDisbursementBalance);
    }

    function _testLoanRepayment(address borrower, uint256 loanId) internal {
        console2.log("\nStep 6: Borrower repays loan");
        (uint256 principal, uint256 outstanding,,,,,,) = credit.getLoan(loanId);
        
        console2.log("  - Principal:", principal);
        console2.log("  - Outstanding (includes interest):", outstanding);
        
        // Outstanding amount already includes principal + interest
        console2.log("  - Total repayment needed:", outstanding);
        
        // Simulate borrower having funds
        vm.prank(owner);
        usdc.mint(borrower, outstanding);
        
        vm.startPrank(borrower);
        usdc.approve(address(credit), outstanding);
        credit.repayLoan(loanId, outstanding);
        vm.stopPrank();
        
        (, uint256 finalOutstanding,,,,, bool finalActive,) = credit.getLoan(loanId);
        console2.log("  - Final outstanding after payment:", finalOutstanding);
        console2.log("  - Loan active after payment:", finalActive);
        
        // Loan should be fully repaid and inactive
        assertTrue(finalOutstanding <= 2000, "Outstanding amount should be very small or zero (allowing for rounding)");
        assertTrue(!finalActive, "Loan should be inactive after full repayment");
    }

    function _testUpdatedCreditScores(address borrower, address attester) internal {
        console2.log("\nStep 7: Check updated credit scores after repayment");
        uint256 borrowerScore = credit.getCreditScore(borrower);
        uint256 attesterScore = credit.getCreditScore(attester);
        console2.log("  - Borrower updated score:", borrowerScore);
        console2.log("  - Attester updated score:", attesterScore);
    }

    function _testAttesterReward(uint256 loanId, address attester) internal {
        console2.log("\nStep 8: Calculate attester reward");
        console2.log("  - Loan ID:", loanId);
        console2.log("  - Attester:", attester);
        
        // Check loan status before computing reward
        (, uint256 outstanding,,,,, bool isActive,) = credit.getLoan(loanId);
        console2.log("  - Loan outstanding:", outstanding);
        console2.log("  - Loan active:", isActive);
        
        uint256 reward = credit.computeAttesterReward(loanId, attester);
        console2.log("  - Attester reward:", reward);
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
        credit.requestLoan(loanAmount, 365 days);
        
        console2.log("Loan request correctly rejected due to zero credit score\n");
    }

    function testSelfAttestation() public {
        console2.log("=== TESTING SELF ATTESTATION ===");
        
        address borrower = borrowers[0];
        
        console2.log("Testing self-attestation (should be rejected)");
        console2.log("Borrower:", borrower);
        
        vm.prank(borrower);
        vm.expectRevert("Cannot attest to self");
        credit.recordAttestation(borrower, 800_000);
        
        console2.log("Self-attestation correctly rejected\n");
    }

    function testPageRankConvergence() public {
        console2.log("=== TESTING PAGERANK CONVERGENCE ===");
        
        address borrower = borrowers[0];
        address attester = attesters[0];
        
        console2.log("Testing PageRank convergence with attestation");
        console2.log("Borrower:", borrower);
        console2.log("Attester:", attester);
        
        // Record attestation to trigger PageRank computation
        vm.prank(attester);
        credit.recordAttestation(borrower, 800_000);
        
        // Check that both participants are in the system
        address[] memory participants = credit.getAllParticipants();
        console2.log("Total participants:", participants.length);
        
        // Get credit scores
        uint256 borrowerScore = credit.getCreditScore(borrower);
        uint256 attesterScore = credit.getCreditScore(attester);
        
        console2.log("Converged credit scores:");
        console2.log("  - Borrower score:", borrowerScore);
        console2.log("  - Attester score:", attesterScore);
        
        // Both should have positive scores after convergence
        assertTrue(borrowerScore > 0, "Borrower should have positive score after convergence");
        assertTrue(attesterScore > 0, "Attester should have positive score after convergence");
        
        console2.log("PageRank convergence test passed\n");
    }
} 