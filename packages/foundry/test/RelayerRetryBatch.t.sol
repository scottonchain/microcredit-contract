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
