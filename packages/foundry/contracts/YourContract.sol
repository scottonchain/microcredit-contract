// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/console2.sol";

/**
 * @title DecentralizedMicrocredit
 * @dev A decentralized microcredit system using social attestations and reputation-based lending
 */
//contract DecentralizedMicrocredit is Ownable, ReentrancyGuard {
    contract YourContract is Ownable, ReentrancyGuard {

    uint256 public constant SCALE = 1e6;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

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

    mapping(uint256 => Loan) private loans;
    mapping(address => uint256) private creditScores;
    mapping(address => Attestation[]) private borrowerAttestations;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanDisbursed(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event AttestationRecorded(address indexed attester, address indexed borrower, uint256 weight);
    event CreditScoreUpdated(address indexed user, uint256 newScore);

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
    }

    function previewLoanTerms(
        address borrower,
        uint256 principal,
        uint256 repaymentPeriod
    ) external view returns (uint256 interestRate, uint256 payment) {
        uint256 score = creditScores[borrower];
        interestRate = _calculateInterest(score);
        uint256 interest = (principal * interestRate * repaymentPeriod) / (SCALE * SECONDS_PER_YEAR);
        payment = (principal + interest) / (repaymentPeriod / 30 days);
    }

    function requestLoan(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "Invalid amount");
        uint256 score = creditScores[msg.sender];
        require(score > 0, "No credit score");

        loanId = nextLoanId++;
        uint256 rate = _calculateInterest(score);
        loans[loanId] = Loan(amount, amount, msg.sender, rate, true);

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
        
        // Debug: Log the addresses
        console2.log("repayLoan - msg.sender:", msg.sender);
        console2.log("repayLoan - loan.borrower:", loan.borrower);
        
        require(msg.sender == loan.borrower, "Not borrower");
        require(amount > 0, "Zero repayment");

        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        loan.outstanding = amount >= loan.outstanding ? 0 : loan.outstanding - amount;
        if (loan.outstanding == 0) loan.isActive = false;

        emit LoanRepaid(loanId, msg.sender, amount);
    }

    function recordAttestation(address borrower, uint256 weight) external {
        require(weight <= SCALE, "Invalid weight");
        borrowerAttestations[borrower].push(Attestation(msg.sender, weight));
        emit AttestationRecorded(msg.sender, borrower, weight);
    }

    function updateCreditScore(address user, uint256 newScore) external onlyOracle {
        creditScores[user] = newScore;
        emit CreditScoreUpdated(user, newScore);
    }

    function getCreditScore(address user) external view returns (uint256 score) {
        return creditScores[user];
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

    // Internal
    function _calculateInterest(uint256 score) internal view returns (uint256 rate) {
        require(score <= SCALE, "Score exceeds scale");
        uint256 x = score; // score is already on SCALE basis
        return rMin + ((rMax - rMin) * (SCALE - x)) / SCALE;
    }
}
