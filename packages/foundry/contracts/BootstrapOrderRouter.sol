// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DecentralizedMicrocredit } from "./DecentralizedMicrocredit.sol";
import { StakeRouterBase } from "./TransitiveStakeRouter.sol";

/**
 * @notice The bootstrap product on one manager: a consenting customer's funded order pays a named loan first,
 *         and the loan is backed by roots' stake through the two-hop router. Testnet only; not a
 *         human-lending release.
 * @dev A worker (a borrower with no credit and no ETH) names this contract as its only pool manager before any
 *      backing exists. From then on the pool refuses every origination for it that does not come from here, and
 *      this contract has exactly one origination entry, `originateOrder`: there is no unbound path that skips the
 *      order. `originateOrder` verifies the customer's funded commitment (pool, token, worker, vendor, amount,
 *      term, max APR, pool nonce and deadline, job hash) against the worker's signed pool request and the
 *      worker's acceptance, then in one transaction reserves the roots' USDC along their consented paths, backs
 *      the worker with it as secured backing from a per-worker vault, submits the signed request and binds the
 *      loan to the order. `settleOrder` (the customer's acceptance) repays the loan's current debt out of the
 *      order's escrow first and pays the worker the remainder; `refundOrder` returns the escrow and never erases
 *      a disbursed loan or a root's loss. Two ledgers share the contract and never mix: roots' deposits
 *      (`free`/`locked`) and customers' escrow (`totalEscrowHeld`); origination never treats escrow as backing and
 *      a root can withdraw only from `free`.
 *      The accounting identity: `token.balanceOf(this) = totalFree + totalEscrowHeld + identified stray transfers`.
 *      Second gate, the credit officer (an AI agent's key, or a contract that wraps it): an order originates only
 *      with that officer's one-order `JobApproval` (order, intent hash, maximum amount, expiry, policy version and
 *      officer epoch). The two gates are separate and both must pass: the roots' consents and balances (the graph)
 *      set the ceiling, re-derived at execution and never read from the approval; the approval can only refuse or
 *      stay at or above the order's amount, so it cannot create, raise, move or revive capacity. The officer and
 *      its admin touch no ledger and no consent; revoking or rotating the officer (a new epoch) voids unused
 *      approvals and stops new admissions only: settlement, refund, sync, repayment and a root's withdrawal read no
 *      officer state. The router starts with no officer, so nothing originates until the admin sets one.
 */
