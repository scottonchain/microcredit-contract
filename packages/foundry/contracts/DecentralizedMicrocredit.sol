// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DecentralizedMicrocredit {
    uint256 public rMin;
    uint256 public rMax;
    IERC20 public immutable usdc;
    address public owner;
    address public oracle;
    uint256 public constant SCALE = 1e6;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BACKPROPAGATION_FACTOR = 50e4;
    uint256 private nextLoanId = 1;
    
    // PageRank constants (using smaller scale to avoid overflow)
    uint256 constant PR_SCALE = 100000; // 1.0 = 100,000 (smaller scale)
    uint256 constant PR_ALPHA = 85000;  // 0.85 = 85,000
    uint256 constant PR_TOL = 100;      // 1e-6 * PR_SCALE
    
    struct Loan {
        uint256 principal;
        uint256 outstanding;
        address borrower;
        uint256 interestRate;
        bool isActive;
    }
    struct Attestation { address attester; uint256 weight; }
    mapping(uint256 => Loan) private loans;
    mapping(address => Attestation[]) private borrowerAttestations;
    mapping(address => uint256) private creditScores;
    mapping(address => uint256) private personalizationVector;
    
    // PageRank storage
    address[] private pagerankNodes;
    mapping(address => uint256) private pagerankNodeIndex;
    mapping(address => bool) private pagerankNodeExists;
    mapping(address => mapping(address => uint256)) private pagerankEdges;
    mapping(address => uint256) private pagerankOutDegree;
    mapping(address => uint256) private pagerankScores;
    mapping(address => mapping(address => uint256)) private pagerankStochasticEdges;
    
    constructor(uint256 _rMin, uint256 _rMax, address _usdc, address _oracle) {
        require(_rMin < _rMax, "rMin must be < rMax");
        require(_usdc != address(0) && _oracle != address(0), "");
        rMin = _rMin;
        rMax = _rMax;
        usdc = IERC20(_usdc);
        owner = msg.sender;
        oracle = _oracle;
    }
    modifier onlyOwner() { require(msg.sender == owner, ""); _; }
    modifier onlyOracle() { require(msg.sender == oracle, ""); _; }
    function setInterestRates(uint256 _rMin, uint256 _rMax) external onlyOwner {
        require(_rMin < _rMax, "rMin must be < rMax");
        rMin = _rMin;
        rMax = _rMax;
    }
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "");
        oracle = _oracle;
    }
    function depositFunds(uint256 amount) external {
        require(amount > 0, "");
        require(usdc.transferFrom(msg.sender, address(this), amount), "");
    }
    function previewLoanTerms(address borrower, uint256 principal, uint256 repaymentPeriod) external view returns (uint256 interestRate, uint256 payment) {
        uint256 score = creditScores[borrower];
        interestRate = _calculateInterest(score);
        uint256 interest = (principal * interestRate * repaymentPeriod) / (SCALE * SECONDS_PER_YEAR);
        payment = (principal + interest) / (repaymentPeriod / 30 days);
    }
    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "");
        uint256 score = creditScores[msg.sender];
        require(score > 0, "");
        loanId = nextLoanId++;
        uint256 rate = _calculateInterest(score);
        uint256 interest = (amount * rate * SECONDS_PER_YEAR) / (SCALE * SECONDS_PER_YEAR);
        loans[loanId] = Loan(amount, amount + interest, msg.sender, rate, true);
    }
    function disburseLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "");
        require(usdc.transfer(loan.borrower, loan.principal), "");
    }
    function repayLoan(uint256 loanId, uint256 amount) external {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "");
        require(msg.sender == loan.borrower, "");
        require(amount > 0, "");
        require(usdc.transferFrom(msg.sender, address(this), amount), "");
        if (amount >= loan.outstanding) {
            loan.outstanding = 0;
            loan.isActive = false;
        } else {
            loan.outstanding -= amount;
        }
        // Update personalization vector and attester rewards (simplified)
        personalizationVector[loan.borrower] += (loan.principal * 10000) / SCALE;
        Attestation[] storage attests = borrowerAttestations[loan.borrower];
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < attests.length; i++) { totalWeight += attests[i].weight; }
        if (totalWeight > 0) {
            for (uint256 i = 0; i < attests.length; i++) {
                address attester = attests[i].attester;
                uint256 attesterWeight = attests[i].weight;
                uint256 attesterBonus = ((loan.principal * 10000) / SCALE * BACKPROPAGATION_FACTOR * attesterWeight) / (SCALE * totalWeight);
                personalizationVector[attester] += attesterBonus;
            }
        }
    }
    function recordAttestation(address borrower, uint256 weight) external {
        require(weight <= SCALE, "");
        require(borrower != msg.sender, "");
        
        // Add to PageRank graph first (always do this)
        _addPagerankNode(msg.sender);
        _addPagerankNode(borrower);
        _addPagerankEdge(msg.sender, borrower, weight);
        
        // Then handle attestation storage
        Attestation[] storage attests = borrowerAttestations[borrower];
        for (uint256 i = 0; i < attests.length; i++) {
            if (attests[i].attester == msg.sender) { 
                attests[i].weight = weight; 
                return; 
            }
        }
        attests.push(Attestation(msg.sender, weight));
    }
    function updateCreditScore(address user, uint256 newScore) external onlyOracle {
        creditScores[user] = newScore;
    }
    function getCreditScore(address user) external view returns (uint256 score) {
        return creditScores[user];
    }
    function getLoan(uint256 loanId) external view returns (uint256 principal, uint256 outstanding, address borrower, uint256 interestRate, bool isActive) {
        Loan storage loan = loans[loanId];
        return (loan.principal, loan.outstanding, loan.borrower, loan.interestRate, loan.isActive);
    }
    function computeAttesterReward(uint256 loanId, address attester) external view returns (uint256 reward) {
        Loan storage loan = loans[loanId];
        Attestation[] storage attests = borrowerAttestations[loan.borrower];
        uint256 totalWeight = 0;
        uint256 attesterWeight = 0;
        for (uint256 i = 0; i < attests.length; i++) {
            totalWeight += attests[i].weight;
            if (attests[i].attester == attester) { attesterWeight = attests[i].weight; }
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
    
    function getAllPageRankScores() external view returns (address[] memory nodes, uint256[] memory scores) {
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
            pagerankNodeIndex[node] = 0;
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
    
    function _addPagerankNode(address node) internal {
        if (!pagerankNodeExists[node]) {
            pagerankNodeIndex[node] = pagerankNodes.length;
            pagerankNodes.push(node);
            pagerankNodeExists[node] = true;
        }
    }
    
    function _addPagerankEdge(address from, address to, uint256 weight) internal {
        pagerankEdges[from][to] = weight;
        pagerankOutDegree[from] += weight;
    }
    
    function _computePageRank(uint256 alpha, uint256 maxIter, uint256 tol) internal returns (uint256 iterations) {
        if (pagerankNodes.length == 0) return 0;
        
        // Initialize scores to 1.0 / numberOfNodes (scaled) - NetworkX default
        uint256 initialScore = PR_SCALE / pagerankNodes.length;
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            pagerankScores[node] = initialScore;
        }
        
        // Create stochastic graph (normalize edge weights by out-degree)
        _createStochasticGraph();
        
        // Run PageRank iterations
        iterations = 0;
        bool converged = false;
        
        while (iterations < maxIter && !converged) {
            converged = _pagerankIteration(alpha, tol);
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
                        pagerankStochasticEdges[node][target] = (originalWeight * PR_SCALE) / outDegree;
                    }
                }
            }
        }
    }
    
    function _pagerankIteration(uint256 alpha, uint256 tol) internal returns (bool converged) {
        uint256 totalDelta = 0;
        uint256 personalizationValue = PR_SCALE / pagerankNodes.length;
        uint256 personalizationContribution = ((PR_SCALE - alpha) * personalizationValue) / PR_SCALE;
        
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
                    uint256 contribution = (alpha * sourceScore * weight) / (PR_SCALE * PR_SCALE);
                    incomingScore += contribution;
                }
            }
            
            // Add dangling contribution (distributed according to personalization vector)
            uint256 danglingContribution = 0;
            if (danglingSum > 0) {
                // NetworkX: x[n] += danglesum * dangling_weights.get(n, 0)
                // Since we use uniform personalization, dangling_weights[n] = 1/N
                uint256 danglingPerNode = (alpha * danglingSum) / (PR_SCALE * pagerankNodes.length);
                danglingContribution = danglingPerNode;
            }
            
            // Update score: NetworkX: x[n] += danglesum * dangling_weights.get(n, 0) + (1.0 - alpha) * p.get(n, 0)
            uint256 newScore = incomingScore + danglingContribution + personalizationContribution;
            pagerankScores[node] = newScore;
            
            // Track convergence
            uint256 delta = oldScore > newScore ? oldScore - newScore : newScore - oldScore;
            totalDelta += delta;
        }
        
        return totalDelta < (tol * pagerankNodes.length);
    }
    
    function _calculateInterest(uint256 score) internal view returns (uint256 rate) {
        require(score <= SCALE, "");
        uint256 x = score;
        return rMin + ((rMax - rMin) * (SCALE - x)) / SCALE;
    }
}
