// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Attestation {
    struct AttestationData {
        address from;
        address to;
        string message;
        uint256 timestamp;
    }

    // Array to store all attestations
    AttestationData[] public attestations;
    
    // Mapping from address to their received attestations indexes
    mapping(address => uint256[]) public receivedAttestations;
    
    // Event emitted when new attestation is created
    event NewAttestation(address indexed from, address indexed to, string message, uint256 timestamp);

    function createAttestation(address to, string memory message) public {
        require(to != address(0), "Cannot attest to zero address");
        require(bytes(message).length > 0, "Message cannot be empty");
        
        uint256 index = attestations.length;
        attestations.push(AttestationData({
            from: msg.sender,
            to: to,
            message: message,
            timestamp: block.timestamp
        }));
        
        receivedAttestations[to].push(index);
        
        emit NewAttestation(msg.sender, to, message, block.timestamp);
    }

    function getAttestationsCount() public view returns (uint256) {
        return attestations.length;
    }

    function getReceivedAttestations(address user) public view returns (AttestationData[] memory) {
        uint256[] memory indices = receivedAttestations[user];
        AttestationData[] memory userAttestations = new AttestationData[](indices.length);
        
        for (uint256 i = 0; i < indices.length; i++) {
            userAttestations[i] = attestations[indices[i]];
        }
        
        return userAttestations;
    }
} 