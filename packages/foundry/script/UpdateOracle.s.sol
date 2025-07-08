// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../contracts/DecentralizedMicrocredit.sol";

contract UpdateOracleScript is Script {
    function run() external {
        // Read deployment data
        string memory deploymentJson = vm.readFile("deployment.json");
        address contractAddress = abi.decode(
            vm.parseJson(deploymentJson, ".DecentralizedMicrocredit"),
            (address)
        );
        
        console.logString(string.concat("Contract address: ", vm.toString(contractAddress)));
        
        // Get current oracle
        DecentralizedMicrocredit microcreditContract = DecentralizedMicrocredit(contractAddress);
        address currentOracle = microcreditContract.oracle();
        
        console.logString(string.concat("Current oracle: ", vm.toString(currentOracle)));
        console.logString(string.concat("New oracle (msg.sender): ", vm.toString(msg.sender)));
        
        // Update oracle
        vm.startBroadcast();
        microcreditContract.setOracle(msg.sender);
        vm.stopBroadcast();
        
        console.logString("Oracle updated successfully!");
    }
} 