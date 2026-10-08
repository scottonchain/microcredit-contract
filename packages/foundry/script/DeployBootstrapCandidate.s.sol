// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import { Script, console } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { BootstrapOrderRouter } from "../contracts/BootstrapOrderRouter.sol";
import { MicrocreditLens } from "../contracts/MicrocreditLens.sol";

/// @dev Reviewed testnet candidate only. Keystore/signer is supplied by custodian CLI, never here.
///      One pool, its lens and one manager: the order-bound transitive router. The order escrow and the unbound
///      two-hop router are components of that contract and are not deployed here.
contract DeployBootstrapCandidate is Script {
    address internal constant CIRCLE_BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(CIRCLE_BASE_SEPOLIA_USDC.code.length != 0, "token absent");
        require(IERC20Metadata(CIRCLE_BASE_SEPOLIA_USDC).decimals() == 6, "wrong token decimals");
        address oracle = vm.envAddress("BOOTSTRAP_ORACLE");
        require(oracle != address(0), "oracle required");
        vm.startBroadcast();
        DecentralizedMicrocredit pool = new DecentralizedMicrocredit(433, 500, 100e6, CIRCLE_BASE_SEPOLIA_USDC, oracle);
        pool.setReserveBps(4500);
        MicrocreditLens lens = new MicrocreditLens(pool);
        BootstrapOrderRouter router = new BootstrapOrderRouter(pool);
        // The credit officer: its own key, set by the router's admin (the deployer). With no OFFICER the router has no
        // officer and nothing can originate (fail closed); the admin sets one later with setOfficer.
        address officer = vm.envOr("OFFICER", address(0));
        if (officer != address(0)) router.setOfficer(officer, 1);
        vm.stopBroadcast();
        console.log("candidate pool", address(pool));
        console.log("candidate lens", address(lens));
        console.log("candidate bootstrap order router", address(router));
        console.log("credit officer (zero: none, nothing originates)", officer);
        // No scores or overrides: the bootstrap uses the roots' stake through the router only.
        // No token mints, original-pool calls, funding or relayed signatures in this script.
    }
}
