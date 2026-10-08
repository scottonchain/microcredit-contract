// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/Script.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditLens } from "../contracts/MicrocreditLens.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { ICreditUsage, OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";

/**
 * @notice Testnet deployment for persona testing (e.g. Base Sepolia). The broadcasting account
 *         becomes owner, oracle, score reporter and guardian, so a tester can grant lines (score
 *         overrides or published scores), set parameters and pause without a timelock. Nothing
 *         is seeded. Refuses to run on any chain but Base Sepolia, Ethereum Sepolia or Anvil.
 * @dev Production uses DeployProduction.s.sol instead (timelock, multisig, no reporter).
 *        forge script script/DeployTestnet.s.sol --rpc-url <testnet> --broadcast --non-interactive \
 *          --account <keystore> --sender <you>
 *      (--non-interactive skips forge's prompt for contracts near the size limit, which otherwise
 *      fails without a terminal; sign with a keystore from `cast wallet import`.)
 *      Then script/TestnetScenarios.s.sol runs the persona scenarios against the deployment.
 *
 *      Environment (all optional; numbers are plain integers, `25e6` is accepted):
 *        USDC_ADDRESS           a test USDC (6 decimals); unset deploys a free-mint MockUSDC
 *        EFFR_BPS               default 433
 *        RISK_PREMIUM_BPS       default 500
 *        MAX_LOAN               USDC (6 decimals) per full line, default 25e6
 *        RESERVE_BPS            default 3000
 *        ISSUANCE_BUDGET_LINES  default 50, so maxTotalScore = 50e6
 *        MAX_SCORE_AGE          seconds, default 7 days
 */
contract DeployTestnetScript is Script {
    uint256 internal constant SCORE_SCALE = 1e6;
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant ANVIL = 31_337;

    struct Deployment {
        address deployer;
        address usdc;
        DecentralizedMicrocredit credit;
        MicrocreditLens lens;
        OracleScoreProvider scores;
    }

    function run() external returns (Deployment memory d) {
        require(
            block.chainid == BASE_SEPOLIA || block.chainid == SEPOLIA || block.chainid == ANVIL,
            "DeployTestnet: testnets only (Base Sepolia, Sepolia, Anvil)"
        );
        uint256 lines = _envUint("ISSUANCE_BUDGET_LINES", 50);

        vm.startBroadcast();
        (, d.deployer,) = vm.readCallers();
        d.usdc = _envAddress("USDC_ADDRESS");
        if (d.usdc == address(0)) {
            // The public Base Sepolia demo runs on Circle's USDC (0x036CbD53842c5426634e7929541eC2318f3dCF7e); a
            // free-mint token there is a mistake unless asked for explicitly.
            require(
                block.chainid != BASE_SEPOLIA || _isSet("ALLOW_MOCK_USDC"),
                "DeployTestnet: set USDC_ADDRESS on Base Sepolia (or ALLOW_MOCK_USDC=1 for a private mock deployment)"
            );
            d.usdc = address(new MockUSDC());
        }
        d.credit = new DecentralizedMicrocredit(
            _envUint("EFFR_BPS", 433),
            _envUint("RISK_PREMIUM_BPS", 500),
            _envUint("MAX_LOAN", 25e6),
            d.usdc,
            d.deployer,
            address(0)
        );
        d.lens = new MicrocreditLens(d.credit);
        d.scores =
            new OracleScoreProvider(d.deployer, d.deployer, _envUint("MAX_SCORE_AGE", 7 days), lines * SCORE_SCALE);
        d.scores.setLending(ICreditUsage(address(d.credit)));
        d.credit.setScoreProvider(d.scores);
        d.credit.setReserveBps(_envUint("RESERVE_BPS", 3000));
        d.credit.setGuardian(d.deployer);
        vm.stopBroadcast();

        console.log("Chain id:", block.chainid);
        console.log("USDC:", d.usdc);
        console.log("DecentralizedMicrocredit:", address(d.credit));
        console.log("MicrocreditLens:", address(d.lens));
        console.log("OracleScoreProvider:", address(d.scores));
        console.log("Owner, oracle, reporter and guardian:", d.deployer);
    }

    function _isSet(string memory name) internal view returns (bool) {
        return bytes(vm.envOr(name, string(""))).length > 0;
    }

    /// @dev Unlike vm.envOr, a malformed value reverts instead of silently using the default.
    function _envUint(string memory name, uint256 defaultValue) internal view returns (uint256) {
        return _isSet(name) ? vm.envUint(name) : defaultValue;
    }

    function _envAddress(string memory name) internal view returns (address) {
        return _isSet(name) ? vm.envAddress(name) : address(0);
    }
}
