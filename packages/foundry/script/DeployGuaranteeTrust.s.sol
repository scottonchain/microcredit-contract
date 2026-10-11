// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../contracts/GuaranteeTrust.sol";

/**
 * @notice Deploys GuaranteeTrust for testnet simulations. Testnet only; no live guarantee.
 * @dev Env (all optional):
 *      TOKEN          token to use; if unset, a fresh MockUSDC is deployed and every receipt must say MockUSDC
 *      UNIT           one token unit for the caps (default 1e6: line 20, attest 20, contribution cap 3)
 *      ISSUER_BUDGET  issuer line budget (default 60 x UNIT)
 *      ADJUDICATOR    defaults to SIM_MNEMONIC index 1 when SIM_MNEMONIC is set, else the broadcaster
 *      ISSUER         defaults to SIM_MNEMONIC index 2 when SIM_MNEMONIC is set, else the broadcaster
 *      Owner, guardian and sponsor are the broadcaster. For the scenarios, set SIM_MNEMONIC so that the
 *      adjudicator and the issuer are distinct keys and no one address holds every role.
 *      forge script script/DeployGuaranteeTrust.s.sol --rpc-url https://sepolia.base.org --broadcast
 */
contract DeployGuaranteeTrust is Script {
    function run() external returns (GuaranteeTrust gt, address token) {
        uint256 unit = vm.envOr("UNIT", uint256(1e6));
        uint256 budget = vm.envOr("ISSUER_BUDGET", 60 * unit);
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) token = address(new MockUSDC());
        string memory mnemonic = vm.envOr("SIM_MNEMONIC", string(""));
        bool sim = bytes(mnemonic).length != 0;
        address adjudicator = vm.envOr("ADJUDICATOR", sim ? vm.addr(vm.deriveKey(mnemonic, 1)) : me);
        address issuer = vm.envOr("ISSUER", sim ? vm.addr(vm.deriveKey(mnemonic, 2)) : me);
        gt = new GuaranteeTrust(IERC20(token), me, adjudicator, issuer, budget, unit);
        vm.stopBroadcast();
        console.log("GuaranteeTrust", address(gt));
        console.log("token", token);
        console.log("owner/guardian", me);
        console.log("adjudicator", adjudicator);
        console.log("issuer", issuer);
    }
}
