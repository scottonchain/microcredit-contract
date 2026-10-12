// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice Conserved trust for new members of a revolving first-job payment guarantee. Testnet only: no live
 *         guarantee, no offer. Design: docs/TRUST_NETWORK_DESIGN.md.
 * @dev A client owes a first-time worker the wage. If the client does not pay, the reserve pays the worker the
 *      guaranteed amount and the worker owes nothing. If the client pays, the worker remits a small capped
 *      contribution that refills the reserve and becomes the worker's dues.
 *
 *      Trust is a liability of someone. A member's own trust has three roots, each with one use:
 *      - stake (cash, locked here): backs others only, so no worker's cash pays for its own client's default;
 *      - dues (contributions irrevocably in the reserve): backs others and the member's own guarantees;
 *      - line (an issuer's vetting, inside the issuer's budget): the member's own guarantees only, never passed on.
 *      Backing moves trust one hop from an attester to a member who consented, and never creates it: received
 *      backing cannot be attested onward. A guarantee opens only on the worker's signed acceptance of its exact
 *      terms (client, client group, amount, the dues it pledges, terms hash, contribution policy, settle-by date).
 *      It commits the worker's capacity (received backing, then line, then pledged dues); each attester's share of
 *      the backing is fixed when the guarantee opens. A claim pays the worker in full and consumes exactly the
 *      committed capacity: each attester's share (its stake first, which returns cash to the reserve, then its
 *      dues), the issuer's budget, the worker's pledged dues. Capacity never reads history; the score is
 *      information only. A guarantee not settled by its settle-by date can be expired by anyone, releasing it.
 *      Accounting identity: token.balanceOf(this) = reserve + totalStake + stray transfers.
 */
