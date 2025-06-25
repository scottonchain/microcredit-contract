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
        credit = new YourContract(500, 2000, address(usdc), owner); // 5% - 20% in basis points

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

    function testFullScenario() public {
        uint256 initialLenderBalance = usdc.balanceOf(lenders[0]);

        // 1. Lenders deposit funds
        for (uint i = 0; i < lenders.length; i++) {
            vm.prank(lenders[i]);
            credit.depositFunds(500_000_000); // 500 USDC

            console2.log("Lender", i);
            console2.log("Lender address:", lenders[i]);
            console2.log("Deposited 500 USDC");
        }

        // 2. Attesters attest to borrowers
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(attesters[i]);
            credit.recordAttestation(borrowers[i], 800_000); // 80%

            console2.log("Attester", i);
            console2.log("Attester address:", attesters[i]);
            console2.log("Attested to borrower:", borrowers[i]);
        }

        // 3. Oracle updates borrower credit scores
        for (uint i = 0; i < borrowers.length; i++) {
            credit.updateCreditScore(borrowers[i], 800_000);
            uint256 score = credit.getCreditScore(borrowers[i]);

            console2.log("Credit score updated for:", borrowers[i]);
            console2.log("Score:", score);
            assertEq(score, 800_000);
        }

        // 4. Borrowers request and receive loans
        uint256[] memory loanIds = new uint256[](borrowers.length);
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(borrowers[i]);
            uint256 loanId = credit.requestLoan(100_000_000); // 100 USDC
            loanIds[i] = loanId;

            console2.log("Borrower:", borrowers[i]);
            console2.log("Requested loan ID:", loanId);

            // Disburse loan
            credit.disburseLoan(loanId);
            console2.log("Loan disbursed for borrower:", borrowers[i]);
        }

        // 5. Borrowers repay
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

            // Simulate borrower receiving funds + interest
            uint256 repaymentAmount = outstanding;

            vm.prank(owner);
            usdc.mint(borrowers[i], repaymentAmount);

            vm.startPrank(borrowers[i]);
            usdc.approve(address(credit), repaymentAmount);
            credit.repayLoan(loanIds[i], repaymentAmount);
            vm.stopPrank();

            console2.log("Borrower:", borrowers[i]);
            console2.log("Repaid:", repaymentAmount);
        }

        // 6. Attesters view reward
        for (uint i = 0; i < attesters.length; i++) {
            uint256 reward = credit.computeAttesterReward(loanIds[i], attesters[i]);
            console2.log("Attester:", attesters[i]);
            console2.log("Reward for loan", loanIds[i], ":", reward);
        }

        // Final sanity check: loan should be inactive
        for (uint i = 0; i < borrowers.length; i++) {
            (, , , , bool isActiveFinal) = credit.getLoan(loanIds[i]);
            assertTrue(!isActiveFinal);
        }
    }

    function testAttestationWithoutScore() public {
        // A borrower gets attested to, but no score is ever set
        address b = borrowers[0];
        address a = attesters[0];

        vm.prank(a);
        credit.recordAttestation(b, 500_000); // 50% attestation

        uint256 score = credit.getCreditScore(b);
        console2.log("Borrower:", b);
        console2.log("Has score:", score);
        assertEq(score, 0); // Expect default zero

        vm.prank(b);
        vm.expectRevert(); // score is 0, so loan might revert
        credit.requestLoan(100_000_000);
    }
}
