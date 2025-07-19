// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "../contracts/MockUSDC.sol";

/**
 * @notice Deploys MockUSDC & DecentralizedMicrocredit, mints USDC + ETH to 10 lenders,
 * and writes deployment.json with addresses.
 */
contract DeployScript is Script {
    function run() external {
        // Start broadcasting - the private key will be provided by the forge script command
        vm.startBroadcast();

        // 1) Deploy token + microcredit
        MockUSDC usdc = new MockUSDC();
        DecentralizedMicrocredit micro = new DecentralizedMicrocredit(
            550,       // 5.5% effrRate (1e4)
            350,       // 3.5% riskPremium (1e4)
            100 * 1e6, // maxLoan = 100 USDC (6 decimals)
            address(usdc),
            vm.addr(999) // placeholder oracle
        );

        // 2) Mint USDC + ETH top-up for 10 lenders
        // Read the mnemonic from the environment, passed in by the Makefile
        string memory mnemonic = vm.envString("MNEMONIC");
        require(bytes(mnemonic).length > 0, "MNEMONIC env var not set");

        uint256 depositAmount = 3000 * 1e6; // 3,000 USDC

        for (uint i = 0; i < 10; i++) {
            // Derive the private key for each lender account using cast-compatible derivation
            uint256 lenderPK = vm.deriveKey(mnemonic, uint32(i));
            address payable lender = payable(vm.addr(lenderPK));

            // mint 3,000 USDC
            usdc.mint(lender, depositAmount);
            // send 1 ETH for gas
            (bool ok, ) = lender.call{value: 1 ether}("");
            require(ok, "ETH topup failed");
        }

        vm.stopBroadcast();

        // 3) Write deployment.json for Makefile
        string memory json = "{}";
        json = vm.serializeAddress(json, "MICRO_ADDRESS", address(micro));
        json = vm.serializeAddress(json, "USDC_ADDRESS", address(usdc));
        vm.writeFile("deployment.json", json);
    }
}
