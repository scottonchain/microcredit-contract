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
}
