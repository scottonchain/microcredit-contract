// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DecentralizedMicrocredit
 * @dev A decentralized microcredit system using social attestations and reputation-based lending
 */
contract YourContract is Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant SCALE = 1e6; // Scale factor for percentages and weights
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant SECONDS_PER_MONTH = 30 days;
    
    // Interest rate parameters (scaled by SCALE)
    uint256 public rMin; // Minimum interest rate
    uint256 public rMax; // Maximum interest rate
    
    // USDC token contract
    IERC20 public immutable usdc;
    
    // Oracle address for credit score updates
    address public oracle;
    
    // Loan counter
    uint256 private nextLoanId = 1;
    
    // Structs
    struct Loan {
        uint256 principal;
        uint256 outstanding;
        address borrower;
        uint256 interestRate; // Annual rate scaled by SCALE
        uint256 creationTime;
        uint256 repaymentPeriod; // Duration in seconds
        bool isActive;
        bool isDisbursed;
    }
    
    struct Attestation {
        address attester;
        uint256 weight; // Scaled by SCALE (0 to 1e6)
        uint256 timestamp;
    }
    
    // Mappings
    mapping(uint256 => Loan) private loans;
    mapping(address => uint256) private creditScores;
    mapping(address => uint256) public lenderBalances;
    mapping(address => Attestation[]) private attestations; // borrower => attestations
    mapping(address => mapping(address => bool)) private hasAttested; // attester => borrower => bool
    
    // Events
    event FundsDeposited(address indexed lender, uint256 amount);
    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanDisbursed(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event AttestationRecorded(address indexed attester, address indexed borrower, uint256 weight);
    event CreditScoreUpdated(address indexed user, uint256 newScore);
    
    // Modifiers
    modifier onlyOracle() {
        require(msg.sender == oracle, "Only oracle can call this function");
        _;
    }
    
    /**
     * @dev Constructor takes the min and max interest rate and USDC token address
     * @param initialOwner The initial owner of the contract
     * @param _rMin Min interest rate (scaled by SCALE, e.g., 50000 = 5%)
     * @param _rMax Max interest rate (scaled by SCALE, e.g., 200000 = 20%)
     * @param _usdc USDC token contract address
     * @param _oracle Oracle address for credit score updates
     */
    constructor(
        address initialOwner,
        uint256 _rMin, 
        uint256 _rMax, 
        address _usdc,
        address _oracle
    ) Ownable(initialOwner) {
        require(_rMin < _rMax, "rMin must be < rMax");
        require(_usdc != address(0), "Invalid USDC address");
        require(_oracle != address(0), "Invalid oracle address");
        
        rMin = _rMin;
        rMax = _rMax;
        usdc = IERC20(_usdc);
        oracle = _oracle;
    }
    
    /**
     * @notice Owner-only setter for interest rate range
     * @param _rMin Min interest rate (scaled by SCALE)
     * @param _rMax Max interest rate (scaled by SCALE)
     */
    function setInterestRates(uint256 _rMin, uint256 _rMax) external onlyOwner {
        require(_rMin < _rMax, "rMin must be < rMax");
        rMin = _rMin;
        rMax = _rMax;
    }
    
    /**
     * @notice Set the oracle address
     * @param _oracle New oracle address
     */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle address");
        oracle = _oracle;
    }
    
    /**
     * @notice Deposit funds into the protocol as a lender
     * @param amount Amount of USDC to deposit (scaled to 6 decimals)
     */
    function depositFunds(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer USDC from lender to contract
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Update lender balance
        lenderBalances[msg.sender] += amount;
        
        emit FundsDeposited(msg.sender, amount);
    }
    
    /**
     * @notice Preview loan terms for a potential borrower
     * @param borrower The address requesting the loan
     * @param principal The requested loan amount (6-decimal USDC)
     * @param repaymentPeriod The requested repayment period (in seconds)
     * @return interestRate The annualized interest rate (basis points)
     * @return payment The estimated monthly payment amount
     */
    function previewLoanTerms(
        address borrower,
        uint256 principal,
        uint256 repaymentPeriod
    ) external view returns (uint256 interestRate, uint256 payment) {
        uint256 score = creditScores[borrower];
        interestRate = _calculateInterestRate(score);
        payment = _calculateMonthlyPayment(principal, interestRate, repaymentPeriod);
    }
    
    /**
     * @notice Request a new microloan
     * @param amount The requested principal amount in USDC
     * @return loanId A unique identifier for the newly created loan
     */
    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "Loan amount must be greater than 0");
        require(creditScores[msg.sender] > 0, "No credit score available");
        
        // Check if contract has enough liquidity
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient liquidity");
        
        loanId = nextLoanId++;
        uint256 interestRate = _calculateInterestRate(creditScores[msg.sender]);
        
        loans[loanId] = Loan({
            principal: amount,
            outstanding: amount,
            borrower: msg.sender,
            interestRate: interestRate,
            creationTime: block.timestamp,
            repaymentPeriod: 365 days, // Default 1 year
            isActive: true,
            isDisbursed: false
        });
        
        emit LoanRequested(loanId, msg.sender, amount);
    }
    
    /**
     * @notice Disburse an approved loan to the borrower
     * @param loanId The ID of the loan being disbursed
     */
    function disburseLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.borrower != address(0), "Loan does not exist");
        require(loan.isActive, "Loan is not active");
        require(!loan.isDisbursed, "Loan already disbursed");
        require(msg.sender == owner() || msg.sender == oracle, "Not authorized to disburse");
        
        // Transfer funds to borrower
        require(usdc.transfer(loan.borrower, loan.principal), "Transfer failed");
        
        loan.isDisbursed = true;
        
        emit LoanDisbursed(loanId, loan.borrower, loan.principal);
    }
    
    /**
     * @notice Repay an existing loan
     * @param loanId The ID of the loan to repay
     * @param amount Amount sent for repayment (USDC)
     */
    function repayLoan(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.borrower == msg.sender, "Only borrower can repay");
        require(loan.isActive, "Loan is not active");
        require(loan.isDisbursed, "Loan not disbursed yet");
        require(amount > 0, "Repayment amount must be greater than 0");
        
        // Calculate total amount due (principal + interest)
        uint256 totalDue = _calculateTotalDue(loanId);
        uint256 repaymentAmount = amount > totalDue ? totalDue : amount;
        
        // Transfer repayment from borrower
        require(usdc.transferFrom(msg.sender, address(this), repaymentAmount), "Transfer failed");
        
        // Update outstanding balance
        loan.outstanding = loan.outstanding > repaymentAmount ? 
            loan.outstanding - repaymentAmount : 0;
        
        // If fully repaid, mark as inactive
        if (loan.outstanding == 0) {
            loan.isActive = false;
        }
        
        // Distribute attester rewards (5% of repayment)
        uint256 attesterRewardPool = (repaymentAmount * 50000) / SCALE; // 5%
        _distributeAttesterRewards(loan.borrower, attesterRewardPool);
        
        emit LoanRepaid(loanId, msg.sender, repaymentAmount);
    }
    
    /**
     * @notice Record an attestation of creditworthiness
     * @param borrower The address of the borrower being attested to
     * @param weight A measure of attestation strength (0 to 1e6)
     */
    function recordAttestation(address borrower, uint256 weight) external {
        require(borrower != address(0), "Invalid borrower address");
        require(borrower != msg.sender, "Cannot attest to yourself");
        require(weight <= SCALE, "Weight cannot exceed maximum");
        require(!hasAttested[msg.sender][borrower], "Already attested to this borrower");
        
        // Record attestation
        attestations[borrower].push(Attestation({
            attester: msg.sender,
            weight: weight,
            timestamp: block.timestamp
        }));
        
        hasAttested[msg.sender][borrower] = true;
        
        emit AttestationRecorded(msg.sender, borrower, weight);
    }
    
    /**
     * @notice Update a participant's credit score (oracle only)
     * @param user The address whose credit score is being updated
     * @param newScore The new credit score
     */
    function updateCreditScore(address user, uint256 newScore) external onlyOracle {
        creditScores[user] = newScore;
        emit CreditScoreUpdated(user, newScore);
    }
    
    /**
     * @notice Retrieve the current credit score for a given address
     * @param user The address to look up
     * @return score The current credit score
     */
    function getCreditScore(address user) external view returns (uint256 score) {
        return creditScores[user];
    }
    
    /**
     * @notice Fetch details of a loan
     * @param loanId The ID of the loan to fetch
     * @return principal The original principal
     * @return outstanding The current remaining balance
     * @return borrower The address of the borrower
     * @return interestRate The interest rate
     * @return isActive Whether the loan is still active
     */
    function getLoan(uint256 loanId) external view returns (
        uint256 principal,
        uint256 outstanding,
        address borrower,
        uint256 interestRate,
        bool isActive
    ) {
        Loan storage loan = loans[loanId];
        return (
            loan.principal,
            loan.outstanding,
            loan.borrower,
            loan.interestRate,
            loan.isActive
        );
    }
    
    /**
     * @notice Compute the reward owed to an attester for a specific loan
     * @param loanId The ID of the loan
     * @param attester The address of the attester
     * @return reward The amount of reward owed to the attester
     */
    function computeAttesterReward(uint256 loanId, address attester) 
        external view returns (uint256 reward) {
        Loan storage loan = loans[loanId];
        require(loan.borrower != address(0), "Loan does not exist");
        
        // Get total attestation weight for borrower
        uint256 totalWeight = _getTotalAttestationWeight(loan.borrower);
        if (totalWeight == 0) return 0;
        
        // Find attester's weight
        uint256 attesterWeight = _getAttesterWeight(loan.borrower, attester);
        if (attesterWeight == 0) return 0;
        
        // Calculate reward based on proportion of total weight
        uint256 totalDue = _calculateTotalDue(loanId);
        uint256 attesterRewardPool = (totalDue * 50000) / SCALE; // 5%
        
        reward = (attesterRewardPool * attesterWeight) / totalWeight;
    }
    
    /**
     * @notice Get attestations for a borrower
     * @param borrower The borrower address
     * @return Array of attestations
     */
    function getAttestations(address borrower) external view returns (Attestation[] memory) {
        return attestations[borrower];
    }
    
    // Internal functions
    
    /**
     * @dev Calculate interest rate based on credit score
     * @param score Credit score of borrower
     * @return Interest rate scaled by SCALE
     */
    function _calculateInterestRate(uint256 score) internal view returns (uint256) {
        if (score == 0) return rMax;
        
        // Assuming max credit score is 1000 for normalization
        uint256 maxScore = 1000;
        uint256 normalizedScore = score > maxScore ? maxScore : score;
        
        // interest(x) = rMin + (rMax - rMin) * (1 - x)
        // where x = score / maxScore
        uint256 x = (normalizedScore * SCALE) / maxScore;
        return rMin + ((rMax - rMin) * (SCALE - x)) / SCALE;
    }
    
    /**
     * @dev Calculate monthly payment amount
     * @param principal Loan principal
     * @param annualRate Annual interest rate (scaled by SCALE)
     * @param periodSeconds Repayment period in seconds
     * @return Monthly payment amount
     */
    function _calculateMonthlyPayment(
        uint256 principal,
        uint256 annualRate,
        uint256 periodSeconds
    ) internal pure returns (uint256) {
        uint256 monthlyRate = annualRate / 12;
        uint256 numPayments = periodSeconds / SECONDS_PER_MONTH;
        
        if (monthlyRate == 0) {
            return principal / numPayments;
        }
        
        // Simple interest calculation for MVP
        uint256 totalInterest = (principal * annualRate * periodSeconds) / (SCALE * 365 days);
        return (principal + totalInterest) / numPayments;
    }
    
    /**
     * @dev Calculate total amount due for a loan
     * @param loanId Loan ID
     * @return Total amount due
     */
    function _calculateTotalDue(uint256 loanId) internal view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 timeElapsed = block.timestamp - loan.creationTime;
        uint256 interest = (loan.principal * loan.interestRate * timeElapsed) / (SCALE * 365 days);
        return loan.outstanding + interest;
    }
    
    /**
     * @dev Get total attestation weight for a borrower
     * @param borrower Borrower address
     * @return Total weight
     */
    function _getTotalAttestationWeight(address borrower) internal view returns (uint256) {
        uint256 totalWeight = 0;
        Attestation[] storage userAttestations = attestations[borrower];
        
        for (uint256 i = 0; i < userAttestations.length; i++) {
            totalWeight += userAttestations[i].weight;
        }
        
        return totalWeight;
    }
    
    /**
     * @dev Get attester's weight for a specific borrower
     * @param borrower Borrower address
     * @param attester Attester address
     * @return Attester's weight
     */
    function _getAttesterWeight(address borrower, address attester) internal view returns (uint256) {
        Attestation[] storage userAttestations = attestations[borrower];
        
        for (uint256 i = 0; i < userAttestations.length; i++) {
            if (userAttestations[i].attester == attester) {
                return userAttestations[i].weight;
            }
        }
        
        return 0;
    }
    
    /**
     * @dev Distribute rewards to attesters
     * @param borrower Borrower address
     * @param totalReward Total reward pool to distribute
     */
    function _distributeAttesterRewards(address borrower, uint256 totalReward) internal {
        if (totalReward == 0) return;
        
        uint256 totalWeight = _getTotalAttestationWeight(borrower);
        if (totalWeight == 0) return;
        
        Attestation[] storage userAttestations = attestations[borrower];
        
        for (uint256 i = 0; i < userAttestations.length; i++) {
            uint256 attesterReward = (totalReward * userAttestations[i].weight) / totalWeight;
            if (attesterReward > 0) {
                require(usdc.transfer(userAttestations[i].attester, attesterReward), "Reward transfer failed");
            }
        }
    }
}