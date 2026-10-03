// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { ICreditUsage, OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";

/**
 * @notice Deploys MockUSDC (unless deployment-config.json points at a live one) and
 *         DecentralizedMicrocredit, then seeds the local demo state.
 * @dev Run with `yarn deploy`. Uses Anvil's deterministic accounts:
 *        9 Alexis: deployer, owner, oracle and score reporter (the local stand-in for the
 *          Chainlink CRE forwarder)
 *        2 Avery: backer, with 92 USDC of granted credit to back others with
 *        3 Brighton: borrower, with a 25 USDC line of his own (from history or an institution)
 *        4 Diana, 5 Eve: background borrowers that bring pool utilisation to 89%
 */
contract DeployScript is Script {
    uint256 internal constant ALEXIS_PK = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
    uint256 internal constant AVERY_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant BRIGHTON_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant DIANA_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant EVE_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    uint256 internal constant EFFR_BPS = 433; // 4.33%
    uint256 internal constant RISK_PREMIUM_BPS = 500; // 5.00%
    uint256 internal constant MAX_LOAN = 100e6; // 100 USDC at a 100% credit score
    uint256 internal constant POOL_SEED = 10_000e6;
    uint256 internal constant MAX_SCORE_AGE = 7 days;
    // Oracle issuance budget: at most 50 full lines (5,000 USDC at maxLoan 100), half the seeded pool.
    uint256 internal constant ISSUANCE_BUDGET = 50e6;
    // Share of interest into the first-loss reserve: covers expected loss at 3% annual default
    // probability, the most the 500 bps premium prices (analysis/credit_risk). The calibration's
    // full recommendation, which also builds a 99% buffer over three years, is 5,500.
    uint256 internal constant RESERVE_BPS = 3_000;

    DecentralizedMicrocredit internal credit;

    function run() external {
        address alexis = vm.addr(ALEXIS_PK);
        vm.startBroadcast(ALEXIS_PK);

        address usdc = _resolveUsdc();
        credit = new DecentralizedMicrocredit(EFFR_BPS, RISK_PREMIUM_BPS, MAX_LOAN, usdc, alexis);
        console.log("DecentralizedMicrocredit deployed at:", address(credit));

        OracleScoreProvider scores = new OracleScoreProvider(alexis, alexis, MAX_SCORE_AGE, ISSUANCE_BUDGET);
        credit.setScoreProvider(scores);
        scores.setLending(ICreditUsage(address(credit)));
        console.log("OracleScoreProvider deployed at:", address(scores));
        credit.setReserveBps(RESERVE_BPS);

        // Seed the lending pool.
        MockUSDC(usdc).mint(alexis, POOL_SEED);
        MockUSDC(usdc).approve(address(credit), POOL_SEED);
        credit.depositFunds(POOL_SEED);
        console.log("Seeded lending pool with 10,000 USDC");

        // Diana + Eve bring utilisation to 89%: the most we can lend while leaving room for
        // a max-size (100 USDC) loan for Brighton under the 90% cap ($8,899 + $100 <= $9,000).
        // Lender APY ~ 8.3% (= 9.33% loan rate x 89% utilisation).
        credit.setMaxLoanAmount(POOL_SEED);
        _seedBorrower(DIANA_PK, 6_500e6);
        _seedBorrower(EVE_PK, 2_399e6);
        credit.setMaxLoanAmount(MAX_LOAN);
        console.log("Background borrowers: Diana $6,500 + Eve $2,399 = $8,899 lent (89%)");

        // Granted credit (score x 100 USDC). Only these accounts hold credit; everyone else can
        // borrow only what one of them backs them with.
        credit.setScoreOverride(alexis, 950_000); // 95 USDC
        credit.setScoreOverride(vm.addr(AVERY_PK), 920_000); // 92 USDC
        credit.setScoreOverride(vm.addr(BRIGHTON_PK), 250_000); // 25 USDC

        _setDisplayName(AVERY_PK, "Avery");
        _setDisplayName(BRIGHTON_PK, "Brighton");

        // Gas money for extra wallets used when demoing with a real browser wallet.
        address[3] memory demoWallets = [
            0x455EB67473a5f8Da69dbFde7eDe1d1c008C31274,
            0xE51a60126dF85801D4C76bDAf58D6F9E81Cc26cA,
            0xC9E2518013169a09dfE47Da38b8DA092AB68d66A
        ];
        for (uint256 i = 0; i < demoWallets.length; i++) {
            _sendEth(demoWallets[i], 10 ether);
        }

        vm.stopBroadcast();

        vm.serializeAddress("deploy", "DecentralizedMicrocredit", address(credit));
        vm.writeJson(vm.serializeAddress("deploy", "USDC", usdc), "deployment.json");
    }

    /// @dev Gives `pk` a 100% score and an open, disbursed loan of `amount`.
    function _seedBorrower(uint256 pk, uint256 amount) internal {
        address borrower = vm.addr(pk);
        credit.setScoreOverride(borrower, 1_000_000);
        _sendEth(borrower, 1 ether);

        vm.stopBroadcast();
        vm.broadcast(pk);
        uint256 loanId = credit.requestLoan(amount);
        vm.startBroadcast(ALEXIS_PK);

        credit.disburseLoan(loanId);
    }

    function _setDisplayName(uint256 pk, string memory name) internal {
        vm.stopBroadcast();
        vm.broadcast(pk);
        credit.setDisplayName(name);
        vm.startBroadcast(ALEXIS_PK);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool sent,) = payable(to).call{ value: amount }("");
        require(sent, "ETH transfer failed");
    }

    /// @dev Reuses the USDC recorded in deployment-config.json when it still has code on this
    ///      chain (e.g. a reloaded Anvil state); otherwise deploys a fresh MockUSDC and records it.
    function _resolveUsdc() internal returns (address usdc) {
        string memory configPath = string.concat(vm.projectRoot(), "/deployment-config.json");
        if (vm.isFile(configPath)) {
            string memory config = vm.readFile(configPath);
            if (vm.keyExistsJson(config, ".usdcAddress")) {
                usdc = vm.parseJsonAddress(config, ".usdcAddress");
            }
        }
        if (usdc != address(0) && usdc.code.length > 0) {
            console.log("Reusing USDC from deployment config:", usdc);
            return usdc;
        }

        usdc = address(new MockUSDC());
        console.log("MockUSDC deployed at:", usdc);
        vm.writeJson(vm.serializeAddress("config", "usdcAddress", usdc), configPath);
    }

    function test() public { }
}
