// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

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
 *      Backing moves trust one hop from an attester to a member and never creates it: received backing cannot be
 *      attested onward. A guarantee commits the worker's capacity (received backing, then line, then dues). A claim
 *      pays the worker in full and consumes the committed capacity: attesters lose their backing pro rata (their
 *      stake first, which returns cash to the reserve, then their dues), the issuer's budget is spent, the worker's
 *      dues are written down. Capacity never reads history; the score is information only.
 *      Accounting identity: token.balanceOf(this) = reserve + totalStake + stray transfers.
 */
contract GuaranteeTrust is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    enum State {
        None,
        Open,
        Paid,
        Claimed,
        Cancelled
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
        uint256 backingCommitted; // received backing committed to own open guarantees
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
        uint128 amount;
        uint128 fromBacking;
        uint128 fromLine;
        uint128 fromDues;
        bytes32 termsHash;
        State state;
        bool remitted;
        bool lapsed;
        uint64 openedAt;
        uint64 paidAt;
        uint128 wage;
        uint128 contributionDue;
        bytes32 evidenceHash;
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

    // ledgers
    uint256 public reserve;
    uint256 public outstanding;
    uint256 public totalStake;
    uint256 public totalDues;
    uint256 public sponsorFunded;

    mapping(address => Member) internal members;
    mapping(address => mapping(address => uint256)) public backing; // attester => member => amount
    mapping(address => address[]) internal attesters; // member => current attesters
    mapping(address => mapping(address => bool)) public consent; // member => attester => allowed
    mapping(bytes32 => bool) public clientOpen;
    mapping(bytes32 => bool) public clientDefaulted;
    Guarantee[] internal guarantees;

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
    event RolesSet(address guardian, address adjudicator, address issuer, uint256 issuerBudget);
    event Paused(bool paused);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserve);
    event ReserveReleased(address indexed to, uint256 amount, uint256 reserve);
    event Staked(address indexed member, uint256 amount, uint256 stake);
    event Unstaked(address indexed member, uint256 amount, uint256 stake);
    event LineSet(address indexed member, uint256 line, uint256 issuerHeld);
    event Attested(address indexed attester, address indexed member, uint256 amount, uint256 backing);
    event ConsentSet(address indexed member, address indexed attester, bool allowed, address by);
    event BackingWithdrawn(address indexed attester, address indexed member, uint256 amount, uint256 backing);
    event GuaranteeOpened(
        uint256 indexed id,
        address indexed worker,
        bytes32 indexed clientId,
        uint256 amount,
        uint256 fromBacking,
        uint256 fromLine,
        uint256 fromDues,
        bytes32 termsHash
    );
    event GuaranteeCancelled(uint256 indexed id);
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
    ) Ownable(owner_) {
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

    function setRoles(address guardian_, address adjudicator_, address issuer_, uint256 issuerBudget_) external onlyOwner {
        if (issuerBudget_ < issuerHeld + issuerSpent) revert BudgetExceeded();
        guardian = guardian_;
        adjudicator = adjudicator_;
        issuer = issuer_;
        issuerBudget = issuerBudget_;
        emit RolesSet(guardian_, adjudicator_, issuer_, issuerBudget_);
    }

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

    /// @notice Stops new guarantees only. Payment records, remittances, claims and withdrawals keep working.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit Paused(paused_);
    }

    // ---------------------------------------------------------------- reserve

    /// @notice Anyone may fund the reserve. Funds are never returned to the funder; only uncommitted sponsor
    ///         capital can be released by the owner, never dues.
    function fundReserve(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        sponsorFunded += amount;
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    /// @notice Releases sponsor capital that is neither committed to open guarantees nor standing behind dues.
    function releaseReserve(address to, uint256 amount) external onlyOwner {
        if (amount > releasable()) revert ReleaseTooLarge();
        reserve -= amount;
        sponsorFunded -= amount;
        token.safeTransfer(to, amount);
        emit ReserveReleased(to, amount, reserve);
    }

    function releasable() public view returns (uint256) {
        uint256 locked = outstanding + totalDues;
        uint256 free = reserve > locked ? reserve - locked : 0;
        return free < sponsorFunded ? free : sponsorFunded;
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
    ///         its member has committed, so held budget cannot be rotated away from open exposure.
    function setLine(address member, uint256 newLine) external onlyIssuer {
        if (newLine > lineCap) revert BadParam();
        Member storage m = members[member];
        if (newLine < m.committedLine) revert LineCommitted();
        if (newLine > m.line) {
            uint256 add = newLine - m.line;
            if (issuerHeld + issuerSpent + add > issuerBudget) revert BudgetExceeded();
            issuerHeld += add;
        } else {
            issuerHeld -= m.line - newLine;
        }
        m.line = newLine;
        emit LineSet(member, newLine, issuerHeld);
    }

    // ---------------------------------------------------------------- backing (one hop)

    /// @notice A member chooses who may back it. Without consent anyone with a little stake could fill a
    ///         newcomer's attester slots and lock out real attesters.
    function setConsent(address attester, bool allowed) external {
        consent[msg.sender][attester] = allowed;
        emit ConsentSet(msg.sender, attester, allowed, msg.sender);
    }

    /// @notice The issuer may record a newcomer's consent for it (a newcomer may hold no gas), as the vetting
    ///         programme that knows the member.
    function setConsentFor(address member, address attester, bool allowed) external onlyIssuer {
        consent[member][attester] = allowed;
        emit ConsentSet(member, attester, allowed, msg.sender);
    }

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

    /// @notice Withdraw backing not committed to the member's open guarantees (each attester's committed share is
    ///         pro rata to its backing).
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

    function withdrawableBacking(address attester, address member) public view returns (uint256) {
        uint256 b = backing[attester][member];
        Member storage m = members[member];
        if (b == 0 || m.backingCommitted == 0) return b;
        uint256 locked = (b * m.backingCommitted + m.backingReceived - 1) / m.backingReceived; // round up
        return b > locked ? b - locked : 0;
    }

    // ---------------------------------------------------------------- guarantees

    function openGuarantee(address worker, bytes32 clientId, uint256 amount, bytes32 termsHash)
        external
        onlyAdjudicator
        returns (uint256 id)
    {
        if (paused) revert IsPaused();
        if (amount == 0) revert ZeroAmount();
        if (clientOpen[clientId] || clientDefaulted[clientId]) revert ClientBlocked();
        Member storage w = members[worker];
        if (w.unpaidContributions != 0) revert ContributionOutstanding();
        if (amount * BPS > reserve * maxShareBps) revert ExposureCap();
        if (outstanding + amount + floorMultiple * amount > reserve) revert ReserveFloor();

        uint256 fromBacking = w.backingReceived - w.backingCommitted;
        if (fromBacking > amount) fromBacking = amount;
        uint256 rest = amount - fromBacking;
        uint256 fromLine = w.line - w.committedLine;
        if (fromLine > rest) fromLine = rest;
        uint256 fromDues = rest - fromLine;
        if (fromDues > _freeOwnDues(w)) revert InsufficientCapacity();

        w.backingCommitted += fromBacking;
        w.committedLine += fromLine;
        w.committedDues += fromDues;
        outstanding += amount;
        clientOpen[clientId] = true;
        w.guaranteesOpened += 1;

        id = guarantees.length;
        guarantees.push(
            Guarantee({
                worker: worker,
                clientId: clientId,
                amount: uint128(amount),
                fromBacking: uint128(fromBacking),
                fromLine: uint128(fromLine),
                fromDues: uint128(fromDues),
                termsHash: termsHash,
                state: State.Open,
                remitted: false,
                lapsed: false,
                openedAt: uint64(block.timestamp),
                paidAt: 0,
                wage: 0,
                contributionDue: 0,
                evidenceHash: bytes32(0)
            })
        );
        emit GuaranteeOpened(id, worker, clientId, amount, fromBacking, fromLine, fromDues, termsHash);
    }

    /// @notice The job did not go ahead: release everything, record nothing against anyone.
    function cancelGuarantee(uint256 id) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        g.state = State.Cancelled;
        _release(g);
        emit GuaranteeCancelled(id);
    }

    /// @notice The client paid the wage. The contribution becomes due; the commitment is released.
    function markPaid(uint256 id, uint256 wage, bytes32 evidenceHash) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        g.state = State.Paid;
        g.wage = uint128(wage);
        g.paidAt = uint64(block.timestamp);
        g.evidenceHash = evidenceHash;
        _release(g);
        uint256 due = (wage * contributionBps) / BPS;
        if (due > contributionCap) due = contributionCap;
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

    /// @notice After the remit window anyone may record a lapse. It is history, not a debt: the contribution stays
    ///         payable, and until it is paid the worker gets no new guarantee.
    function markLapsed(uint256 id) external {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Paid || g.remitted || g.lapsed) revert NothingDue();
        if (block.timestamp < g.paidAt + remitWindow) revert TooEarly();
        g.lapsed = true;
        members[g.worker].contributionsLapsed += 1;
        emit ContributionLapsed(id, g.worker);
    }

    /// @notice The client did not pay. The reserve pays the worker in full; the worker owes nothing. The capacity
    ///         that underwrote the guarantee is consumed: attesters' backing pro rata, the issuer line, the dues.
    function claim(uint256 id, bytes32 evidenceHash) external onlyAdjudicator {
        Guarantee storage g = guarantees[id];
        if (g.state != State.Open) revert WrongState();
        g.state = State.Claimed;
        g.evidenceHash = evidenceHash;
        address worker = g.worker;
        Member storage w = members[worker];
        uint256 amount = g.amount;

        outstanding -= amount;
        clientOpen[g.clientId] = false;
        clientDefaulted[g.clientId] = true;
        w.claimsAsWorker += 1;

        if (g.fromLine != 0) {
            w.committedLine -= g.fromLine;
            w.line -= g.fromLine;
            issuerHeld -= g.fromLine;
            issuerSpent += g.fromLine;
            emit LineConsumed(id, worker, g.fromLine);
        }
        if (g.fromDues != 0) {
            w.committedDues -= g.fromDues;
            w.dues -= g.fromDues;
            totalDues -= g.fromDues;
            emit DuesConsumed(id, worker, g.fromDues);
        }
        if (g.fromBacking != 0) _consumeBacking(id, worker, g.fromBacking);

        reserve -= amount; // slashed stake added back inside _consumeBacking
        token.safeTransfer(worker, amount);
        emit Claimed(id, worker, g.clientId, amount, evidenceHash);
    }

    // ---------------------------------------------------------------- views

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

    function _release(Guarantee storage g) internal {
        Member storage w = members[g.worker];
        w.backingCommitted -= g.fromBacking;
        w.committedLine -= g.fromLine;
        w.committedDues -= g.fromDues;
        outstanding -= g.amount;
        clientOpen[g.clientId] = false;
    }

    /// @dev Charge `loss` of received backing to `member`'s attesters pro rata. Each attester pays from its stake
    ///      first (the cash returns to the reserve), then from its uncommitted dues.
    function _consumeBacking(uint256 id, address member_, uint256 loss) internal {
        Member storage m = members[member_];
        address[] storage list = attesters[member_];
        uint256 total = m.backingReceived;
        uint256 left = loss;
        uint256 n = list.length;
        // iterate backwards so that unlinking (swap and pop) does not skip anyone
        for (uint256 k = n; k > 0; k--) {
            address att = list[k - 1];
            uint256 b = backing[att][member_];
            uint256 share = k == 1 ? left : (loss * b) / total;
            left -= _charge(id, att, member_, b, share > left ? left : share);
        }
        // rounding can leave a few units when the last share was capped by its backing: take them from anyone left
        for (uint256 k = list.length; left != 0 && k > 0; k--) {
            address att = list[k - 1];
            left -= _charge(id, att, member_, backing[att][member_], left);
        }
        m.backingReceived -= loss;
        m.backingCommitted -= loss;
    }

    /// @dev Charge up to `want` to one attester's backing of `member_`; returns what was charged.
    function _charge(uint256 id, address att, address member_, uint256 b, uint256 want) internal returns (uint256 share) {
        share = want > b ? b : want;
        if (share == 0) return 0;
        backing[att][member_] = b - share;
        Member storage a = members[att];
        a.backingGiven -= share;
        a.backingLost += share;
        a.attesteeClaims += 1;
        uint256 slash = share <= a.stake ? share : a.stake;
        if (slash != 0) {
            a.stake -= slash;
            totalStake -= slash;
            reserve += slash;
        }
        uint256 fromDues = share - slash;
        if (fromDues != 0) {
            a.dues -= fromDues; // _freeToBack guaranteed uncommitted dues cover the rest
            totalDues -= fromDues;
        }
        if (b == share) _unlink(att, member_);
        emit BackingConsumed(id, att, member_, share, slash);
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