contract GuaranteeTrust is Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TERM = 1 days; // shortest settle-by a worker may accept

    bytes32 public constant ACCEPTANCE_TYPEHASH = keccak256(
        "Acceptance(address worker,bytes32 clientId,bytes32 groupId,uint256 amount,uint256 maxFromDues,bytes32 termsHash,uint256 contributionBps,uint256 contributionCap,uint256 remitWindow,uint64 settleBy,uint64 holdUntil,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CONSENT_TYPEHASH =
        keccak256("Consent(address member,address attester,bool allowed,uint256 nonce,uint256 deadline)");

    enum State {
        None,
        Open,
        Paid,
        Claimed,
        Cancelled,
        Expired
    }

    /// @notice What a worker signs to accept one guarantee. A gasless relay may submit it; nobody can replace it.
    struct Acceptance {
        address worker;
        bytes32 clientId; // the client the guarantee covers
        bytes32 groupId; // the client's canonical group (a common parent or payer); zero: the client is its own group
        uint256 amount;
        uint256 maxFromDues; // the most of the worker's own dues it agrees may stand behind this guarantee
        bytes32 termsHash; // the human-readable terms the worker accepted
        uint256 contributionBps; // must equal the policy in force; fixed for this guarantee
        uint256 contributionCap;
        uint256 remitWindow; // must equal the window in force; fixed for this guarantee
        uint64 settleBy; // after this, an undisputed guarantee can no longer be settled and anyone may expire it
        uint64 holdUntil; // the latest a dispute opened by settleBy keeps it settleable; settleBy <= holdUntil
        uint256 nonce; // any unused number of the worker's; revocable before use
        uint256 deadline; // the signature's own expiry
    }

    struct Member {
        // own trust
        uint256 stake;
        uint256 dues;
        uint256 line;
        // uses of own trust
        uint256 backingGiven; // stake and dues committed to others
        uint256 committedLine; // line committed to own open guarantees
        uint256 committedDues; // dues committed to own open guarantees
        // received
        uint256 backingReceived;
        uint256 backingCommitted; // received backing committed to own open guarantees (sum of locked shares)
        uint256 openAttestees;
        uint256 unpaidContributions;
        // history (information only)
        uint64 guaranteesOpened;
        uint64 guaranteesPaid;
        uint64 claimsAsWorker;
        uint64 contributionsRemitted;
        uint64 contributionsLapsed;
        uint64 attestationsGiven;
        uint64 attestationsReceived;
        uint64 attesteeClaims;
        uint256 contributedTotal;
        uint256 backingLost;
    }

    struct Guarantee {
        address worker;
        bytes32 clientId;
        bytes32 groupId;
        uint128 amount;
        uint128 fromBacking;
        uint128 fromLine;
        uint128 fromDues;
        bytes32 termsHash;
        State state;
        bool remitted;
        bool lapsed;
        bool disputed;
        uint64 openedAt;
        uint64 paidAt;
        uint64 settleBy;
        uint64 holdUntil;
        uint128 wage;
        uint128 contributionDue;
        uint128 contributionBps;
        uint128 contributionCap;
        uint64 remitWindow;
        bytes32 evidenceHash;
    }

    /// @notice One attester's share of a guarantee's backing, fixed at opening.
    struct Share {
        address attester;
        uint128 amount;
    }

    struct Score {
        uint64 guaranteesOpened;
        uint64 guaranteesPaid;
        uint64 claimsAsWorker;
        uint64 contributionsRemitted;
        uint64 contributionsLapsed;
        uint64 attestationsGiven;
        uint64 attestationsReceived;
        uint64 attesteeClaims;
        uint256 contributedTotal;
        uint256 backingLost;
        int256 composite;
    }

    IERC20 public immutable token;

    address public guardian;
    address public adjudicator;
    address public issuer;
    bool public paused;

    // issuer budget: lines held now plus lines spent by claims never exceed it
    uint256 public issuerBudget;
    uint256 public issuerHeld;
    uint256 public issuerSpent;

    // parameters
    uint256 public maxShareBps = 2000; // a guarantee is at most a fifth of the reserve
    uint256 public floorMultiple = 2; // after opening, the reserve keeps at least floorMultiple x G uncommitted
    uint256 public contributionBps = 500; // 5% of the wage
    uint256 public contributionCap; // in token units
    uint256 public remitWindow = 14 days;
    uint256 public lineCap;
    uint256 public attestCap;
    uint256 public maxAttesters = 5; // attesters per member
    uint256 public maxOpenAttestees = 5; // members per attester
    uint256 public maxGroupShareBps = 3000; // open guarantees on one client group are at most 30% of the reserve
    uint256 public maxTerm = 60 days; // longest settle-by a worker may accept

    // ledgers
    uint256 public reserve;
    uint256 public outstanding;
    uint256 public totalStake;
    uint256 public totalDues;
    // sponsor capital: funded, less released, less line-backed claims; funders hold shares of it, so a loss lowers
    // every funder's entitlement pro rata and a later deposit never repays an earlier funder
    uint256 public sponsorCapital;
    uint256 public totalSponsorShares;
    mapping(address => uint256) public sponsorSharesOf;

    mapping(address => Member) internal members;
    mapping(address => mapping(address => uint256)) public backing; // attester => member => amount
    mapping(address => mapping(address => uint256)) public lockedBacking; // attester => member => in open shares
    mapping(address => address[]) internal attesters; // member => current attesters
    mapping(address => mapping(address => bool)) public consent; // member => attester => allowed
    mapping(address => mapping(uint256 => bool)) public nonceUsed; // signer => nonce => used or revoked
    mapping(bytes32 => bool) public clientOpen;
    mapping(bytes32 => bool) public clientDefaulted;
    mapping(bytes32 => uint256) public groupExposure;
    mapping(bytes32 => bool) public groupDefaulted;
    mapping(bytes32 => bytes32) public clientGroup; // canonical group, fixed at the client's first guarantee
    mapping(address => mapping(address => uint256)) public consentNonce; // member => attester => next nonce
    Guarantee[] internal guarantees;
    mapping(uint256 => Share[]) internal shares;

    event ParamsSet(
        uint256 maxShareBps,
        uint256 floorMultiple,
        uint256 contributionBps,
        uint256 contributionCap,
        uint256 remitWindow,
        uint256 lineCap,
        uint256 attestCap,
        uint256 maxAttesters,
        uint256 maxOpenAttestees
    );
    event GroupAndTermSet(uint256 maxGroupShareBps, uint256 maxTerm);
    event RolesSet(address guardian, address adjudicator, address issuer, uint256 issuerBudget);
    event Paused(bool paused);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserve);
    event ReserveReleased(address indexed funder, uint256 amount, uint256 reserve);
    event Staked(address indexed member, uint256 amount, uint256 stake);
    event Unstaked(address indexed member, uint256 amount, uint256 stake);
    event LineSet(address indexed member, uint256 line, uint256 issuerHeld);
    event Attested(address indexed attester, address indexed member, uint256 amount, uint256 backing);
    event ConsentSet(address indexed member, address indexed attester, bool allowed, address submittedBy);
    event NonceRevoked(address indexed signer, uint256 nonce);
    event BackingWithdrawn(address indexed attester, address indexed member, uint256 amount, uint256 backing);
    event GuaranteeOpened(
        uint256 indexed id,
        address indexed worker,
        bytes32 indexed clientId,
        bytes32 groupId,
        uint256 amount,
        uint256 fromBacking,
        uint256 fromLine,
        uint256 fromDues,
        bytes32 termsHash,
        uint64 settleBy
    );
    event ShareLocked(uint256 indexed id, address indexed attester, uint256 amount);
    event GuaranteeCancelled(uint256 indexed id, bytes32 resolutionHash);
    event DisputeOpened(uint256 indexed id, address by, uint64 holdUntil, bytes32 reasonHash);
    event GuaranteeExpired(uint256 indexed id, address by);
    event GuaranteePaid(uint256 indexed id, uint256 wage, uint256 contributionDue);
    event ContributionRemitted(uint256 indexed id, address indexed payer, address indexed worker, uint256 amount);
    event ContributionLapsed(uint256 indexed id, address indexed worker);
    event Claimed(uint256 indexed id, address indexed worker, bytes32 indexed clientId, uint256 amount, bytes32 evidenceHash);
    event BackingConsumed(
        uint256 indexed id, address indexed attester, address indexed member, uint256 amount, uint256 stakeSlashed
    );
    event LineConsumed(uint256 indexed id, address indexed member, uint256 amount);
    event DuesConsumed(uint256 indexed id, address indexed member, uint256 amount);

    error NotAdjudicator();
    error NotIssuer();
    error NotGuardian();
    error IsPaused();
    error ZeroAmount();
    error BadParam();
    error InsufficientTrust();
    error InsufficientCapacity();
    error ExposureCap();
    error GroupCap();
    error ReserveFloor();
    error ClientBlocked();
    error ContributionOutstanding();
    error SelfAttestation();
    error NoConsent();
    error AttestCap();
    error TooManyAttesters();
    error TooManyAttestees();
    error BackingLocked();
    error BudgetExceeded();
    error LineCommitted();
    error WrongState();
    error TooEarly();
    error NothingDue();
    error ReleaseTooLarge();
    error BadSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error PolicyMismatch();
    error BadTerm();
    error PastSettleBy();
    error StaleNonce();
    error GroupMismatch();
    error ZeroClient();
    error SponsorCapital();
    error ReleaseWhileOpen();
    error NotParty();
    error NoResolution();

    modifier onlyAdjudicator() {
        if (msg.sender != adjudicator) revert NotAdjudicator();
        _;
    }

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer();
        _;
    }

    constructor(
        IERC20 token_,
        address owner_,
        address adjudicator_,
        address issuer_,
        uint256 issuerBudget_,
        uint256 unit // one token unit, e.g. 1e6 for USDC: sets the testnet caps
    ) Ownable(owner_) EIP712("GuaranteeTrust", "2") {
        token = token_;
        guardian = owner_;
        adjudicator = adjudicator_;
        issuer = issuer_;
        issuerBudget = issuerBudget_;
        contributionCap = 3 * unit;
        lineCap = 20 * unit;
        attestCap = 20 * unit;
        emit RolesSet(owner_, adjudicator_, issuer_, issuerBudget_);
    }

    // ---------------------------------------------------------------- admin

    /// @dev A guardian that was the old owner follows ownership, so a transferred owner keeps no pause power.
    function _transferOwnership(address newOwner) internal override {
        address old = owner();
        super._transferOwnership(newOwner);
        if (guardian == old) guardian = newOwner;
    }

    function setRoles(address guardian_, address adjudicator_, address issuer_, uint256 issuerBudget_) external onlyOwner {
        if (issuerBudget_ < issuerHeld + issuerSpent) revert BudgetExceeded();
        guardian = guardian_;
        adjudicator = adjudicator_;
        issuer = issuer_;
        issuerBudget = issuerBudget_;
        emit RolesSet(guardian_, adjudicator_, issuer_, issuerBudget_);
    }

    /// @notice New parameters apply to guarantees opened afterwards; an open guarantee keeps the contribution policy
    ///         its worker signed.
    function setParams(
        uint256 maxShareBps_,
        uint256 floorMultiple_,
        uint256 contributionBps_,
        uint256 contributionCap_,
        uint256 remitWindow_,
        uint256 lineCap_,
        uint256 attestCap_,
        uint256 maxAttesters_,
        uint256 maxOpenAttestees_
    ) external onlyOwner {
        if (
            maxShareBps_ == 0 || maxShareBps_ > BPS || contributionBps_ > BPS || remitWindow_ < 1 days
                || remitWindow_ > 90 days || maxAttesters_ == 0 || maxAttesters_ > 20 || maxOpenAttestees_ == 0
                || maxOpenAttestees_ > 50 || floorMultiple_ > 10
        ) revert BadParam();
        maxShareBps = maxShareBps_;
        floorMultiple = floorMultiple_;
        contributionBps = contributionBps_;
        contributionCap = contributionCap_;
        remitWindow = remitWindow_;
        lineCap = lineCap_;
        attestCap = attestCap_;
        maxAttesters = maxAttesters_;
        maxOpenAttestees = maxOpenAttestees_;
        emit ParamsSet(
            maxShareBps_,
            floorMultiple_,
            contributionBps_,
            contributionCap_,
            remitWindow_,
            lineCap_,
            attestCap_,
            maxAttesters_,
            maxOpenAttestees_
        );
    }

    function setGroupAndTerm(uint256 maxGroupShareBps_, uint256 maxTerm_) external onlyOwner {
        if (maxGroupShareBps_ == 0 || maxGroupShareBps_ > BPS || maxTerm_ < 1 days || maxTerm_ > 365 days) {
            revert BadParam();
        }
        maxGroupShareBps = maxGroupShareBps_;
        maxTerm = maxTerm_;
        emit GroupAndTermSet(maxGroupShareBps_, maxTerm_);
    }

    /// @notice Stops new guarantees only. Payment records, remittances, claims, expiry and withdrawals keep working.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit Paused(paused_);
    }

    // ---------------------------------------------------------------- reserve

    /// @notice Anyone may fund the reserve and receives shares of the sponsor capital at its current value. The
    ///         owner can return capital only to a funder, only up to the current value of its shares, never dues,
    ///         never the capital behind issuer lines and never while any guarantee is open. A funder who joins
    ///         while guarantees are open shares in their line-backed losses, as in any mutual pool.
    function fundReserve(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 minted = (amount * (totalSponsorShares + 1)) / (sponsorCapital + 1);
        if (minted == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        sponsorCapital += amount;
        totalSponsorShares += minted;
        sponsorSharesOf[msg.sender] += minted;
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    /// @notice Returns sponsor capital to a funder, burning its shares at their current value (rounded against the
    ///         funder). Released only while nothing is open, so no admitted guarantee loses its safety loading.
    function releaseReserve(address funder, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (outstanding != 0) revert ReleaseWhileOpen();
        if (amount > releasable()) revert ReleaseTooLarge();
        uint256 burned = Math.mulDiv(amount, totalSponsorShares + 1, sponsorCapital + 1, Math.Rounding.Ceil);
        if (burned > sponsorSharesOf[funder]) revert ReleaseTooLarge();
        sponsorSharesOf[funder] -= burned;
        totalSponsorShares -= burned;
        reserve -= amount;
        sponsorCapital -= amount;
        token.safeTransfer(funder, amount);
        emit ReserveReleased(funder, amount, reserve);
    }

    /// @notice Sponsor capital that could be released now: nothing while a guarantee is open, never dues and never
    ///         the capital behind held lines.
    function releasable() public view returns (uint256) {
        if (outstanding != 0) return 0;
        return sponsorCapital > issuerHeld ? sponsorCapital - issuerHeld : 0;
    }

    /// @notice The current value of a funder's shares of the sponsor capital.
    function sponsorValueOf(address funder) external view returns (uint256) {
        return Math.mulDiv(sponsorSharesOf[funder], sponsorCapital + 1, totalSponsorShares + 1);
    }

    // ---------------------------------------------------------------- own trust

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        Member storage m = members[msg.sender];
        m.stake += amount;
        totalStake += amount;
        emit Staked(msg.sender, amount, m.stake);
    }

    function unstake(uint256 amount) external {
        Member storage m = members[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > m.stake || m.stake - amount + (m.dues - m.committedDues) < m.backingGiven) revert InsufficientTrust();
        m.stake -= amount;
        totalStake -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, m.stake);
    }

    /// @notice The issuer sets a member's line. The budget holds every line; a line can be lowered only to what
    ///         its member has committed, so held budget cannot be rotated away from open exposure. Lines held never
    ///         exceed the sponsor capital, so a line-backed claim is never paid from dues.
    function setLine(address member, uint256 newLine) external onlyIssuer {
        if (newLine > lineCap) revert BadParam();
        Member storage m = members[member];
        if (newLine < m.committedLine) revert LineCommitted();
        if (newLine > m.line) {
            uint256 add = newLine - m.line;
            if (issuerHeld + issuerSpent + add > issuerBudget) revert BudgetExceeded();
            if (issuerHeld + add > sponsorCapital) revert SponsorCapital();
            issuerHeld += add;
        } else {
            issuerHeld -= m.line - newLine;
        }
        m.line = newLine;
        emit LineSet(member, newLine, issuerHeld);
    }

    // ---------------------------------------------------------------- consent and nonces

    /// @notice A member chooses who may back it. Without consent anyone with a little stake could fill a
    ///         newcomer's attester slots and lock out real attesters. Each decision advances the pair's nonce, so it
    ///         cancels every earlier unsubmitted signature for that attester.
    function setConsent(address attester, bool allowed) external {
        consentNonce[msg.sender][attester] += 1;
        consent[msg.sender][attester] = allowed;
        emit ConsentSet(msg.sender, attester, allowed, msg.sender);
    }

    /// @notice The member's signed consent, submitted by anyone (a newcomer may hold no gas). No role can consent
    ///         for a member. Nonces are sequential per member and attester, so decisions apply in the order signed.
    function setConsentBySig(
        address member,
        address attester,
        bool allowed,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != consentNonce[member][attester]) revert StaleNonce();
        bytes32 digest = consentDigest(member, attester, allowed, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNow(member, digest, signature)) revert BadSignature();
        consentNonce[member][attester] = nonce + 1;
        consent[member][attester] = allowed;
        emit ConsentSet(member, attester, allowed, msg.sender);
    }

    /// @notice Withdraw a signed acceptance before anyone submits it.
    function revokeNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce);
        emit NonceRevoked(msg.sender, nonce);
    }

    // ---------------------------------------------------------------- backing (one hop)

    /// @notice Back `member` with `amount` of the caller's own stake and dues, with the member's consent. Received
    ///         backing and issuer lines cannot be attested onward.
    function attest(address member, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (member == msg.sender) revert SelfAttestation();
        if (!consent[member][msg.sender]) revert NoConsent();
        Member storage a = members[msg.sender];
        if (_freeToBack(a) < amount) revert InsufficientTrust();
        uint256 current = backing[msg.sender][member];
        if (current + amount > attestCap) revert AttestCap();
        Member storage m = members[member];
        if (current == 0) {
            if (attesters[member].length >= maxAttesters) revert TooManyAttesters();
            if (a.openAttestees >= maxOpenAttestees) revert TooManyAttestees();
            attesters[member].push(msg.sender);
            a.openAttestees += 1;
            a.attestationsGiven += 1;
            m.attestationsReceived += 1;
        }
        backing[msg.sender][member] = current + amount;
        a.backingGiven += amount;
        m.backingReceived += amount;
        emit Attested(msg.sender, member, amount, current + amount);
    }

    /// @notice Withdraw backing that is not locked in a share of one of the member's open guarantees.
    function withdrawBacking(address member, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > withdrawableBacking(msg.sender, member)) revert BackingLocked();
        Member storage m = members[member];
        Member storage a = members[msg.sender];
        uint256 left = backing[msg.sender][member] - amount;
        backing[msg.sender][member] = left;
        a.backingGiven -= amount;
        m.backingReceived -= amount;
        if (left == 0) _unlink(msg.sender, member);
        emit BackingWithdrawn(msg.sender, member, amount, left);
    }

    /// @notice A member removes an attester whose backing is not locked in an open guarantee, freeing its slot. The
    ///         backing returns to the attester's own free trust.
    function dropAttester(address attester) external {
        uint256 amount = backing[attester][msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (lockedBacking[attester][msg.sender] != 0) revert BackingLocked();
        backing[attester][msg.sender] = 0;
        members[attester].backingGiven -= amount;
        members[msg.sender].backingReceived -= amount;
        consent[msg.sender][attester] = false;
        consentNonce[msg.sender][attester] += 1;
        _unlink(attester, msg.sender);
        emit BackingWithdrawn(attester, msg.sender, amount, 0);
        emit ConsentSet(msg.sender, attester, false, msg.sender);
    }

    function withdrawableBacking(address attester, address member) public view returns (uint256) {
        return backing[attester][member] - lockedBacking[attester][member];
    }

    // ---------------------------------------------------------------- guarantees

    /// @notice Opens a guarantee on the worker's signed acceptance of its exact terms. The adjudicator submits it;
    ///         neither the adjudicator nor anyone else can open one the worker did not sign.
    function openGuarantee(Acceptance calldata a, bytes calldata signature) external onlyAdjudicator returns (uint256 id) {
        if (paused) revert IsPaused();
        if (a.amount == 0) revert ZeroAmount();
        if (a.clientId == bytes32(0)) revert ZeroClient(); // zero is clientGroup's "unset"
        if (block.timestamp > a.deadline) revert SignatureExpired();
        if (a.settleBy < block.timestamp + MIN_TERM || a.holdUntil < a.settleBy || a.holdUntil > block.timestamp + maxTerm) {
            revert BadTerm();
        }
        if (a.contributionBps != contributionBps || a.contributionCap != contributionCap || a.remitWindow != remitWindow) {
            revert PolicyMismatch();
        }
        _useNonce(a.worker, a.nonce);
        if (!SignatureChecker.isValidSignatureNow(a.worker, acceptanceDigest(a), signature)) revert BadSignature();

        bytes32 group = a.groupId == bytes32(0) ? a.clientId : a.groupId;
        bytes32 known = clientGroup[a.clientId];
        if (known == bytes32(0)) clientGroup[a.clientId] = group;
        else if (known != group) revert GroupMismatch();
        if (clientOpen[a.clientId] || clientDefaulted[a.clientId] || groupDefaulted[group]) revert ClientBlocked();
        Member storage w = members[a.worker];
        if (w.unpaidContributions != 0) revert ContributionOutstanding();
        uint256 amount = a.amount;
        if (amount * BPS > reserve * maxShareBps) revert ExposureCap();
        if ((groupExposure[group] + amount) * BPS > reserve * maxGroupShareBps) revert GroupCap();
        if (outstanding + amount + floorMultiple * amount > reserve) revert ReserveFloor();

        uint256 fromBacking = w.backingReceived - w.backingCommitted;
        if (fromBacking > amount) fromBacking = amount;
        uint256 rest = amount - fromBacking;
        uint256 fromLine = w.line - w.committedLine;
        if (fromLine > rest) fromLine = rest;
        uint256 fromDues = rest - fromLine;
        if (fromDues > _freeOwnDues(w) || fromDues > a.maxFromDues) revert InsufficientCapacity();

        id = guarantees.length;
        w.committedLine += fromLine;
        w.committedDues += fromDues;
        if (fromBacking != 0) _lockShares(id, a.worker, fromBacking);
        outstanding += amount;
        groupExposure[group] += amount;
        clientOpen[a.clientId] = true;
        w.guaranteesOpened += 1;

        guarantees.push(
            Guarantee({
                worker: a.worker,
                clientId: a.clientId,
                groupId: group,
                amount: uint128(amount),
                fromBacking: uint128(fromBacking),
                fromLine: uint128(fromLine),
                fromDues: uint128(fromDues),
                termsHash: a.termsHash,
                state: State.Open,
                remitted: false,
                lapsed: false,
                disputed: false,
                openedAt: uint64(block.timestamp),
                paidAt: 0,
                settleBy: a.settleBy,
                holdUntil: a.holdUntil,
                wage: 0,
                contributionDue: 0,
                contributionBps: uint128(a.contributionBps),
                contributionCap: uint128(a.contributionCap),
                remitWindow: uint64(a.remitWindow),
                evidenceHash: bytes32(0)
            })
        );
        emit GuaranteeOpened(id, a.worker, a.clientId, group, amount, fromBacking, fromLine, fromDues, a.termsHash, a.settleBy);
    }

    /// @notice The job did not go ahead: release everything, record nothing against anyone. A disputed guarantee is
    ///         cancelled only with the hash of the resolution's evidence, so a dispute is never erased silently.
    function cancelGuarantee(uint256 id, bytes32 resolutionHash) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        if (g.disputed && resolutionHash == bytes32(0)) revert NoResolution();
        g.state = State.Cancelled;
        g.evidenceHash = resolutionHash;
        _release(id, g);
        emit GuaranteeCancelled(id, resolutionHash);
    }

    /// @notice The worker or the adjudicator records a dispute, once, by the settle-by date, with an opaque hash of its
    ///         reason (no private data on chain). A disputed guarantee stays settleable until the hold-until date the
    ///         worker signed (at most the longest term from opening), so a dispute still open at settle-by is not lost
    ///         to expiry. Only a settlement carrying a resolution evidence hash closes it, or expiry at hold-until. The
    ///         adjudicator is trusted to resolve it: there is no appeal on chain, and nothing extends the hold.
    function openDispute(uint256 id, bytes32 reasonHash) external {
        Guarantee storage g = guarantees[id];
        if (msg.sender != g.worker && msg.sender != adjudicator) revert NotParty();
        if (g.state != State.Open || g.disputed) revert WrongState();
        if (block.timestamp > g.settleBy) revert PastSettleBy();
        if (reasonHash == bytes32(0)) revert NoResolution();
        g.disputed = true;
        emit DisputeOpened(id, msg.sender, g.holdUntil, reasonHash);
    }

    function _settleDeadline(Guarantee storage g) internal view returns (uint64) {
        return g.disputed ? g.holdUntil : g.settleBy;
    }

    /// @notice Past its settle-by date (or, if disputed, its hold-until date) an unsettled guarantee can be expired by
    ///         anyone: everything is released, no claim is paid and no contribution falls due. This bounds how long a
    ///         lost adjudicator can lock capacity.
    function expireGuarantee(uint256 id) external {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        if (block.timestamp <= _settleDeadline(g)) revert TooEarly();
        g.state = State.Expired;
        _release(id, g);
        emit GuaranteeExpired(id, msg.sender);
    }

    /// @notice The client paid the wage. The contribution the worker signed for becomes due; the commitment is released.
    function markPaid(uint256 id, uint256 wage, bytes32 evidenceHash) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        if (block.timestamp > _settleDeadline(g)) revert PastSettleBy();
        if (g.disputed && evidenceHash == bytes32(0)) revert NoResolution();
        g.state = State.Paid;
        g.wage = uint128(wage);
        g.paidAt = uint64(block.timestamp);
        g.evidenceHash = evidenceHash;
        _release(id, g);
        uint256 due = (wage * g.contributionBps) / BPS;
        if (due > g.contributionCap) due = g.contributionCap;
        g.contributionDue = uint128(due);
        Member storage w = members[g.worker];
        w.guaranteesPaid += 1;
        if (due != 0) w.unpaidContributions += 1;
        else g.remitted = true;
        emit GuaranteePaid(id, wage, due);
    }

    /// @notice Anyone may remit a paid guarantee's contribution. It refills the reserve and becomes the worker's dues.
    function remit(uint256 id) external {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Paid || g.remitted) revert NothingDue();
        uint256 due = g.contributionDue;
        g.remitted = true;
        token.safeTransferFrom(msg.sender, address(this), due);
        reserve += due;
        totalDues += due;
        Member storage w = members[g.worker];
        w.dues += due;
        w.contributedTotal += due;
        w.contributionsRemitted += 1;
        w.unpaidContributions -= 1;
        emit ContributionRemitted(id, msg.sender, g.worker, due);
    }

    /// @notice After the remit window the worker signed, anyone may record a lapse. It is history, not a debt: the contribution stays
    ///         payable, and until it is paid the worker gets no new guarantee.
    function markLapsed(uint256 id) external {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Paid || g.remitted || g.lapsed) revert NothingDue();
        if (block.timestamp < g.paidAt + g.remitWindow) revert TooEarly();
        g.lapsed = true;
        members[g.worker].contributionsLapsed += 1;
        emit ContributionLapsed(id, g.worker);
    }

    /// @notice The client did not pay. The reserve pays the worker in full; the worker owes nothing. The capacity
    ///         that underwrote the guarantee is consumed: each attester's fixed share, the issuer line, the pledged
    ///         dues. The client and its group take no further guarantee.
    function claim(uint256 id, bytes32 evidenceHash) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        if (block.timestamp > _settleDeadline(g)) revert PastSettleBy();
        if (g.disputed && evidenceHash == bytes32(0)) revert NoResolution();
        g.state = State.Claimed;
        g.evidenceHash = evidenceHash;
        address worker = g.worker;
        Member storage w = members[worker];
        uint256 amount = g.amount;

        outstanding -= amount;
        groupExposure[g.groupId] -= amount;
        clientOpen[g.clientId] = false;
        clientDefaulted[g.clientId] = true;
        groupDefaulted[g.groupId] = true;
        w.claimsAsWorker += 1;

        if (g.fromLine != 0) {
            w.committedLine -= g.fromLine;
            w.line -= g.fromLine;
            issuerHeld -= g.fromLine;
            issuerSpent += g.fromLine;
            sponsorCapital -= g.fromLine;
            emit LineConsumed(id, worker, g.fromLine);
        }
        if (g.fromDues != 0) {
            w.committedDues -= g.fromDues;
            w.dues -= g.fromDues;
            totalDues -= g.fromDues;
            emit DuesConsumed(id, worker, g.fromDues);
        }
        if (g.fromBacking != 0) _consumeShares(id, worker, g.fromBacking);

        reserve -= amount; // slashed stake was added back inside _consumeShares
        token.safeTransfer(worker, amount);
        emit Claimed(id, worker, g.clientId, amount, evidenceHash);
    }

    // ---------------------------------------------------------------- views

    function acceptanceDigest(Acceptance calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ACCEPTANCE_TYPEHASH,
                    a.worker,
                    a.clientId,
                    a.groupId,
                    a.amount,
                    a.maxFromDues,
                    a.termsHash,
                    a.contributionBps,
                    a.contributionCap,
                    a.remitWindow,
                    a.settleBy,
                    a.holdUntil,
                    a.nonce,
                    a.deadline
                )
            )
        );
    }

    function consentDigest(address member, address attester, bool allowed, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(CONSENT_TYPEHASH, member, attester, allowed, nonce, deadline)));
    }

    /// @notice What the member can be guaranteed now: free received backing, free line, free dues.
    function capacity(address member) public view returns (uint256) {
        Member storage m = members[member];
        return (m.backingReceived - m.backingCommitted) + (m.line - m.committedLine) + _freeOwnDues(m);
    }

    /// @notice What the member can still attest to others: free stake and dues.
    function freeToBack(address member) external view returns (uint256) {
        return _freeToBack(members[member]);
    }

    function memberOf(address who) external view returns (Member memory) {
        return members[who];
    }

    function attestersOf(address who) external view returns (address[] memory) {
        return attesters[who];
    }

    function guarantee(uint256 id) external view returns (Guarantee memory) {
        return guarantees[id];
    }

    function sharesOf(uint256 id) external view returns (Share[] memory) {
        return shares[id];
    }

    function guaranteeCount() external view returns (uint256) {
        return guarantees.length;
    }

    /// @notice History and a display composite. Information only: capacity never reads it (the dues bound).
    ///         composite = 10 x paid + 5 x remitted - 20 x lapsed - 10 x claims on members this one backed.
    function score(address who) external view returns (Score memory s) {
        Member storage m = members[who];
        s.guaranteesOpened = m.guaranteesOpened;
        s.guaranteesPaid = m.guaranteesPaid;
        s.claimsAsWorker = m.claimsAsWorker;
        s.contributionsRemitted = m.contributionsRemitted;
        s.contributionsLapsed = m.contributionsLapsed;
        s.attestationsGiven = m.attestationsGiven;
        s.attestationsReceived = m.attestationsReceived;
        s.attesteeClaims = m.attesteeClaims;
        s.contributedTotal = m.contributedTotal;
        s.backingLost = m.backingLost;
        s.composite = int256(uint256(m.guaranteesPaid)) * 10 + int256(uint256(m.contributionsRemitted)) * 5
            - int256(uint256(m.contributionsLapsed)) * 20 - int256(uint256(m.attesteeClaims)) * 10;
    }

    // ---------------------------------------------------------------- internals

    function _useNonce(address signer, uint256 nonce) internal {
        if (nonceUsed[signer][nonce]) revert NonceAlreadyUsed();
        nonceUsed[signer][nonce] = true;
    }

    /// @dev Stake and uncommitted dues not yet given as backing.
    function _freeToBack(Member storage m) internal view returns (uint256) {
        uint256 own = m.stake + (m.dues - m.committedDues);
        return own > m.backingGiven ? own - m.backingGiven : 0;
    }

    /// @dev Dues usable for the member's own guarantees: uncommitted dues not standing behind backing given, after
    ///      stake has covered as much of that backing as it can.
    function _freeOwnDues(Member storage m) internal view returns (uint256) {
        uint256 free = m.dues - m.committedDues;
        uint256 backedFromDues = m.backingGiven > m.stake ? m.backingGiven - m.stake : 0;
        return free > backedFromDues ? free - backedFromDues : 0;
    }

    /// @dev Fix each attester's share of `amount` now, pro rata to its unlocked backing, remainder to whoever has room.
    function _lockShares(uint256 id, address member_, uint256 amount) internal {
        Member storage m = members[member_];
        address[] storage list = attesters[member_];
        uint256 n = list.length;
        uint256 totalFree = m.backingReceived - m.backingCommitted;
        uint256[] memory part = new uint256[](n);
        uint256 left = amount;
        for (uint256 k; k < n; k++) {
            address att = list[k];
            part[k] = (amount * (backing[att][member_] - lockedBacking[att][member_])) / totalFree;
            left -= part[k];
        }
        for (uint256 k; k < n && left != 0; k++) {
            address att = list[k];
            uint256 room = backing[att][member_] - lockedBacking[att][member_] - part[k];
            uint256 add = room < left ? room : left;
            part[k] += add;
            left -= add;
        }
        for (uint256 k; k < n; k++) {
            if (part[k] == 0) continue;
            address att = list[k];
            lockedBacking[att][member_] += part[k];
            shares[id].push(Share({ attester: att, amount: uint128(part[k]) }));
            emit ShareLocked(id, att, part[k]);
        }
        m.backingCommitted += amount;
    }

    function _release(uint256 id, Guarantee storage g) internal {
        Member storage w = members[g.worker];
        Share[] storage s = shares[id];
        for (uint256 k; k < s.length; k++) {
            lockedBacking[s[k].attester][g.worker] -= s[k].amount;
        }
        w.backingCommitted -= g.fromBacking;
        w.committedLine -= g.fromLine;
        w.committedDues -= g.fromDues;
        outstanding -= g.amount;
        groupExposure[g.groupId] -= g.amount;
        clientOpen[g.clientId] = false;
    }

    /// @dev Charge each attester exactly its share: stake first (the cash returns to the reserve), then its
    ///      uncommitted dues, which the backing invariant guarantees cover the rest.
    function _consumeShares(uint256 id, address member_, uint256 total) internal {
        Member storage m = members[member_];
        Share[] storage s = shares[id];
        for (uint256 k; k < s.length; k++) {
            address att = s[k].attester;
            uint256 amt = s[k].amount;
            uint256 left = backing[att][member_] - amt;
            backing[att][member_] = left;
            lockedBacking[att][member_] -= amt;
            Member storage a = members[att];
            a.backingGiven -= amt;
            a.backingLost += amt;
            a.attesteeClaims += 1;
            uint256 slash = amt <= a.stake ? amt : a.stake;
            if (slash != 0) {
                a.stake -= slash;
                totalStake -= slash;
                reserve += slash;
            }
            if (amt != slash) {
                a.dues -= amt - slash;
                totalDues -= amt - slash;
            }
            if (left == 0) _unlink(att, member_);
            emit BackingConsumed(id, att, member_, amt, slash);
        }
        m.backingReceived -= total;
        m.backingCommitted -= total;
    }

    function _unlink(address att, address member_) internal {
        address[] storage list = attesters[member_];
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            if (list[i] == att) {
                list[i] = list[n - 1];
                list.pop();
                break;
            }
        }
        members[att].openAttestees -= 1;
    }
}
