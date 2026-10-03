// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Signature, nonce, deadline and relayer-whitelist rules shared by all meta-transactions.
contract MetaTransactionsTest is MicrocreditTestBase {
    uint256 private constant LOAN_AMOUNT = 1_000e6;
    uint256 private constant MAX_LOAN_AMOUNT = 10_000e6;

    uint256 private borrowerPk = 0xA11CE;
    address private borrower = vm.addr(borrowerPk);
    uint256 private impostorPk = 0xB0B;

    function setUp() public {
        _deploy(500, 500, MAX_LOAN_AMOUNT);
        _deposit(makeAddr("lender"), 10_000e6);
        vm.prank(owner);
        credit.setScoreOverride(borrower, 800_000); // 80% -> 8,000 USDC limit
    }

    function _loanRequest(uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (DecentralizedMicrocredit.LoanRequest memory)
    {
        return DecentralizedMicrocredit.LoanRequest({
            borrower: borrower, amount: amount, nonce: nonce, deadline: deadline
        });
    }

    function _requestLoan() internal returns (uint256 loanId) {
        DecentralizedMicrocredit.LoanRequest memory req =
            _loanRequest(LOAN_AMOUNT, credit.nonces(borrower), _deadline());
        bytes memory sig = _signLoanRequest(borrowerPk, req);
        vm.prank(relayer);
        loanId = credit.requestLoanMeta(req, sig);
    }

    function _disburseRequest(uint256 loanId, address to)
        internal
        view
        returns (DecentralizedMicrocredit.DisburseRequest memory)
    {
        return DecentralizedMicrocredit.DisburseRequest({
            borrower: borrower, loanId: loanId, to: to, nonce: credit.nonces(borrower), deadline: _deadline()
        });
    }

    /// @dev A borrower with no ETH can borrow and receive funds entirely through a relayer.
    function testGaslessBorrowing() public {
        vm.deal(borrower, 0);
        uint256 loanId = _requestLoan();
        assertGt(loanId, 0);

        DecentralizedMicrocredit.DisburseRequest memory req = _disburseRequest(loanId, borrower);
        bytes memory sig = _signDisburseRequest(borrowerPk, req);
        vm.prank(relayer);
        credit.disburseLoanMeta(req, sig);

        assertEq(usdc.balanceOf(borrower), LOAN_AMOUNT);
    }

    /// @dev A borrower with no ETH repays via relayer using an ERC-2612 permit.
    function testGaslessRepaymentWithPermit() public {
        vm.deal(borrower, 0);
        uint256 loanId = _requestLoan();
        DecentralizedMicrocredit.DisburseRequest memory disburse = _disburseRequest(loanId, borrower);
        bytes memory disburseSig = _signDisburseRequest(borrowerPk, disburse);
        vm.prank(relayer);
        credit.disburseLoanMeta(disburse, disburseSig);

        DecentralizedMicrocredit.RepayRequest memory repay = DecentralizedMicrocredit.RepayRequest({
            borrower: borrower,
            loanId: loanId,
            amount: LOAN_AMOUNT,
            nonce: credit.nonces(borrower),
            deadline: _deadline()
        });
        bytes memory repaySig = _signRepayRequest(borrowerPk, repay);
        DecentralizedMicrocredit.PermitData memory permit = _signPermit(borrowerPk, LOAN_AMOUNT, _deadline());

        vm.prank(relayer);
        credit.repayLoanMeta(repay, repaySig, permit);

        (, uint256 outstanding,,, bool isActive) = credit.getLoan(loanId);
        assertFalse(isActive);
        assertEq(outstanding, 0);
        assertEq(usdc.balanceOf(borrower), 0);
    }

    function testExpiredDeadline() public {
        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(LOAN_AMOUNT, 0, block.timestamp - 1);
        bytes memory sig = _signLoanRequest(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.SignatureExpired.selector);
        credit.requestLoanMeta(req, sig);
    }

    function testInvalidNonce() public {
        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(LOAN_AMOUNT, 1, _deadline());
        bytes memory sig = _signLoanRequest(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.InvalidNonce.selector);
        credit.requestLoanMeta(req, sig);
    }

    function testInvalidSignature() public {
        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(LOAN_AMOUNT, 0, _deadline());
        bytes memory sig = _signLoanRequest(impostorPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.InvalidSignature.selector);
        credit.requestLoanMeta(req, sig);
    }

    function testNonceIncrementingPreventsReplay() public {
        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(LOAN_AMOUNT, 0, _deadline());
        bytes memory sig = _signLoanRequest(borrowerPk, req);

        vm.startPrank(relayer);
        credit.requestLoanMeta(req, sig);
        assertEq(credit.nonces(borrower), 1);

        vm.expectRevert(DecentralizedMicrocredit.InvalidNonce.selector);
        credit.requestLoanMeta(req, sig);
        vm.stopPrank();
    }

    function testCannotRedirectDisbursement() public {
        uint256 loanId = _requestLoan();
        DecentralizedMicrocredit.DisburseRequest memory req = _disburseRequest(loanId, relayer);
        bytes memory sig = _signDisburseRequest(borrowerPk, req);

        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.MustSendToBorrower.selector);
        credit.disburseLoanMeta(req, sig);
    }

    function testScoreGatingAppliesToMetaRequests() public {
        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(MAX_LOAN_AMOUNT, 0, _deadline());
        bytes memory sig = _signLoanRequest(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.BorrowLimitExceeded.selector);
        credit.requestLoanMeta(req, sig);
    }

    function testRelayerWhitelist() public {
        vm.prank(owner);
        credit.setRelayerWhitelistEnabled(true);

        DecentralizedMicrocredit.LoanRequest memory req = _loanRequest(LOAN_AMOUNT, 0, _deadline());
        bytes memory sig = _signLoanRequest(borrowerPk, req);

        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.UnauthorizedRelayer.selector);
        credit.requestLoanMeta(req, sig);

        vm.prank(owner);
        credit.setRelayerWhitelisted(relayer, true);

        vm.prank(relayer);
        assertGt(credit.requestLoanMeta(req, sig), 0);
    }
}
