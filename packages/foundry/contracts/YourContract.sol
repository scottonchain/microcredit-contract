// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/console2.sol";
import "./NetworkXPageRank.sol";

/**
 * @title DecentralizedMicrocredit
 * @dev A decentralized microcredit system using social attestations and PageRank-based reputation scoring
 */
contract YourContract is Ownable, ReentrancyGuard {

    uint256 public constant SCALE = 1e6;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant DAMPING_FACTOR = 70e4; // 0.70 in basis points
    uint256 public constant MAX_ITERATIONS = 100;
    uint256 public constant CONVERGENCE_THRESHOLD = 1; // Much lower threshold for more sensitivity
    uint256 public constant BACKPROPAGATION_FACTOR = 50e4; // 0.5 in basis points

    uint256 public rMin;
    uint256 public rMax;

    IERC20 public immutable usdc;
    address public oracle;

    uint256 private nextLoanId = 1;

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

    struct PageRankData {
        mapping(address => uint256) personalizationVector;
        mapping(address => uint256) creditScores;
        address[] allParticipants;
        bool initialized;
        NetworkXPageRank.Graph graph;
    }

    mapping(uint256 => Loan) private loans;
    mapping(address => Attestation[]) private borrowerAttestations;
    mapping(address => uint256) private participantIndex; // For efficient lookups
    
    PageRankData private pageRankData;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanDisbursed(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event AttestationRecorded(address indexed attester, address indexed borrower, uint256 weight);
    event CreditScoreUpdated(address indexed user, uint256 newScore);
    event PageRankComputed(uint256 iteration, uint256 totalDelta);

    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    constructor(uint256 _rMin, uint256 _rMax, address _usdc, address _oracle) Ownable(msg.sender) {
        require(_rMin < _rMax, "rMin must be < rMax");
        require(_usdc != address(0) && _oracle != address(0), "Invalid address");

        rMin = _rMin;
        rMax = _rMax;
        usdc = IERC20(_usdc);
        oracle = _oracle;
    }

    function setInterestRates(uint256 _rMin, uint256 _rMax) external onlyOwner {
        require(_rMin < _rMax, "Invalid interest bounds");
        rMin = _rMin;
        rMax = _rMax;
    }

    function depositFunds(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Add lender to participants if not already present
        _addParticipant(msg.sender);
        
        // Trigger PageRank update due to new participant
        _updatePageRankScores();
    }

    function previewLoanTerms(
        address borrower,
        uint256 principal,
        uint256 repaymentPeriod
    ) external view returns (uint256 interestRate, uint256 payment) {
        uint256 score = _getCreditScore(borrower);
        interestRate = _calculateInterest(score);
        uint256 interest = (principal * interestRate * repaymentPeriod) / (SCALE * SECONDS_PER_YEAR);
        payment = (principal + interest) / (repaymentPeriod / 30 days);
    }

    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "Invalid amount");
        uint256 score = _getCreditScore(msg.sender);
        require(score > 0, "No credit score");

        loanId = nextLoanId++;
        uint256 rate = _calculateInterest(score);
        
        // Calculate total amount owed (principal + interest)
        // For simplicity, we'll assume a 1-year repayment period
        uint256 interest = (amount * rate) / SCALE; // Interest rate is in basis points
        uint256 totalOwed = amount + interest;
        
        loans[loanId] = Loan(amount, totalOwed, msg.sender, rate, true);

        emit LoanRequested(loanId, msg.sender, amount);
    }

    function disburseLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Inactive loan");
        require(loan.borrower != address(0), "Invalid loan");
        require(usdc.transfer(loan.borrower, loan.principal), "Disbursement failed");

        emit LoanDisbursed(loanId, loan.borrower, loan.principal);
    }

    function repayLoan(uint256 loanId, uint256 amount) external {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Inactive loan");
        require(msg.sender == loan.borrower, "Not borrower");
        require(amount > 0, "Zero repayment");

        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 previousOutstanding = loan.outstanding;
        loan.outstanding = amount >= loan.outstanding ? 0 : loan.outstanding - amount;
        
        if (loan.outstanding == 0 && previousOutstanding > 0) {
            // Loan fully repaid - update credit scores and mark as inactive
            loan.isActive = false;
            _handleSuccessfulRepayment(loan.borrower, loan.principal);
        }

        emit LoanRepaid(loanId, msg.sender, amount);
    }

    function recordAttestation(address borrower, uint256 weight) external {
        require(weight <= SCALE, "Invalid weight");
        require(borrower != msg.sender, "Cannot attest to self");
        
        // Add both attester and borrower to participants
        _addParticipant(msg.sender);
        _addParticipant(borrower);
        
        // Check if attester already has an attestation for this borrower
        Attestation[] storage attests = borrowerAttestations[borrower];
        bool found = false;
        
        for (uint256 i = 0; i < attests.length; i++) {
            if (attests[i].attester == msg.sender) {
                // Update existing attestation
                attests[i].weight = weight;
                found = true;
                break;
            }
        }
        
        if (!found) {
            // Add new attestation
            attests.push(Attestation(msg.sender, weight));
        }
        
        emit AttestationRecorded(msg.sender, borrower, weight);
        
        // Trigger PageRank update due to attestation change
        _updatePageRankScores();
    }

    // Internal function for oracle to update credit scores
    function _updateCreditScore(address user, uint256 newScore) internal {
        _addParticipant(user);
        pageRankData.creditScores[user] = newScore;
        emit CreditScoreUpdated(user, newScore);
    }

    // External function for oracle to update credit scores
    function updateCreditScore(address user, uint256 newScore) external onlyOracle {
        require(newScore <= SCALE, "Score exceeds scale");
        _updateCreditScore(user, newScore);
    }

    // Batch update function for oracle to update multiple scores at once
    function updateCreditScores(address[] calldata users, uint256[] calldata scores) external onlyOracle {
        require(users.length == scores.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            require(scores[i] <= SCALE, "Score exceeds scale");
            _updateCreditScore(users[i], scores[i]);
        }
    }

    // Function to trigger PageRank computation (for local development)
    function computePageRankScores() external {
        _updatePageRankScores();
    }

    function getCreditScore(address user) external view returns (uint256 score) {
        return _getCreditScore(user);
    }

    function getLoan(uint256 loanId)
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
        Loan memory loan = loans[loanId];
        return (loan.principal, loan.outstanding, loan.borrower, loan.interestRate, loan.isActive);
    }

    function computeAttesterReward(uint256 loanId, address attester) external view returns (uint256 reward) {
        Loan storage loan = loans[loanId];
        require(loan.borrower != address(0), "Invalid loan");

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

        uint256 totalReward = (loan.principal * 50000) / SCALE; // 5%
        reward = (totalReward * attesterWeight) / totalWeight;
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle");
        oracle = _oracle;
    }

