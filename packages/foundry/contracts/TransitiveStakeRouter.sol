// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { DecentralizedMicrocredit } from "./DecentralizedMicrocredit.sol";

/**
 * @notice Holds one borrower's backing for the router. It is the pool's only counterparty for that
 *         borrower: the router sends it the USDC of a loan's lot, it stakes the lot and backs the
 *         borrower with it (secured, since it holds no granted credit), and when the loan has closed
 *         it unbacks, unstakes and returns whatever the pool did not slash. What comes back is the
 *         exact USDC the lot kept, so the router needs nothing from the pool but its public views.
 */
contract StakeVault {
    using SafeERC20 for IERC20;

    DecentralizedMicrocredit public immutable pool;
    IERC20 public immutable token;
    address public immutable router;

    error NotRouter();

    constructor(DecentralizedMicrocredit pool_, IERC20 token_) {
        pool = pool_;
        token = token_;
        router = msg.sender;
    }

    /// @dev Stake `amount` (already sent here) and back `borrower` with all of it.
    function lock(address borrower, uint256 amount) external {
        if (msg.sender != router) revert NotRouter();
        token.forceApprove(address(pool), amount);
        pool.stake(amount);
        pool.back(borrower, amount);
        token.forceApprove(address(pool), 0);
    }

    /// @dev Drop the backing, unstake what is left and send it to the router. Returns the amount sent.
    function release(address borrower) external returns (uint256 returned) {
        if (msg.sender != router) revert NotRouter();
        pool.back(borrower, 0);
        returned = pool.stakeOf(address(this));
        if (returned != 0) {
            pool.unstake(returned);
            token.safeTransfer(router, returned);
        }
    }
}

/**
 * @notice Shared machinery of the two-hop, stake-rooted routers: a root puts USDC in, a mid-level party it
 *         trusts vouches for a borrower, and the borrower borrows against the root's stake without any
 *         issuer or credit officer. Nothing here creates credit: every unit a borrower can draw through
 *         the router is USDC a root deposited and consented to risk.
 * @dev The borrower names the concrete router as its pool manager (`setManager`) before any backing exists,
 *      so the pool refuses every origination for that borrower that does not come from there (CI-31). A
 *      certificate is the borrower's signed pool request plus up to MAX_PATHS paths; each path is a root
 *      and a mid with two EIP-712 consents, each with a live-exposure limit, a term limit, a version and an
 *      expiry. Root consent: root to mid, with `borrower` as its scope (zero: any borrower the mid vouches
 *      for; otherwise that one borrower). Its exposure, version and revocation are shared across every
 *      borrower the root has delegated to that mid, so the limit is a cap on the relationship, not on one
 *      loan. Mid consent: mid to this borrower. Admission moves the roots' USDC to the borrower's vault,
 *      which backs the borrower in the pool, then submits the borrower's request. The lot stays locked
 *      until the loan has closed; `sync` (anyone, and run first by every origination) then returns it, and a
 *      default's loss is attributed to the roots pro rata to their path amounts.
 *      The submitter picks the paths among the consents it holds: every choice stays inside each signer's
 *      consent, and a signer who wants a single use sets the limit to that use and revokes after.
 *      What is not guarded here is stated in docs/TRANSITIVE_STAKE_ROUTER.md (aliases, mids with no
 *      capital at risk, third-party backers filling the pool's backer slots, loan terms chosen by the
 *      borrower inside the consents). Not a human-lending release.
 */
