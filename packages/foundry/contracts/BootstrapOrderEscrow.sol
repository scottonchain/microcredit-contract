// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { DecentralizedMicrocredit } from "./DecentralizedMicrocredit.sol";

/**
 * @notice Testnet adapter: a consenting customer's funded order pays a named loan first.
 * @dev The worker names this contract as its pool manager (`setManager`) before any backing exists, so
 *      the pool refuses every origination for the worker that does not come from here. The customer's
 *      funding commits to the exact pool intent (pool, token, worker, vendor, amount, term, max APR,
 *      pool nonce and deadline, job hash); the worker signs the same intent; `originate` verifies both,
 *      submits the worker's signed pool request and binds the new loan to the order in one transaction.
 *      So a loan made before the order cannot be attached to it, and a refund consumes the commitment:
 *      after it the signed advance cannot be broadcast anywhere (the pool gate refuses any other caller).
 *      Delivery acceptance is the customer's decision, not an oracle: rejection refunds the customer and
 *      leaves a disbursed loan and any sponsor loss unchanged. Not a human-lending release.
 */
contract BootstrapOrderEscrow is EIP712, ReentrancyGuard {
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

    DecentralizedMicrocredit public immutable pool;
    IERC20 public immutable token;
    uint256 public nextOrderId = 1;
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
    error InvalidConsent();
    error IntentMismatch();
    error NotManager();
    error DebtExceedsCap();
    error DebtNotCleared();
    error WrongFunding();

    event Funded(
        uint256 indexed orderId, address indexed payer, address indexed worker, uint256 price, bytes32 intentHash
    );
    event Originated(uint256 indexed orderId, uint256 indexed loanId);
    event Settled(uint256 indexed orderId, uint256 debtPaid, uint256 workerPaid);
    event Refunded(uint256 indexed orderId, uint256 amount);

    constructor(DecentralizedMicrocredit pool_) EIP712("BootstrapOrderEscrow", "2") {
        pool = pool_;
        token = pool_.usdc();
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
            i.worker == address(0) || i.worker == address(this) || i.vendor == address(0) || i.amount == 0 || price == 0
                || maxDebt < i.amount || maxDebt > price || settleBy <= block.timestamp || i.deadline <= block.timestamp
        ) revert InvalidOrder();
        id = nextOrderId++;
        bytes32 h = intentHash(i);
        orders[id] = Order(msg.sender, price, maxDebt, settleBy, h, 0, State.Funded);
        _intents[id] = i;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), price);
        if (token.balanceOf(address(this)) - beforeBalance != price) revert WrongFunding();
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
     * @notice Verify the worker's two signatures, submit its signed pool request as the pool manager and
     *         bind the new loan to the order, atomically. Anyone may call; the worker needs no ETH.
     * @param req The worker's pool request; every field must equal the funded intent.
     * @param poolSig The worker's signature for the pool (`BorrowAndDisburse`).
     * @param orderSig The worker's signature of this adapter's `AcceptOrder`.
     */
    function originate(
        uint256 id,
        DecentralizedMicrocredit.BorrowAndDisburse calldata req,
        bytes calldata poolSig,
        bytes calldata orderSig
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
        if (pool.managerOf(i.worker) != address(this)) revert NotManager();
        if (!SignatureChecker.isValidSignatureNow(i.worker, acceptanceDigest(id), orderSig)) revert InvalidConsent();

        o.state = State.Bound; // before the external call
        pool.borrowAndDisburseMeta(req, poolSig);

        uint256[] memory ids = pool.getBorrowerLoanIds(i.worker);
        loanId = ids[ids.length - 1];
        (uint256 principal,, address borrower,,) = pool.getLoan(loanId);
        if (borrower != i.worker || principal != i.amount || loanOrder[loanId] != 0) revert InvalidLoan();
        o.loanId = loanId;
        loanOrder[loanId] = id;
        emit Originated(id, loanId);
    }

    /// @notice Customer acceptance of delivery clears the debt first, then pays the worker the remainder.
    function settle(uint256 id) external nonReentrant {
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
    }

    /// @notice The customer may reject at any time; anyone may return an expired order to its payer.
    /// @dev Refund consumes the commitment: an unoriginated order can never originate afterwards, and with this
    ///      adapter as the worker's manager the pool refuses the signed advance from any other caller. A loan
    ///      already disbursed stays the worker's debt (the sponsor's stake takes any loss): refund never forgives it.
    function refund(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.state != State.Funded && o.state != State.Bound) revert InvalidOrder();
        if (msg.sender != o.payer && block.timestamp <= o.settleBy) revert Unauthorized();
        o.state = State.Refunded;
        token.safeTransfer(o.payer, o.price);
        emit Refunded(id, o.price);
    }
}