function _addParticipant(address participant) internal {
    if (participantIndex[participant] == 0 && participant != address(0)) {
        pageRankData.allParticipants.push(participant);
        participantIndex[participant] = pageRankData.allParticipants.length;

        // Assign initial personalization weight without normalizing
        pageRankData.personalizationVector[participant] = SCALE;
    }
}


    // function _normalizePersonalizationVector() internal {
    //     uint256 total = 0;
    //     for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
    //         total += pageRankData.personalizationVector[pageRankData.allParticipants[i]];
    //     }
        
    //     if (total > 0) {
    //         for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
    //             address participant = pageRankData.allParticipants[i];
    //             pageRankData.personalizationVector[participant] = 
    //                 (pageRankData.personalizationVector[participant] * SCALE) / total;
    //         }
    //     }
    // }

    function _updatePageRankScores() internal {
        if (pageRankData.allParticipants.length == 0) return;
        
        // Always reinitialize graph with current participants
        NetworkXPageRank.initializeGraph(pageRankData.graph, pageRankData.allParticipants);
        pageRankData.initialized = true;
        
        // Clear existing edges and rebuild graph from attestations
        _rebuildGraph();
        
        // Compute PageRank using NetworkX algorithm
        NetworkXPageRank.PageRankResult memory result = NetworkXPageRank.pagerank(
            pageRankData.graph,
            NetworkXPageRank.DEFAULT_ALPHA,
            pageRankData.personalizationVector,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            pageRankData.creditScores
        );
        
        emit PageRankComputed(result.iterations, pageRankData.allParticipants.length);
    }

    function _rebuildGraph() internal {
        // Clear existing edges by resetting outDegree and edges
        for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
            address participant = pageRankData.allParticipants[i];
            pageRankData.graph.outDegree[participant] = 0;
            
            // Clear all edges from this participant
            for (uint256 j = 0; j < pageRankData.allParticipants.length; j++) {
                address target = pageRankData.allParticipants[j];
                pageRankData.graph.edges[participant][target] = 0;
            }
        }
        
        // Add edges from attestations
        for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
            address borrower = pageRankData.allParticipants[i];
            Attestation[] storage attests = borrowerAttestations[borrower];
            
            for (uint256 j = 0; j < attests.length; j++) {
                address attester = attests[j].attester;
                uint256 weight = attests[j].weight;
                
                // Add edge from attester to borrower with weight
                NetworkXPageRank.addEdge(pageRankData.graph, attester, borrower, weight);
            }
        }
    }

    function _handleSuccessfulRepayment(address borrower, uint256 loanAmount) internal {
        // Positive update for borrower
        uint256 borrowerBonus = (loanAmount * 10000) / SCALE; // 1% bonus
        _updatePersonalizationVector(borrower, borrowerBonus, true);
        
        // Positive update for attesters (backpropagation)
        Attestation[] storage attests = borrowerAttestations[borrower];
        uint256 totalWeight = 0;
        
        for (uint256 i = 0; i < attests.length; i++) {
            totalWeight += attests[i].weight;
        }
        
        if (totalWeight > 0) {
            for (uint256 i = 0; i < attests.length; i++) {
                address attester = attests[i].attester;
                uint256 attesterWeight = attests[i].weight;
                uint256 attesterBonus = (borrowerBonus * BACKPROPAGATION_FACTOR * attesterWeight) / (SCALE * totalWeight);
                _updatePersonalizationVector(attester, attesterBonus, true);
            }
        }
        
        // Recompute PageRank scores
        _updatePageRankScores();
    }

    function _updatePersonalizationVector(address participant, uint256 delta, bool isPositive) internal {
        uint256 currentValue = pageRankData.personalizationVector[participant];
        if (isPositive) {
            pageRankData.personalizationVector[participant] = currentValue + delta;
        } else {
            pageRankData.personalizationVector[participant] = currentValue > delta ? currentValue - delta : 0;
        }
    }

    function _getCreditScore(address user) internal view returns (uint256) {
        return pageRankData.creditScores[user];
    }

    // Internal
    function _calculateInterest(uint256 score) internal view returns (uint256 rate) {
        require(score <= SCALE, "Score exceeds scale");
        uint256 x = score; // score is already on SCALE basis
        return rMin + ((rMax - rMin) * (SCALE - x)) / SCALE;
    }

    // Public getters for testing and debugging
    function getPersonalizationVector(address participant) external view returns (uint256) {
        return pageRankData.personalizationVector[participant];
    }

    function getAllParticipants() external view returns (address[] memory) {
        return pageRankData.allParticipants;
    }

    function getAttestations(address borrower) external view returns (Attestation[] memory) {
        return borrowerAttestations[borrower];
    }

    // Export all attestation data for external NetworkX processing
    function exportAttestationData() external view returns (
        address[] memory borrowers,
        address[][] memory attesters,
        uint256[][] memory weights
    ) {
        uint256 totalAttestations = 0;
        
        // First pass: count total attestations
        for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
            address participant = pageRankData.allParticipants[i];
            totalAttestations += borrowerAttestations[participant].length;
        }
        
        // Initialize arrays
        borrowers = new address[](totalAttestations);
        attesters = new address[][](totalAttestations);
        weights = new uint256[][](totalAttestations);
        
        uint256 index = 0;
        for (uint256 i = 0; i < pageRankData.allParticipants.length; i++) {
            address borrower = pageRankData.allParticipants[i];
            Attestation[] storage attests = borrowerAttestations[borrower];
            
            if (attests.length > 0) {
                borrowers[index] = borrower;
                
                address[] memory borrowerAttesters = new address[](attests.length);
                uint256[] memory borrowerWeights = new uint256[](attests.length);
                
                for (uint256 j = 0; j < attests.length; j++) {
                    borrowerAttesters[j] = attests[j].attester;
                    borrowerWeights[j] = attests[j].weight;
                }
                
                attesters[index] = borrowerAttesters;
                weights[index] = borrowerWeights;
                index++;
            }
        }
    }


}
