// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IScoreProvider } from "./interfaces/IScoreProvider.sol";

/**
 * @title DecentralizedMicrocredit
 * @notice Single-pool, collateral-free USDC lending backed by social credit. Every account's
 *         credit is either granted (its credit score, set by an admin override or published by
 *         an oracle through a swappable {IScoreProvider}, times maxLoanAmount) or staked USDC.
 *         Backing a borrower moves part of the backer's own credit to them, so credit is
 *         conserved: an account with no granted credit and no stake can neither borrow nor
 *         back anyone, and Sybil accounts cannot manufacture credit by vouching for each other.
 *         Every user action also has an EIP-712 meta-transaction entry point so a relayer can
 *         pay gas.
 *
 *         Lenders own the pool through non-transferable shares. Interest is recognised when it
 *         is repaid (cash basis): repayments settle accrued interest first, and the interest,
 *         less the protocol fee, raises the share price for every lender.
 *
 *         When a backed borrower defaults, the backers pay first: committed stake is slashed back
 *         into the pool and committed credit is burned from their granted credit (creditLoss).
 */
contract DecentralizedMicrocredit is EIP712 {
    using SafeERC20 for IERC20;

    // ───────────────────────────── constants ─────────────────────────────

    uint256 public constant SCALE = 1e6; // credit scores (1e6 = 100%)
    uint256 public constant BASIS_POINTS = 10000; // interest rates and pool ratios (1e4 = 100%)
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant CENT = 10_000; // 0.01 USDC (6 decimals)
    uint256 private constant GRACE_PERIOD = 1 days; // no interest accrues during the first day
    /// @notice Queued withdrawals paid at most per deposit, repayment or withdrawal, so a long
    ///         queue cannot push those calls past the block gas limit. {processWithdrawalQueue}
    ///         drains the rest.
    uint256 public constant QUEUE_FILLS_PER_CALL = 10;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 2_000; // 20% of repaid interest
    uint256 public constant MAX_RESERVE_BPS = 5_000; // 50% of repaid interest
    uint256 public constant DEFAULT_LOAN_TERM = 30 days; // for requestLoan / requestLoanMeta
    uint256 public constant MIN_LOAN_TERM = 1 days;
    uint256 public constant MAX_LOAN_TERM = 365 days;
    /// @notice How long after its due date an unpaid loan can be marked defaulted.
    uint256 public constant LATE_PERIOD = 30 days;
    /// @notice After this long, anyone may cancel an undisbursed loan to free its reservation.
    uint256 public constant RESERVATION_TTL = 7 days;
    /// @notice Bounds the backers per borrower, and so the work of limits and defaults.
    uint256 public constant MAX_BACKERS_PER_BORROWER = 32;
    /// @dev Virtual shares and assets, as in OpenZeppelin's ERC4626 with a 6-decimal offset: the
    ///      first deposit cannot be front-run into a rounding loss. They hold a negligible slice
    ///      of the pool, so balances can read a few millionths of a cent low.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

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
    bytes32 private constant BACK_REQUEST_TYPEHASH =
        keccak256("BackRequest(address backer,address borrower,uint256 amount,uint256 nonce,uint256 deadline)");

    // ───────────────────────────── types ─────────────────────────────

    /// @dev Requested -> Active -> Repaid | Defaulted, or Requested -> Cancelled.
    enum LoanStatus {
        None,
        Requested, // liquidity reserved, not yet disbursed
        Active, // disbursed and outstanding
        Repaid,
        Defaulted,
        Cancelled
    }

    struct Loan {
        uint256 principal;
        uint256 repaid; // cumulative repayments, interest and principal
        uint256 principalRepaid; // part of `repaid` applied to principal (interest is settled first)
        address borrower;
        uint256 interestRate; // APR in BASIS_POINTS, fixed at origination
        uint256 term; // seconds from disbursement to the due date
        uint256 requestedAt;
        uint256 disbursedAt; // interest accrues from here
        LoanStatus status;
        uint256 impaired; // principal provisioned against (see impairLoan), out of totalAssets
    }

    /// @dev Credit a backer has committed to a borrower: `secured` from the backer's stake,
    ///      `unsecured` from the backer's granted credit.
    struct Backing {
        address backer;
        uint256 secured;
        uint256 unsecured;
    }

    struct WithdrawalQueueItem {
        address lender;
        address to;
        uint256 shares; // shares still waiting; paid out at the share price when filled
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

    struct BackRequest {
        address backer;
        address borrower;
        uint256 amount;
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

    // Credit scores, computed off-chain and published by an oracle (see IScoreProvider)
    IScoreProvider public scoreProvider;

    // Pool accounting: totalAssets() = lenderCash + totalLentOut - totalImpaired. Tracked internally rather than
    // read from the token balance, so stray transfers cannot move the share price.
    uint256 public lenderCash; // lenders' USDC held here, reserved included; excludes protocol fees
    uint256 public totalLentOut; // principal still owed on disbursed, active loans
    uint256 public totalImpaired; // part of totalLentOut provisioned against on overdue loans
    uint256 public reservedLiquidity; // principal approved but not yet disbursed
    uint256 public lendingUtilizationCap; // max (lent + reserved) / totalAssets, in BASIS_POINTS
    uint256 public liquidityBuffer; // share of totalAssets new loans must leave liquid, in BASIS_POINTS
    uint256 public liquidityThreshold; // absolute USDC new loans must leave liquid
    uint256 public protocolFeeBps; // share of repaid interest kept by the protocol, in BASIS_POINTS
    uint256 public protocolFees; // accrued, unclaimed protocol fees (USDC)
    uint256 public reserveBps; // share of repaid interest that funds the first-loss reserve, in BASIS_POINTS
    uint256 public firstLossReserve; // USDC that pays uncovered default losses before lenders; not lenders' asset

    // Lenders
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    // USDC deposited, less the pro-rata cost basis of shares withdrawn; earnings = balance - this
    mapping(address => uint256) public lenderPrincipal;
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

    // Backing: credit committed by backers to borrowers
    mapping(address => Backing[]) private _backings; // per borrower
    mapping(address => mapping(address => uint256)) private _backingSlot; // backer => borrower => index + 1
    address[] private _backedBorrowers;
    address[] private _backers;
    mapping(address => bool) private _backerSeen;
    mapping(address => bool) public isKYCVerified;
    // Admin-assigned scores. When non-zero, getCreditScore returns this instead of the provider's.
    mapping(address => uint256) public scoreOverrides;
    mapping(address => string) public displayNames;

    // Credit
    mapping(address => uint256) public stakeOf; // USDC staked as secured credit, held outside the pool
    uint256 public totalStaked;
    mapping(address => uint256) public stakeCommitted; // stake committed to backing, per backer
    mapping(address => uint256) public creditCommitted; // granted credit committed to backing, per backer
    mapping(address => uint256) public creditLoss; // backed defaults charged against granted credit
    mapping(address => uint256) public duesPaid; // interest paid on own loans, net of the protocol fee
    mapping(address => uint256) public activeLoanCount; // per borrower, requested and not yet closed
    mapping(address => uint256) public completedLoans; // per borrower, repaid in full
    mapping(address => uint256) public defaultedLoans; // per borrower; any default blocks borrowing
    mapping(address => uint256) private _outstandingPrincipal; // per borrower, across open loans

    // Meta-transactions
    mapping(address => uint256) public nonces;
    mapping(address => bool) public relayerWhitelist;
    bool public relayerWhitelistEnabled;

    // FIFO withdrawal queue (filled as liquidity returns)
    WithdrawalQueueItem[] private withdrawalQueue;
    uint256 private withdrawalHead;
    mapping(address => uint256) public queuedShares; // per lender, still waiting in the queue
    uint256 public totalQueuedShares; // their value is owed to the queue before new loans or withdrawals

    // ───────────────────────────── events ─────────────────────────────

    event ParameterUpdated(bytes32 indexed parameter, uint256 value);
    event LiquidityLimitsUpdated(uint256 bufferBp, uint256 threshold);
    event OracleUpdated(address oracle);
    event ScoreProviderUpdated(address provider);
    event RelayerWhitelisted(address indexed relayer, bool allowed);
    event ScoreOverrideSet(address indexed user, uint256 score);
    event KycVerified(address indexed user);
    /// @dev Authoritative record of a credit to `lender` (for meta deposits, the signed receiver).
    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, address indexed to, uint256 assets, uint256 shares);
    event LoanRequested(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate);
    event LoanDisbursed(address indexed borrower, uint256 indexed loanId, address to, uint256 amount);
    event LoanCancelled(address indexed borrower, uint256 indexed loanId);
    event LoanImpaired(uint256 indexed loanId, uint256 impaired);
    /// @dev `writtenOff` is the unpaid principal; `recovered` the part paid back to lenders from
    ///      backers' slashed stake and the first-loss reserve.
    event LoanDefaulted(address indexed borrower, uint256 indexed loanId, uint256 writtenOff, uint256 recovered);
    /// @dev A backer's share of a default: `slashed` stake returned to the pool, `charged` granted credit burned.
    event BackerCharged(address indexed backer, uint256 indexed loanId, uint256 slashed, uint256 charged);
    event Backed(address indexed backer, address indexed borrower, uint256 secured, uint256 unsecured);
    event DisplayNameSet(address indexed user, string name);
    event LoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 amount);
    /// @dev How a repayment was split; `fee` is the protocol's cut of `interest`.
    event RepaymentApplied(uint256 indexed loanId, uint256 interest, uint256 principal, uint256 fee);
    event ProtocolFeesClaimed(address indexed to, uint256 amount);
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveReleased(uint256 amount);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event MetaLoanRequested(address indexed borrower, uint256 amount, uint256 loanId);
    event MetaLoanDisbursed(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 amount);
    event MetaLoanCreated(
        address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate, uint256 repaymentPeriod
    );
    /// @dev Emitted alongside {Deposited} by the relayed deposit paths. `lender` is the payer whose
    ///      USDC was pulled; {Deposited} names the account actually credited (`receiver`).
    event MetaDeposit(address indexed lender, uint256 amount, address indexed receiver, uint256 sharesMinted);
    event MetaWithdrawalRequested(address indexed lender, uint256 indexed queueId, uint256 amount, address indexed to);
    event MetaWithdrawalFilled(uint256 indexed queueId, uint256 amountFilled);

    // ───────────────────────────── errors ─────────────────────────────
    // packages/nextjs/utils/contractErrors.ts maps each to plain-language text for the UI.

    // access & config
    error NotOwner();
    error NotOracle();
    error UnauthorizedRelayer();
    error ZeroAddress();
    error ZeroAmount();
    error AboveOneHundredPercent();
    error FeeTooHigh();
    error ReserveTooHigh();
    error ScoreTooHigh();
    error AlreadyVerified();
    error NameTooLong();
    error ExceedsAccruedFees();
    error ExceedsReserve();
    // meta-transactions & permits
    error SignatureExpired();
    error InvalidNonce();
    error InvalidSignature();
    error PermitFailed();
    error PermitValueTooLow();
    // pool
    error ZeroShares();
    error InsufficientBalance();
    error InsufficientLiquidity();
    // loans
    error NoCredit();
    error BorrowLimitExceeded();
    error BorrowerInDefault();
    error UtilisationCapExceeded();
    error InvalidTerm();
    error AprChanged();
    error LoanNotRequested();
    error LoanNotActive();
    error LoanClosed();
    error NotCancellableYet();
    error NotYetDefaultable();
    error NotOverdue();
    error NotBorrower();
    error WrongBorrower();
    error MustSendToBorrower();
    error NothingToRepay();
    error OutstandingChanged();
    // backing & stake
    error SelfBacking();
    error TooManyBackers();
    error InsufficientCredit();
    error BackingInUse();
    error StakeCommitted();
    error InsufficientStake();

    // ───────────────────────────── setup & access ─────────────────────────────

    constructor(uint256 _effrRate, uint256 _riskPremium, uint256 _maxLoanAmount, address _usdc, address _oracle)
        EIP712("DecentralizedMicrocredit", "1")
    {
        require(_usdc != address(0) && _oracle != address(0), ZeroAddress());
        usdc = IERC20(_usdc);
        owner = msg.sender;
        oracle = _oracle;
        effrRate = _effrRate;
        riskPremium = _riskPremium;
        maxLoanAmount = _maxLoanAmount;
        lendingUtilizationCap = 9000; // 90%
        liquidityBuffer = 500; // 5%
    }

    modifier onlyOwner() {
        require(msg.sender == owner, NotOwner());
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, NotOracle());
        _;
    }

    /// @dev Applies the optional relayer whitelist to meta-transaction entry points.
    modifier onlyAllowedRelayer() {
        if (relayerWhitelistEnabled) {
            require(relayerWhitelist[msg.sender], UnauthorizedRelayer());
        }
        _;
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), ZeroAddress());
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    /// @notice Where credit scores come from; zero leaves only admin overrides.
    function setScoreProvider(IScoreProvider provider) external onlyOwner {
        scoreProvider = provider;
        emit ScoreProviderUpdated(address(provider));
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
        require(cap <= BASIS_POINTS, AboveOneHundredPercent());
        lendingUtilizationCap = cap;
        emit ParameterUpdated("lendingUtilizationCap", cap);
    }

    /// @param bufferBp Share of deposits to keep liquid, in BASIS_POINTS.
    /// @param threshold Absolute USDC amount (6 decimals) to keep liquid.
    function setLiquidityLimits(uint256 bufferBp, uint256 threshold) external onlyOwner {
        require(bufferBp <= BASIS_POINTS, AboveOneHundredPercent());
        liquidityBuffer = bufferBp;
        liquidityThreshold = threshold;
        emit LiquidityLimitsUpdated(bufferBp, threshold);
    }

    /// @param feeBps Share of repaid interest kept by the protocol, in BASIS_POINTS.
    function setProtocolFeeBps(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_PROTOCOL_FEE_BPS, FeeTooHigh());
        protocolFeeBps = feeBps;
        emit ParameterUpdated("protocolFeeBps", feeBps);
    }

    /// @param bps Share of repaid interest that funds the first-loss reserve, in BASIS_POINTS.
    function setReserveBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_RESERVE_BPS, ReserveTooHigh());
        reserveBps = bps;
        emit ParameterUpdated("reserveBps", bps);
    }

    /// @notice Add first-loss capital: an issuer, institution or the operator standing behind the
    ///         pool's credit. It pays default losses before lenders and is never returned to the payer.
    function fundReserve(uint256 amount) external {
        require(amount > 0, ZeroAmount());
        _pullUsdc(msg.sender, amount);
        firstLossReserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Return part of the first-loss reserve to lenders once it exceeds what the pool needs.
    function releaseReserve(uint256 amount) external onlyOwner {
        require(amount <= firstLossReserve, ExceedsReserve());
        firstLossReserve -= amount;
        lenderCash += amount;
        emit ReserveReleased(amount);
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    function claimProtocolFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        require(amount <= protocolFees, ExceedsAccruedFees());
        protocolFees -= amount;
        _pushUsdc(to, amount);
        emit ProtocolFeesClaimed(to, amount);
    }

    function setRelayerWhitelistEnabled(bool enabled) external onlyOwner {
        relayerWhitelistEnabled = enabled;
        emit ParameterUpdated("relayerWhitelistEnabled", enabled ? 1 : 0);
    }

    function setRelayerWhitelisted(address relayer, bool allowed) external onlyOwner {
        require(relayer != address(0), ZeroAddress());
        relayerWhitelist[relayer] = allowed;
        emit RelayerWhitelisted(relayer, allowed);
    }

    /// @notice Assign a credit score directly, bypassing the score provider. Set 0 to clear.
    /// @param score Score in SCALE units (1e6 = 100%).
    function setScoreOverride(address user, uint256 score) external onlyOwner {
        require(score <= SCALE, ScoreTooHigh());
        scoreOverrides[user] = score;
        emit ScoreOverrideSet(user, score);
    }

    function markKYCVerified(address user) external onlyOracle {
        require(!isKYCVerified[user], AlreadyVerified());
        isKYCVerified[user] = true;
        emit KycVerified(user);
    }

    function setDisplayName(string calldata name) external {
        require(bytes(name).length <= 32, NameTooLong());
        displayNames[msg.sender] = name;
        emit DisplayNameSet(msg.sender, name);
    }

    // ───────────────────────────── lending pool ─────────────────────────────

    function depositFunds(uint256 amount) external {
        require(amount > 0, ZeroAmount());
        _pullUsdc(msg.sender, amount);
        _recordDeposit(msg.sender, amount);
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /**
     * @notice Withdraw `amount` USDC now, or everything not already queued with
     *         `type(uint256).max`. Queued withdrawals are paid first. Exits may use the
     *         liquidity buffer, which only limits new loans.
     */
    function withdrawFunds(uint256 amount) external {
        require(amount > 0, ZeroAmount());
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);

        (uint256 shares, uint256 assets) = _sharesForWithdrawal(msg.sender, amount);
        require(lenderCash >= reservedLiquidity + totalQueuedWithdrawals() + assets, InsufficientLiquidity());

        _payOut(msg.sender, msg.sender, assets, shares);
    }

    // ───────────────────────────── loans ─────────────────────────────

    /// @notice Request a loan as the caller, due DEFAULT_LOAN_TERM after disbursement.
    ///         Liquidity is reserved until {disburseLoan} or {cancelLoan}.
    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        return _originateLoan(msg.sender, amount, DEFAULT_LOAN_TERM);
    }

    /// @notice Send a requested loan's principal to its borrower. Callable by anyone.
    function disburseLoan(uint256 loanId) external {
        _disburseLoan(loanId, loans[loanId].borrower);
    }

    /// @notice Cancel an undisbursed loan: the borrower at any time, anyone once the
    ///         reservation is older than RESERVATION_TTL.
    function cancelLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Requested, LoanNotRequested());
        require(
            msg.sender == loan.borrower || block.timestamp > loan.requestedAt + RESERVATION_TTL, NotCancellableYet()
        );

        reservedLiquidity -= loan.principal;
        _closeLoan(loan, LoanStatus.Cancelled);
        emit LoanCancelled(loan.borrower, loanId);
    }

    /**
     * @notice Provision against a loan once it is past due. Callable by anyone, and again to
     *         update. The unpaid principal that secured backing does not cover leaves
     *         totalAssets until the borrower repays it or the loan defaults, so a lender who
     *         exits before {markDefaulted} cannot leave a loss that is already visible to those
     *         who stay. Expected-loss provisioning in the IFRS 9 / CECL sense, with the
     *         unsecured part counted as fully lost.
     * @dev With several open loans, each loan counts the borrower's whole secured backing, so
     *      the provision can be low; {markDefaulted} always settles the true loss.
     */
    function impairLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, LoanNotActive());
        require(block.timestamp > loan.disbursedAt + loan.term, NotOverdue());

        uint256 unpaid = loan.principal - loan.principalRepaid;
        uint256 secured = 0;
        Backing[] storage edges = _backings[loan.borrower];
        for (uint256 i = 0; i < edges.length; i++) {
            secured += edges[i].secured;
        }
        uint256 provision = unpaid > secured ? unpaid - secured : 0;
        totalImpaired = totalImpaired + provision - loan.impaired;
        loan.impaired = provision;
        emit LoanImpaired(loanId, provision);
    }

    /**
     * @notice Mark a loan defaulted once it is LATE_PERIOD past due. Callable by anyone.
     *         The unpaid principal is written off and charged to the borrower's backers (see
     *         {_chargeBackers}); the borrower can never borrow or back again. What slashed stake
     *         does not recover is paid from the first-loss reserve, and lenders absorb the rest
     *         through a lower share price.
     */
    function markDefaulted(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, LoanNotActive());
        require(block.timestamp > loan.disbursedAt + loan.term + LATE_PERIOD, NotYetDefaultable());

        uint256 writtenOff = loan.principal - loan.principalRepaid;
        totalLentOut -= writtenOff;
        totalImpaired -= loan.impaired;
        loan.impaired = 0;
        _outstandingPrincipal[loan.borrower] -= writtenOff;
        loan.status = LoanStatus.Defaulted;
        activeLoanCount[loan.borrower] -= 1;
        defaultedLoans[loan.borrower] += 1;
        uint256 recovered = _chargeBackers(loan.borrower, loanId, writtenOff);
        uint256 fromReserve = Math.min(writtenOff - recovered, firstLossReserve);
        firstLossReserve -= fromReserve;
        recovered += fromReserve;
        lenderCash += recovered;
        emit LoanDefaulted(loan.borrower, loanId, writtenOff, recovered);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Repay up to `amount`; any excess over the outstanding balance is not pulled.
    function repayLoan(uint256 loanId, uint256 amount) external {
        Loan storage loan = _repayableLoan(loanId);
        require(msg.sender == loan.borrower, NotBorrower());
        require(amount > 0, ZeroAmount());

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
        require(loan.borrower == borrower, WrongBorrower());

        _permit(borrower, value, deadline, v, r, s);

        uint256 spend = amount == 0 ? _roundToCent(getCurrentOutstandingAmount(loanId)) : amount;
        if (spend > value) {
            spend = value;
        }
        require(spend > 0, NothingToRepay());

        uint256 paid = _repay(loanId, loan, borrower, spend);
        emit LoanRepaid(borrower, loanId, paid);
    }

    // ───────────────────────────── credit & backing ─────────────────────────────

    /// @notice Stake USDC as secured credit to back borrowers with. Held outside the lending pool.
    function stake(uint256 amount) external {
        require(amount > 0, ZeroAmount());
        _pullUsdc(msg.sender, amount);
        stakeOf[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw stake that is not committed to backing.
    function unstake(uint256 amount) external {
        uint256 staked = stakeOf[msg.sender];
        require(amount > 0 && amount <= staked, InsufficientStake());
        require(staked - amount >= stakeCommitted[msg.sender], StakeCommitted());
        stakeOf[msg.sender] = staked - amount;
        totalStaked -= amount;
        _pushUsdc(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Back `borrower` with `amount` USDC of your own credit; a lower amount reduces the
     *         backing and 0 withdraws it. New backing commits your free granted credit first,
     *         then free stake, and your own capacity falls by exactly what the borrower gains.
     *         Backing cannot be cut below what the borrower owes on open loans. If the borrower
     *         defaults, committed stake is slashed into the pool and committed credit is burned
     *         from your granted credit.
     */
    function back(address borrower, uint256 amount) external {
        _setBacking(msg.sender, borrower, amount);
    }

    /// @notice Credit score in SCALE units: the admin override if set, otherwise the score
    ///         provider's (0 when there is none, or its scores are stale).
    function getCreditScore(address user) public view returns (uint256) {
        if (scoreOverrides[user] != 0) return scoreOverrides[user];
        if (address(scoreProvider) == address(0)) return 0;
        return Math.min(scoreProvider.creditScore(user), SCALE);
    }

    /**
     * @notice Unsecured credit `account` holds itself: its issued line (credit score x
     *         maxLoanAmount) plus the dues it has paid (interest net of the protocol fee), less the
     *         defaults charged to it as a backer. 0 once it has defaulted on a loan.
     * @dev Dues are the largest credit on-chain history can earn without an accountable issuer:
     *      any rule granting more than the value a history paid to lenders can be farmed by
     *      recycling one seed through fresh accounts (docs/CREDIT_MODEL.md, Theorem 3).
     */
    function grantedCredit(address account) public view returns (uint256) {
        if (defaultedLoans[account] != 0) return 0;
        uint256 granted = Math.mulDiv(maxLoanAmount, getCreditScore(account), SCALE) + duesPaid[account];
        uint256 lost = creditLoss[account];
        return granted > lost ? granted - lost : 0;
    }

    /**
     * @notice Max total principal across `borrower`'s open loans, and how much of it is unused:
     *         granted credit the borrower has not committed to others, plus backing received.
     */
    function getBorrowLimit(address borrower) public view returns (uint256 limit, uint256 available) {
        if (defaultedLoans[borrower] != 0) return (0, 0);
        uint256 granted = grantedCredit(borrower);
        uint256 committed = creditCommitted[borrower];
        limit = (granted > committed ? granted - committed : 0) + _backingReceived(borrower);
        uint256 owed = _activePrincipal(borrower);
        available = limit > owed ? limit - owed : 0;
    }

    /**
     * @notice What `backer` can still commit to backing: granted credit not committed or used by
     *         its own loans (which draw on backing received first), and stake not committed.
     */
    function getFreeCredit(address backer) public view returns (uint256 credit, uint256 staked) {
        (, uint256 available) = getBorrowLimit(backer);
        uint256 granted = grantedCredit(backer);
        uint256 committed = creditCommitted[backer];
        credit = Math.min(granted > committed ? granted - committed : 0, available);
        staked = stakeOf[backer] - stakeCommitted[backer];
    }

    function getBacking(address backer, address borrower) external view returns (uint256 secured, uint256 unsecured) {
        uint256 slot = _backingSlot[backer][borrower];
        if (slot == 0) return (0, 0);
        Backing storage edge = _backings[borrower][slot - 1];
        return (edge.secured, edge.unsecured);
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
        loanId = _originateLoan(req.borrower, req.amount, DEFAULT_LOAN_TERM);
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
        require(req.to == loans[req.loanId].borrower && req.to == req.borrower, MustSendToBorrower());

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
        require(currentApr <= req.maxAprBps, AprChanged());

        uint256 loanId = _originateLoan(req.borrower, req.amount, req.repaymentPeriod);
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
        require(loan.borrower == req.borrower, WrongBorrower());

        uint256 out = getCurrentOutstandingAmount(req.loanId);
        if (out < CENT) {
            _closeLoan(loan, LoanStatus.Repaid);
            emit MetaLoanRepaid(req.borrower, req.loanId, 0);
            return;
        }

        if (permit.deadline != 0) {
            _permit(req.borrower, permit);
            require(permit.value >= out, PermitValueTooLow());
        }
        if (req.amount != 0 && req.amount < out) {
            require(out - req.amount <= CENT, OutstandingChanged());
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
            require(permit.value >= req.amount, PermitValueTooLow());
        }

        require(req.receiver != address(0), ZeroAddress());

        _pullUsdc(req.lender, req.amount);
        uint256 shares = _recordDeposit(req.receiver, req.amount);
        emit MetaDeposit(req.lender, req.amount, req.receiver, shares);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Gasless deposit of exactly `permit.value`, authorized by the permit alone.
    function depositPermitOnlyMeta(address lender, PermitData calldata permit) external onlyAllowedRelayer {
        require(lender != address(0), ZeroAddress());
        require(permit.value > 0, ZeroAmount());

        _permit(lender, permit);
        _pullUsdc(lender, permit.value);
        uint256 shares = _recordDeposit(lender, permit.value);
        emit MetaDeposit(lender, permit.value, lender, shares);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /**
     * @notice Queue a gasless withdrawal of `req.amount` USDC (`type(uint256).max` for everything
     *         not already queued); it is paid immediately as far as liquidity allows. The
     *         matching shares are locked and keep earning until paid at the share price then.
     */
    function requestWithdrawalMeta(RequestWithdrawal calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.lender,
            req.nonce,
            req.deadline,
            keccak256(abi.encode(REQUEST_WITHDRAWAL_TYPEHASH, req.lender, req.amount, req.to, req.nonce, req.deadline)),
            sig
        );
        require(req.amount > 0, ZeroAmount());
        (uint256 shares, uint256 assets) = _sharesForWithdrawal(req.lender, req.amount);
        queuedShares[req.lender] += shares;
        totalQueuedShares += shares;

        uint256 queueId = withdrawalQueue.length;
        withdrawalQueue.push(WithdrawalQueueItem({ lender: req.lender, to: req.to, shares: shares, active: true }));
        emit MetaWithdrawalRequested(req.lender, queueId, assets, req.to);

        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /// @notice Pays up to `maxItems` queued withdrawals from available liquidity. Anyone may call
    ///         it; payouts only ever go to each request's signed recipient.
    function processWithdrawalQueue(uint256 maxItems) external {
        _tryFillWithdrawalQueue(maxItems);
    }

    /// @notice Gasless {back} signed by the backer.
    function backMeta(BackRequest calldata req, bytes calldata sig) external onlyAllowedRelayer {
        _verifyMeta(
            req.backer,
            req.nonce,
            req.deadline,
            keccak256(abi.encode(BACK_REQUEST_TYPEHASH, req.backer, req.borrower, req.amount, req.nonce, req.deadline)),
            sig
        );
        _setBacking(req.backer, req.borrower, req.amount);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Borrower APR (EFFR + premium) in BASIS_POINTS.
    function getLoanRate() external view returns (uint256) {
        return effrRate + riskPremium;
    }

    /// @notice Projected lender APY in BASIS_POINTS: loan rate x pool utilisation, net of the
    ///         protocol fee and the reserve share, before default losses. Realised only as
    ///         borrowers repay.
    function getFundingPoolAPY() external view returns (uint256) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        uint256 utilisationBp = ((totalLentOut + reservedLiquidity) * BASIS_POINTS) / assets;
        uint256 grossBp = ((effrRate + riskPremium) * utilisationBp) / BASIS_POINTS;
        return (grossBp * (BASIS_POINTS - protocolFeeBps - reserveBps)) / BASIS_POINTS;
    }

    /// @notice USDC the lenders own: cash held for them plus principal still owed by borrowers,
    ///         less what is provisioned against overdue loans (see {impairLoan}).
    function totalAssets() public view returns (uint256) {
        return lenderCash + totalLentOut - totalImpaired;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Current USDC value of `lender`'s shares, queued ones included.
    function lenderBalance(address lender) public view returns (uint256) {
        return convertToAssets(sharesOf[lender]);
    }

    /// @notice Current USDC value of `lender`'s shares waiting in the withdrawal queue.
    function queuedWithdrawals(address lender) external view returns (uint256) {
        return convertToAssets(queuedShares[lender]);
    }

    /// @notice USDC owed to the withdrawal queue, held back from new loans and direct withdrawals.
    function totalQueuedWithdrawals() public view returns (uint256) {
        return convertToAssets(totalQueuedShares);
    }

    /**
     * @return _totalAssets    USDC owned by lenders (see {totalAssets})
     * @return _availableFunds Liquid USDC not reserved for loans or owed to the withdrawal queue
     * @return _reservedFunds  USDC reserved for approved, undisbursed loans
     * @return _lenderCount    Unique depositors
     */
    function getPoolInfo()
        external
        view
        returns (uint256 _totalAssets, uint256 _availableFunds, uint256 _reservedFunds, uint256 _lenderCount)
    {
        _totalAssets = totalAssets();
        _reservedFunds = reservedLiquidity;
        uint256 committed = _reservedFunds + totalQueuedWithdrawals();
        _availableFunds = lenderCash > committed ? lenderCash - committed : 0;
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
        isActive = _isOpen(loan);
        outstanding = isActive ? getCurrentOutstandingAmount(loanId) : 0;
        return (loan.principal, outstanding, loan.borrower, loan.interestRate, isActive);
    }

    /// @notice Lifecycle and schedule of a loan; `disbursedAt` and `dueAt` are 0 until disbursement.
    function getLoanTerms(uint256 loanId)
        external
        view
        returns (LoanStatus status, uint256 term, uint256 requestedAt, uint256 disbursedAt, uint256 dueAt)
    {
        Loan storage loan = loans[loanId];
        dueAt = loan.disbursedAt == 0 ? 0 : loan.disbursedAt + loan.term;
        return (loan.status, loan.term, loan.requestedAt, loan.disbursedAt, dueAt);
    }

    /**
     * @notice Principal plus simple interest accrued since origination, less repayments.
     * @dev No interest accrues during the first day. Interest keeps accruing on the original
     *      principal until the loan closes; partial repayments reduce the balance, not the base.
     */
    function getCurrentOutstandingAmount(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        require(_isOpen(loan), LoanClosed());

        uint256 owed = loan.principal + _interestAccrued(loan);
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

    /// @notice Every address that has ever backed a borrower.
    function getBackers() external view returns (address[] memory) {
        return _backers;
    }

    /// @notice Every address that has ever been backed.
    function getBackedBorrowers() external view returns (address[] memory) {
        return _backedBorrowers;
    }

    function getBackings(address borrower) external view returns (Backing[] memory) {
        return _backings[borrower];
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev Checks deadline, consumes the signer's nonce, and verifies an EIP-712 signature
    ///      (EOA or ERC-1271 wallet) over `structHash`.
    function _verifyMeta(address signer, uint256 nonce, uint256 deadline, bytes32 structHash, bytes calldata sig)
        internal
    {
        require(block.timestamp <= deadline, SignatureExpired());
        require(nonce == nonces[signer]++, InvalidNonce());
        require(SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), sig), InvalidSignature());
    }

    function _permit(address holder, PermitData calldata permit) internal {
        _permit(holder, permit.value, permit.deadline, permit.v, permit.r, permit.s);
    }

    /// @dev Anyone can submit a permit signature first (e.g. by watching the mempool), which makes
    ///      the relayed permit() revert on a used nonce. Proceed when the allowance is already set.
    function _permit(address holder, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        try IERC20Permit(address(usdc)).permit(holder, address(this), value, deadline, v, r, s) { }
        catch {
            require(usdc.allowance(holder, address(this)) >= value, PermitFailed());
        }
    }

    function _pullUsdc(address from, uint256 amount) internal {
        usdc.safeTransferFrom(from, address(this), amount);
    }

    function _pushUsdc(address to, uint256 amount) internal {
        usdc.safeTransfer(to, amount);
    }

    /// @dev Mints shares for `assets` already pulled in, at the current share price.
    function _recordDeposit(address lender, uint256 assets) internal returns (uint256 shares) {
        shares = convertToShares(assets);
        require(shares > 0, ZeroShares());
        sharesOf[lender] += shares;
        totalShares += shares;
        lenderCash += assets;
        lenderPrincipal[lender] += assets;
        if (!isLender[lender]) {
            isLender[lender] = true;
            lenderCount += 1;
            _lenders.push(lender);
        }
        emit Deposited(lender, assets, shares);
    }

    /// @dev Burns `shares` of `lender`'s and sends `assets` to `to`.
    function _payOut(address lender, address to, uint256 assets, uint256 shares) internal {
        lenderPrincipal[lender] -= Math.mulDiv(lenderPrincipal[lender], shares, sharesOf[lender]);
        sharesOf[lender] -= shares;
        totalShares -= shares;
        lenderCash -= assets;
        _pushUsdc(to, assets);
        emit Withdrawn(lender, to, assets, shares);
    }

    /// @dev Shares worth at least `assets`; used whenever shares are burned for a USDC amount.
    function _convertToSharesRoundingUp(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS, Math.Rounding.Ceil);
    }

    /**
     * @dev Shares to burn (rounded up) and USDC to pay for withdrawing `amount` of `lender`'s
     *      unqueued balance; `type(uint256).max` withdraws all of it.
     */
    function _sharesForWithdrawal(address lender, uint256 amount)
        internal
        view
        returns (uint256 shares, uint256 assets)
    {
        uint256 free = sharesOf[lender] - queuedShares[lender];
        if (amount == type(uint256).max) {
            shares = free;
            assets = convertToAssets(shares);
        } else {
            shares = _convertToSharesRoundingUp(amount);
            assets = amount;
        }
        require(shares > 0 && shares <= free, InsufficientBalance());
    }

    /// @dev Principal still owed across the borrower's open (requested or active) loans.
    function _activePrincipal(address borrower) internal view returns (uint256) {
        return _outstandingPrincipal[borrower];
    }

    function _isOpen(Loan storage loan) internal view returns (bool) {
        return loan.status == LoanStatus.Requested || loan.status == LoanStatus.Active;
    }

    /**
     * @dev Single origination path for requestLoan, requestLoanMeta and borrowAndDisburseMeta.
     *      Enforces the borrower's credit limit across open loans, the pool utilisation cap and
     *      the liquidity buffer, then reserves the principal.
     */
    function _originateLoan(address borrower, uint256 amount, uint256 term) internal returns (uint256 loanId) {
        require(amount > 0, ZeroAmount());
        require(term >= MIN_LOAN_TERM && term <= MAX_LOAN_TERM, InvalidTerm());
        require(defaultedLoans[borrower] == 0, BorrowerInDefault());
        (uint256 limit, uint256 available) = getBorrowLimit(borrower);
        require(limit > 0, NoCredit());
        require(amount <= available, BorrowLimitExceeded());

        uint256 assets = totalAssets();
        uint256 maxCommitment = (assets * lendingUtilizationCap) / BASIS_POINTS;
        require(reservedLiquidity + totalLentOut + amount <= maxCommitment, UtilisationCapExceeded());

        uint256 bufferRequired = (assets * liquidityBuffer) / BASIS_POINTS;
        require(
            lenderCash - reservedLiquidity >= amount + totalQueuedWithdrawals() + bufferRequired + liquidityThreshold,
            InsufficientLiquidity()
        );

        reservedLiquidity += amount;

        loanId = nextLoanId++;
        loans[loanId] = Loan({
            principal: amount,
            repaid: 0,
            principalRepaid: 0,
            borrower: borrower,
            interestRate: effrRate + riskPremium,
            term: term,
            requestedAt: block.timestamp,
            disbursedAt: 0,
            status: LoanStatus.Requested,
            impaired: 0
        });

        _allLoanIds.push(loanId);
        if (!_borrowerSeen[borrower]) {
            _borrowerSeen[borrower] = true;
            _borrowers.push(borrower);
        }
        _borrowerLoans[borrower].push(loanId);
        activeLoanCount[borrower] += 1;
        _outstandingPrincipal[borrower] += amount;
        emit LoanRequested(borrower, loanId, amount, effrRate + riskPremium);
    }

    /// @dev Moves a reserved loan's principal to `to`. Callers decide who may receive it.
    function _disburseLoan(uint256 loanId, address to) internal returns (uint256 principal) {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Requested, LoanNotRequested());
        loan.status = LoanStatus.Active;
        loan.disbursedAt = block.timestamp;

        principal = loan.principal;
        reservedLiquidity -= principal;
        lenderCash -= principal;
        totalLentOut += principal;
        _pushUsdc(to, principal);
        emit LoanDisbursed(loan.borrower, loanId, to, principal);
    }

    function _repayableLoan(uint256 loanId) internal view returns (Loan storage loan) {
        loan = loans[loanId];
        require(loan.status == LoanStatus.Active, LoanNotActive());
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

            uint256 interestDue = _interestAccrued(loan) - (loan.repaid - loan.principalRepaid);
            uint256 interest = paid < interestDue ? paid : interestDue;
            uint256 principal = paid - interest;
            uint256 fee = (interest * protocolFeeBps) / BASIS_POINTS;
            uint256 toReserve = (interest * reserveBps) / BASIS_POINTS;

            loan.repaid += paid;
            loan.principalRepaid += principal;
            totalLentOut -= principal;
            uint256 recovered = Math.min(principal, loan.impaired);
            loan.impaired -= recovered;
            totalImpaired -= recovered;
            _outstandingPrincipal[loan.borrower] -= principal;
            duesPaid[loan.borrower] += interest - fee;
            lenderCash += paid - fee - toReserve;
            protocolFees += fee;
            firstLossReserve += toReserve;
            emit RepaymentApplied(loanId, interest, principal, fee);
        }
        if (owed - paid < CENT) {
            _closeLoan(loan, LoanStatus.Repaid);
        }
        _tryFillWithdrawalQueue(QUEUE_FILLS_PER_CALL);
    }

    /**
     * @dev Closes a repaid or cancelled loan. For a repaid loan, any principal still unpaid
     *      (under a cent, see {_repay}) is written off; a cancelled loan was never lent out.
     */
    function _closeLoan(Loan storage loan, LoanStatus status) internal {
        uint256 unpaid = loan.principal - loan.principalRepaid;
        if (status == LoanStatus.Repaid) {
            totalLentOut -= unpaid;
            totalImpaired -= loan.impaired;
            loan.impaired = 0;
            completedLoans[loan.borrower] += 1;
        }
        _outstandingPrincipal[loan.borrower] -= unpaid;
        activeLoanCount[loan.borrower] -= 1;
        loan.status = status;
    }

    /**
     * @dev Charges a default's `loss` to `borrower`'s backers: secured backing first (stake
     *      slashed, pro rata, and returned to the pool), then unsecured backing (granted credit
     *      burned via creditLoss, pro rata). Anything left falls on lenders. Charged backing is
     *      consumed; the rest is released once the borrower has no open loans, and otherwise
     *      keeps backing those. Returns the stake recovered.
     */
    function _chargeBackers(address borrower, uint256 loanId, uint256 loss) internal returns (uint256 recovered) {
        Backing[] storage edges = _backings[borrower];
        uint256 totalSecured = 0;
        uint256 totalUnsecured = 0;
        for (uint256 i = 0; i < edges.length; i++) {
            totalSecured += edges[i].secured;
            totalUnsecured += edges[i].unsecured;
        }
        uint256 fromStake = Math.min(loss, totalSecured);
        uint256 fromCredit = Math.min(loss - fromStake, totalUnsecured);
        bool release = activeLoanCount[borrower] == 0;

        for (uint256 i = 0; i < edges.length; i++) {
            Backing storage edge = edges[i];
            address backer = edge.backer;
            uint256 slashed = fromStake == 0 ? 0 : Math.mulDiv(fromStake, edge.secured, totalSecured);
            uint256 charged = fromCredit == 0 ? 0 : Math.mulDiv(fromCredit, edge.unsecured, totalUnsecured);
            if (slashed > 0) {
                stakeOf[backer] -= slashed;
                totalStaked -= slashed;
                recovered += slashed;
            }
            if (charged > 0) creditLoss[backer] += charged;

            uint256 releasedSecured = release ? edge.secured : slashed;
            uint256 releasedUnsecured = release ? edge.unsecured : charged;
            stakeCommitted[backer] -= releasedSecured;
            creditCommitted[backer] -= releasedUnsecured;
            edge.secured -= releasedSecured;
            edge.unsecured -= releasedUnsecured;
            if (slashed > 0 || charged > 0) emit BackerCharged(backer, loanId, slashed, charged);
        }
    }

    /**
     * @dev Backing `borrower` receives. Unsecured backing counts only as far as its backer's
     *      granted credit, net of the backer's own outstanding loans, still covers everything
     *      the backer committed, so credit that a backer has lost cannot keep backing anyone.
     */
    function _backingReceived(address borrower) internal view returns (uint256 total) {
        Backing[] storage edges = _backings[borrower];
        for (uint256 i = 0; i < edges.length; i++) {
            Backing storage edge = edges[i];
            total += edge.secured;
            if (edge.unsecured == 0) continue;
            address backer = edge.backer;
            uint256 committed = creditCommitted[backer];
            uint256 granted = grantedCredit(backer);
            uint256 owed = _activePrincipal(backer);
            uint256 cover = granted > owed ? granted - owed : 0;
            total += cover >= committed ? edge.unsecured : Math.mulDiv(edge.unsecured, cover, committed);
        }
    }

    /// @dev Simple interest on the original principal since disbursement; none in the first day.
    function _interestAccrued(Loan storage loan) internal view returns (uint256) {
        if (loan.disbursedAt == 0) return 0;
        uint256 elapsed = block.timestamp - loan.disbursedAt;
        if (elapsed < GRACE_PERIOD) return 0;
        return (((loan.principal * loan.interestRate) / BASIS_POINTS) * elapsed) / SECONDS_PER_YEAR;
    }

    /// @dev Sets `backer`'s backing of `borrower` to `amount` (see {back}).
    function _setBacking(address backer, address borrower, uint256 amount) internal {
        require(borrower != backer, SelfBacking());
        Backing[] storage edges = _backings[borrower];
        uint256 slot = _backingSlot[backer][borrower];
        if (slot == 0) {
            require(edges.length < MAX_BACKERS_PER_BORROWER, TooManyBackers());
            edges.push(Backing({ backer: backer, secured: 0, unsecured: 0 }));
            slot = edges.length;
            _backingSlot[backer][borrower] = slot;
            if (slot == 1) _backedBorrowers.push(borrower);
            if (!_backerSeen[backer]) {
                _backerSeen[backer] = true;
                _backers.push(backer);
            }
        }
        Backing storage edge = edges[slot - 1];
        uint256 current = edge.secured + edge.unsecured;

        if (amount > current) {
            uint256 extra = amount - current;
            (uint256 freeCredit, uint256 freeStake) = getFreeCredit(backer);
            uint256 fromCredit = Math.min(extra, freeCredit);
            require(extra - fromCredit <= freeStake, InsufficientCredit());
            edge.unsecured += fromCredit;
            edge.secured += extra - fromCredit;
            creditCommitted[backer] += fromCredit;
            stakeCommitted[backer] += extra - fromCredit;
        } else if (amount < current) {
            // Release unsecured backing before secured, so a stake-backed loan stays secured.
            uint256 cutAmount = current - amount;
            uint256 fromCredit = Math.min(cutAmount, edge.unsecured);
            edge.unsecured -= fromCredit;
            edge.secured -= cutAmount - fromCredit;
            creditCommitted[backer] -= fromCredit;
            stakeCommitted[backer] -= cutAmount - fromCredit;
            (uint256 limit,) = getBorrowLimit(borrower);
            require(_activePrincipal(borrower) <= limit, BackingInUse());
        }
        emit Backed(backer, borrower, edge.secured, edge.unsecured);
    }

    /**
     * @dev Pays up to `maxItems` queued withdrawals in FIFO order from liquidity not reserved for
     *      loans, at the current share price. The liquidity buffer exists for exits, so the queue
     *      may use it. Called from every path that adds liquidity, and before direct withdrawals.
     */
    function _tryFillWithdrawalQueue(uint256 maxItems) internal {
        for (uint256 visited = 0; visited < maxItems && withdrawalHead < withdrawalQueue.length; visited++) {
            WithdrawalQueueItem storage item = withdrawalQueue[withdrawalHead];
            if (!item.active || item.shares == 0) {
                item.active = false;
                withdrawalHead++;
                continue;
            }

            uint256 liquid = lenderCash - reservedLiquidity;
            if (liquid < CENT) break;

            uint256 owed = convertToAssets(item.shares);
            uint256 pay = owed;
            uint256 burn = item.shares;
            if (owed > liquid) {
                pay = liquid;
                burn = Math.min(_convertToSharesRoundingUp(pay), item.shares);
            }

            queuedShares[item.lender] -= burn;
            totalQueuedShares -= burn;
            item.shares -= burn;
            _payOut(item.lender, item.to, pay, burn);
            emit MetaWithdrawalFilled(withdrawalHead, pay);

            if (item.shares != 0) break; // partial fill; resume on the next liquidity event
            item.active = false;
            withdrawalHead++;
        }
    }

    function _roundToCent(uint256 x) internal pure returns (uint256) {
        return ((x + CENT / 2) / CENT) * CENT;
    }
}