abstract contract StakeRouterBase is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PATHS = 4;

    /// @dev One edge of trust. Root to mid: `to` is the mid and `borrower` the scope (zero: any borrower the mid
    ///      vouches for, otherwise that one borrower); usage and version are shared across all of them. Mid to
    ///      borrower: `to == borrower == borrower`. `limit` caps the live USDC exposure along the edge, `maxTerm`
    ///      the repayment period (seconds) of any loan that uses it.
    struct Consent {
        address from;
        address to;
        address borrower;
        uint256 limit;
        uint256 maxTerm;
        uint256 version;
        uint256 expiry;
    }

    struct Path {
        uint256 amount;
        Consent rootEdge;
        bytes rootSig;
        Consent midEdge;
        bytes midSig;
    }

    struct PathLot {
        address root;
        address mid;
        uint256 amount;
    }

    struct Lot {
        bool open;
        uint256 loanId;
        uint256 amount;
        PathLot[] paths;
    }

    DecentralizedMicrocredit public immutable pool;
    IERC20 public immutable token;

    /// @notice A root's USDC not allocated to any open loan; withdrawable.
    mapping(address => uint256) public free;
    /// @notice A root's USDC allocated to open loans.
    mapping(address => uint256) public locked;
    /// @notice Cumulative loss attributed to a root by defaults.
    mapping(address => uint256) public lossOf;
    uint256 public totalFree;
    uint256 public totalLocked;

    mapping(bytes32 => uint256) public edgeVersion;
    mapping(bytes32 => uint256) public edgeUsed;
    mapping(address => StakeVault) public vaultOf;
    mapping(address => Lot) internal _lots;

    bytes32 public constant CONSENT_TYPEHASH = keccak256(
        "EdgeConsent(address from,address to,address borrower,uint256 limit,uint256 maxTerm,uint256 version,uint256 expiry)"
    );

    error InvalidCertificate();
    error InvalidConsent();
    error LimitExceeded();
    error NotManager();
    error OpenLot();
    error InsufficientFree();
    error AmountMismatch();
    error VaultHasCredit();
    error BackingNotSecured();
    error LoanMismatch();
    error ZeroAmount();
    error WrongFunding();

    event Deposited(address indexed root, uint256 amount);
    event Withdrawn(address indexed root, uint256 amount);
    event EdgeRevoked(address indexed from, address indexed to, address indexed scope, uint256 newVersion);
    event Allocated(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 paths);
    event Released(address indexed borrower, uint256 indexed loanId, uint256 returned, uint256 loss);
    event RootLoss(address indexed root, address indexed borrower, uint256 indexed loanId, uint256 loss);

    constructor(DecentralizedMicrocredit pool_) {
        pool = pool_;
        token = pool_.usdc();
    }

    // ───────────────────────────── roots ─────────────────────────────

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert WrongFunding();
        free[msg.sender] += amount;
        totalFree += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw USDC that is not allocated to an open loan.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > free[msg.sender]) revert InsufficientFree();
        free[msg.sender] -= amount;
        totalFree -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Void every root consent the caller signed for `mid`, whatever borrower it names. Live exposure
    ///         stays until its loans close; only new allocations need a consent of the new version.
    function revokeRootEdge(address mid) external {
        uint256 v = ++edgeVersion[edgeKey(msg.sender, mid, address(0))];
        emit EdgeRevoked(msg.sender, mid, address(0), v);
    }

    /// @notice Void every mid consent the caller signed for `borrower`.
    function revokeMidEdge(address borrower) external {
        uint256 v = ++edgeVersion[edgeKey(msg.sender, borrower, borrower)];
        emit EdgeRevoked(msg.sender, borrower, borrower, v);
    }

    // ───────────────────────────── origination ─────────────────────────────

    /// @dev Admit the certificate and originate the borrower's loan, atomically; the caller must be a concrete
    ///      router entry that has done its own checks and holds the reentrancy lock.
    function _originateLot(
        DecentralizedMicrocredit.BorrowAndDisburse calldata req,
        bytes calldata poolSig,
        Path[] calldata paths
    ) internal returns (uint256 loanId) {
        address borrower = req.borrower;
        if (borrower == address(0) || borrower == address(this) || req.to == address(this)) {
            revert InvalidCertificate();
        }
        if (pool.managerOf(borrower) != address(this)) revert NotManager();
        if (_sync(borrower)) revert OpenLot();

        Lot storage lot = _lots[borrower];
        uint256 total = _admit(lot, borrower, req.repaymentPeriod, paths);
        if (total != req.amount) revert AmountMismatch();

        StakeVault vault = vaultOf[borrower];
        if (address(vault) == address(0)) {
            vault = new StakeVault(pool, token);
            vaultOf[borrower] = vault;
        }
        if (req.to == address(vault) || pool.grantedCredit(address(vault)) != 0) revert VaultHasCredit();

        lot.open = true;
        lot.amount = total;
        totalLocked += total;
        token.safeTransfer(address(vault), total);
        vault.lock(borrower, total);
        (uint256 secured, uint256 unsecured) = pool.getBacking(address(vault), borrower);
        if (secured != total || unsecured != 0) revert BackingNotSecured();

        pool.borrowAndDisburseMeta(req, poolSig);

        uint256[] memory ids = pool.getBorrowerLoanIds(borrower);
        loanId = ids[ids.length - 1];
        (uint256 principal,, address debtor,, bool active) = pool.getLoan(loanId);
        if (debtor != borrower || principal != total || !active) revert LoanMismatch();
        lot.loanId = loanId;
        emit Allocated(borrower, loanId, total, paths.length);
    }

    /// @dev Checks every path and moves each root's USDC from free to locked. Returns the sum of the paths.
    function _admit(Lot storage lot, address borrower, uint256 term, Path[] calldata paths)
        internal
        returns (uint256 total)
    {
        uint256 n = paths.length;
        if (n == 0 || n > MAX_PATHS) revert InvalidCertificate();
        for (uint256 i = 0; i < n; i++) {
            Path calldata p = paths[i];
            address root = p.rootEdge.from;
            address mid = p.rootEdge.to;
            if (
                p.amount == 0 || root == address(0) || mid == address(0) || root == mid || root == borrower
                    || mid == borrower || root == address(this) || mid == address(this)
                    || (p.rootEdge.borrower != address(0) && p.rootEdge.borrower != borrower) || p.midEdge.from != mid
                    || p.midEdge.to != borrower || p.midEdge.borrower != borrower
            ) revert InvalidCertificate();

            _useConsent(edgeKey(root, mid, address(0)), p.rootEdge, p.rootSig, p.amount, term);
            _useConsent(edgeKey(mid, borrower, borrower), p.midEdge, p.midSig, p.amount, term);

            if (free[root] < p.amount) revert InsufficientFree();
            free[root] -= p.amount;
            locked[root] += p.amount;
            totalFree -= p.amount;
            lot.paths.push(PathLot({ root: root, mid: mid, amount: p.amount }));
            total += p.amount;
        }
    }

    function _useConsent(bytes32 key, Consent calldata c, bytes calldata sig, uint256 amount, uint256 term) internal {
        if (c.version != edgeVersion[key] || block.timestamp > c.expiry || term > c.maxTerm) revert InvalidConsent();
        if (!SignatureChecker.isValidSignatureNow(c.from, consentDigest(c), sig)) revert InvalidConsent();
        uint256 used = edgeUsed[key] + amount;
        if (used > c.limit) revert LimitExceeded();
        edgeUsed[key] = used;
    }

    // ───────────────────────────── release ─────────────────────────────

    /// @notice Return a closed loan's lot: the unslashed USDC goes back to the roots' free balances and any
    ///         loss is attributed to them. Anyone may call; nothing happens while the loan is open.
    function sync(address borrower) external nonReentrant {
        _sync(borrower);
    }

    /// @dev Returns true when the borrower still has an open lot after the call.
    function _sync(address borrower) internal returns (bool stillOpen) {
        Lot storage lot = _lots[borrower];
        if (!lot.open) return false;
        (DecentralizedMicrocredit.LoanStatus status,,,,) = pool.getLoanTerms(lot.loanId);
        if (
            status == DecentralizedMicrocredit.LoanStatus.Requested
                || status == DecentralizedMicrocredit.LoanStatus.Active
        ) return true;

        uint256 amount = lot.amount;
        uint256 loanId = lot.loanId;
        uint256 returned = Math.min(vaultOf[borrower].release(borrower), amount);
        uint256 loss = amount - returned;

        PathLot[] memory paths = lot.paths;
        uint256[] memory share = _attribute(paths, amount, loss);
        for (uint256 i = 0; i < paths.length; i++) {
            PathLot memory p = paths[i];
            edgeUsed[edgeKey(p.root, p.mid, address(0))] -= p.amount;
            edgeUsed[edgeKey(p.mid, borrower, borrower)] -= p.amount;
            locked[p.root] -= p.amount;
            free[p.root] += p.amount - share[i];
            lossOf[p.root] += share[i];
            if (share[i] != 0) emit RootLoss(p.root, borrower, loanId, share[i]);
        }
        totalLocked -= amount;
        totalFree += returned;
        delete _lots[borrower];
        emit Released(borrower, loanId, returned, loss);
        return false;
    }

    /// @dev Pro rata to path amounts, rounded down; the remainder (fewer units than paths) goes one unit
    ///      each to paths that can still bear it, so no path ever bears more than its own amount.
    function _attribute(PathLot[] memory paths, uint256 amount, uint256 loss)
        internal
        pure
        returns (uint256[] memory share)
    {
        share = new uint256[](paths.length);
        uint256 assigned;
        for (uint256 i = 0; i < paths.length; i++) {
            share[i] = Math.mulDiv(loss, paths[i].amount, amount);
            assigned += share[i];
        }
        uint256 residual = loss - assigned;
        for (uint256 i = 0; i < paths.length && residual != 0; i++) {
            if (share[i] < paths[i].amount) {
                share[i] += 1;
                residual -= 1;
            }
        }
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Root edges use `edgeKey(root, mid, address(0))` (one bucket for the relationship); mid edges use
    ///         `edgeKey(mid, borrower, borrower)`.
    function edgeKey(address from, address to, address scope) public pure returns (bytes32) {
        return keccak256(abi.encode(from, to, scope));
    }

    function consentDigest(Consent calldata c) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(CONSENT_TYPEHASH, c.from, c.to, c.borrower, c.limit, c.maxTerm, c.version, c.expiry))
        );
    }

    function lotOf(address borrower)
        external
        view
        returns (bool open, uint256 loanId, uint256 amount, PathLot[] memory paths)
    {
        Lot storage lot = _lots[borrower];
        return (lot.open, lot.loanId, lot.amount, lot.paths);
    }
}

/**
 * @notice The unbound two-hop router: anyone holding a borrower's signed pool request and the consents may
 *         originate. It does not bind a loan to a customer's order; the bootstrap product is
 *         `BootstrapOrderRouter`, which does. Kept as the order-free building block and for its tests.
 */
contract TransitiveStakeRouter is StakeRouterBase {
    constructor(DecentralizedMicrocredit pool_) StakeRouterBase(pool_) EIP712("TransitiveStakeRouter", "2") { }

    /**
     * @notice Admit a certificate and originate the borrower's loan, atomically. Anyone may call; the
     *         borrower and the signers of the consents need no ETH.
     * @param req The borrower's signed pool request (the loan's amount, vendor, term and APR cap).
     * @param poolSig The borrower's signature for the pool.
     * @param paths One to MAX_PATHS paths whose amounts sum to `req.amount`.
     */
    function originate(
        DecentralizedMicrocredit.BorrowAndDisburse calldata req,
        bytes calldata poolSig,
        Path[] calldata paths
    ) external nonReentrant returns (uint256 loanId) {
        return _originateLot(req, poolSig, paths);
    }
}
