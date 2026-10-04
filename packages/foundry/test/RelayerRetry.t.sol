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
}
