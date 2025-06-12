// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Attestation.sol";

contract AttestationTest is Test {
    Attestation public attestation;
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public {
        attestation = new Attestation();
        
        // Create test addresses with some ETH
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        // Log the addresses
        console.log("Test Addresses:");
        console.log("Alice's address:", alice);
        console.log("Bob's address:", bob);
        console.log("Charlie's address:", charlie);
    }

    function testCreateAttestation() public {
        vm.startPrank(alice);
        attestation.createAttestation(bob, "Great developer!");
        vm.stopPrank();

        assertEq(attestation.getAttestationsCount(), 1);
    }

    function testMultipleAttestations() public {
        // Alice attests to Bob
        vm.startPrank(alice);
        attestation.createAttestation(bob, "Excellent work on the smart contract!");
        attestation.createAttestation(charlie, "Thanks for the code review!");
        vm.stopPrank();

        // Bob attests to Charlie
        vm.startPrank(bob);
        attestation.createAttestation(charlie, "Amazing collaboration!");
        vm.stopPrank();

        // Charlie attests to Alice
        vm.startPrank(charlie);
        attestation.createAttestation(alice, "Great team lead!");
        vm.stopPrank();

        // Check total attestations
        assertEq(attestation.getAttestationsCount(), 4);

        // Check Bob's received attestations
        Attestation.AttestationData[] memory bobAttestations = attestation.getReceivedAttestations(bob);
        assertEq(bobAttestations.length, 1);
        assertEq(bobAttestations[0].from, alice);
        assertEq(bobAttestations[0].message, "Excellent work on the smart contract!");

        // Check Charlie's received attestations
        Attestation.AttestationData[] memory charlieAttestations = attestation.getReceivedAttestations(charlie);
        assertEq(charlieAttestations.length, 2);
    }

    function testInvalidAttestation() public {
        vm.startPrank(alice);
        
        // Test attestation to zero address
        vm.expectRevert("Cannot attest to zero address");
        attestation.createAttestation(address(0), "Invalid attestation");
        
        // Test empty message
        vm.expectRevert("Message cannot be empty");
        attestation.createAttestation(bob, "");
        
        vm.stopPrank();
    }

    function testManyAttestations() public {
        // Create 10 attestations from different addresses to different recipients
        for(uint i = 0; i < 10; i++) {
            address sender = makeAddr(string(abi.encodePacked("sender", vm.toString(i))));
            address recipient = makeAddr(string(abi.encodePacked("recipient", vm.toString(i))));
            vm.deal(sender, 1 ether);
            
            vm.startPrank(sender);
            attestation.createAttestation(
                recipient, 
                string(abi.encodePacked("Attestation number ", vm.toString(i)))
            );
            vm.stopPrank();
        }

        assertEq(attestation.getAttestationsCount(), 10);
    }
} 