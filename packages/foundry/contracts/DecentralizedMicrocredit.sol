// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PageRank } from "./PageRank.sol";

/**
 * @title DecentralizedMicrocredit
 * @notice Single-pool, collateral-free USDC lending. Borrow limits come from a PageRank credit
 *         score over attestations; every user action also has an EIP-712 meta-transaction entry
 *         point so a relayer can pay gas.
 * @dev DEMO CONTRACT. PageRank is recomputed on-chain after every attestation; in production
 *      that work (and credit score updates) is meant to move to an off-chain oracle.
 */
contract DecentralizedMicrocredit is EIP712, PageRank {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants ─────────────────────────────

    uint256 public constant SCALE = 1e6; // credit scores and attestation weights (1e6 = 100%)
    uint256 public constant BASIS_POINTS = 10000; // interest rates and pool ratios (1e4 = 100%)
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant CENT = 10_000; // 0.01 USDC (6 decimals)
    uint256 private constant GRACE_PERIOD = 1 days; // no interest accrues during the first day
    uint256 private constant ATTESTER_REWARD_RATE = 50_000; // 5% of principal, in SCALE
    /// @notice Queued withdrawals paid at most per deposit, repayment or withdrawal, so a long
    ///         queue cannot push those calls past the block gas limit. {processWithdrawalQueue}
    ///         drains the rest.
    uint256 public constant QUEUE_FILLS_PER_CALL = 10;

    bytes32 private constant LOAN_REQUEST_TYPEHASH =
        keccak256("LoanRequest(address borrower,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 private constant DISBURSE_REQUEST_TYPEHASH =
        keccak256("DisburseRequest(address borrower,uint256 loanId,address to,uint256 nonce,uint256 deadline)");
    bytes32 private constant REPAY_REQUEST_TYPEHASH =
        keccak256("RepayRequest(address borrower,uint256 loanId,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 private constant BORROW_AND_DISBURSE_TYPEHASH = keccak256(
        "BorrowAndDisburse(address borrower,uint256 amount,address to,uint256 repaymentPeriod,uint256 maxAprBps,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant DEPOSIT_REQUEST_TYPEHASH =
        keccak256("DepositRequest(address lender,uint256 amount,address receiver,uint256 nonce,uint256 deadline)");
    bytes32 private constant REQUEST_WITHDRAWAL_TYPEHASH =
        keccak256("RequestWithdrawal(address lender,uint256 amount,address to,uint256 nonce,uint256 deadline)");
    bytes32 private constant ATTEST_REQUEST_TYPEHASH =
        keccak256("AttestRequest(address attester,address borrower,uint256 weight,uint256 nonce,uint256 deadline)");

    // ───────────────────────────── types ─────────────────────────────

    struct Loan {
        uint256 principal;
        uint256 repaid; // cumulative repayments
        address borrower;
        uint256 interestRate; // APR in BASIS_POINTS, fixed at origination
        bool isActive;
        bool disbursed;
        uint256 createdAt; // interest accrues from here
    }

    struct Attestation {
        address attester;
        uint256 weight; // 0..SCALE
    }

    struct WithdrawalQueueItem {
        address lender;
        address to;
        uint256 remaining; // USDC still owed to this request
        bool active;
    }

    // EIP-712 meta-transaction requests (field order must match the typehashes above).
    struct LoanRequest {
        address borrower;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct DisburseRequest {
        address borrower;
        uint256 loanId;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    struct RepayRequest {
        address borrower;
        uint256 loanId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct BorrowAndDisburse {
        address borrower;
        uint256 amount;
        address to;
        uint256 repaymentPeriod;
        uint256 maxAprBps;
        uint256 nonce;
        uint256 deadline;
    }

    struct DepositRequest {
        address lender;
        uint256 amount;
        address receiver;
        uint256 nonce;
        uint256 deadline;
    }

    struct RequestWithdrawal {
        address lender;
        uint256 amount;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    struct AttestRequest {
        address attester;
        address borrower;
        uint256 weight;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev EIP-2612 permit; a zero `deadline` means "no permit" where permits are optional.
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ───────────────────────────── state ─────────────────────────────

    IERC20 public immutable usdc;
    address public owner;
    address public oracle;

    // Interest: every loan's APR is fixed at effrRate + riskPremium when it is created.
    // effrRate tracks the Effective Federal Funds Rate (set manually here; intended to come
    // from Pyth: https://www.pyth.network/price-feeds/rates-effr).
    uint256 public effrRate;
    uint256 public riskPremium;
    // Max principal (USDC, 6 decimals) at a 100% credit score; scales linearly with score.
    uint256 public maxLoanAmount;

    // PageRank personalization (teleportation) weights, in USDC units:
    // weight = basePersonalization + min(lenderDeposits, personalizationCap) + (KYC ? kycBonus : 0)
    uint256 public basePersonalization;
    uint256 public kycBonus;
    uint256 public personalizationCap;

    // Pool liquidity
    uint256 public totalDeposits; // principal deposited by lenders, net of withdrawals
    uint256 public totalLentOut; // principal held by borrowers on active loans
    uint256 public reservedLiquidity; // principal approved but not yet disbursed
    uint256 public lendingUtilizationCap; // max (lent + reserved) / deposits, in BASIS_POINTS
    uint256 public liquidityBuffer; // share of deposits kept liquid, in BASIS_POINTS
    uint256 public liquidityThreshold; // absolute USDC kept liquid

    // Lenders
    mapping(address => uint256) public lenderDeposits;
    uint256 public lenderCount;
    mapping(address => bool) private isLender;
    address[] private _lenders;

    // Loans
    uint256 private nextLoanId = 1;
    mapping(uint256 => Loan) private loans;
    uint256[] private _allLoanIds;
    address[] private _borrowers;
    mapping(address => bool) private _borrowerSeen;
    mapping(address => uint256[]) private _borrowerLoans;

    // Attestations and credit
    mapping(address => Attestation[]) private borrowerAttestations;
    address[] private _attesters;
    mapping(address => bool) private _attesterSeen;
    mapping(address => bool) public isKYCVerified;
    // Admin-assigned scores. When non-zero, getCreditScore returns this instead of PageRank.
    mapping(address => uint256) public scoreOverrides;
    mapping(address => string) public displayNames;

    // Meta-transactions
    mapping(address => uint256) public nonces;
    mapping(address => bool) public relayerWhitelist;
    bool public relayerWhitelistEnabled;

    // FIFO withdrawal queue (filled as liquidity returns)
    WithdrawalQueueItem[] private withdrawalQueue;
    uint256 private withdrawalHead;
    mapping(address => uint256) public queuedWithdrawals; // per lender, still waiting in the queue
    uint256 public totalQueuedWithdrawals; // sum of queuedWithdrawals; liquidity owed to the queue first

    // ───────────────────────────── events ─────────────────────────────

    event ParameterUpdated(bytes32 indexed parameter, uint256 value);
    event LiquidityLimitsUpdated(uint256 bufferBp, uint256 threshold);
    event OracleUpdated(address oracle);
    event RelayerWhitelisted(address indexed relayer, bool allowed);
    event ScoreOverrideSet(address indexed user, uint256 score);
    event KycVerified(address indexed user);
    event Deposited(address indexed lender, uint256 amount);
    event Withdrawn(address indexed lender, address indexed to, uint256 amount);
    event LoanRequested(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate);
    event LoanDisbursed(address indexed borrower, uint256 indexed loanId, address to, uint256 amount);
    event Attested(address indexed attester, address indexed borrower, uint256 weight);
    event DisplayNameSet(address indexed user, string name);
    event LoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanRequested(address indexed borrower, uint256 amount, uint256 loanId);
    event MetaLoanDisbursed(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanCreated(
        address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate, uint256 repaymentPeriod
    );
    event MetaDeposit(address indexed lender, uint256 amount, address indexed receiver, uint256 sharesMinted);
    event MetaWithdrawalRequested(address indexed lender, uint256 indexed queueId, uint256 amount, address indexed to);
    event MetaWithdrawalFilled(uint256 indexed queueId, uint256 amountFilled);
    event MetaAttested(address indexed attester, address indexed borrower, uint256 weight);

    // ───────────────────────────── setup & access ─────────────────────────────

    constructor(uint256 _effrRate, uint256 _riskPremium, uint256 _maxLoanAmount, address _usdc, address _oracle)
        EIP712("DecentralizedMicrocredit", "1")
    {
        require(_usdc != address(0) && _oracle != address(0), "Invalid addresses");
        usdc = IERC20(_usdc);
        owner = msg.sender;
        oracle = _oracle;
        effrRate = _effrRate;
        riskPremium = _riskPremium;
        maxLoanAmount = _maxLoanAmount;
        kycBonus = 100 * 1e6;
        personalizationCap = 100 * 1e6;
        lendingUtilizationCap = 9000; // 90%
        liquidityBuffer = 500; // 5%
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Owner only");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "Oracle only");
        _;
    }

    modifier onlyOwnerOrOracle() {
        require(msg.sender == owner || msg.sender == oracle, "Owner or oracle only");
        _;
    }

    /// @dev Applies the optional relayer whitelist to meta-transaction entry points.
    modifier onlyAllowedRelayer() {
        if (relayerWhitelistEnabled) {
            require(relayerWhitelist[msg.sender], "Unauthorized relayer");
        }
        _;
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle");
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    function setKycBonus(uint256 _kycBonus) external onlyOwner {
        kycBonus = _kycBonus;
        emit ParameterUpdated("kycBonus", _kycBonus);
    }

    function setBasePersonalization(uint256 _base) external onlyOwner {
        basePersonalization = _base;
        emit ParameterUpdated("basePersonalization", _base);
    }

    function setPersonalizationCap(uint256 _cap) external onlyOwner {
        personalizationCap = _cap;
        emit ParameterUpdated("personalizationCap", _cap);
    }

    function setEffrRate(uint256 _effrRate) external onlyOwner {
        effrRate = _effrRate;
        emit ParameterUpdated("effrRate", _effrRate);
    }

    function setRiskPremium(uint256 _riskPremium) external onlyOwner {
        riskPremium = _riskPremium;
        emit ParameterUpdated("riskPremium", _riskPremium);
    }

    function setMaxLoanAmount(uint256 _maxLoanAmount) external onlyOwner {
        maxLoanAmount = _maxLoanAmount;
        emit ParameterUpdated("maxLoanAmount", _maxLoanAmount);
    }

    /// @param cap Max share of deposits that may be lent or reserved, in BASIS_POINTS.
    function setLendingUtilizationCap(uint256 cap) external onlyOwner {
        require(cap <= BASIS_POINTS, "Cap cannot exceed 100%");
        lendingUtilizationCap = cap;
        emit ParameterUpdated("lendingUtilizationCap", cap);
    }

    /// @param bufferBp Share of deposits to keep liquid, in BASIS_POINTS.
    /// @param threshold Absolute USDC amount (6 decimals) to keep liquid.
    function setLiquidityLimits(uint256 bufferBp, uint256 threshold) external onlyOwner {
        require(bufferBp <= BASIS_POINTS, "Buffer > 100%");
        liquidityBuffer = bufferBp;
        liquidityThreshold = threshold;
        emit LiquidityLimitsUpdated(bufferBp, threshold);
    }

    function setRelayerWhitelistEnabled(bool enabled) external onlyOwner {
        relayerWhitelistEnabled = enabled;
        emit ParameterUpdated("relayerWhitelistEnabled", enabled ? 1 : 0);
    }

    function setRelayerWhitelisted(address relayer, bool allowed) external onlyOwner {
        require(relayer != address(0), "Invalid relayer address");
        relayerWhitelist[relayer] = allowed;
        emit RelayerWhitelisted(relayer, allowed);
    }

    /// @notice Assign a credit score directly, bypassing PageRank. Set 0 to clear.
    /// @param score Score in SCALE units (1e6 = 100%).
    function setScoreOverride(address user, uint256 score) external onlyOwner {
        require(score <= SCALE, "Score exceeds SCALE");
        scoreOverrides[user] = score;
        emit ScoreOverrideSet(user, score);
    }

    function markKYCVerified(address user) external onlyOracle {
        require(!isKYCVerified[user], "Already verified");
        isKYCVerified[user] = true;
        emit KycVerified(user);
    }

    function setDisplayName(string calldata name) external {
        require(bytes(name).length <= 32, "Name too long");
        displayNames[msg.sender] = name;
        emit DisplayNameSet(msg.sender, name);
    }

    // ───────────────────────────── lending pool ─────────────────────────────

    function depositFunds(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        _pullUsdc(msg.sender, amount);
        _recordDeposit(msg.sender, amount);
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Withdraw immediately. Queued withdrawals are paid first, and funds already queued
    ///         cannot be withdrawn again here.
    function withdrawFunds(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        require(lenderDeposits[msg.sender] - queuedWithdrawals[msg.sender] >= amount, "Insufficient balance");
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);

        uint256 bufferRequired = (totalDeposits * liquidityBuffer) / BASIS_POINTS;
        require(
            usdc.balanceOf(address(this))
                >= reservedLiquidity + totalQueuedWithdrawals + amount + bufferRequired + liquidityThreshold,
            "LIQUIDITY_BELOW_THRESHOLD"
        );

        _payOut(msg.sender, msg.sender, amount);
    }

    // ───────────────────────────── loans ─────────────────────────────

    /// @notice Request a loan as the caller. Liquidity is reserved until {disburseLoan}.
    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        return _originateLoan(msg.sender, amount);
    }

    /// @notice Send a requested loan's principal to its borrower. Callable by anyone.
    function disburseLoan(uint256 loanId) external {
        _disburseLoan(loanId, loans[loanId].borrower);
    }

    /// @notice Repay up to `amount`; any excess over the outstanding balance is not pulled.
    function repayLoan(uint256 loanId, uint256 amount) external {
        Loan storage loan = _repayableLoan(loanId);
        require(msg.sender == loan.borrower, "Borrower only");
        require(amount > 0, "Amount > 0");

        uint256 paid = _repay(loanId, loan, msg.sender, amount);
        emit LoanRepaid(msg.sender, loanId, paid);
    }

    /**
     * @notice Repay with a single EIP-2612 permit signature; anyone (e.g. a relayer) may submit.
     * @param amount Amount to repay; 0 repays the cent-rounded outstanding balance.
     *        The amount pulled never exceeds the permit `value`.
     */
    function repayWithPermit(
        address borrower,
        uint256 loanId,
        uint256 amount,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        Loan storage loan = _repayableLoan(loanId);
        require(loan.borrower == borrower, "Wrong borrower");

        _permit(borrower, value, deadline, v, r, s);

        uint256 spend = amount == 0 ? _roundToCent(getCurrentOutstandingAmount(loanId)) : amount;
        if (spend > value) {
            spend = value;
        }
        require(spend > 0, "Nothing to repay");

        uint256 paid = _repay(loanId, loan, borrower, spend);
        emit LoanRepaid(borrower, loanId, paid);
    }

    // ───────────────────────────── attestations & credit ─────────────────────────────

    /**
     * @notice Vouch for `borrower` with confidence `weight` (0..SCALE). Re-attesting updates the
     *         weight. PageRank is recomputed immediately (demo only).
     */
    function recordAttestation(address borrower, uint256 weight) external {
        _recordAttestation(msg.sender, borrower, weight);
    }

    /// @notice Recompute PageRank over the current attestation graph.
    function computePageRank() external returns (uint256 iterations) {
        return _computePageRank();
    }

    /// @notice Remove the whole PageRank graph and all scores.
    function clearPageRankState() external onlyOwnerOrOracle {
        _clearPageRankState();
    }

    /**
     * @notice Credit score in SCALE units: the admin override if set, otherwise PageRank mapped
     *         through credit = SCALE * x / (x + 100), where x = 1000 * PR / max(PR).
     * @dev The saturating curve keeps scores meaningful even though PageRank is zero-sum.
     */
    function getCreditScore(address user) public view returns (uint256) {
        if (scoreOverrides[user] != 0) return scoreOverrides[user];

        uint256 maxPageRank = getMaxPageRankScore();
        if (maxPageRank == 0) return 0;

        uint256 x = (pagerankScores[user] * 1000) / maxPageRank; // 0..1000
        return (SCALE * x) / (x + 100);
    }

    /// @notice Share of a 5%-of-principal reward pot owed to `attester`, by attestation weight.
    function computeAttesterReward(uint256 loanId, address attester) external view returns (uint256 reward) {
        Loan storage loan = loans[loanId];
        Attestation[] storage attests = borrowerAttestations[loan.borrower];
        uint256 totalWeight = 0;
        uint256 attesterWeight = 0;
        for (uint256 i = 0; i < attests.length; i++) {
            totalWeight += attests[i].weight;
            if (attests[i].attester == attester) {
                attesterWeight = attests[i].weight;
            }
        }
        if (totalWeight == 0 || attesterWeight == 0) return 0;
        uint256 totalReward = (loan.principal * ATTESTER_REWARD_RATE) / SCALE;
        reward = (totalReward * attesterWeight) / totalWeight;
    }

    // ───────────────────────────── meta-transactions ─────────────────────────────

    function requestLoanMeta(LoanRequest calldata req, bytes calldata sig)
        external
        onlyAllowedRelayer
        returns (uint256 loanId)
    {
        _verifyMeta(
            req.borrower,
            req.nonce,
            req.deadline,
            keccak256(abi.encode(LOAN_REQUEST_TYPEHASH, req.borrower, req.amount, req.nonce, req.deadline)),
            sig
        );
        loanId = _originateLoan(req.borrower, req.amount);
        emit MetaLoanRequested(req.borrower, req.amount, loanId);
    }

    function disburseLoanMeta(DisburseRequest calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.borrower,
            req.nonce,
            req.deadline,
            keccak256(abi.encode(DISBURSE_REQUEST_TYPEHASH, req.borrower, req.loanId, req.to, req.nonce, req.deadline)),
            sig
        );
        require(req.to == loans[req.loanId].borrower && req.to == req.borrower, "Must send to borrower");

        uint256 principal = _disburseLoan(req.loanId, req.to);
        emit MetaLoanDisbursed(req.borrower, req.loanId, principal);
    }

    /// @notice One-click borrow: create and disburse a loan in one relayed transaction.
    function borrowAndDisburseMeta(BorrowAndDisburse calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.borrower,
            req.nonce,
            req.deadline,
            keccak256(
                abi.encode(
                    BORROW_AND_DISBURSE_TYPEHASH,
                    req.borrower,
                    req.amount,
                    req.to,
                    req.repaymentPeriod,
                    req.maxAprBps,
                    req.nonce,
                    req.deadline
                )
            ),
            sig
        );

        uint256 currentApr = effrRate + riskPremium;
        require(currentApr <= req.maxAprBps, "APR changed");

        uint256 loanId = _originateLoan(req.borrower, req.amount);
        _disburseLoan(loanId, req.to);

        emit MetaLoanCreated(req.borrower, loanId, req.amount, currentApr, req.repaymentPeriod);
        emit MetaLoanDisbursed(req.borrower, loanId, req.amount);
    }

    /**
     * @notice Repay a loan in full via relayer, optionally executing an ERC-2612 permit first.
     * @dev `req.amount == 0` repays everything. A non-zero amount must be within 1 cent of the
     *      current outstanding balance; the canonical balance is pulled either way. Balances
     *      under 1 cent are forgiven without a transfer.
     */
    function repayLoanMeta(RepayRequest calldata req, bytes calldata sig, PermitData calldata permit)
        external
        onlyAllowedRelayer
    {
        _verifyMeta(
            req.borrower,
            req.nonce,
            req.deadline,
            keccak256(
                abi.encode(REPAY_REQUEST_TYPEHASH, req.borrower, req.loanId, req.amount, req.nonce, req.deadline)
            ),
            sig
        );

        Loan storage loan = _repayableLoan(req.loanId);
        require(loan.borrower == req.borrower, "Wrong borrower");

        uint256 out = getCurrentOutstandingAmount(req.loanId);
        if (out < CENT) {
            _closeLoan(loan);
            emit MetaLoanRepaid(req.borrower, req.loanId, 0);
            return;
        }

        if (permit.deadline != 0) {
            _permit(req.borrower, permit);
            require(permit.value >= out, "Permit value too low");
        }
        if (req.amount != 0 && req.amount < out) {
            require(out - req.amount <= CENT, "OUTSTANDING_CHANGED");
        }

        _repay(req.loanId, loan, req.borrower, out);
        emit MetaLoanRepaid(req.borrower, req.loanId, out);
    }

    /// @notice Gasless deposit of the signer's USDC, credited to `req.receiver`, with optional permit.
    function depositWithPermitMeta(DepositRequest calldata req, bytes calldata sig, PermitData calldata permit)
        external
        onlyAllowedRelayer
    {
        _verifyMeta(
            req.lender,
            req.nonce,
            req.deadline,
            keccak256(
                abi.encode(DEPOSIT_REQUEST_TYPEHASH, req.lender, req.amount, req.receiver, req.nonce, req.deadline)
            ),
            sig
        );

        if (permit.deadline != 0) {
            _permit(req.lender, permit);
            require(permit.value >= req.amount, "Permit value too low");
        }

        require(req.receiver != address(0), "Bad receiver");

        _pullUsdc(req.lender, req.amount);
        _recordDeposit(req.receiver, req.amount);
        emit MetaDeposit(req.lender, req.amount, req.receiver, req.amount);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Gasless deposit of exactly `permit.value`, authorized by the permit alone.
    function depositPermitOnlyMeta(address lender, PermitData calldata permit) external onlyAllowedRelayer {
        require(lender != address(0), "Bad lender");
        require(permit.value > 0, "Zero amount");

        _permit(lender, permit);
        _pullUsdc(lender, permit.value);
        _recordDeposit(lender, permit.value);
        emit MetaDeposit(lender, permit.value, lender, permit.value);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Queue a gasless withdrawal; it is paid immediately as far as liquidity allows.
    function requestWithdrawalMeta(RequestWithdrawal calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.lender,
            req.nonce,
            req.deadline,
            keccak256(abi.encode(REQUEST_WITHDRAWAL_TYPEHASH, req.lender, req.amount, req.to, req.nonce, req.deadline)),
            sig
        );
        require(lenderDeposits[req.lender] - queuedWithdrawals[req.lender] >= req.amount, "Insufficient balance");
        queuedWithdrawals[req.lender] += req.amount;
        totalQueuedWithdrawals += req.amount;

        uint256 queueId = withdrawalQueue.length;
        withdrawalQueue.push(
            WithdrawalQueueItem({ lender: req.lender, to: req.to, remaining: req.amount, active: true })
        );
        emit MetaWithdrawalRequested(req.lender, queueId, req.amount, req.to);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Pays up to `maxItems` queued withdrawals from available liquidity. Anyone may call
    ///         it; payouts only ever go to each request's signed recipient.
    function processWithdrawalQueue(uint256 maxItems) external {
        _tryFillWithdrawalQueue(maxItems);
    }

    /// @notice Gasless attestation signed by the attester.
    function attestMeta(AttestRequest calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.attester,
            req.nonce,
            req.deadline,
            keccak256(
                abi.encode(ATTEST_REQUEST_TYPEHASH, req.attester, req.borrower, req.weight, req.nonce, req.deadline)
            ),
            sig
        );
        _recordAttestation(req.attester, req.borrower, req.weight);
        emit MetaAttested(req.attester, req.borrower, req.weight);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Borrower APR (EFFR + premium) in BASIS_POINTS.
    function getLoanRate() external view returns (uint256) {
        return effrRate + riskPremium;
    }

    /// @notice Projected lender APY in BASIS_POINTS: loan rate x pool utilisation.
    function getFundingPoolAPY() external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        uint256 utilisationBp = ((totalLentOut + reservedLiquidity) * BASIS_POINTS) / totalDeposits;
        return ((effrRate + riskPremium) * utilisationBp) / BASIS_POINTS;
    }

    /**
     * @return _totalDeposits  Net lender deposits (USDC, 6 decimals)
     * @return _availableFunds Liquid USDC not reserved for pending disbursements
     * @return _reservedFunds  USDC reserved for approved, undisbursed loans
     * @return _lenderCount    Unique depositors
     */
    function getPoolInfo()
        external
        view
        returns (uint256 _totalDeposits, uint256 _availableFunds, uint256 _reservedFunds, uint256 _lenderCount)
    {
        _totalDeposits = totalDeposits;
        _reservedFunds = reservedLiquidity;
        uint256 committed = _reservedFunds + totalQueuedWithdrawals;
        uint256 balance = usdc.balanceOf(address(this));
        _availableFunds = balance > committed ? balance - committed : 0;
        _lenderCount = lenderCount;
    }

    /// @return interestRate APR in BASIS_POINTS
    /// @return payment      Weekly payment over `repaymentPeriod` (one payment if under a week)
    function previewLoanTerms(
        address,
        /* borrower */
        uint256 principal,
        uint256 repaymentPeriod
    )
        external
        view
        returns (uint256 interestRate, uint256 payment)
    {
        interestRate = effrRate + riskPremium;
        uint256 interest = (principal * interestRate * repaymentPeriod) / (BASIS_POINTS * SECONDS_PER_YEAR);
        uint256 payments = repaymentPeriod / 7 days;
        payment = (principal + interest) / (payments == 0 ? 1 : payments);
    }

    function getLoan(uint256 loanId)
        external
        view
        returns (uint256 principal, uint256 outstanding, address borrower, uint256 interestRate, bool isActive)
    {
        Loan storage loan = loans[loanId];
        outstanding = loan.isActive ? getCurrentOutstandingAmount(loanId) : 0;
        return (loan.principal, outstanding, loan.borrower, loan.interestRate, loan.isActive);
    }

    /**
     * @notice Principal plus simple interest accrued since origination, less repayments.
     * @dev No interest accrues during the first day. Interest keeps accruing on the original
     *      principal until the loan closes; partial repayments reduce the balance, not the base.
     */
    function getCurrentOutstandingAmount(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan inactive");

        uint256 owed = loan.principal;
        uint256 timeElapsed = block.timestamp - loan.createdAt;
        if (timeElapsed >= GRACE_PERIOD) {
            uint256 annualInterest = (loan.principal * loan.interestRate) / BASIS_POINTS;
            owed += (annualInterest * timeElapsed) / SECONDS_PER_YEAR;
        }
        return owed > loan.repaid ? owed - loan.repaid : 0;
    }

    /// @notice Outstanding balance rounded half-up to the cent, as shown in the UI.
    function getOutstandingRoundedToCent(uint256 loanId) external view returns (uint256) {
        return _roundToCent(getCurrentOutstandingAmount(loanId));
    }

    function getAllLoanIds() external view returns (uint256[] memory) {
        return _allLoanIds;
    }

    function getBorrowers() external view returns (address[] memory) {
        return _borrowers;
    }

    function getBorrowerLoanIds(address borrower) external view returns (uint256[] memory) {
        return _borrowerLoans[borrower];
    }

    function getLenders() external view returns (address[] memory) {
        return _lenders;
    }

    function getAttesters() external view returns (address[] memory) {
        return _attesters;
    }

    function getBorrowerAttestations(address borrower) external view returns (Attestation[] memory) {
        return borrowerAttestations[borrower];
    }

    /// @notice Every address that has received at least one attestation.
    function getBorrowersWithAttestations() external view returns (address[] memory result) {
        address[] storage nodes = _pagerankNodes();
        address[] memory matches = new address[](nodes.length);
        uint256 count = 0;
        for (uint256 i = 0; i < nodes.length; i++) {
            if (borrowerAttestations[nodes[i]].length > 0) {
                matches[count++] = nodes[i];
            }
        }
        result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = matches[i];
        }
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev Checks deadline, consumes the signer's nonce, and verifies an EIP-712 signature
    ///      (EOA or ERC-1271 wallet) over `structHash`.
    function _verifyMeta(address signer, uint256 nonce, uint256 deadline, bytes32 structHash, bytes calldata sig)
        internal
    {
        require(block.timestamp <= deadline, "Expired");
        require(nonce == nonces[signer]++, "Bad nonce");
        require(SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), sig), "Bad signature");
    }

    function _permit(address holder, PermitData calldata permit) internal {
        _permit(holder, permit.value, permit.deadline, permit.v, permit.r, permit.s);
    }

    /// @dev Anyone can submit a permit signature first (e.g. by watching the mempool), which makes
    ///      the relayed permit() revert on a used nonce. Proceed when the allowance is already set.
    function _permit(address holder, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        try IERC20Permit(address(usdc)).permit(holder, address(this), value, deadline, v, r, s) { }
        catch {
            require(usdc.allowance(holder, address(this)) >= value, "Permit failed");
        }
    }

    function _pullUsdc(address from, uint256 amount) internal {
        usdc.safeTransferFrom(from, address(this), amount);
    }

    function _pushUsdc(address to, uint256 amount) internal {
        usdc.safeTransfer(to, amount);
    }

    function _recordDeposit(address lender, uint256 amount) internal {
        totalDeposits += amount;
        lenderDeposits[lender] += amount;
        if (!isLender[lender]) {
            isLender[lender] = true;
            lenderCount += 1;
            _lenders.push(lender);
        }
        emit Deposited(lender, amount);
    }

    /// @dev Pays `amount` of `lender`'s deposit out to `to`.
    function _payOut(address lender, address to, uint256 amount) internal {
        lenderDeposits[lender] -= amount;
        totalDeposits -= amount;
        _pushUsdc(to, amount);
        emit Withdrawn(lender, to, amount);
    }

    /// @dev Sum of principal across the borrower's active loans.
    function _activePrincipal(address borrower) internal view returns (uint256 total) {
        uint256[] storage ids = _borrowerLoans[borrower];
        for (uint256 i = 0; i < ids.length; i++) {
            Loan storage loan = loans[ids[i]];
            if (loan.isActive) {
                total += loan.principal;
            }
        }
    }

    /**
     * @dev Single origination path for requestLoan, requestLoanMeta and borrowAndDisburseMeta.
     *      Enforces the score-based limit across the borrower's active loans, the pool
     *      utilisation cap and the liquidity buffer, then reserves the principal.
     */
    function _originateLoan(address borrower, uint256 amount) internal returns (uint256 loanId) {
        require(amount > 0, "Amount > 0");
        uint256 score = getCreditScore(borrower);
        require(score > 0, "Score > 0");

        uint256 limit = Math.mulDiv(maxLoanAmount, score, SCALE);
        require(_activePrincipal(borrower) + amount <= limit, "Outstanding loans exceed max");

        uint256 maxCommitment = (totalDeposits * lendingUtilizationCap) / BASIS_POINTS;
        require(reservedLiquidity + totalLentOut + amount <= maxCommitment, "Pool utilisation cap exceeded");

        uint256 bufferRequired = (totalDeposits * liquidityBuffer) / BASIS_POINTS;
        require(
            usdc.balanceOf(address(this)) - reservedLiquidity
                >= amount + totalQueuedWithdrawals + bufferRequired + liquidityThreshold,
            "LIQUIDITY_BELOW_THRESHOLD"
        );

        reservedLiquidity += amount;

        loanId = nextLoanId++;
        loans[loanId] = Loan({
            principal: amount,
            repaid: 0,
            borrower: borrower,
            interestRate: effrRate + riskPremium,
            isActive: true,
            disbursed: false,
            createdAt: block.timestamp
        });

        _allLoanIds.push(loanId);
        if (!_borrowerSeen[borrower]) {
            _borrowerSeen[borrower] = true;
            _borrowers.push(borrower);
        }
        _borrowerLoans[borrower].push(loanId);
        emit LoanRequested(borrower, loanId, amount, effrRate + riskPremium);
    }

    /// @dev Moves a reserved loan's principal to `to`. Callers decide who may receive it.
    function _disburseLoan(uint256 loanId, address to) internal returns (uint256 principal) {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan inactive");
        require(!loan.disbursed, "Already disbursed");
        loan.disbursed = true;

        principal = loan.principal;
        reservedLiquidity -= principal;
        totalLentOut += principal;
        _pushUsdc(to, principal);
        emit LoanDisbursed(loan.borrower, loanId, to, principal);
    }

    function _repayableLoan(uint256 loanId) internal view returns (Loan storage loan) {
        loan = loans[loanId];
        require(loan.isActive, "Loan inactive");
        require(loan.disbursed, "Not disbursed");
    }

    /**
     * @dev Pulls `min(amount, outstanding)` from `payer` and closes the loan once less than a
     *      cent remains (sub-cent balances are forgiven). Returns the amount pulled.
     */
    function _repay(uint256 loanId, Loan storage loan, address payer, uint256 amount) internal returns (uint256 paid) {
        uint256 owed = getCurrentOutstandingAmount(loanId);
        paid = amount < owed ? amount : owed;
        if (paid > 0) {
            _pullUsdc(payer, paid);
            loan.repaid += paid;
        }
        if (owed - paid < CENT) {
            _closeLoan(loan);
        }
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    function _closeLoan(Loan storage loan) internal {
        totalLentOut -= loan.principal;
        loan.isActive = false;
    }

    function _recordAttestation(address attester, address borrower, uint256 weight) internal {
        require(weight <= SCALE, "Weight too high");
        require(borrower != attester, "Self-attestation");

        if (!_attesterSeen[attester]) {
            _attesterSeen[attester] = true;
            _attesters.push(attester);
        }

        _addPagerankNode(attester);
        _addPagerankNode(borrower);
        _setPagerankEdge(attester, borrower, weight);

        Attestation[] storage attests = borrowerAttestations[borrower];
        bool updated = false;
        for (uint256 i = 0; i < attests.length; i++) {
            if (attests[i].attester == attester) {
                attests[i].weight = weight;
                updated = true;
                break;
            }
        }
        if (!updated) {
            attests.push(Attestation({ attester: attester, weight: weight }));
        }

        emit Attested(attester, borrower, weight);
        _computePageRank(); // DEMO ONLY: production moves this off-chain
    }

    /// @inheritdoc PageRank
    function _personalizationWeight(address node) internal view override returns (uint256 weight) {
        // An admin-assigned score anchors trust directly, so the node's attestations carry it.
        if (scoreOverrides[node] != 0) return scoreOverrides[node];

        uint256 deposits = lenderDeposits[node];
        weight = basePersonalization + (deposits > personalizationCap ? personalizationCap : deposits);
        if (isKYCVerified[node]) {
            weight += kycBonus;
        }
    }

    /// @dev Pays up to `maxItems` queued withdrawals in FIFO order while liquidity stays above
    ///      the guards. Called from every path that adds liquidity, and before direct withdrawals.
    function _tryFillWithdrawalQueue(uint256 maxItems) internal {
        uint256 bufferRequired = (totalDeposits * liquidityBuffer) / BASIS_POINTS;

        for (uint256 visited = 0; visited < maxItems && withdrawalHead < withdrawalQueue.length; visited++) {
            WithdrawalQueueItem storage item = withdrawalQueue[withdrawalHead];
            if (!item.active || item.remaining == 0) {
                item.active = false;
                withdrawalHead++;
                continue;
            }

            uint256 liquid = usdc.balanceOf(address(this));
            uint256 locked = reservedLiquidity + bufferRequired + liquidityThreshold;
            if (liquid <= locked || liquid - locked < CENT) break;

            uint256 available = liquid - locked;
            uint256 pay = item.remaining <= available ? item.remaining : available;

            queuedWithdrawals[item.lender] -= pay;
            totalQueuedWithdrawals -= pay;
            item.remaining -= pay;
            _payOut(item.lender, item.to, pay);
            emit MetaWithdrawalFilled(withdrawalHead, pay);

            if (item.remaining != 0) break; // partial fill; resume on the next liquidity event
            item.active = false;
            withdrawalHead++;
        }
    }

    function _roundToCent(uint256 x) internal pure returns (uint256) {
        return ((x + CENT / 2) / CENT) * CENT;
    }
}