contract BootstrapOrderRouter is StakeRouterBase {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Funded,
        Bound,
        Settled,
        Refunded
    }

    /// @dev What the customer pays for and the worker agrees to: the pool request, field for field.
    struct Intent {
        address worker;
        address vendor;
        uint256 amount;
        uint256 term;
        uint256 maxAprBps;
        uint256 nonce; // the worker's pool nonce the signed request uses
        uint256 deadline; // the signed pool request's deadline: the origination window
        bytes32 jobHash;
    }

    struct Order {
        address payer;
        uint256 price;
        uint256 maxDebt;
        uint256 settleBy; // settlement window; after it anyone may return the funds to the payer
        bytes32 intentHash;
        uint256 loanId;
        State state;
    }

    /// @dev The officer's one-order approval: bound to the order and its intent hash, with a ceiling on the amount.
    struct JobApproval {
        uint256 orderId;
        bytes32 intentHash;
        uint256 maxAmount;
        uint256 expiry;
        uint256 policyVersion;
        uint256 officerEpoch;
    }

    struct Approval {
        uint256 maxAmount;
        uint256 expiry;
        uint256 policyVersion;
        uint256 officerEpoch;
    }

    address public officer; // zero: no officer, no admissions (fail closed)
    address public officerAdmin; // sets or revokes the officer; touches no ledger and no consent
    uint256 public officerEpoch = 1;
    uint256 public policyVersion = 1;
    mapping(uint256 => Approval) public approvals;

    uint256 public nextOrderId = 1;
    /// @notice Customers' USDC held for open orders (Funded or Bound); disjoint from the roots' `free` and `locked`.
    uint256 public totalEscrowHeld;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => Intent) internal _intents;
    mapping(uint256 => uint256) public loanOrder;

    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "OrderIntent(address pool,address token,address worker,address vendor,uint256 amount,uint256 term,uint256 maxAprBps,uint256 nonce,uint256 deadline,bytes32 jobHash)"
    );
    bytes32 public constant ACCEPT_TYPEHASH = keccak256(
        "AcceptOrder(uint256 orderId,address payer,uint256 price,uint256 maxDebt,uint256 settleBy,bytes32 intentHash)"
    );

    error InvalidOrder();
    error Unauthorized();
    error InvalidLoan();
    error IntentMismatch();
    error DebtExceedsCap();
    error DebtNotCleared();
    error NoApproval();
    error ApprovalTooSmall();
    error NotOfficerAdmin();

    event Funded(
        uint256 indexed orderId, address indexed payer, address indexed worker, uint256 price, bytes32 intentHash
    );
    event Originated(uint256 indexed orderId, uint256 indexed loanId);
    event Settled(uint256 indexed orderId, uint256 debtPaid, uint256 workerPaid);
    event Refunded(uint256 indexed orderId, uint256 amount);
    event OfficerSet(address indexed officer, uint256 epoch, uint256 policyVersion);
    event OfficerAdminSet(address indexed admin);
    event OrderApproved(uint256 indexed orderId, uint256 maxAmount, uint256 expiry);

    bytes32 public constant APPROVAL_TYPEHASH = keccak256(
        "JobApproval(uint256 orderId,bytes32 intentHash,uint256 maxAmount,uint256 expiry,uint256 policyVersion,uint256 officerEpoch)"
    );

    constructor(DecentralizedMicrocredit pool_) StakeRouterBase(pool_) EIP712("BootstrapOrderRouter", "1") {
        officerAdmin = msg.sender;
        emit OfficerAdminSet(msg.sender);
    }

    modifier onlyOfficerAdmin() {
        if (msg.sender != officerAdmin) revert NotOfficerAdmin();
        _;
    }

    /// @notice Name the officer and the policy version approvals must carry. A new epoch voids every approval not yet
    ///         used. Moves no funds and changes no consent.
    function setOfficer(address newOfficer, uint256 newPolicyVersion) external onlyOfficerAdmin {
        officer = newOfficer;
        policyVersion = newPolicyVersion;
        unchecked {
            ++officerEpoch;
        }
        emit OfficerSet(newOfficer, officerEpoch, newPolicyVersion);
    }

    /// @notice Stop new admissions at once: the admin or the officer itself clears the officer and voids unused approvals.
    function revokeOfficer() external {
        if (msg.sender != officerAdmin && msg.sender != officer) revert NotOfficerAdmin();
        officer = address(0);
        unchecked {
            ++officerEpoch;
        }
        emit OfficerSet(address(0), officerEpoch, policyVersion);
    }

    function setOfficerAdmin(address newAdmin) external onlyOfficerAdmin {
        officerAdmin = newAdmin;
        emit OfficerAdminSet(newAdmin);
    }

    function approvalDigest(JobApproval memory a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    APPROVAL_TYPEHASH, a.orderId, a.intentHash, a.maxAmount, a.expiry, a.policyVersion, a.officerEpoch
                )
            )
        );
    }

    /// @notice Record the officer's signed approval for one funded order. Anyone may submit it. It binds the order
    ///         and its intent hash and carries the officer epoch and policy version it was signed under.
    function approveOrder(JobApproval calldata a, bytes calldata officerSig) external {
        Order storage o = orders[a.orderId];
        if (o.state != State.Funded) revert InvalidOrder();
        if (
            officer == address(0) || a.intentHash != o.intentHash || a.officerEpoch != officerEpoch
                || a.policyVersion != policyVersion || a.expiry <= block.timestamp || a.maxAmount == 0
        ) revert NoApproval();
        if (!SignatureChecker.isValidSignatureNow(officer, approvalDigest(a), officerSig)) revert InvalidConsent();
        approvals[a.orderId] = Approval(a.maxAmount, a.expiry, a.policyVersion, a.officerEpoch);
        emit OrderApproved(a.orderId, a.maxAmount, a.expiry);
    }

    function intentHash(Intent memory i) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                address(pool),
                address(token),
                i.worker,
                i.vendor,
                i.amount,
                i.term,
                i.maxAprBps,
                i.nonce,
                i.deadline,
                i.jobHash
            )
        );
    }

    /// @notice Customer funds an order and commits to the exact pool intent. `price` is held until settlement
    ///         or refund; `maxDebt` caps what may be repaid out of it.
    function fund(Intent calldata i, uint256 price, uint256 maxDebt, uint256 settleBy)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (
            i.worker == address(0) || i.worker == address(this) || i.vendor == address(0) || i.vendor == address(this)
                || i.amount == 0 || price == 0 || maxDebt < i.amount || maxDebt > price || settleBy <= block.timestamp
                || i.deadline <= block.timestamp
        ) revert InvalidOrder();
        id = nextOrderId++;
        bytes32 h = intentHash(i);
        orders[id] = Order(msg.sender, price, maxDebt, settleBy, h, 0, State.Funded);
        _intents[id] = i;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), price);
        if (token.balanceOf(address(this)) - beforeBalance != price) revert WrongFunding();
        totalEscrowHeld += price;
        emit Funded(id, msg.sender, i.worker, price, h);
    }

    function intentOf(uint256 id) external view returns (Intent memory) {
        return _intents[id];
    }

    /// @notice What the worker signs to accept the order: the customer, the price, the cap, the window and the intent.
    function acceptanceDigest(uint256 id) public view returns (bytes32) {
        Order memory o = orders[id];
        return _hashTypedDataV4(
            keccak256(abi.encode(ACCEPT_TYPEHASH, id, o.payer, o.price, o.maxDebt, o.settleBy, o.intentHash))
        );
    }

    /**
     * @notice Verify the worker's two signatures and the roots' consents, back the worker with the roots' stake,
     *         submit the worker's signed pool request as the pool manager and bind the new loan to the order,
     *         atomically. Anyone may call; the worker and the roots' signers need no ETH.
     * @param req The worker's pool request; every field must equal the funded intent.
     * @param poolSig The worker's signature for the pool (`BorrowAndDisburse`).
     * @param orderSig The worker's signature of this contract's `AcceptOrder`.
     * @param paths One to MAX_PATHS root-mid paths whose amounts sum to `req.amount`.
     */
    function originateOrder(
        uint256 id,
        DecentralizedMicrocredit.BorrowAndDisburse calldata req,
        bytes calldata poolSig,
        bytes calldata orderSig,
        Path[] calldata paths
    ) external nonReentrant returns (uint256 loanId) {
        Order storage o = orders[id];
        Intent storage i = _intents[id];
        if (o.state != State.Funded || block.timestamp > o.settleBy || block.timestamp > i.deadline) {
            revert InvalidOrder();
        }
        if (
            req.borrower != i.worker || req.to != i.vendor || req.amount != i.amount || req.repaymentPeriod != i.term
                || req.maxAprBps != i.maxAprBps || req.nonce != i.nonce || req.deadline != i.deadline
        ) revert IntentMismatch();
        if (!SignatureChecker.isValidSignatureNow(i.worker, acceptanceDigest(id), orderSig)) revert InvalidConsent();
        {
            // the officer gate: a live approval under the current epoch and policy, for at least this amount
            Approval memory ap = approvals[id];
            if (
                officer == address(0) || ap.officerEpoch != officerEpoch || ap.policyVersion != policyVersion
                    || ap.expiry < block.timestamp
            ) revert NoApproval();
            if (req.amount > ap.maxAmount) revert ApprovalTooSmall();
        }
        delete approvals[id]; // one order, one use

        o.state = State.Bound; // before the external calls
        loanId = _originateLot(req, poolSig, paths);
        if (loanOrder[loanId] != 0) revert InvalidLoan();
        o.loanId = loanId;
        loanOrder[loanId] = id;
        emit Originated(id, loanId);
    }

    /// @notice Customer acceptance of delivery clears the debt first, then pays the worker the remainder, then
    ///         returns the roots' lot (the loan is closed).
    function settleOrder(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (msg.sender != o.payer) revert Unauthorized();
        if (o.state != State.Bound || block.timestamp > o.settleBy) revert InvalidOrder();
        (DecentralizedMicrocredit.LoanStatus status,,,,) = pool.getLoanTerms(o.loanId);
        if (
            status != DecentralizedMicrocredit.LoanStatus.Active && status != DecentralizedMicrocredit.LoanStatus.Repaid
        ) revert InvalidLoan();
        uint256 debt = pool.getCurrentOutstandingAmount(o.loanId);
        if (debt > o.maxDebt || debt > o.price) revert DebtExceedsCap();
        o.state = State.Settled;
        totalEscrowHeld -= o.price;
        if (debt != 0) {
            token.forceApprove(address(pool), debt);
            pool.repayLoan(o.loanId, debt);
            token.forceApprove(address(pool), 0);
        }
        (,,,, bool active) = pool.getLoan(o.loanId);
        if (active) revert DebtNotCleared();
        address worker = _intents[id].worker;
        token.safeTransfer(worker, o.price - debt);
        emit Settled(id, debt, o.price - debt);
        _sync(worker); // the loan is closed: the roots' lot comes back now, not when somebody remembers
    }

    /// @notice The customer may reject at any time; anyone may return an expired order to its payer.
    /// @dev Refund consumes the commitment: an unoriginated order can never originate afterwards, and with this
    ///      contract as the worker's only manager the pool refuses the signed advance from any other caller. A loan
    ///      already disbursed stays the worker's debt and the roots' exposure: refund never forgives it.
    function refundOrder(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.state != State.Funded && o.state != State.Bound) revert InvalidOrder();
        if (msg.sender != o.payer && block.timestamp <= o.settleBy) revert Unauthorized();
        o.state = State.Refunded;
        totalEscrowHeld -= o.price;
        token.safeTransfer(o.payer, o.price);
        emit Refunded(id, o.price);
    }
}
