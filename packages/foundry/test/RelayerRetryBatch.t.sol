// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Retry fixture chain-7 (merktop, Moltbook comment 4a2af6b1 on post 117ae039): the relayer submits through a
///      batch envelope that swallows inner reverts. The envelope's receipt (its tx succeeded) says nothing about the
///      signed intent inside it. What does: nonces(signer). This contract consumes a nonce only inside a call that
///      succeeds as a whole (require(nonce == nonces[signer]++) and a revert of the call undoes the increment), so for
///      one signer the nonce range [before, after) names exactly which of its intents landed, given the relayer's own
///      intent -> nonce journal. The envelope's tx hash is needed to find the envelope, not to settle what landed.
contract RelayerRetryBatchTest is MicrocreditTestBase {
    uint256 internal constant POOL = 10_000e6;
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal poolLender = makeAddr("poolLender");
    SwallowingBatch internal envelope;

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(poolLender, POOL);
        vm.prank(owner);
        credit.setScoreOverride(borrower, 500_000);
        envelope = new SwallowingBatch();
        vm.prank(owner);
        credit.setRelayerWhitelisted(address(envelope), true);
    }

    function _borrow(uint256 amount) internal returns (uint256 loanId) {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: amount,
            to: borrower,
            repaymentPeriod: 28 days,
            maxAprBps: 933,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, _signBorrowAndDisburse(borrowerPk, req));
        uint256[] memory ids = credit.getBorrowerLoanIds(borrower);
        loanId = ids[ids.length - 1];
    }

    function _req(uint256 loanId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (DecentralizedMicrocredit.RepayRequest memory)
    {
        return DecentralizedMicrocredit.RepayRequest({
            borrower: borrower, loanId: loanId, amount: 0, nonce: nonce, deadline: deadline
        });
    }

    /// chain-7a: one expired intent inside the envelope. The envelope tx succeeds (no revert), the intent did not
    /// land, and only the nonce says so.
    function testEnvelopeSucceedsWhileWrappedIntentDidNotLand() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        uint256 n = credit.nonces(borrower);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId, n, block.timestamp - 1); // expired
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            DecentralizedMicrocredit.repayLoanMeta,
            (req, _signRepayRequest(borrowerPk, req), _signPermit(borrowerPk, 100e6, _deadline()))
        );

        vm.prank(relayer);
        bool[] memory ok = envelope.batch(address(credit), calls); // the envelope tx "succeeds"
        assertFalse(ok[0], "inner call reverted (SignatureExpired)");
        assertEq(credit.nonces(borrower), n, "nonce unchanged: the intent did not land");
        (, uint256 outstanding,,, bool isActive) = credit.getLoan(loanId);
        assertGt(outstanding, 0, "loan still owed");
        assertTrue(isActive, "loan still open");
    }

    /// chain-7b: two intents of one signer in one envelope, the second one expired. Exactly one lands, and the nonce
    /// range [before, after) names it; the envelope receipt alone cannot.
    function testNonceRangeNamesWhichWrappedIntentLanded() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        uint256 n = credit.nonces(borrower);
        DecentralizedMicrocredit.RepayRequest memory a = _req(loanId, n, _deadline());
        DecentralizedMicrocredit.RepayRequest memory b = _req(loanId, n + 1, block.timestamp - 1); // expired
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            DecentralizedMicrocredit.repayLoanMeta,
            (a, _signRepayRequest(borrowerPk, a), _signPermit(borrowerPk, 100e6, _deadline()))
        );
        calls[1] =
            abi.encodeCall(DecentralizedMicrocredit.repayLoanMeta, (b, _signRepayRequest(borrowerPk, b), _noPermit()));

        vm.prank(relayer);
        bool[] memory ok = envelope.batch(address(credit), calls);
        assertTrue(ok[0], "intent a landed");
        assertFalse(ok[1], "intent b reverted");
        assertEq(credit.nonces(borrower), n + 1, "exactly one nonce consumed: [n, n+1) = intent a");
        (, uint256 outstanding,,, bool isActive) = credit.getLoan(loanId);
        assertEq(outstanding, 0, "the landed intent repaid the loan");
        assertFalse(isActive, "loan closed by intent a");
    }

    /// chain-7c: same two intents, reversed order. b (nonce n+1) reverts InvalidNonce before a lands, then a lands.
    /// The consumed nonce range is the same, so the journal reading does not depend on the envelope's order.
    function testEnvelopeOrderDoesNotChangeTheConsumedNonceRange() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        uint256 n = credit.nonces(borrower);
        DecentralizedMicrocredit.RepayRequest memory a = _req(loanId, n, _deadline());
        DecentralizedMicrocredit.RepayRequest memory b = _req(loanId, n + 1, _deadline());
        bytes[] memory calls = new bytes[](2);
        calls[0] =
            abi.encodeCall(DecentralizedMicrocredit.repayLoanMeta, (b, _signRepayRequest(borrowerPk, b), _noPermit()));
        calls[1] = abi.encodeCall(
            DecentralizedMicrocredit.repayLoanMeta,
            (a, _signRepayRequest(borrowerPk, a), _signPermit(borrowerPk, 100e6, _deadline()))
        );

        vm.prank(relayer);
        bool[] memory ok = envelope.batch(address(credit), calls);
        assertFalse(ok[0], "b first: InvalidNonce, nothing consumed");
        assertTrue(ok[1], "a then lands");
        assertEq(credit.nonces(borrower), n + 1, "consumed range is still [n, n+1)");
    }

    // ───────────── chain-7, two signers in one envelope (the case chain-7 left untested) ─────────────

    uint256 internal otherPk = 0xA11CE;
    address internal other = vm.addr(otherPk);

    function _borrowAs(uint256 pk, uint256 amount) internal returns (uint256 loanId) {
        address who = vm.addr(pk);
        vm.prank(owner);
        credit.setScoreOverride(who, 500_000);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: who,
            amount: amount,
            to: who,
            repaymentPeriod: 28 days,
            maxAprBps: 933,
            nonce: credit.nonces(who),
            deadline: _deadline()
        });
        vm.prank(relayer);
        credit.borrowAndDisburseMeta(req, _signBorrowAndDisburse(pk, req));
        uint256[] memory ids = credit.getBorrowerLoanIds(who);
        loanId = ids[ids.length - 1];
    }

    function _repayCall(uint256 pk, uint256 loanId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        DecentralizedMicrocredit.RepayRequest memory req = DecentralizedMicrocredit.RepayRequest({
            borrower: vm.addr(pk), loanId: loanId, amount: 0, nonce: nonce, deadline: deadline
        });
        return abi.encodeCall(
            DecentralizedMicrocredit.repayLoanMeta,
            (req, _signRepayRequest(pk, req), _signPermit(pk, 100e6, _deadline()))
        );
    }

    /// chain-7d: two signers, one intent each, in one envelope; the first signer's intent is expired. The envelope
    /// tx succeeds. Per-signer counters keep the ranges apart: [nA, nA) is empty (nothing of A landed) and
    /// [nB, nB+1) names B's intent. A journal keyed by (signer, nonce) settles both without the envelope receipt.
    function testTwoSignersOnlyTheLandedSignersNonceMoves() public {
        uint256 loanA = _borrow(40e6);
        uint256 loanB = _borrowAs(otherPk, 40e6);
        usdc.mint(borrower, 100e6);
        usdc.mint(other, 100e6);
        uint256 nA = credit.nonces(borrower);
        uint256 nB = credit.nonces(other);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _repayCall(borrowerPk, loanA, nA, block.timestamp - 1); // expired
        calls[1] = _repayCall(otherPk, loanB, nB, _deadline());

        vm.prank(relayer);
        bool[] memory ok = envelope.batch(address(credit), calls);
        assertFalse(ok[0], "A's intent reverted (SignatureExpired)");
        assertTrue(ok[1], "B's intent landed");
        assertEq(credit.nonces(borrower), nA, "A: range [nA, nA) empty, nothing landed");
        assertEq(credit.nonces(other), nB + 1, "B: range [nB, nB+1) names B's intent");
        (, uint256 outA,,, bool activeA) = credit.getLoan(loanA);
        (, uint256 outB,,, bool activeB) = credit.getLoan(loanB);
        assertGt(outA, 0, "A still owes");
        assertTrue(activeA, "A's loan still open");
        assertEq(outB, 0, "B repaid");
        assertFalse(activeB, "B's loan closed");
    }

    /// chain-7e: two signers, three intents (A valid, A expired, B valid) in one envelope. Two nonces were consumed
    /// in total, which alone cannot say whose. Read per signer: [nA, nA+1) names A's valid intent (its expired one
    /// consumed nothing), [nB, nB+1) names B's. Each signer's range is independent of the other's calls.
    function testTwoSignersEachRangeNamesItsOwnLandedIntent() public {
        uint256 loanA = _borrow(40e6);
        uint256 loanB = _borrowAs(otherPk, 40e6);
        usdc.mint(borrower, 100e6);
        usdc.mint(other, 100e6);
        uint256 nA = credit.nonces(borrower);
        uint256 nB = credit.nonces(other);
        bytes[] memory calls = new bytes[](3);
        calls[0] = _repayCall(borrowerPk, loanA, nA, _deadline());
        calls[1] = _repayCall(borrowerPk, loanA, nA + 1, block.timestamp - 1); // expired
        calls[2] = _repayCall(otherPk, loanB, nB, _deadline());

        vm.prank(relayer);
        bool[] memory ok = envelope.batch(address(credit), calls);
        assertTrue(ok[0], "A's valid intent landed");
        assertFalse(ok[1], "A's expired intent reverted");
        assertTrue(ok[2], "B's intent landed");
        assertEq(credit.nonces(borrower), nA + 1, "A: exactly one consumed, [nA, nA+1) = A's valid intent");
        assertEq(credit.nonces(other), nB + 1, "B: exactly one consumed, [nB, nB+1) = B's intent");
        (, uint256 outA,,, bool activeA) = credit.getLoan(loanA);
        (, uint256 outB,,, bool activeB) = credit.getLoan(loanB);
        assertEq(outA, 0, "A repaid by its valid intent");
        assertFalse(activeA, "A's loan closed");
        assertEq(outB, 0, "B repaid");
        assertFalse(activeB, "B's loan closed");
    }
}

/// @dev A batch envelope that swallows inner reverts and never reverts itself (the shape merktop described:
///      multicall / bundler / forwarder whose calldata is the outer call).
contract SwallowingBatch {
    function batch(address target, bytes[] calldata calls) external returns (bool[] memory ok) {
        ok = new bool[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (ok[i],) = target.call(calls[i]);
        }
    }
}
