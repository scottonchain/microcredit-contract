// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { DeployProductionScript } from "../script/DeployProduction.s.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";

/// @dev An ERC20 with OpenZeppelin's default 18 decimals: the wrong token for USDC_ADDRESS.
contract EighteenDecimalToken is ERC20 {
    constructor() ERC20("Not USDC", "FAKE") { }
}

/**
 * @dev Runs script/DeployProduction.s.sol in-process. Nothing is broadcast and no file is written
 *      (the script writes deployment.production.json only under `forge script --broadcast`).
 *
 *      Environment variables are process-wide and forge runs test functions in parallel, so every
 *      case that sets them lives in {test_RunFromEnvironment}. The other tests pass a Config to
 *      {DeployProductionScript.deploy} directly and never touch the environment.
 */
contract DeployProductionTest is Test {
    DeployProductionScript internal script;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin multisig");
    address internal forwarder = makeAddr("CRE forwarder");
    address internal workflowOwner = makeAddr("CRE workflow owner");
    address internal relayer = makeAddr("relayer");
    bytes32 internal constant WORKFLOW_ID = keccak256("credit-line-workflow");

    string[15] internal envVars = [
        "USDC_ADDRESS",
        "ADMIN",
        "TIMELOCK_DELAY",
        "EFFR_BPS",
        "RISK_PREMIUM_BPS",
        "MAX_LOAN",
        "RESERVE_BPS",
        "PROTOCOL_FEE_BPS",
        "ISSUANCE_BUDGET_LINES",
        "MAX_INCREASE_PER_REPORT_LINES",
        "MAX_SCORE_AGE",
        "CRE_FORWARDER",
        "CRE_WORKFLOW_OWNER",
        "CRE_WORKFLOW_ID",
        "RELAYER"
    ];

    function setUp() public {
        script = new DeployProductionScript();
        usdc = new MockUSDC();
        // The script requires code at ADMIN (a multisig) and at the CRE forwarder.
        vm.etch(admin, hex"00");
        vm.etch(forwarder, hex"00");
    }

    // ───────────────────────────── run() from the environment ─────────────────────────────

    function test_RunFromEnvironment() public {
        string memory output = string.concat(vm.projectRoot(), "/", script.OUTPUT_FILE());
        bool outputExisted = vm.isFile(output);
        _clearEnv();

        // Required variables, and the token check.
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("EFFR_BPS", "433");
        vm.expectRevert(bytes("DeployProduction: USDC_ADDRESS is required"));
        script.run();

        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("ADMIN", "");
        vm.expectRevert(bytes("DeployProduction: ADMIN is required"));
        script.run();

        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("USDC_ADDRESS", vm.toString(address(new EighteenDecimalToken())));
        vm.expectRevert(bytes("DeployProduction: USDC_ADDRESS must have 6 decimals"));
        script.run();
        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));

        vm.setEnv("EFFR_BPS", "");
        vm.expectRevert(bytes("DeployProduction: EFFR_BPS is required (current EFFR in bps)"));
        script.run();
        vm.setEnv("EFFR_BPS", "433");

        // A malformed number reverts instead of silently falling back to the default.
        vm.setEnv("RISK_PREMIUM_BPS", "8OO");
        try script.run() {
            fail();
        } catch (bytes memory reason) {
            assertTrue(vm.contains(string(reason), "RISK_PREMIUM_BPS"));
        }
        vm.setEnv("RISK_PREMIUM_BPS", "");

        // Only the required variables: the calibrated defaults land, and nothing can publish scores.
        DeployProductionScript.Deployment memory d = script.run();
        _assertDefaultsLanded(d);

        // Every variable set.
        vm.setEnv("TIMELOCK_DELAY", "259200");
        vm.setEnv("RISK_PREMIUM_BPS", "1400");
        vm.setEnv("MAX_LOAN", "50e6");
        vm.setEnv("RESERVE_BPS", "7500");
        vm.setEnv("PROTOCOL_FEE_BPS", "500");
        vm.setEnv("ISSUANCE_BUDGET_LINES", "40");
        vm.setEnv("MAX_INCREASE_PER_REPORT_LINES", "10");
        vm.setEnv("MAX_SCORE_AGE", "86400");
        vm.setEnv("CRE_FORWARDER", vm.toString(forwarder));
        vm.setEnv("CRE_WORKFLOW_OWNER", vm.toString(workflowOwner));
        vm.setEnv("CRE_WORKFLOW_ID", vm.toString(WORKFLOW_ID));
        vm.setEnv("RELAYER", vm.toString(relayer));
        d = script.run();
        _clearEnv();

        DecentralizedMicrocredit credit = d.credit;
        OracleScoreProvider scores = d.scores;
        assertEq(d.timelock.getMinDelay(), 3 days);
        assertEq(credit.effrRate(), 433);
        assertEq(credit.riskPremium(), 1400);
        assertEq(credit.maxLoanAmount(), 50e6);
        assertEq(credit.reserveBps(), 7500);
        assertEq(credit.protocolFeeBps(), 500);
        assertEq(scores.maxTotalScore(), 40e6);
        assertEq(scores.maxIncreasePerReport(), 10e6);
        assertEq(scores.maxScoreAge(), 1 days);
        assertEq(scores.forwarder(), forwarder);
        assertEq(scores.expectedWorkflowOwner(), workflowOwner);
        assertEq(scores.expectedWorkflowId(), WORKFLOW_ID);
        assertEq(scores.reporter(), address(0));
        assertTrue(credit.relayerWhitelistEnabled());
        assertTrue(credit.relayerWhitelist(relayer));

        _acceptThroughTimelock(d, 3 days);

        if (!outputExisted) assertFalse(vm.isFile(output), "tests must not write deployment.production.json");
    }

    // ───────────────────────────── deploy(Config) ─────────────────────────────

    function test_HandoverNeedsTheTimelockAndLocksOutTheDeployer() public {
        DeployProductionScript.Deployment memory d = script.deploy(_config());
        _acceptThroughTimelock(d, 2 days);
    }

    function test_RejectsUnsafeConfig() public {
        DeployProductionScript.Config memory cfg = _config();
        cfg.usdc = makeAddr("no code");
        _expectInvalid(cfg, "DeployProduction: USDC_ADDRESS has no code on this chain");

        cfg = _config();
        cfg.admin = makeAddr("an EOA");
        _expectInvalid(cfg, "DeployProduction: ADMIN has no code; it must be the multisig contract");

        cfg = _config();
        cfg.timelockDelay = 1 days - 1;
        _expectInvalid(cfg, "DeployProduction: TIMELOCK_DELAY must be at least 1 day");

        cfg = _config();
        cfg.maxLoan = 25; // whole USDC instead of 6 decimals
        _expectInvalid(cfg, "DeployProduction: MAX_LOAN must be 1 to 10,000 USDC in 6 decimals (25 USDC = 25000000)");

        cfg = _config();
        cfg.maxIncreasePerReportLines = cfg.issuanceBudgetLines + 1;
        _expectInvalid(cfg, "DeployProduction: MAX_INCREASE_PER_REPORT_LINES exceeds ISSUANCE_BUDGET_LINES");

        // The CRE forwarder is shared by every workflow, so an unpinned one would accept anyone's reports.
        cfg = _config();
        cfg.creForwarder = forwarder;
        cfg.creWorkflowOwner = workflowOwner;
        _expectInvalid(cfg, "DeployProduction: CRE_FORWARDER needs CRE_WORKFLOW_OWNER and CRE_WORKFLOW_ID");

        cfg = _config();
        cfg.creWorkflowId = WORKFLOW_ID;
        _expectInvalid(cfg, "DeployProduction: CRE_WORKFLOW_OWNER / CRE_WORKFLOW_ID set without CRE_FORWARDER");

        // The deployer (tx.origin in a test) may hold no lasting role.
        cfg = _config();
        cfg.relayer = tx.origin;
        _expectInvalid(cfg, "DeployProduction: RELAYER must not be the deployer");

        cfg = _config();
        cfg.admin = tx.origin;
        vm.etch(tx.origin, hex"00");
        _expectInvalid(cfg, "DeployProduction: ADMIN must not be the deployer");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _assertDefaultsLanded(DeployProductionScript.Deployment memory d) internal {
        DecentralizedMicrocredit credit = d.credit;
        OracleScoreProvider scores = d.scores;

        assertEq(d.timelock.getMinDelay(), 2 days);
        assertEq(address(credit.usdc()), address(usdc));
        assertEq(credit.effrRate(), 433);
        assertEq(credit.riskPremium(), 800);
        assertEq(credit.maxLoanAmount(), 25e6);
        assertEq(credit.reserveBps(), 4500);
        assertEq(credit.protocolFeeBps(), 0);
        assertEq(credit.oracle(), admin);
        assertEq(address(credit.scoreProvider()), address(scores));
        assertFalse(credit.relayerWhitelistEnabled());
        assertEq(credit.totalAssets(), 0);

        assertEq(scores.maxTotalScore(), 20e6);
        assertEq(scores.maxIncreasePerReport(), 5e6);
        assertEq(scores.maxScoreAge(), 7 days);
        assertEq(address(scores.lending()), address(credit));
        assertEq(scores.totalScore(), 0);

        // No forwarder and no reporter: nothing can publish scores until governance configures it.
        assertEq(scores.forwarder(), address(0));
        assertEq(scores.reporter(), address(0));
        bytes memory report = abi.encode(uint64(1), new address[](0), new uint256[](0));
        vm.prank(d.deployer);
        vm.expectRevert(OracleScoreProvider.NotReporter.selector);
        scores.publishScores(report);
        vm.prank(admin);
        vm.expectRevert(OracleScoreProvider.NotForwarder.selector);
        scores.onReport("", report);
    }

    /// @dev The ownership window, then ADMIN accepting both contracts through the timelock with
    ///      the calldata the script printed, then the deployer locked out.
    function _acceptThroughTimelock(DeployProductionScript.Deployment memory d, uint256 delay) internal {
        DecentralizedMicrocredit credit = d.credit;
        OracleScoreProvider scores = d.scores;
        TimelockController timelock = d.timelock;
        address deployer = d.deployer;
        assertEq(deployer, tx.origin, "the script broadcasts from the forge sender");

        // The window: the deployer still owns both, the timelock is pending.
        assertEq(credit.owner(), deployer);
        assertEq(credit.pendingOwner(), address(timelock));
        assertEq(scores.owner(), deployer);
        assertEq(scores.pendingOwner(), address(timelock));

        // The deployer holds no timelock role, and ADMIN cannot accept around the timelock.
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        bytes memory accept = abi.encodeCall(DecentralizedMicrocredit.acceptOwnership, ());
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, proposerRole)
        );
        timelock.schedule(address(credit), 0, accept, bytes32(0), bytes32(0), delay);
        vm.prank(admin);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.acceptOwnership();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        scores.acceptOwnership();

        // The printed calldata is exactly schedule / execute of acceptOwnership(), salt and predecessor 0.
        assertEq(
            d.scheduleAcceptCredit,
            abi.encodeCall(TimelockController.schedule, (address(credit), 0, accept, bytes32(0), bytes32(0), delay))
        );
        assertEq(
            d.executeAcceptScores,
            abi.encodeCall(TimelockController.execute, (address(scores), 0, accept, bytes32(0), bytes32(0)))
        );

        vm.startPrank(admin);
        _send(address(timelock), d.scheduleAcceptCredit);
        _send(address(timelock), d.scheduleAcceptScores);

        // Not executable before the delay.
        vm.warp(block.timestamp + delay - 1);
        (bool ok,) = address(timelock).call(d.executeAcceptCredit);
        assertFalse(ok, "executed before the delay");

        vm.warp(block.timestamp + 1);
        _send(address(timelock), d.executeAcceptCredit);
        _send(address(timelock), d.executeAcceptScores);
        vm.stopPrank();

        assertEq(credit.owner(), address(timelock));
        assertEq(credit.pendingOwner(), address(0));
        assertEq(scores.owner(), address(timelock));
        assertEq(scores.pendingOwner(), address(0));

        // The deployer can no longer call owner functions.
        vm.startPrank(deployer);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.setMaxLoanAmount(1_000e6);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.setScoreOverride(deployer, 1e6);
        vm.expectRevert(DecentralizedMicrocredit.NotOwner.selector);
        credit.transferOwnership(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        scores.setReporter(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        scores.setIssuanceLimits(1_000e6, 1_000e6);
        vm.stopPrank();
    }

    function _config() internal view returns (DeployProductionScript.Config memory cfg) {
        cfg.usdc = address(usdc);
        cfg.admin = admin;
        cfg.timelockDelay = 2 days;
        cfg.effrBps = 433;
        cfg.riskPremiumBps = 800;
        cfg.maxLoan = 25e6;
        cfg.reserveBps = 4500;
        cfg.protocolFeeBps = 0;
        cfg.issuanceBudgetLines = 20;
        cfg.maxIncreasePerReportLines = 5;
        cfg.maxScoreAge = 7 days;
    }

    function _expectInvalid(DeployProductionScript.Config memory cfg, string memory message) internal {
        vm.expectRevert(bytes(message));
        script.deploy(cfg);
    }

    function _send(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _clearEnv() internal {
        for (uint256 i = 0; i < envVars.length; i++) {
            vm.setEnv(envVars[i], "");
        }
    }
}
