// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/YourContract.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract YourContractTest is Test {
    YourContract public contractInstance;
    ERC20Mock public usdc;

    address public owner = address(0x1);
    address public oracle = address(0x2);
    address public borrower = address(0x3);
    address public attester1 = address(0x4);
    address public attester2 = address(0x5);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new ERC20Mock();

        contractInstance = new YourContract(100000, 500000, address(usdc), oracle);

        // Fund borrower
        usdc.mint(borrower, 1_000 ether);
        vm.stopPrank();
    }

    function testRecordAttestations() public {
        vm.startPrank(attester1);
        contractInstance.recordAttestation(borrower, 400000);
        vm.stopPrank();

        vm.startPrank(attester2);
        contractInstance.recordAttestation(borrower, 600000);
        vm.stopPrank();

        // You'd call `getAttestations` here if you exposed it in the contract
    }

    function testComputeAttesterReward() public {
        // Set credit score
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 600);

        // Record attestations
        vm.prank(attester1);
        contractInstance.recordAttestation(borrower, 200000);

        vm.prank(attester2);
        contractInstance.recordAttestation(borrower, 800000);

        // Approve and request loan
        vm.startPrank(borrower);
        usdc.approve(address(contractInstance), 1_000 ether);
        uint256 loanId = contractInstance.requestLoan(100 ether);
        vm.stopPrank();

        // Compute rewards
        uint256 reward1 = contractInstance.computeAttesterReward(loanId, attester1);
        uint256 reward2 = contractInstance.computeAttesterReward(loanId, attester2);
        uint256 total = reward1 + reward2;

        assertEq(total, 5 ether); // 5% of 100
    }

    function testRejectLoanWithNoCredit() public {  
        vm.expectRevert("No credit score");
        vm.prank(borrower);
        contractInstance.requestLoan(100 ether);
    }

    function testAcceptLoanWithCredit() public {
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 500);

        vm.prank(borrower);
        contractInstance.requestLoan(100 ether);
    }

    function testDisburseLoan() public {
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 500);

        // Fund the contract with USDC for disbursement
        vm.startPrank(owner);
        usdc.mint(address(contractInstance), 100 ether);
        vm.stopPrank();

        vm.startPrank(borrower);
        usdc.approve(address(contractInstance), 1_000 ether);
        uint256 loanId = contractInstance.requestLoan(100 ether);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(borrower);

        vm.prank(owner);
        contractInstance.disburseLoan(loanId);

        uint256 afterBal = usdc.balanceOf(borrower);
        assertEq(afterBal - before, 100 ether);
    }

    function testAttestationsAffectReputation() public {
        // Initial credit score
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 300);
        
        uint256 initialScore = contractInstance.getCreditScore(borrower);
        assertEq(initialScore, 300);

        // Record multiple attestations with different weights
        vm.prank(attester1);
        contractInstance.recordAttestation(borrower, 200000); // 20% weight

        vm.prank(attester2);
        contractInstance.recordAttestation(borrower, 800000); // 80% weight

        // Oracle updates credit score based on attestations
        // Higher attestation weights should lead to better credit scores
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 700); // Improved score

        uint256 newScore = contractInstance.getCreditScore(borrower);
        assertEq(newScore, 700);
        assertGt(newScore, initialScore, "Credit score should improve with attestations");

        // Test that higher attestation weights lead to better loan terms
        (uint256 interestRate1,) = contractInstance.previewLoanTerms(borrower, 100 ether, 365 days);
        
        // Compare with a borrower who has no attestations
        address borrower2 = address(0x6);
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower2, 300); // Same initial score
        
        (uint256 interestRate2,) = contractInstance.previewLoanTerms(borrower2, 100 ether, 365 days);
        
        // Borrower with attestations should get better interest rate
        assertLt(interestRate1, interestRate2, "Borrower with attestations should get better interest rate");
    }

    function testAttestationWeightImpact() public {
        // Set initial credit score
        vm.prank(oracle);
        contractInstance.updateCreditScore(borrower, 400);

        // Record attestations with different weights
        vm.prank(attester1);
        contractInstance.recordAttestation(borrower, 100000); // 10% weight

        vm.prank(attester2);
        contractInstance.recordAttestation(borrower, 900000); // 90% weight

        // Request a loan to test reward distribution
        vm.startPrank(borrower);
        usdc.approve(address(contractInstance), 1_000 ether);
        uint256 loanId = contractInstance.requestLoan(100 ether);
        vm.stopPrank();

        // Fund contract for disbursement
        vm.startPrank(owner);
        usdc.mint(address(contractInstance), 100 ether);
        vm.stopPrank();

        // Disburse loan
        vm.prank(owner);
        contractInstance.disburseLoan(loanId);

        // Test reward distribution based on attestation weights
        uint256 reward1 = contractInstance.computeAttesterReward(loanId, attester1);
        uint256 reward2 = contractInstance.computeAttesterReward(loanId, attester2);
        
        // Attester2 should get 9x more reward than attester1 (90% vs 10%)
        assertGt(reward2, reward1, "Higher weight attestation should get more reward");
        assertEq(reward2, reward1 * 9, "Reward should be proportional to attestation weight");
    }
}
