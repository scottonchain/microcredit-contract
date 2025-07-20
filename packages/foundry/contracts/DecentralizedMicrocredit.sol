// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";

contract DecentralizedMicrocredit {
    // NOTE: Variable-rate parameters removed in favour of fixed-rate design.
    // uint256 public rMin;
    // uint256 public rMax;
    IERC20 public immutable usdc;
    address public owner;
    address public oracle;
    uint256 public constant SCALE = 1e6; // Used for credit score scaling
    uint256 public constant BASIS_POINTS = 10000; // Interest-rate scaling (1e4 = 100%)
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 private nextLoanId = 1;

    // PageRank constants (using smaller scale to avoid overflow)
    uint256 constant PR_SCALE = 100000; // 1.0 = 100,000 (smaller scale)
    uint256 constant PR_ALPHA = 85000; // 0.85 = 85,000
    uint256 constant PR_TOL = 100; // 1e-6 * PR_SCALE

    /* ─────────────────────────────────────────────────────────────────────────────
     *  PERSONALIZATION & PRIME RATE PARAMETERS
     *
     *  These variables drive the new weighted PageRank teleportation mechanism
     *  as well as the base interest-rate economics introduced in this upgrade.
     *  All values are denominated in USDC’s 6-decimal format to keep consistency
     *  with deposits, then normalized to PR_SCALE (100 000) for PageRank maths.
     *
     *  ‣ basePersonalization     :   Non-zero weight given to every address so
     *                                 even nodes without deposits/KYC receive a
     *                                 small share of the teleportation mass.
     *  ‣ kycBonus               :   Extra weight applied if `isKYCVerified`.
     *  ‣ personalizationCap      :   Upper bound of deposit amount considered
     *                                 for the funding component (prevents whales
     *                                 from dominating teleportation weights).
     *
     *  PRIME RATE:  Traditional banking concept used here as a configurable
     *  base APR.  The final loan rate is a simple fixed sum `primeRate +
     *  riskPremium` – both set at the platform level, independent of user
     *  credit score (score now only gates maximum borrow size).
     * ────────────────────────────────────────────────────────────────────────────*/
    uint256 public basePersonalization;
    uint256 public kycBonus;
    uint256 public personalizationCap;

    // ────────────── FIXED INTEREST PARAMETERS ──────────────
    // All interest-rate values are expressed in BASIS_POINTS (1e4 = 100%).
    // EFFR (Effective Federal Funds Rate), currently set manually for testing.
    // In production, this will be fetched from Pyth Network:
    // https://www.pyth.network/price-feeds/rates-effr
    uint256 public effrRate; // Base rate derived from EFFR (e.g. 750 = 7.5%)
    uint256 public riskPremium; // Additional platform-wide premium (basis points)

    // Maximum principal a borrower can request scaled in USDC (6-decimals)
    uint256 public maxLoanAmount;

    // Per-lender cumulative deposit tracker used when computing personalization
    mapping(address => uint256) public lenderDeposits;

    struct Loan {
        uint256 principal;
        uint256 outstanding;
        address borrower;
        uint256 interestRate;
        bool isActive;
    }
    struct Attestation {
        address attester;
        uint256 weight;
    }
    mapping(uint256 => Loan) private loans;
    mapping(address => Attestation[]) private borrowerAttestations;
    // Tracks whether a borrower has completed KYC verification
    mapping(address => bool) public isKYCVerified;

    // Lending pool tracking
    uint256 public totalDeposits; // Cumulative deposits into the pool (6-decimals like USDC)
    uint256 public lenderCount; // Unique depositors count
    mapping(address => bool) private isLender; // Tracks whether an address has deposited before

    // ────────────── ENUMERATION STORAGE ──────────────
    // All ever-created loan IDs
    uint256[] private _allLoanIds;
    // Unique borrowers and mapping to their loan IDs
    address[] private _borrowers;
    mapping(address => bool) private _borrowerSeen;
    mapping(address => uint256[]) private _borrowerLoans;

    // Unique lenders list (addresses that have deposited at least once)
    address[] private _lenders;

    // Unique attesters – filled when an address calls recordAttestation at least once
    address[] private _attesters;
    mapping(address => bool) private _attesterSeen;

    // ────────────── LENDING UTILIZATION ──────────────
    // Tracks how much of the pool is currently committed to loans (principal value)
    uint256 public totalLentOut;

    // Maximum utilisation ratio expressed in BASIS_POINTS (e.g. 9000 = 90 %).
    uint256 public lendingUtilizationCap;

    // Amount of pool liquidity committed to yet-undisbursed loans
    uint256 public reservedLiquidity;

    // PageRank storage
    address[] private pagerankNodes;
    mapping(address => bool) private pagerankNodeExists;
    mapping(address => mapping(address => uint256)) private pagerankEdges;
    mapping(address => uint256) private pagerankOutDegree;
    // Exposed as public to enable off-chain inspection and simplify tests.
    mapping(address => uint256) public pagerankScores;
    mapping(address => mapping(address => uint256))
        private pagerankStochasticEdges;

    constructor(
        uint256 _effrRate,
        uint256 _riskPremium,
        uint256 _maxLoanAmount,
        address _usdc,
        address _oracle
    ) {
        require(_usdc != address(0) && _oracle != address(0), "Invalid addresses");
        usdc = IERC20(_usdc);
        owner = msg.sender;
        oracle = _oracle;
        // Initialise fixed-rate parameters
        effrRate = _effrRate;
        riskPremium = _riskPremium;
        maxLoanAmount = _maxLoanAmount;
        basePersonalization = 100 * 1e6; // $100 in 6-decimals
        kycBonus = 100 * 1e6; // $100 bonus for KYC
        personalizationCap = 100 * 1e6; // Cap funding contribution at $100

        // Initialise utilisation cap at 90 %
        lendingUtilizationCap = 9000; // 90 % in BASIS_POINTS
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Owner only");
        _;
    }
    modifier onlyOracle() {
        require(msg.sender == oracle, "Oracle only");
        _;
    }

    // Note: variable-rate setter removed in the fixed-rate model.
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle");
        oracle = _oracle;
    }

    // ─────────────── ADMIN SETTERS (UX helpers) ───────────────
    // Simple owner-only mutators exposing each economic parameter individually.
    // NOTE: no additional validation performed here besides implicit uint range;
    // callers (the dApp) should supply sane values.
    function setKycBonus(uint256 _kycBonus) external onlyOwner {
        kycBonus = _kycBonus;
    }

    function setBasePersonalization(uint256 _base) external onlyOwner {
        basePersonalization = _base;
    }

    function setPersonalizationCap(uint256 _cap) external onlyOwner {
        personalizationCap = _cap;
    }

    // Placeholder admin setter – will be replaced by oracle-powered update once
    // EFFR is sourced directly from Pyth Network in production deployments.
    function setEffrRate(uint256 _effrRate) external onlyOwner {
        effrRate = _effrRate;
    }

    function setRiskPremium(uint256 _riskPremium) external onlyOwner {
        riskPremium = _riskPremium;
    }

    function setMaxLoanAmount(uint256 _maxLoanAmount) external onlyOwner {
        maxLoanAmount = _maxLoanAmount;
    }

    /**
     * @notice Update the maximum portion of pool funds that can be lent out.
     * @param cap New cap in BASIS_POINTS (10 000 = 100 %).
     */
    function setLendingUtilizationCap(uint256 cap) external onlyOwner {
        require(cap <= BASIS_POINTS, "Cap cannot exceed 100%");
        lendingUtilizationCap = cap;
    }

    /**
     * ------------------------------------------------------------------------
     *  VIEW HELPERS FOR FRONT-END
     * ---------------------------------------------------------------------*/

    /**
     * @notice Borrower loan rate (EFFR + premium) expressed in BASIS_POINTS.
     */
    function getLoanRate() external view returns (uint256) {
        return effrRate + riskPremium; // e.g. 1000 = 10 % APR
    }

    /**
     * @notice Projected APY for liquidity providers given current utilisation.
     * @dev    Returns 0 when the pool is empty.
     *         APY = LoanRate * Utilisation.
     */
    function getFundingPoolAPY() external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        uint256 active = totalLentOut + reservedLiquidity; // principal accruing interest (includes yet-to-disburse)
        uint256 utilisationBp = (active * BASIS_POINTS) / totalDeposits; // 0-10000
        uint256 loanRateBp = effrRate + riskPremium;
        return (loanRateBp * utilisationBp) / BASIS_POINTS; // BASIS_POINTS output
    }

    function depositFunds(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // Update pool stats
        totalDeposits += amount;
        // Track individual deposits so we can compute funding-based weight in
        // the PageRank personalization vector.
        lenderDeposits[msg.sender] += amount;
        if (!isLender[msg.sender]) {
            isLender[msg.sender] = true;
            lenderCount += 1;
            _lenders.push(msg.sender);
        }
    }

    function withdrawFunds(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        require(
            lenderDeposits[msg.sender] >= amount,
            "Insufficient balance"
        );

        uint256 liquidBalance = usdc.balanceOf(address(this));
        require(
            liquidBalance - reservedLiquidity >= amount,
            "Insufficient liquidity"
        );

        lenderDeposits[msg.sender] -= amount;
        totalDeposits -= amount;
        require(usdc.transfer(msg.sender, amount), "Transfer failed");
    }

    /**
     * @notice Return high-level pool statistics for front-end display
     * @return _totalDeposits   Sum of all deposits ever made (USDC 6-decimals)
     * @return _availableFunds  Liquid USDC available to lend/withdraw (excludes reserved)
     * @return _reservedFunds   Funds committed to pending loan disbursements
     * @return _lenderCount     Unique addresses that have deposited
     */
    function getPoolInfo()
        external
        view
        returns (
            uint256 _totalDeposits,
            uint256 _availableFunds,
            uint256 _reservedFunds,
            uint256 _lenderCount
        )
    {
        _totalDeposits = totalDeposits;
        _reservedFunds = reservedLiquidity;
        _availableFunds = usdc.balanceOf(address(this)) - _reservedFunds;
        _lenderCount = lenderCount;
    }

    function previewLoanTerms(
        address /* borrower */,
        uint256 principal,
        uint256 repaymentPeriod
    ) external view returns (uint256 interestRate, uint256 payment) {
        // Fixed global rate (prime + premium)
        interestRate = effrRate + riskPremium;
        uint256 interest = (principal * interestRate * repaymentPeriod) /
            (BASIS_POINTS * SECONDS_PER_YEAR);
        payment = (principal + interest) / (repaymentPeriod / 30 days);
    }

    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "Amount > 0");
        uint256 score = getCreditScore(msg.sender);
        require(score > 0, "Score > 0");

        // Enforce per-borrower loan cap proportional to credit score
        // Compute allowed amount using division first to prevent overflow when
        // maxLoanAmount is very large (e.g. type(uint256).max in tests).
        // Safe because SCORE ≤ SCALE, so (maxLoanAmount / SCALE) fits in uint256.
        uint256 allowed = (maxLoanAmount / SCALE) * score;
        require(amount <= allowed, "Amount exceeds maximum for score");

        // ────────── Utilisation guard ──────────
        uint256 newTotalCommitted = reservedLiquidity + totalLentOut + amount;
        uint256 maxAllowedCommitment = (totalDeposits * lendingUtilizationCap) /
            BASIS_POINTS;
        require(
            newTotalCommitted <= maxAllowedCommitment,
            "Pool utilisation cap exceeded"
        );

        // Ensure sufficient unreserved liquidity in the pool
        uint256 liquidBalance = usdc.balanceOf(address(this));
        require(
            amount <= liquidBalance - reservedLiquidity,
            "Insufficient available liquidity"
        );

        // Reserve liquidity immediately upon loan approval; this counts towards utilisation via reservedLiquidity
        reservedLiquidity += amount;

        loanId = nextLoanId++;
        uint256 rate = effrRate + riskPremium;
        uint256 interest = (amount * rate) / BASIS_POINTS;
        loans[loanId] = Loan(amount, amount + interest, msg.sender, rate, true);

        // ───── enumeration bookkeeping ─────
        _allLoanIds.push(loanId);
        if (!_borrowerSeen[msg.sender]) {
            _borrowerSeen[msg.sender] = true;
            _borrowers.push(msg.sender);
        }
        _borrowerLoans[msg.sender].push(loanId);
    }

