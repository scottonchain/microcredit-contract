// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import {Attestation} from "../src/Attestation.sol";

contract InteractWithAttestation is ScaffoldETHDeploy {
    function run() external {
        // Get the private key from .env
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        if (deployerPrivateKey == 0) {
            revert InvalidPrivateKey(
                "You don't have a deployer account. Make sure you have set DEPLOYER_PRIVATE_KEY in .env or use `yarn generate` to generate a new random account"
            );
        }

        // Create some test addresses
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        console.log("\nDeploying contract and setting up test addresses...");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract
        Attestation attestation = new Attestation();
        console.log("Attestation contract deployed at:", address(attestation));

        // Fund the test addresses
        payable(alice).transfer(100 ether);
        payable(bob).transfer(100 ether);
        payable(charlie).transfer(100 ether);

        // Stop deployer broadcast before starting pranks
        vm.stopBroadcast();

        console.log("\nTest Addresses (funded with 100 ETH each):");
        console.log("Alice:", alice);
        console.log("Bob:", bob);
        console.log("Charlie:", charlie);

        console.log("\nCreating attestations...");

        // Alice creates attestations
        console.log("\nAlice creating attestations...");
        vm.prank(alice);
        try attestation.createAttestation(bob, "Bob is a great developer!") {
            console.log("Successfully created attestation: Alice -> Bob");
        } catch Error(string memory reason) {
            console.log("Failed to create attestation: Alice -> Bob");
            console.log("Reason:", reason);
        }

        vm.prank(alice);
        try attestation.createAttestation(charlie, "Charlie helped review my code!") {
            console.log("Successfully created attestation: Alice -> Charlie");
        } catch Error(string memory reason) {
            console.log("Failed to create attestation: Alice -> Charlie");
            console.log("Reason:", reason);
        }

        // Bob creates attestation
        console.log("\nBob creating attestation...");
        vm.prank(bob);
        try attestation.createAttestation(charlie, "Charlie is an amazing collaborator!") {
            console.log("Successfully created attestation: Bob -> Charlie");
        } catch Error(string memory reason) {
            console.log("Failed to create attestation: Bob -> Charlie");
            console.log("Reason:", reason);
        }

        // Charlie creates attestation
        console.log("\nCharlie creating attestation...");
        vm.prank(charlie);
        try attestation.createAttestation(alice, "Alice is a fantastic team lead!") {
            console.log("Successfully created attestation: Charlie -> Alice");
        } catch Error(string memory reason) {
            console.log("Failed to create attestation: Charlie -> Alice");
            console.log("Reason:", reason);
        }

        // Read and display attestations
        console.log("\nReading attestations...");
        
        uint256 totalAttestations = attestation.getAttestationsCount();
        console.log("\nTotal Attestations:", totalAttestations);

        if (totalAttestations > 0) {
            console.log("\nBob's received attestations:");
            Attestation.AttestationData[] memory bobAttestations = attestation.getReceivedAttestations(bob);
            for(uint i = 0; i < bobAttestations.length; i++) {
                console.log("From:", bobAttestations[i].from);
                console.log("Message:", bobAttestations[i].message);
                console.log("Timestamp:", bobAttestations[i].timestamp);
                console.log("---");
            }

            console.log("\nCharlie's received attestations:");
            Attestation.AttestationData[] memory charlieAttestations = attestation.getReceivedAttestations(charlie);
            for(uint i = 0; i < charlieAttestations.length; i++) {
                console.log("From:", charlieAttestations[i].from);
                console.log("Message:", charlieAttestations[i].message);
                console.log("Timestamp:", charlieAttestations[i].timestamp);
                console.log("---");
            }

            console.log("\nAlice's received attestations:");
            Attestation.AttestationData[] memory aliceAttestations = attestation.getReceivedAttestations(alice);
            for(uint i = 0; i < aliceAttestations.length; i++) {
                console.log("From:", aliceAttestations[i].from);
                console.log("Message:", aliceAttestations[i].message);
                console.log("Timestamp:", aliceAttestations[i].timestamp);
                console.log("---");
            }
        } else {
            console.log("No attestations found!");
        }
    }
} 