// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/YourContract.sol";
import "../src/mocks/MockUSDC.sol"; // your ERC20 token mock

contract DecentralizedMicrocreditTest is Test {
    YourContract credit;
    MockUSDC usdc;

    address owner;
    address[] lenders;
    address[] borrowers;
    address[] attesters;

    function setUp() public {
        owner = address(this);
        usdc = new MockUSDC("Mock USDC", "USDC", 6);
        credit = new YourContract(500, 2000, address(usdc), owner); // 5% - 20% in basis points, USDC address, oracle

        // Mint USDC and approve
        for (uint i = 0; i < 10; i++) {
            address lender = address(uint160(uint(keccak256(abi.encode("lender", i)))));
            address borrower = address(uint160(uint(keccak256(abi.encode("borrower", i)))));
            address attester = address(uint160(uint(keccak256(abi.encode("attester", i)))));

            lenders.push(lender);
            borrowers.push(borrower);
            attesters.push(attester);

            usdc.mint(lender, 1_000_000_000); // 1,000 USDC
            usdc.mint(borrower, 0);
            usdc.mint(attester, 0);

            vm.prank(lender);
            usdc.approve(address(credit), type(uint256).max);
        }
    }

    function testScenario() public {
        // 1. Lenders deposit funds
        for (uint i = 0; i < lenders.length; i++) {
            vm.prank(lenders[i]);
            credit.depositFunds(500_000_000); // 500 USDC
        }

        // 2. Attesters attest to borrowers
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(attesters[i]);
            credit.recordAttestation(borrowers[i], 800_000); // 80% confidence
        }

        // 3. Oracle updates borrower credit scores
        for (uint i = 0; i < borrowers.length; i++) {
            credit.updateCreditScore(borrowers[i], 800_000); // x = 0.8
        }

        // 4. Borrowers request and receive loans
        uint256[] memory loanIds = new uint256[](borrowers.length);
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(borrowers[i]);
            uint256 loanId = credit.requestLoan(100_000_000); // 100 USDC
            loanIds[i] = loanId;

            // Disburse loan as owner or oracle
            credit.disburseLoan(loanId);
        }

        // 5. Borrowers repay
        for (uint i = 0; i < borrowers.length; i++) {
            // Debug: Check loan details
            (uint256 principal, uint256 outstanding, address borrower, uint256 interestRate, bool isActive) = credit.getLoan(loanIds[i]);
            console2.log("Loan", loanIds[i]);
            console2.log("Stored borrower:", borrower);
            console2.log("Test borrower:", borrowers[i]);
            
            // Mint USDC to borrower
            vm.prank(owner);
            usdc.mint(borrowers[i], 110_000_000); // 100 + interest
            
            // Switch to borrower for approval and repayment
            vm.startPrank(borrowers[i]);
            usdc.approve(address(credit), 110_000_000);
            credit.repayLoan(loanIds[i], 110_000_000);
            vm.stopPrank();
        }

        // 6. Attesters claim/view rewards
        for (uint i = 0; i < attesters.length; i++) {
            uint256 reward = credit.computeAttesterReward(loanIds[i], attesters[i]);
            console2.log("Attester", attesters[i], "reward:", reward);
        }
    }
}