function disburseLoan(uint256 loanId) external {
    Loan storage loan = loans[loanId];
    require(loan.isActive, "Loan inactive");

    // Move principal from reserved to lent-out balance
    reservedLiquidity -= loan.principal;
    totalLentOut += loan.principal;

    bool success = usdc.transfer(loan.borrower, loan.principal);
    if (!success) {
        revert("Transfer failed");
    }
}


    function repayLoan(uint256 loanId, uint256 amount) external {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan inactive");
        require(msg.sender == loan.borrower, "Borrower only");
        require(amount > 0, "Amount > 0");
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        if (amount >= loan.outstanding) {
            // Loan fully repaid – free up utilised principal
            totalLentOut -= loan.principal;

            loan.outstanding = 0;
            loan.isActive = false;
        } else {
            loan.outstanding -= amount;
        }
    }


    function addressToString(address _address) public pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(_address);
        bytes memory hexString = new bytes(42); // Length for '0x' + 40 hex chars

        hexString[0] = '0';
        hexString[1] = 'x';

        for (uint i = 0; i < 20; i++) {
            uint8 byteVal = uint8(addressBytes[i]);
            hexString[2 + i * 2] = _byteToHexChar(byteVal >> 4);
            hexString[3 + i * 2] = _byteToHexChar(byteVal & 0x0f);
        }

        return string(hexString);
    }

    // Helper function to convert a byte to its corresponding hex character
    function _byteToHexChar(uint8 _byte) internal pure returns (bytes1) {
        if (_byte < 10) {
            return bytes1(_byte + 48); // ASCII code for '0' to '9'
        } else {
            return bytes1(_byte + 87); // ASCII code for 'a' to 'f'
        }
    }

 function recordAttestation(address borrower, uint256 weight) external {
    require(weight <= SCALE, "Weight too high");
    require(borrower != msg.sender, "Self-attestation");

    if (!_attesterSeen[msg.sender]) {
        _attesterSeen[msg.sender] = true;
        _attesters.push(msg.sender);
    }

    _addPagerankNode(msg.sender);
    _addPagerankNode(borrower);
    _addPagerankEdge(msg.sender, borrower, weight);

    Attestation[] storage attests = borrowerAttestations[borrower];
    for (uint256 i = 0; i < attests.length; i++) {
        if (attests[i].attester == msg.sender) {
            attests[i].weight = weight;
            return;
        }
    }
    attests.push(Attestation(msg.sender, weight));
}


    // ─────────────────────────────────────────────────────────────────────
    //  CREDIT SCORE
    //  Computed dynamically from PageRank so no storage is required.
    //  Returns a value scaled to `SCALE` (1e6) for compatibility with the
    //  previous fixed-score design.
    // -------------------------------------------------------------------
    function getMaxPageRankScore() public view returns (uint256) {
        uint256 maxScore = 0;
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            uint256 score = pagerankScores[node];
            if (score > maxScore) {
                maxScore = score;
            }
        }
        return maxScore;
    }

    function getCreditScore(address user) public view returns (uint256) {
        // Converts PageRank score to credit score using a softplus-like curve:
        //   credit = (SCALE * x) / (x + 100), where x = (PR * 1000) / maxPageRank
        // Produces a smooth 0 → SCALE output that breaks PageRank’s zero-sum nature.
        uint256 pr = pagerankScores[user]; // 0 – maxPageRank
        uint256 maxPageRank = getMaxPageRankScore();
        
        if (maxPageRank == 0) return 0; // No PageRank scores computed yet
        
        uint256 x = (pr * 1000) / maxPageRank; // 0 – 1000
        return (SCALE * x) / (x + 100); // 0 – SCALE (1e6)
    }

    /**
     * @notice Mark a user as having passed KYC verification
     * @dev Can only be called by the oracle address set by the owner
     * @param user The address of the user that has completed KYC
     */
    function markKYCVerified(address user) external onlyOracle {
        require(!isKYCVerified[user], "Already verified");
        isKYCVerified[user] = true;
    }

    /**
     * @notice Register a borrower (for testing purposes)
     * @dev Can only be called by the owner or oracle
     * @param borrower The address of the borrower to register
     */
    function registerBorrower(address borrower) external {
        require(msg.sender == owner || msg.sender == oracle, "Only owner or oracle can register borrowers");
        if (!_borrowerSeen[borrower]) {
            _borrowerSeen[borrower] = true;
            _borrowers.push(borrower);
        }
    }

    function getLoan(
        uint256 loanId
    )
        external
        view
        returns (
            uint256 principal,
            uint256 outstanding,
            address borrower,
            uint256 interestRate,
            bool isActive
        )
    {
        Loan storage loan = loans[loanId];
        return (
            loan.principal,
            loan.outstanding,
            loan.borrower,
            loan.interestRate,
            loan.isActive
        );
    }

    function computeAttesterReward(
        uint256 loanId,
        address attester
    ) external view returns (uint256 reward) {
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
        uint256 totalReward = (loan.principal * 50000) / SCALE;
        reward = (totalReward * attesterWeight) / totalWeight;
    }

    // PageRank functions
    function computePageRank() external returns (uint256 iterations) {
        return _computePageRank(PR_ALPHA, 100, PR_TOL); // Adjusted maxIter and tol
    }

    function getPageRankScore(address node) external view returns (uint256) {
        return pagerankScores[node];
    }

    function getAllPageRankScores()
        external
        view
        returns (address[] memory nodes, uint256[] memory scores)
    {
        nodes = pagerankNodes;
        scores = new uint256[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            scores[i] = pagerankScores[nodes[i]];
        }
    }

    function clearPageRankState() external {
        // Clear all PageRank data
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            pagerankNodeExists[node] = false;
            pagerankScores[node] = 0;
            pagerankOutDegree[node] = 0;

            // Clear edges
            for (uint256 j = 0; j < pagerankNodes.length; j++) {
                address target = pagerankNodes[j];
                pagerankEdges[node][target] = 0;
                pagerankStochasticEdges[node][target] = 0;
            }
        }

        // Clear arrays
        delete pagerankNodes;
    }

    /**
     * @notice Clear PageRank state efficiently (gas-optimized version)
     * @dev Only clears node data, not edge data (edges will be overwritten anyway)
     */
    function clearPageRankStateEfficient() external {
        // Clear node data only (skip edge clearing to save gas)
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            pagerankNodeExists[node] = false;
            pagerankScores[node] = 0;
            pagerankOutDegree[node] = 0;
        }

        // Clear arrays
        delete pagerankNodes;
    }

    function _addPagerankNode(address node) internal {
        if (!pagerankNodeExists[node]) {
            pagerankNodes.push(node);
            pagerankNodeExists[node] = true;
        }
    }

    function _addPagerankEdge(
        address from,
        address to,
        uint256 weight
    ) internal {
        pagerankEdges[from][to] = weight;
        pagerankOutDegree[from] += weight;
    }

    function _computePageRank(
        uint256 alpha,
        uint256 maxIter,
        uint256 tol
    ) internal returns (uint256 iterations) {
        if (pagerankNodes.length == 0) return 0;

        // Initialize scores to 1.0 / numberOfNodes (scaled) - NetworkX default
        uint256 initialScore = PR_SCALE / pagerankNodes.length;
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            pagerankScores[node] = initialScore;
        }

        // Create stochastic graph (normalize edge weights by out-degree)
        _createStochasticGraph();

        // >>>>>> BUILD PERSONALIZATION VECTOR BASED ON FUNDING & KYC <<<<<<
        // Build node-specific teleportation weights (funding + KYC + base)
        uint256[] memory personalizationVector = _buildPersonalizationVector();
        // <<<<<< END ADDITION >>>>>>

        // Run PageRank iterations
        iterations = 0;
        bool converged = false;

        while (iterations < maxIter && !converged) {
            converged = _pagerankIteration(alpha, tol, personalizationVector);
            iterations++;
        }

        return iterations;
    }

    function _createStochasticGraph() internal {
        // Clear previous stochastic weights
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            uint256 outDegree = pagerankOutDegree[node];

            // Clear all stochastic edges for this node
            for (uint256 j = 0; j < pagerankNodes.length; j++) {
                address target = pagerankNodes[j];
                pagerankStochasticEdges[node][target] = 0;
            }

            if (outDegree > 0) {
                // Normalize edge weights by out-degree
                for (uint256 j = 0; j < pagerankNodes.length; j++) {
                    address target = pagerankNodes[j];
                    uint256 originalWeight = pagerankEdges[node][target];
                    if (originalWeight > 0) {
                        // Normalize: weight / out_degree
                        pagerankStochasticEdges[node][target] =
                            (originalWeight * PR_SCALE) /
                            outDegree;
                    }
                }
            }
        }
    }

    /**
     * @dev One Gauss-Seidel style PageRank iteration using node-specific
     *      personalization vector.  Returns `true` when L1 delta < tol * N.
     */
    function _pagerankIteration(
        uint256 alpha,
        uint256 tol,
        uint256[] memory personalizationVector
    ) internal returns (bool converged) {
        uint256 totalDelta = 0;

        // Compute dangling sum (sum of scores from nodes with no outgoing edges)
        uint256 danglingSum = 0;
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            if (pagerankOutDegree[node] == 0) {
                danglingSum += pagerankScores[node];
            }
        }

        // Store old scores in temporary array
        uint256[] memory oldScores = new uint256[](pagerankNodes.length);
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            oldScores[i] = pagerankScores[pagerankNodes[i]];
        }

        // Process each node
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            uint256 oldScore = oldScores[i];
            uint256 incomingScore = 0;

            // Sum incoming scores from nodes that point to this node
            // This is the key part: we need to accumulate scores for the target node
            for (uint256 j = 0; j < pagerankNodes.length; j++) {
                address source = pagerankNodes[j];
                uint256 weight = pagerankStochasticEdges[source][node];
                if (weight > 0) {
                    // NetworkX does: x[nbr] += alpha * xlast[n] * wt
                    // So we accumulate for the target node (node) from source
                    uint256 sourceScore = oldScores[j];
                    uint256 contribution = (alpha * sourceScore * weight) /
                        (PR_SCALE * PR_SCALE);
                    incomingScore += contribution;
                }
            }

            // Add dangling contribution (distributed according to personalization vector)
            uint256 danglingContribution = 0;
            if (danglingSum > 0) {
                // NetworkX: x[n] += danglesum * dangling_weights.get(n, 0)
                // Since we use uniform personalization, dangling_weights[n] = 1/N
                uint256 danglingPerNode = (alpha * danglingSum) /
                    (PR_SCALE * pagerankNodes.length);
                danglingContribution = danglingPerNode;
            }

            // Update score using weighted personalization vector
            // Teleportation: (1 – α) * p[node]  (all values scaled by PR_SCALE)
            uint256 teleportationContribution = ((PR_SCALE - alpha) *
                personalizationVector[i]) / PR_SCALE;
            uint256 newScore = incomingScore +
                danglingContribution +
                teleportationContribution;
            pagerankScores[node] = newScore;

            // Track convergence
            uint256 delta = oldScore > newScore
                ? oldScore - newScore
                : newScore - oldScore;
            totalDelta += delta;
        }

        return totalDelta < (tol * pagerankNodes.length);
    }

    function _calculateInterest(
        uint256 /*ignored*/
    ) internal view returns (uint256 rate) {
        // Fixed platform-wide rate independent of individual credit score.
        return effrRate + riskPremium;
    }

    /**
     * @notice Assemble & normalise the personalization vector for PageRank.
     * @dev Each node’s raw weight = BASE + min(deposits, CAP) + (KYC? BONUS:0).
     *      The array is then scaled so that Σp_i = PR_SCALE (1.0 in our units).
     */
    function _buildPersonalizationVector()
        internal
        view
        returns (uint256[] memory vector)
    {
        uint256 n = pagerankNodes.length;
        vector = new uint256[](n);
        if (n == 0) {
            return vector;
        }

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < n; i++) {
            address node = pagerankNodes[i];

            uint256 weight = basePersonalization;

            uint256 depositWeight = lenderDeposits[node];
            if (depositWeight > personalizationCap) {
                depositWeight = personalizationCap;
            }
            weight += depositWeight;

            if (isKYCVerified[node]) {
                weight += kycBonus;
            }

            vector[i] = weight;
            totalWeight += weight;
        }

        if (totalWeight == 0) {
            for (uint256 i = 0; i < n; i++) {
                vector[i] = PR_SCALE / n;
            }
        } else {
            for (uint256 i = 0; i < n; i++) {
                vector[i] = (vector[i] * PR_SCALE) / totalWeight;
            }
        }
    }

    /**
     * ------------------------------------------------------------------------
     *  ENUMERATION GETTERS – used by Admin dashboard
     * ---------------------------------------------------------------------*/

    function getAllLoanIds() external view returns (uint256[] memory) {
        return _allLoanIds;
    }

    function getBorrowers() external view returns (address[] memory) {
        return _borrowers;
    }

    function getBorrowerLoanIds(
        address borrower
    ) external view returns (uint256[] memory) {
        return _borrowerLoans[borrower];
    }

    function getLenders() external view returns (address[] memory) {
        return _lenders;
    }

    function getAttesters() external view returns (address[] memory) {
        return _attesters;
    }

    /**
     * @notice Return all attestations received by a borrower for front-end use.
     */
    function getBorrowerAttestations(
        address borrower
    ) external view returns (Attestation[] memory) {
        return borrowerAttestations[borrower];
    }

    /**
     * @notice Get all addresses that have received attestations (borrowers)
     * @dev This returns addresses that have attestations, even if they haven't requested loans
     */
    function getBorrowersWithAttestations() external view returns (address[] memory) {
        address[] memory borrowers = new address[](pagerankNodes.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            if (borrowerAttestations[node].length > 0) {
                borrowers[count] = node;
                count++;
            }
        }
        
        // Resize array to actual count
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = borrowers[i];
        }
        
        return result;
    }
}
