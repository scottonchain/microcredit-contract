// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditLens } from "../contracts/MicrocreditLens.sol";
import { ICreditUsage, OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";

/**
 * @notice Production deployment: a TimelockController governed by the ADMIN multisig, the lending
 *         pool and its score provider, configured from environment variables and handed over to
 *         the timelock. See docs/DEPLOYMENT.md. Nothing is seeded: no deposits, loans, scores or
 *         score overrides.
 * @dev Do not run with --broadcast before the approvals in docs/DEPLOYMENT.md. A dry run is
 *      `forge script script/DeployProduction.s.sol --rpc-url <url> --sender <deployer>`.
 *
 *      The deployer stays owner of both contracts until the timelock accepts ownership. That
 *      takes one timelock delay after ADMIN schedules the two operations this script prints. In
 *      that window the deployer key can still call owner functions, so it must stay offline and
 *      the pool must not be announced or funded until both acceptances are verified on-chain.
 *
 *      Environment (an empty value counts as unset; numbers are plain integers, `25e6` is accepted):
 *        USDC_ADDRESS                  required, Circle USDC on the target chain (6 decimals)
 *        ADMIN                         required, the multisig that proposes and executes on the timelock
 *        EFFR_BPS                      required, current Effective Federal Funds Rate in bps
 *        TIMELOCK_DELAY                seconds, default 2 days, 1 to 30 days
 *        RISK_PREMIUM_BPS              default 800 (analysis/credit_risk, annual PD 5%)
 *        MAX_LOAN                      USDC, 6 decimals, default 25e6 (a pilot line)
 *        RESERVE_BPS                   default 4500, interim (owner decision; docs/ECONOMICS.md, "The reserve share")
 *        PROTOCOL_FEE_BPS              default 0
 *        ISSUANCE_BUDGET_LINES         default 20, so maxTotalScore = 20e6
 *        MAX_INCREASE_PER_REPORT_LINES default 5
 *        MAX_SCORE_AGE                 seconds, default 7 days
 *        CRE_FORWARDER                 optional; if unset nothing can publish scores until governance sets one
 *        CRE_WORKFLOW_OWNER            required with CRE_FORWARDER
 *        CRE_WORKFLOW_ID               required with CRE_FORWARDER (bytes32)
 *        RELAYER                       optional; if set, the relayer whitelist is enabled with it alone
 */
contract DeployProductionScript is Script {
    struct Config {
        address usdc;
        address admin;
        uint256 timelockDelay;
        uint256 effrBps;
        uint256 riskPremiumBps;
        uint256 maxLoan;
        uint256 reserveBps;
        uint256 protocolFeeBps;
        uint256 issuanceBudgetLines;
        uint256 maxIncreasePerReportLines;
        uint256 maxScoreAge;
        address creForwarder;
        address creWorkflowOwner;
        bytes32 creWorkflowId;
        address relayer;
    }

    /// @dev The two `schedule` / `execute` payloads are the exact calldata ADMIN sends to the timelock.
    struct Deployment {
        address deployer;
        TimelockController timelock;
        DecentralizedMicrocredit credit;
        MicrocreditLens lens;
        OracleScoreProvider scores;
        bytes scheduleAcceptCredit;
        bytes executeAcceptCredit;
        bytes scheduleAcceptScores;
        bytes executeAcceptScores;
    }

    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint256 public constant MIN_TIMELOCK_DELAY = 1 days;
    uint256 public constant MAX_TIMELOCK_DELAY = 30 days;
    uint256 public constant DEFAULT_RISK_PREMIUM_BPS = 800;
    uint256 public constant DEFAULT_MAX_LOAN = 25e6;
    uint256 public constant DEFAULT_RESERVE_BPS = 4_500;
    uint256 public constant DEFAULT_PROTOCOL_FEE_BPS = 0;
    uint256 public constant DEFAULT_ISSUANCE_BUDGET_LINES = 20;
    uint256 public constant DEFAULT_MAX_INCREASE_PER_REPORT_LINES = 5;
    uint256 public constant DEFAULT_MAX_SCORE_AGE = 7 days;

    // Sanity bounds that catch unit mistakes (percent for bps, whole USDC for 6 decimals).
    uint256 public constant MAX_EFFR_BPS = 2_000;
    uint256 public constant MAX_RISK_PREMIUM_BPS = 5_000;
    uint256 public constant MIN_MAX_LOAN = 1e6; // 1 USDC
    uint256 public constant MAX_MAX_LOAN = 10_000e6; // 10,000 USDC

    uint256 internal constant SCORE_SCALE = 1e6; // OracleScoreProvider.SCALE: one full line

    bytes32 public constant ACCEPT_SALT = bytes32(0);
    bytes32 public constant ACCEPT_PREDECESSOR = bytes32(0);
    string public constant OUTPUT_FILE = "deployment.production.json";

    function run() external returns (Deployment memory) {
        return deploy(readConfig());
    }

    /// @notice The configuration the environment describes, with defaults filled in.
    function readConfig() public view returns (Config memory cfg) {
        cfg.usdc = _envAddress("USDC_ADDRESS");
        cfg.admin = _envAddress("ADMIN");
        cfg.timelockDelay = _envUint("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);
        require(_isSet("EFFR_BPS"), "DeployProduction: EFFR_BPS is required (current EFFR in bps)");
        cfg.effrBps = vm.envUint("EFFR_BPS");
        cfg.riskPremiumBps = _envUint("RISK_PREMIUM_BPS", DEFAULT_RISK_PREMIUM_BPS);
        cfg.maxLoan = _envUint("MAX_LOAN", DEFAULT_MAX_LOAN);
        cfg.reserveBps = _envUint("RESERVE_BPS", DEFAULT_RESERVE_BPS);
        cfg.protocolFeeBps = _envUint("PROTOCOL_FEE_BPS", DEFAULT_PROTOCOL_FEE_BPS);
        cfg.issuanceBudgetLines = _envUint("ISSUANCE_BUDGET_LINES", DEFAULT_ISSUANCE_BUDGET_LINES);
        cfg.maxIncreasePerReportLines = _envUint("MAX_INCREASE_PER_REPORT_LINES", DEFAULT_MAX_INCREASE_PER_REPORT_LINES);
        cfg.maxScoreAge = _envUint("MAX_SCORE_AGE", DEFAULT_MAX_SCORE_AGE);
        cfg.creForwarder = _envAddress("CRE_FORWARDER");
        cfg.creWorkflowOwner = _envAddress("CRE_WORKFLOW_OWNER");
        cfg.creWorkflowId = _isSet("CRE_WORKFLOW_ID") ? vm.envBytes32("CRE_WORKFLOW_ID") : bytes32(0);
        cfg.relayer = _envAddress("RELAYER");
    }

    /// @notice Validate `cfg`, deploy, configure and start the handover to the timelock.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        validate(cfg);
        d.deployer = _broadcaster();
        require(cfg.admin != d.deployer, "DeployProduction: ADMIN must not be the deployer");
        require(cfg.relayer != d.deployer, "DeployProduction: RELAYER must not be the deployer");

        vm.startBroadcast(d.deployer);

        address[] memory governors = new address[](1);
        governors[0] = cfg.admin;
        // admin = 0: the timelock administers itself, so role changes also wait out the delay.
        d.timelock = new TimelockController(cfg.timelockDelay, governors, governors, address(0));

        // The constructor makes the deployer owner; ADMIN gets the oracle role (markKYCVerified).
        d.credit = new DecentralizedMicrocredit(cfg.effrBps, cfg.riskPremiumBps, cfg.maxLoan, cfg.usdc, cfg.admin);
        d.lens = new MicrocreditLens(d.credit);
        // No reporter: scores arrive only through a pinned CRE workflow, once one is configured.
        d.scores =
            new OracleScoreProvider(d.deployer, address(0), cfg.maxScoreAge, cfg.issuanceBudgetLines * SCORE_SCALE);
        d.scores.setIssuanceLimits(cfg.issuanceBudgetLines * SCORE_SCALE, cfg.maxIncreasePerReportLines * SCORE_SCALE);
        d.scores.setLending(ICreditUsage(address(d.credit)));
        if (cfg.creForwarder != address(0)) {
            d.scores.setForwarder(cfg.creForwarder, cfg.creWorkflowOwner, cfg.creWorkflowId);
        }

        d.credit.setScoreProvider(d.scores);
        // The multisig can pause new lending at once; unpausing goes through the timelock.
        d.credit.setGuardian(cfg.admin);
        d.credit.setReserveBps(cfg.reserveBps);
        d.credit.setProtocolFeeBps(cfg.protocolFeeBps);
        if (cfg.relayer != address(0)) {
            d.credit.setRelayerWhitelisted(cfg.relayer, true);
            d.credit.setRelayerWhitelistEnabled(true);
        }

        d.credit.transferOwnership(address(d.timelock));
        d.scores.transferOwnership(address(d.timelock));

        vm.stopBroadcast();

        _buildAcceptCalls(d, cfg.timelockDelay);
        checkDeployment(d, cfg);
        _report(d, cfg);
        _writeOutput(d, cfg);
    }

    /// @notice Reverts with a clear message on any configuration the protocol should not launch with.
    function validate(Config memory cfg) public view {
        require(cfg.usdc != address(0), "DeployProduction: USDC_ADDRESS is required");
        require(cfg.usdc.code.length > 0, "DeployProduction: USDC_ADDRESS has no code on this chain");
        (bool ok, bytes memory ret) = cfg.usdc.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        require(ok && ret.length == 32, "DeployProduction: USDC_ADDRESS does not implement decimals()");
        require(abi.decode(ret, (uint256)) == 6, "DeployProduction: USDC_ADDRESS must have 6 decimals");

        require(cfg.admin != address(0), "DeployProduction: ADMIN is required");
        require(cfg.admin.code.length > 0, "DeployProduction: ADMIN has no code; it must be the multisig contract");

        require(cfg.timelockDelay >= MIN_TIMELOCK_DELAY, "DeployProduction: TIMELOCK_DELAY must be at least 1 day");
        require(cfg.timelockDelay <= MAX_TIMELOCK_DELAY, "DeployProduction: TIMELOCK_DELAY must be at most 30 days");

        require(cfg.effrBps <= MAX_EFFR_BPS, "DeployProduction: EFFR_BPS above 2000; it is in bps (4.33% = 433)");
        require(
            cfg.riskPremiumBps <= MAX_RISK_PREMIUM_BPS,
            "DeployProduction: RISK_PREMIUM_BPS above 5000; it is in bps (8% = 800)"
        );
        require(
            cfg.maxLoan >= MIN_MAX_LOAN && cfg.maxLoan <= MAX_MAX_LOAN,
            "DeployProduction: MAX_LOAN must be 1 to 10,000 USDC in 6 decimals (25 USDC = 25000000)"
        );
        require(cfg.reserveBps <= 8_000, "DeployProduction: RESERVE_BPS must be at most 8000");
        require(cfg.protocolFeeBps <= 2_000, "DeployProduction: PROTOCOL_FEE_BPS must be at most 2000");

        require(cfg.issuanceBudgetLines > 0, "DeployProduction: ISSUANCE_BUDGET_LINES must be positive");
        require(
            cfg.issuanceBudgetLines <= 1_000_000,
            "DeployProduction: ISSUANCE_BUDGET_LINES is in full lines, not 1e6 units"
        );
        require(cfg.maxIncreasePerReportLines > 0, "DeployProduction: MAX_INCREASE_PER_REPORT_LINES must be positive");
        require(
            cfg.maxIncreasePerReportLines <= cfg.issuanceBudgetLines,
            "DeployProduction: MAX_INCREASE_PER_REPORT_LINES exceeds ISSUANCE_BUDGET_LINES"
        );
        require(
            cfg.maxScoreAge >= 1 hours && cfg.maxScoreAge <= 30 days,
            "DeployProduction: MAX_SCORE_AGE must be 1 hour to 30 days"
        );

        if (cfg.creForwarder == address(0)) {
            require(
                cfg.creWorkflowOwner == address(0) && cfg.creWorkflowId == bytes32(0),
                "DeployProduction: CRE_WORKFLOW_OWNER / CRE_WORKFLOW_ID set without CRE_FORWARDER"
            );
        } else {
            require(cfg.creForwarder.code.length > 0, "DeployProduction: CRE_FORWARDER has no code on this chain");
            // The forwarder is shared by every CRE workflow; unpinned, any of them could publish scores.
            require(
                cfg.creWorkflowOwner != address(0) && cfg.creWorkflowId != bytes32(0),
                "DeployProduction: CRE_FORWARDER needs CRE_WORKFLOW_OWNER and CRE_WORKFLOW_ID"
            );
        }
    }

    /// @notice Asserts the deployed state: configuration landed, the handover to the timelock is
    ///         pending, and the deployer holds nothing beyond owning both contracts until then.
    function checkDeployment(Deployment memory d, Config memory cfg) public view {
        DecentralizedMicrocredit credit = d.credit;
        OracleScoreProvider scores = d.scores;
        TimelockController timelock = d.timelock;
        require(scores.SCALE() == SCORE_SCALE, "check: score scale");
        require(address(d.lens.credit()) == address(credit), "check: lens");

        require(address(credit.usdc()) == cfg.usdc, "check: usdc");
        require(credit.effrRate() == cfg.effrBps, "check: effrRate");
        require(credit.riskPremium() == cfg.riskPremiumBps, "check: riskPremium");
        require(credit.maxLoanAmount() == cfg.maxLoan, "check: maxLoanAmount");
        require(credit.reserveBps() == cfg.reserveBps, "check: reserveBps");
        require(credit.protocolFeeBps() == cfg.protocolFeeBps, "check: protocolFeeBps");
        require(address(credit.scoreProvider()) == address(scores), "check: scoreProvider");
        require(credit.guardian() == cfg.admin, "check: guardian");
        require(!credit.paused(), "check: paused");
        require(credit.oracle() == cfg.admin, "check: oracle must be ADMIN");
        require(credit.relayerWhitelistEnabled() == (cfg.relayer != address(0)), "check: relayer whitelist");
        if (cfg.relayer != address(0)) require(credit.relayerWhitelist(cfg.relayer), "check: relayer");
        require(credit.totalAssets() == 0 && credit.totalShares() == 0, "check: pool must be empty");

        require(scores.maxTotalScore() == cfg.issuanceBudgetLines * SCORE_SCALE, "check: maxTotalScore");
        require(
            scores.maxIncreasePerReport() == cfg.maxIncreasePerReportLines * SCORE_SCALE, "check: maxIncreasePerReport"
        );
        require(scores.maxScoreAge() == cfg.maxScoreAge, "check: maxScoreAge");
        require(address(scores.lending()) == address(credit), "check: lending");
        require(scores.forwarder() == cfg.creForwarder, "check: forwarder");
        require(scores.expectedWorkflowOwner() == cfg.creWorkflowOwner, "check: workflow owner");
        require(scores.expectedWorkflowId() == cfg.creWorkflowId, "check: workflow id");
        require(scores.reporter() == address(0), "check: no reporter");
        require(
            scores.totalScore() == 0 && scores.totalHeld() == 0 && scores.epoch() == 0, "check: no scores published"
        );

        require(timelock.getMinDelay() == cfg.timelockDelay, "check: timelock delay");
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "check: timelock self-admin");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.admin), "check: ADMIN proposer");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), cfg.admin), "check: ADMIN executor");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.admin), "check: ADMIN canceller");
        require(!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "check: execution must not be open");

        // The handover is pending; the deployer owns both until the timelock accepts.
        require(credit.owner() == d.deployer && credit.pendingOwner() == address(timelock), "check: credit handover");
        require(scores.owner() == d.deployer && scores.pendingOwner() == address(timelock), "check: scores handover");

        // Beyond that, the deployer holds no role anywhere.
        address deployer = d.deployer;
        require(credit.oracle() != deployer, "check: deployer is oracle");
        require(!credit.relayerWhitelist(deployer), "check: deployer is relayer");
        require(scores.forwarder() != deployer && scores.reporter() != deployer, "check: deployer can publish");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "check: deployer timelock admin");
        require(!timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "check: deployer proposer");
        require(!timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer), "check: deployer executor");
        require(!timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), "check: deployer canceller");
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev The account this run broadcasts from (--sender, --account, --ledger or --private-key).
    function _broadcaster() internal returns (address who) {
        vm.startBroadcast();
        (, who,) = vm.readCallers();
        vm.stopBroadcast();
    }

    function _buildAcceptCalls(Deployment memory d, uint256 delay) internal pure {
        d.scheduleAcceptCredit = _scheduleAccept(address(d.credit), delay);
        d.executeAcceptCredit = _executeAccept(address(d.credit));
        d.scheduleAcceptScores = _scheduleAccept(address(d.scores), delay);
        d.executeAcceptScores = _executeAccept(address(d.scores));
    }

    function _scheduleAccept(address target, uint256 delay) internal pure returns (bytes memory) {
        return
            abi.encodeCall(TimelockController.schedule, (target, 0, _accept(), ACCEPT_PREDECESSOR, ACCEPT_SALT, delay));
    }

    function _executeAccept(address target) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.execute, (target, 0, _accept(), ACCEPT_PREDECESSOR, ACCEPT_SALT));
    }

    function _accept() internal pure returns (bytes memory) {
        return abi.encodeCall(DecentralizedMicrocredit.acceptOwnership, ());
    }

    function _report(Deployment memory d, Config memory cfg) internal view {
        console.log("");
        console.log("== DeployProduction: chain id", block.chainid);
        console.log("Deployer (temporary owner):", d.deployer);
        console.log("ADMIN multisig:            ", cfg.admin);
        console.log("USDC:                      ", cfg.usdc);
        console.log("  name / symbol:          ", IERC20Metadata(cfg.usdc).name(), IERC20Metadata(cfg.usdc).symbol());
        console.log("TimelockController:        ", address(d.timelock));
        console.log("  minDelay (s):            ", cfg.timelockDelay);
        console.log("DecentralizedMicrocredit:  ", address(d.credit));
        console.log("MicrocreditLens:           ", address(d.lens));
        console.log("OracleScoreProvider:       ", address(d.scores));
        console.log("");
        console.log("effrRate / riskPremium (bps):", cfg.effrBps, cfg.riskPremiumBps);
        console.log("maxLoanAmount (USDC, 6 dec): ", cfg.maxLoan);
        console.log("reserveBps / protocolFeeBps: ", cfg.reserveBps, cfg.protocolFeeBps);
        console.log(
            "issuance budget / per report (full lines):", cfg.issuanceBudgetLines, cfg.maxIncreasePerReportLines
        );
        console.log(
            "  most oracle-issued credit lent at once (whole USDC):", cfg.issuanceBudgetLines * cfg.maxLoan / 1e6
        );
        console.log("maxScoreAge (s):             ", cfg.maxScoreAge);
        if (cfg.creForwarder == address(0)) {
            console.log("CRE forwarder: none. Nothing can publish scores until governance calls setForwarder.");
        } else {
            console.log("CRE forwarder:               ", cfg.creForwarder);
            console.log("  workflow owner:            ", cfg.creWorkflowOwner);
            console.log("  workflow id:               ", vm.toString(cfg.creWorkflowId));
        }
        if (cfg.relayer == address(0)) {
            console.log("Relayer whitelist: disabled (any relayer may submit signed meta-transactions)");
        } else {
            console.log("Relayer whitelist: enabled with", cfg.relayer);
        }

        console.log("");
        console.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        console.log("!! OWNERSHIP WINDOW: the deployer is still OWNER of both contracts.");
        console.log("!! The timelock is pendingOwner and takes over only when ADMIN executes the two");
        console.log("!! operations below, at least TIMELOCK_DELAY after scheduling them. Until then:");
        console.log("!!   keep the deployer key offline, do not deposit, do not announce the pool.");
        console.log("!! Verify afterwards: owner() == timelock and pendingOwner() == 0 on both.");
        console.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        console.log("");
        console.log("ADMIN sends these to the timelock (value 0), the two schedule calls first:", address(d.timelock));
        _reportOperation("1. DecentralizedMicrocredit.acceptOwnership()", d.timelock, address(d.credit), d);
        _reportOperation("2. OracleScoreProvider.acceptOwnership()", d.timelock, address(d.scores), d);
    }

    function _reportOperation(string memory label, TimelockController timelock, address target, Deployment memory d)
        internal
        view
    {
        bool isCredit = target == address(d.credit);
        console.log(label);
        console.log("   target:      ", target);
        console.log("   data:        ", vm.toString(_accept()));
        console.log("   predecessor: ", vm.toString(ACCEPT_PREDECESSOR));
        console.log("   salt:        ", vm.toString(ACCEPT_SALT));
        console.log(
            "   operation id:",
            vm.toString(timelock.hashOperation(target, 0, _accept(), ACCEPT_PREDECESSOR, ACCEPT_SALT))
        );
        console.log("   schedule calldata:", vm.toString(isCredit ? d.scheduleAcceptCredit : d.scheduleAcceptScores));
        console.log("   execute calldata: ", vm.toString(isCredit ? d.executeAcceptCredit : d.executeAcceptScores));
    }

    /// @dev Written only by `forge script --broadcast` (or --resume), never by a dry run or a test.
    function _writeOutput(Deployment memory d, Config memory cfg) internal {
        string memory key = "production";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", d.deployer);
        vm.serializeAddress(key, "admin", cfg.admin);
        vm.serializeAddress(key, "USDC", cfg.usdc);
        vm.serializeAddress(key, "TimelockController", address(d.timelock));
        vm.serializeAddress(key, "DecentralizedMicrocredit", address(d.credit));
        vm.serializeAddress(key, "MicrocreditLens", address(d.lens));
        vm.serializeAddress(key, "OracleScoreProvider", address(d.scores));
        vm.serializeUint(key, "timelockDelay", cfg.timelockDelay);
        vm.serializeUint(key, "effrBps", cfg.effrBps);
        vm.serializeUint(key, "riskPremiumBps", cfg.riskPremiumBps);
        vm.serializeUint(key, "maxLoan", cfg.maxLoan);
        vm.serializeUint(key, "reserveBps", cfg.reserveBps);
        vm.serializeUint(key, "protocolFeeBps", cfg.protocolFeeBps);
        vm.serializeUint(key, "maxTotalScore", cfg.issuanceBudgetLines * SCORE_SCALE);
        vm.serializeUint(key, "maxIncreasePerReport", cfg.maxIncreasePerReportLines * SCORE_SCALE);
        vm.serializeUint(key, "maxScoreAge", cfg.maxScoreAge);
        vm.serializeAddress(key, "creForwarder", cfg.creForwarder);
        vm.serializeAddress(key, "creWorkflowOwner", cfg.creWorkflowOwner);
        vm.serializeBytes32(key, "creWorkflowId", cfg.creWorkflowId);
        vm.serializeAddress(key, "relayer", cfg.relayer);
        vm.serializeBytes(key, "scheduleAcceptCredit", d.scheduleAcceptCredit);
        vm.serializeBytes(key, "executeAcceptCredit", d.executeAcceptCredit);
        vm.serializeBytes(key, "scheduleAcceptScores", d.scheduleAcceptScores);
        string memory json = vm.serializeBytes(key, "executeAcceptScores", d.executeAcceptScores);

        string memory path = string.concat(vm.projectRoot(), "/", OUTPUT_FILE);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            vm.writeJson(json, path);
            console.log("");
            console.log("Wrote", path);
        } else {
            console.log("");
            console.log("Not broadcasting, so not writing", path);
        }
    }

    /// @dev Unset or empty reads as false, so a test can clear a variable with vm.setEnv(name, "").
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
