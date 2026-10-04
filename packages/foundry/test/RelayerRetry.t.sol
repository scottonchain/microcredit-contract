// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";
import { Vm } from "forge-std/Vm.sol";

/// @dev Relayer retry after an unknown outcome (the "timeout after the provider accepted it" case).
///      Checks, for repayLoanMeta: does replaying the same signed request double-charge, can a fresh
///      signature for the same intent double-charge, and can a reconciler link the emitted receipt
///      back to the signed intent without trusting the relayer's own log?
contract RelayerRetryTest is MicrocreditTestBase {
    uint256 internal constant POOL = 10_000e6;
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    address internal poolLender = makeAddr("poolLender");

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(poolLender, POOL);
        vm.prank(owner);
        credit.setScoreOverride(borrower, 500_000);
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

    function _req(uint256 loanId) internal view returns (DecentralizedMicrocredit.RepayRequest memory) {
        return DecentralizedMicrocredit.RepayRequest({
            borrower: borrower, loanId: loanId, amount: 0, nonce: credit.nonces(borrower), deadline: _deadline()
        });
    }

    /// Check 1: the relayer re-submits the SAME signed request after the first landed (ack lost).
    function testReplaySameSignedRequestPullsOnce() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, 100e6, _deadline());

        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, permit);
        uint256 afterFirst = usdc.balanceOf(borrower);

        vm.prank(relayer);
        vm.expectRevert(); // nonce already consumed: InvalidNonce
        credit.repayLoanMeta(req, sig, permit);
        assertEq(usdc.balanceOf(borrower), afterFirst, "second submission pulled funds");
    }

    /// Check 2: the relayer, unsure, asks the borrower for a FRESH signature for the same intent.
    function testFreshSignatureAfterLandedRepayRevertsAndPullsNothing() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        vm.prank(relayer);
        credit.repayLoanMeta(req, _signRepayRequest(borrowerPk, req), _signPermit(borrowerPk, 100e6, _deadline()));
        uint256 afterFirst = usdc.balanceOf(borrower);

        DecentralizedMicrocredit.RepayRequest memory req2 = _req(loanId); // new nonce
        bytes memory sig2 = _signRepayRequest(borrowerPk, req2);
        // leave a standing allowance so a second pull would succeed if the loan were still repayable
        vm.prank(borrower);
        usdc.approve(address(credit), type(uint256).max);
        vm.prank(relayer);
        vm.expectRevert(); // LoanNotActive
        credit.repayLoanMeta(req2, sig2, _noPermit());
        assertEq(usdc.balanceOf(borrower), afterFirst, "fresh signature double-charged");
    }

    /// Check 3 (the finding): the receipt event names borrower, loanId, amount. It does not name the
    /// signed intent (nonce / request digest), so a reconciler cannot tie "this signed request" to
    /// "this receipt" from the event alone. Records the receipt fields rather than asserting a fix.
    function testReceiptDoesNotBindSignedIntent() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        vm.recordLogs();
        vm.prank(relayer);
        credit.repayLoanMeta(req, _signRepayRequest(borrowerPk, req), _signPermit(borrowerPk, 100e6, _deadline()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 metaRepaid = keccak256("MetaLoanRepaid(address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == metaRepaid) {
                found = true;
                // topics: sig, borrower, loanId ; data: amount only. No nonce, no request digest.
                assertEq(logs[i].topics.length, 3, "indexed fields");
                assertEq(logs[i].data.length, 32, "data is just the amount");
            }
        }
        assertTrue(found);
    }

    /// Check 4 (maintainers' recovery rule): after an unknown outcome, the nonce tells the relayer whether
    /// the request landed. It moved => do not resubmit or re-sign; the loan is repaid exactly once.
    function testUnknownOutcomeRecoveryReadsNonce() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        uint256 nonceBefore = credit.nonces(borrower);
        assertEq(req.nonce, nonceBefore, "request signed against current nonce");

        vm.prank(relayer);
        credit.repayLoanMeta(req, _signRepayRequest(borrowerPk, req), _signPermit(borrowerPk, 100e6, _deadline()));
        // The relayer lost the ack. It reads state instead of resending:
        assertEq(credit.nonces(borrower), nonceBefore + 1, "nonce moved => request landed");
        // Observation only: the contract exposes the signal; "do not resubmit" is a relayer-side rule.
        (, uint256 outstanding,,, bool isActive) = credit.getLoan(loanId);
        assertEq(outstanding, 0, "loan fully repaid by the one landed request");
        assertFalse(isActive, "loan no longer open");
    }

    /// Check 5 (chain-3, calldata half): the call that consumed the nonce carries the whole signed request in its
    /// calldata, so a reconciler holding the receipt's tx can recover (borrower, loanId, nonce) from tx.input.
    /// Forge has no tx object, so the recorded call into the contract stands in for tx.input of a direct relayer tx.
    function testCalldataCarriesSignedRequest() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, 100e6, _deadline());

        vm.startStateDiffRecording();
        vm.prank(relayer);
        credit.repayLoanMeta(req, sig, permit);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();

        bytes memory input;
        for (uint256 i = 0; i < acc.length; i++) {
            if (acc[i].account == address(credit) && acc[i].depth == 1 && acc[i].data.length > 4) {
                if (bytes4(acc[i].data) == DecentralizedMicrocredit.repayLoanMeta.selector) {
                    input = acc[i].data;
                    break;
                }
            }
        }
        assertGt(input.length, 4, "found the repayLoanMeta call input");
        bytes memory args = new bytes(input.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = input[i + 4];
        }
        (DecentralizedMicrocredit.RepayRequest memory got,,) =
            abi.decode(args, (DecentralizedMicrocredit.RepayRequest, bytes, DecentralizedMicrocredit.PermitData));
        assertEq(got.borrower, borrower, "borrower recoverable from calldata");
        assertEq(got.loanId, loanId, "loanId recoverable from calldata");
        assertEq(got.nonce, req.nonce, "nonce recoverable from calldata");
        assertEq(credit.nonces(borrower), got.nonce + 1, "that nonce is the one that moved");
    }

    /// Check 6 (counter-case for chain-3): the relayer submits through a wrapper contract. The tx.input is now the
    /// wrapper's calldata, and the repayLoanMeta call sits one level down. A reconciler that only matches the
    /// repayLoanMeta selector at the top level finds nothing. Nonce check still works.
    function testWrappedBatchHidesRequestFromTopLevelSelector() public {
        uint256 loanId = _borrow(40e6);
        usdc.mint(borrower, 100e6);
        DecentralizedMicrocredit.RepayRequest memory req = _req(loanId);
        bytes memory sig = _signRepayRequest(borrowerPk, req);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, 100e6, _deadline());
        Wrapper w = new Wrapper();
        vm.prank(owner);
        credit.setRelayerWhitelisted(address(w), true);
        bytes memory inner = abi.encodeCall(DecentralizedMicrocredit.repayLoanMeta, (req, sig, permit));
        bytes memory outer = abi.encodeCall(Wrapper.forward, (address(credit), inner));

        assertTrue(
            bytes4(outer) != DecentralizedMicrocredit.repayLoanMeta.selector, "top-level selector is the wrapper's"
        );
        vm.prank(relayer);
        w.forward(address(credit), inner);
        assertEq(credit.nonces(borrower), req.nonce + 1, "nonce check still shows it landed");
    }
}

contract Wrapper {
    function forward(address target, bytes calldata data) external {
        (bool ok,) = target.call(data);
        require(ok, "inner call failed");
    }
}
