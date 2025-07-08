// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/DecentralizedMicrocredit.sol";

// Simple mock USDC contract for testing
contract MockUSDC is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name = "Mock USDC";
    string private _symbol = "USDC";
    uint8 private _decimals = 6;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(_balances[from] >= amount, "Insufficient balance");
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _balances[from] -= amount;
        _balances[to] += amount;
        _allowances[from][msg.sender] -= amount;
        return true;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract DecentralizedMicrocreditTest is Test {
    DecentralizedMicrocredit credit;
    MockUSDC usdc;
    address owner;
    address borrower;
    address lender;
    address oracle;

    function setUp() public {
        owner = makeAddr("owner");
        borrower = makeAddr("borrower");
        lender = makeAddr("lender");
        oracle = makeAddr("oracle");

        // Deploy mock USDC
        usdc = new MockUSDC();

        vm.startPrank(owner);
        credit = new DecentralizedMicrocredit(500, 2000, address(usdc), oracle); // 5% - 20% in basis points
        vm.stopPrank();

        // Set up initial balances
        usdc.mint(owner, 1000000e6); // 1M USDC for owner
        usdc.mint(borrower, 1000e6); // 1000 USDC for borrower
        usdc.mint(lender, 1000000e6); // 1M USDC for lender

        // Owner deposits funds into the contract
        vm.startPrank(owner);
        usdc.approve(address(credit), 1000000e6);
        credit.depositFunds(500000e6); // Deposit 500K USDC
        vm.stopPrank();

        // Set up credit score for borrower
        vm.prank(oracle);
        credit.updateCreditScore(borrower, 500000); // 50% credit score
    }

    function testRequestLoan() public {
        vm.startPrank(borrower);
        uint256 loanId = credit.requestLoan(1000e6);
        assertEq(loanId, 1);
        
        (uint256 principal, uint256 outstanding, address loanBorrower, uint256 interestRate, bool isActive) = credit.getLoan(loanId);
        assertEq(principal, 1000e6);
        assertEq(loanBorrower, borrower);
        assertTrue(isActive);
        vm.stopPrank();
    }

    function testRepayLoan() public {
        // Request loan
        vm.startPrank(borrower);
        uint256 loanId = credit.requestLoan(1000e6);
        
        // Disburse loan
        vm.stopPrank();
        vm.prank(owner);
        credit.disburseLoan(loanId);
        
        // Repay loan
        vm.startPrank(borrower);
        usdc.approve(address(credit), 1100e6); // Approve more than needed
        credit.repayLoan(loanId, 1100e6);
        
        (,,, , bool isActive) = credit.getLoan(loanId);
        assertFalse(isActive); // Loan should be repaid
        vm.stopPrank();
    }

    function testRecordAttestation() public {
        vm.prank(lender);
        credit.recordAttestation(borrower, 800000); // 80% weight
        
        // Test attester reward calculation
        vm.startPrank(borrower);
        uint256 loanId = credit.requestLoan(1000e6);
        vm.stopPrank();
        
        vm.prank(owner);
        credit.disburseLoan(loanId);
        
        uint256 reward = credit.computeAttesterReward(loanId, lender);
        assertGt(reward, 0);
    }

    function testCreditScoreUpdate() public {
        uint256 initialScore = credit.getCreditScore(borrower);
        assertEq(initialScore, 500000);
        
        vm.prank(oracle);
        credit.updateCreditScore(borrower, 700000); // Update to 70%
        
        uint256 newScore = credit.getCreditScore(borrower);
        assertEq(newScore, 700000);
    }

    function testInterestRateCalculation() public {
        vm.startPrank(borrower);
        uint256 loanId = credit.requestLoan(1000e6);
        vm.stopPrank();
        
        (,,, uint256 interestRate,) = credit.getLoan(loanId);
        
        // With 50% credit score, interest rate should be between rMin and rMax
        assertGe(interestRate, 500); // rMin
        assertLe(interestRate, 2000); // rMax
    }

    function testDepositFunds() public {
        // Check initial balance
        uint256 initialBalance = usdc.balanceOf(address(credit));
        assertEq(initialBalance, 500000e6); // Should have 500K from setUp
        
        // Deposit more funds
        vm.startPrank(owner);
        usdc.approve(address(credit), 100000e6);
        credit.depositFunds(100000e6);
        vm.stopPrank();
        
        // Check new balance
        uint256 newBalance = usdc.balanceOf(address(credit));
        assertEq(newBalance, 600000e6); // Should have 600K total
    }

    function testPageRankMatchesNetworkX() public {
        // Create the same graph as NetworkX test
        // NetworkX test case: 3 nodes with edges (0x1111 -> 0x2222: 80%, 0x1111 -> 0x3333: 40%)
        address node1 = address(0x1111);
        address node2 = address(0x2222);
        address node3 = address(0x3333);
        
        // Add attestations (this will add edges to PageRank graph)
        vm.prank(node1);
        credit.recordAttestation(node2, 800000); // 80% weight
        
        vm.prank(node1);
        credit.recordAttestation(node3, 400000); // 40% weight
        
        // Compute PageRank
        uint256 iterations = credit.computePageRank();
        assertGt(iterations, 0, "PageRank should run iterations");
        assertLe(iterations, 100, "PageRank should converge within max iterations");
        
        // Get PageRank scores
        (address[] memory nodes, uint256[] memory scores) = credit.getAllPageRankScores();
        
        // Verify we have 3 nodes
        assertEq(nodes.length, 3, "Should have 3 nodes in graph");
        assertEq(scores.length, 3, "Should have 3 scores");
        
        // Find scores for each node
        uint256 score1 = 0;
        uint256 score2 = 0;
        uint256 score3 = 0;
        
        for (uint256 i = 0; i < nodes.length; i++) {
            if (nodes[i] == node1) score1 = scores[i];
            else if (nodes[i] == node2) score2 = scores[i];
            else if (nodes[i] == node3) score3 = scores[i];
        }
        
        // Verify scores are reasonable (should be between 0 and 100,000, scaled)
        assertGt(score1, 0, "Node1 should have positive score");
        assertGt(score2, 0, "Node2 should have positive score");
        assertGt(score3, 0, "Node3 should have positive score");
        assertLe(score1, 100000, "Node1 score should be <= 1.0 (scaled)");
        assertLe(score2, 100000, "Node2 score should be <= 1.0 (scaled)");
        assertLe(score3, 100000, "Node3 score should be <= 1.0 (scaled)");
        
        // Verify that node2 (higher weight edge) has higher score than node3 (lower weight edge)
        // This is the key test - PageRank should reflect the edge weights
        assertGt(score2, score3, "Node2 should have higher score than node3 due to higher edge weight");
        
        // Verify scores sum to approximately 1.0 (scaled to 100,000) - PageRank property
        uint256 totalScore = score1 + score2 + score3;
        assertApproxEqAbs(totalScore, 99999, 5000, "Total PageRank scores should sum to ~1.0 (scaled)");
        
        // Test individual node score retrieval
        uint256 retrievedScore1 = credit.getPageRankScore(node1);
        uint256 retrievedScore2 = credit.getPageRankScore(node2);
        uint256 retrievedScore3 = credit.getPageRankScore(node3);
        
        assertEq(retrievedScore1, score1, "Individual score retrieval should match");
        assertEq(retrievedScore2, score2, "Individual score retrieval should match");
        assertEq(retrievedScore3, score3, "Individual score retrieval should match");
    }

    function testPageRankConvergence() public {
        // Test with a larger graph to ensure convergence
        address[] memory testNodes = new address[](5);
        testNodes[0] = address(0x1111);
        testNodes[1] = address(0x2222);
        testNodes[2] = address(0x3333);
        testNodes[3] = address(0x4444);
        testNodes[4] = address(0x5555);
        
        // Create a more complex graph
        vm.prank(testNodes[0]);
        credit.recordAttestation(testNodes[1], 500000);
        
        vm.prank(testNodes[1]);
        credit.recordAttestation(testNodes[2], 300000);
        
        vm.prank(testNodes[2]);
        credit.recordAttestation(testNodes[3], 700000);
        
        vm.prank(testNodes[3]);
        credit.recordAttestation(testNodes[4], 400000);
        
        vm.prank(testNodes[4]);
        credit.recordAttestation(testNodes[0], 600000);
        
        // Compute PageRank
        uint256 iterations = credit.computePageRank();
        
        // Should converge within reasonable iterations
        assertGt(iterations, 0, "Should run at least one iteration");
        assertLe(iterations, 100, "Should converge within max iterations");
        
        // Verify all nodes have scores
        for (uint256 i = 0; i < testNodes.length; i++) {
            uint256 score = credit.getPageRankScore(testNodes[i]);
            assertGt(score, 0, "All nodes should have positive scores");
        }
    }

    function testPageRankExactNetworkXMatch() public {
        // This test verifies exact match with NetworkX results
        // Expected NetworkX results for simple test case (scaled to 100,000):
        // 0x1111: ~25974 (0.259741)
        // 0x2222: ~40692 (0.406926) 
        // 0x3333: ~33333 (0.333333)
        
        address node1 = address(0x1111);
        address node2 = address(0x2222);
        address node3 = address(0x3333);
        
        // Add attestations (this will add edges to PageRank graph)
        vm.prank(node1);
        credit.recordAttestation(node2, 800000); // 80% weight
        
        vm.prank(node1);
        credit.recordAttestation(node3, 400000); // 40% weight
        
        // Compute PageRank
        uint256 iterations = credit.computePageRank();
        assertGt(iterations, 0, "PageRank should run iterations");
        
        // Get individual scores
        uint256 score1 = credit.getPageRankScore(node1);
        uint256 score2 = credit.getPageRankScore(node2);
        uint256 score3 = credit.getPageRankScore(node3);
        
        // Verify exact match with NetworkX results (allowing for small precision differences)
        // NetworkX results are approximate due to floating point, so we use tolerance
        uint256 tolerance = 500; // 500 absolute difference (scaled to 100,000) - reasonable for precision differences
        
        // Expected NetworkX values (scaled to 100,000)
        uint256 expectedScore1 = 25974;
        uint256 expectedScore2 = 40692;
        uint256 expectedScore3 = 33333;
        
        // Use absolute difference instead of relative
        assertApproxEqAbs(score1, expectedScore1, tolerance, "Node1 score should match NetworkX");
        assertApproxEqAbs(score2, expectedScore2, tolerance, "Node2 score should match NetworkX");
        assertApproxEqAbs(score3, expectedScore3, tolerance, "Node3 score should match NetworkX");
        
        // Verify key PageRank properties
        assertGt(score2, score3, "Node2 should have higher score than Node3");
        assertGt(score2, score1, "Node2 should have higher score than Node1");
        
        // Verify scores sum to approximately 1.0 (scaled to 100,000)
        uint256 totalScore = score1 + score2 + score3;
        assertApproxEqAbs(totalScore, 99999, 2000, "Total scores should sum to ~1.0 (scaled)");
        
        console.log("PageRank Results:");
        console.log("Node1 (0x1111):", score1);
        console.log("Node2 (0x2222):", score2);
        console.log("Node3 (0x3333):", score3);
        console.log("Total:", totalScore);
        console.log("Iterations:", iterations);
    }
} 