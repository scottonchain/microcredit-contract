// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/DecentralizedMicrocredit.sol";

contract ParticipantsArrayTests is Test {
    DecentralizedMicrocredit credit;
    IERC20 usdc;
    address owner;
    address[] participants;

    function setUp() public {
        owner = makeAddr("owner");
        
        // Create a mock USDC token address
        usdc = IERC20(makeAddr("usdc"));
        
        vm.startPrank(owner);
        credit = new DecentralizedMicrocredit(500, 2000, address(usdc), owner); // 5% - 20% in basis points
        vm.stopPrank();

        // Create test participants
        for (uint i = 0; i < 10; i++) {
            address participant = makeAddr(string.concat("participant", vm.toString(i)));
            participants.push(participant);
        }
    }

    function testAddParticipants() public {
        // Add participants through attestations
        for (uint i = 0; i < participants.length; i++) {
            address attester = participants[i];
            address borrower = participants[(i + 1) % participants.length];
            
            vm.prank(attester);
            credit.recordAttestation(borrower, 500000); // 50% weight
        }
        
        // Note: The current contract doesn't have getAllParticipants function
        // This test would need to be updated based on the actual interface
    }

    function testParticipantCreditScores() public {
        // Add participants and set credit scores
        for (uint i = 0; i < participants.length; i++) {
            address participant = participants[i];
            uint256 score = 100000 + (i * 50000); // Varying scores
            
            vm.prank(owner);
            credit.updateCreditScore(participant, score);
            
            uint256 retrievedScore = credit.getCreditScore(participant);
            assertEq(retrievedScore, score);
        }
    }
} 