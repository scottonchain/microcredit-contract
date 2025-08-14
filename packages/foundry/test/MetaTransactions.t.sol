// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../contracts/DecentralizedMicrocredit.sol";
import "../contracts/MockUSDC.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title MetaTransactionsTest
 * @dev Tests for EIP-712 meta-transaction functionality in DecentralizedMicrocredit
 */
contract MetaTransactionsTest is Test {
    using stdStorage for StdStorage;
    DecentralizedMicrocredit private microcredit;
    MockUSDC private usdc;
    address private owner;
    address private oracle;
    address private borrower;
    address private relayer;
    address private lender;
    uint256 private borrowerPrivateKey;
    uint256 private relayerPrivateKey;

    // Constants
    uint256 private constant INITIAL_LENDER_FUNDS = 10_000 * 1e6; // 10,000 USDC
    uint256 private constant LOAN_AMOUNT = 1_000 * 1e6; // 1,000 USDC
    uint256 private constant CREDIT_SCORE = 800000; // 0.8 * 1e6
    uint256 private constant EFFR_RATE = 500; // 5% base rate
    uint256 private constant RISK_PREMIUM = 500; // 5% risk premium
    uint256 private constant MAX_LOAN_AMOUNT = 10_000 * 1e6; // 10,000 USDC max
    uint256 private constant DEADLINE_OFFSET = 1 hours;

    // EIP-712 domain separator parameters
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 private constant LOAN_REQUEST_TYPEHASH = keccak256(
        "LoanRequest(address borrower,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant DISBURSE_REQUEST_TYPEHASH = keccak256(
        "DisburseRequest(address borrower,uint256 loanId,address to,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant REPAY_REQUEST_TYPEHASH = keccak256(
        "RepayRequest(address borrower,uint256 loanId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // EIP-2612 permit typehash
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        // Setup test accounts with known private keys
        borrowerPrivateKey = 0xA11CE;
        borrower = vm.addr(borrowerPrivateKey);
        
        relayerPrivateKey = 0xB0B;
        relayer = vm.addr(relayerPrivateKey);
        
        owner = address(this);
        oracle = makeAddr("oracle");
        lender = makeAddr("lender");

        // Deploy contracts
        usdc = new MockUSDC();
        microcredit = new DecentralizedMicrocredit(
            EFFR_RATE,
            RISK_PREMIUM,
            MAX_LOAN_AMOUNT,
            address(usdc),
            oracle
        );

        // Set up proper PageRank initialization for the borrower
        // First, add an attestation to ensure the borrower is in the pagerankNodes array
        address attester = owner;
        vm.startPrank(attester);
        microcredit.recordAttestation(borrower, 500000); // Weight = 0.5 * SCALE
        vm.stopPrank();
        
        // Now set a high score directly in storage to override the calculated one
        uint256 slot = stdstore.target(address(microcredit)).sig("pagerankScores(address)").with_key(borrower).find();
        vm.store(address(microcredit), bytes32(slot), bytes32(CREDIT_SCORE));
        
        // Run PageRank computation once to ensure scores are registered
        vm.startPrank(owner);
        microcredit.computePageRank();
        vm.stopPrank();
        
        // Verify the borrower has a non-zero credit score
        uint256 score = microcredit.getCreditScore(borrower);
        require(score > 0, "Borrower credit score setup failed");

        // Fund accounts
        usdc.mint(lender, INITIAL_LENDER_FUNDS);
        
        // Fund the lending pool
        vm.startPrank(lender);
        usdc.approve(address(microcredit), INITIAL_LENDER_FUNDS);
        microcredit.depositFunds(INITIAL_LENDER_FUNDS);
        vm.stopPrank();
    }

    /**
     * @dev End-to-end test: borrower with 0 ETH repays via meta-tx using ERC20Permit
     */
    function testGaslessRepaymentWithPermit() public {
        // Ensure borrower has USDC and no ETH
        vm.deal(borrower, 0);
        assertEq(borrower.balance, 0, "Borrower should have 0 ETH");

        // Fund borrower with USDC for repayment
        usdc.mint(borrower, LOAN_AMOUNT);

        // Create a loan via meta path so there's something to repay
        uint256 nonce1 = microcredit.nonces(borrower);
        uint256 deadline1 = block.timestamp + DEADLINE_OFFSET;
        bytes memory sig1 = signLoanRequest(borrowerPrivateKey, borrower, LOAN_AMOUNT, nonce1, deadline1);
        vm.startPrank(relayer);
        uint256 loanId = microcredit.requestLoanMeta(
            DecentralizedMicrocredit.LoanRequest({ borrower: borrower, amount: LOAN_AMOUNT, nonce: nonce1, deadline: deadline1 }),
            sig1
        );
        // Disburse to borrower
        uint256 nonce2 = microcredit.nonces(borrower);
        uint256 deadline2 = block.timestamp + DEADLINE_OFFSET;
        bytes memory sig2 = signDisburseRequest(borrowerPrivateKey, borrower, loanId, borrower, nonce2, deadline2);
        microcredit.disburseLoanMeta(
            DecentralizedMicrocredit.DisburseRequest({ borrower: borrower, loanId: loanId, to: borrower, nonce: nonce2, deadline: deadline2 }),
            sig2
        );
        vm.stopPrank();

        // Prepare repay request (full amount)
        uint256 repayAmount = LOAN_AMOUNT;
        uint256 nonce3 = microcredit.nonces(borrower);
        uint256 deadline3 = block.timestamp + DEADLINE_OFFSET;
        bytes memory repaySig = signRepayRequest(borrowerPrivateKey, borrower, loanId, repayAmount, nonce3, deadline3);

        // Prepare ERC20Permit for the contract to pull tokens
        uint256 usdcNonce = usdc.nonces(borrower);
        (uint8 v, bytes32 r, bytes32 s) = signPermit(
            borrowerPrivateKey,
            borrower,
            address(microcredit),
            repayAmount,
            usdcNonce,
            deadline3
        );

        // Execute meta-repay as relayer
        vm.startPrank(relayer);
        microcredit.repayLoanMeta(
            DecentralizedMicrocredit.RepayRequest({ borrower: borrower, loanId: loanId, amount: repayAmount, nonce: nonce3, deadline: deadline3 }),
            repaySig,
            DecentralizedMicrocredit.PermitData({ value: repayAmount, deadline: deadline3, v: v, r: r, s: s })
        );
        vm.stopPrank();

        // Verify loan closed and borrower USDC decreased accordingly
        (, uint256 outstanding, , , bool isActive) = microcredit.getLoan(loanId);
        assertEq(isActive, false, "Loan should be closed");
        assertEq(outstanding, 0, "Outstanding should be zero");
    }

    /**
     * @dev Helper function to sign EIP-712 loan requests
     */
    function signLoanRequest(
        uint256 signerPrivateKey,
        address borrowerAddress,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(microcredit)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                LOAN_REQUEST_TYPEHASH,
                borrowerAddress,
                amount,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function signRepayRequest(
        uint256 signerPrivateKey,
        address borrowerAddress,
        uint256 loanId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(microcredit)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                REPAY_REQUEST_TYPEHASH,
                borrowerAddress,
                loanId,
                amount,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function signPermit(
        uint256 ownerPk,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        // Domain per ERC20Permit("USD Coin")
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("USD Coin"),
                keccak256("1"),
                block.chainid,
                address(usdc)
            )
        );
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    /**
     * @dev Helper function to sign EIP-712 disburse requests
     */
    function signDisburseRequest(
        uint256 signerPrivateKey,
        address borrowerAddress,
        uint256 loanId,
        address to,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(microcredit)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DISBURSE_REQUEST_TYPEHASH,
                borrowerAddress,
                loanId,
                to,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @dev Test that a borrower with 0 ETH can request and disburse a loan via meta transactions
     */
    function testGaslessBorrowing() public {
        // Verify borrower has no ETH
        vm.deal(borrower, 0);
        assertEq(borrower.balance, 0, "Borrower should have 0 ETH");

        // Create loan request
        uint256 nonce1 = microcredit.nonces(borrower);
        uint256 deadline1 = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature1 = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            nonce1,
            deadline1
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: LOAN_AMOUNT,
            nonce: nonce1,
            deadline: deadline1
        });

        // Execute as relayer
        vm.startPrank(relayer);
        uint256 loanId = microcredit.requestLoanMeta(loanReq, signature1);
        
        // Verify loan was created
        assertGt(loanId, 0, "Loan ID should be greater than 0");

        // Create disburse request
        uint256 nonce2 = microcredit.nonces(borrower);
        uint256 deadline2 = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature2 = signDisburseRequest(
            borrowerPrivateKey,
            borrower,
            loanId,
            borrower,
            nonce2,
            deadline2
        );

        DecentralizedMicrocredit.DisburseRequest memory disburseReq = DecentralizedMicrocredit.DisburseRequest({
            borrower: borrower,
            loanId: loanId,
            to: borrower,
            nonce: nonce2,
            deadline: deadline2
        });

        // Execute disburse as relayer
        microcredit.disburseLoanMeta(disburseReq, signature2);
        vm.stopPrank();

        // Verify borrower received the funds
        assertEq(usdc.balanceOf(borrower), LOAN_AMOUNT, "Borrower should have received loan amount");
    }

    /**
     * @dev Test that transaction reverts with an expired deadline
     */
    function testExpiredDeadline() public {
        uint256 nonce = microcredit.nonces(borrower);
        uint256 expiredDeadline = block.timestamp - 1; // Already expired
        bytes memory signature = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            nonce,
            expiredDeadline
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: LOAN_AMOUNT,
            nonce: nonce,
            deadline: expiredDeadline
        });

        // Should revert with "Expired" message
        vm.startPrank(relayer);
        vm.expectRevert("Expired");
        microcredit.requestLoanMeta(loanReq, signature);
        vm.stopPrank();
    }

    /**
     * @dev Test that transaction reverts with an invalid nonce
     */
    function testInvalidNonce() public {
        uint256 correctNonce = microcredit.nonces(borrower);
        uint256 invalidNonce = correctNonce + 1; // Wrong nonce
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            invalidNonce,
            deadline
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: LOAN_AMOUNT,
            nonce: invalidNonce,
            deadline: deadline
        });

        // Should revert with "Bad nonce" message
        vm.startPrank(relayer);
        vm.expectRevert("Bad nonce");
        microcredit.requestLoanMeta(loanReq, signature);
        vm.stopPrank();
    }

    /**
     * @dev Test that transaction reverts with an invalid signature
     */
    function testInvalidSignature() public {
        uint256 nonce = microcredit.nonces(borrower);
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        
        // Sign with relayer's key instead of borrower's key
        bytes memory invalidSignature = signLoanRequest(
            relayerPrivateKey, // Wrong private key
            borrower,
            LOAN_AMOUNT,
            nonce,
            deadline
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: LOAN_AMOUNT,
            nonce: nonce,
            deadline: deadline
        });

        // Should revert with "Bad signature" message
        vm.startPrank(relayer);
        vm.expectRevert("Bad signature");
        microcredit.requestLoanMeta(loanReq, invalidSignature);
        vm.stopPrank();
    }

    /**
     * @dev Test that disbursement can only go to the borrower, not redirected elsewhere
     */
    function testCannotRedirectDisbursement() public {
        // First create a loan
        uint256 nonce1 = microcredit.nonces(borrower);
        uint256 deadline1 = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature1 = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            nonce1,
            deadline1
        );

        vm.startPrank(relayer);
        uint256 loanId = microcredit.requestLoanMeta(
            DecentralizedMicrocredit.LoanRequest({
                borrower: borrower,
                amount: LOAN_AMOUNT,
                nonce: nonce1,
                deadline: deadline1
            }),
            signature1
        );

        // Try to disburse to relayer instead of borrower
        uint256 nonce2 = microcredit.nonces(borrower);
        uint256 deadline2 = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature2 = signDisburseRequest(
            borrowerPrivateKey,
            borrower,
            loanId,
            relayer, // Redirect to relayer instead of borrower
            nonce2,
            deadline2
        );

        DecentralizedMicrocredit.DisburseRequest memory disburseReq = DecentralizedMicrocredit.DisburseRequest({
            borrower: borrower,
            loanId: loanId,
            to: relayer,
            nonce: nonce2,
            deadline: deadline2
        });

        // Should revert with "Must send to borrower" message
        vm.expectRevert("Must send to borrower");
        microcredit.disburseLoanMeta(disburseReq, signature2);
        vm.stopPrank();
    }

    /**
     * @dev Test that utilization cap and score gating are still enforced in meta-tx path
     */
    function testUtilizationCapAndScoreGating() public {
        // First, add borrower to the PageRank graph so they exist in the system
        address attester = owner;
        vm.startPrank(attester);
        microcredit.recordAttestation(borrower, 100); // Very small attestation
        vm.stopPrank();
        
        // Set a very low score using stdstore
        // Direct storage manipulation to set a very low score
        uint256 slot = stdstore.target(address(microcredit)).sig("pagerankScores(address)").with_key(borrower).find();
        vm.store(address(microcredit), bytes32(slot), bytes32(uint256(1))); // Almost zero score
        
        // Run PageRank computation once to ensure scores are registered
        vm.startPrank(owner);
        microcredit.computePageRank();
        vm.stopPrank();
        
        // Verify the borrower has a very low but non-zero credit score
        uint256 score = microcredit.getCreditScore(borrower);
        console.log("Borrower credit score for gating test:", score);
        require(score > 0, "Borrower credit score should be non-zero");

        uint256 nonce = microcredit.nonces(borrower);
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            MAX_LOAN_AMOUNT, // Try to borrow maximum
            nonce,
            deadline
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: MAX_LOAN_AMOUNT,
            nonce: nonce,
            deadline: deadline
        });

        // Should revert due to utilization cap or score limit
        vm.startPrank(relayer);
        vm.expectRevert("Outstanding loans exceed max");
        microcredit.requestLoanMeta(loanReq, signature);
        vm.stopPrank();
    }

    /**
     * @dev Test that nonces increment correctly and prevent replay attacks
     */
    function testNonceIncrementing() public {
        // Create and execute first loan request
        uint256 initialNonce = microcredit.nonces(borrower);
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            initialNonce,
            deadline
        );

        vm.startPrank(relayer);
        microcredit.requestLoanMeta(
            DecentralizedMicrocredit.LoanRequest({
                borrower: borrower,
                amount: LOAN_AMOUNT,
                nonce: initialNonce,
                deadline: deadline
            }),
            signature
        );

        // Verify nonce incremented
        assertEq(microcredit.nonces(borrower), initialNonce + 1, "Nonce should increment");

        // Try to replay the same request
        vm.expectRevert("Bad nonce");
        microcredit.requestLoanMeta(
            DecentralizedMicrocredit.LoanRequest({
                borrower: borrower,
                amount: LOAN_AMOUNT,
                nonce: initialNonce, // Original nonce
                deadline: deadline
            }),
            signature
        );
        vm.stopPrank();
    }

    /**
     * @dev Test relayer whitelist functionality
     */
    function testRelayerWhitelist() public {
        // Enable whitelist
        microcredit.setRelayerWhitelistEnabled(true);
        
        // Create valid request
        uint256 nonce = microcredit.nonces(borrower);
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        bytes memory signature = signLoanRequest(
            borrowerPrivateKey,
            borrower,
            LOAN_AMOUNT,
            nonce,
            deadline
        );

        DecentralizedMicrocredit.LoanRequest memory loanReq = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower,
            amount: LOAN_AMOUNT,
            nonce: nonce,
            deadline: deadline
        });

        // Should revert since relayer isn't whitelisted
        vm.startPrank(relayer);
        vm.expectRevert("Unauthorized relayer");
        microcredit.requestLoanMeta(loanReq, signature);
        vm.stopPrank();

        // Whitelist the relayer
        microcredit.setRelayerWhitelisted(relayer, true);

        // Now should succeed
        vm.startPrank(relayer);
        uint256 loanId = microcredit.requestLoanMeta(loanReq, signature);
        vm.stopPrank();
        
        // Verify loan was created
        assertGt(loanId, 0, "Loan ID should be greater than 0");
    }
}
