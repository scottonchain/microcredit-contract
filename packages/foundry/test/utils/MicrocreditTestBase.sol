// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/**
 * @dev Shared fixture for DecentralizedMicrocredit tests: deploys the contract against the real
 *      MockUSDC (ERC20 + ERC20Permit) and provides EIP-712 / EIP-2612 signing helpers.
 *      Typed-data hashes are rebuilt here from the type strings rather than read from the
 *      contract, so the tests also pin the wire format the frontend signs.
 */
abstract contract MicrocreditTestBase is Test {
    DecentralizedMicrocredit internal credit;
    MockUSDC internal usdc;
    address internal owner = makeAddr("owner");
    address internal oracle = makeAddr("oracle");
    address internal relayer = makeAddr("relayer");

    uint256 internal constant SCALE = 1e6;
    uint256 internal constant DEADLINE_OFFSET = 1 hours;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant LOAN_REQUEST_TYPEHASH =
        keccak256("LoanRequest(address borrower,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DISBURSE_REQUEST_TYPEHASH =
        keccak256("DisburseRequest(address borrower,uint256 loanId,address to,uint256 nonce,uint256 deadline)");
    bytes32 internal constant REPAY_REQUEST_TYPEHASH =
        keccak256("RepayRequest(address borrower,uint256 loanId,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 internal constant BORROW_AND_DISBURSE_TYPEHASH = keccak256(
        "BorrowAndDisburse(address borrower,uint256 amount,address to,uint256 repaymentPeriod,uint256 maxAprBps,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant DEPOSIT_REQUEST_TYPEHASH =
        keccak256("DepositRequest(address lender,uint256 amount,address receiver,uint256 nonce,uint256 deadline)");
    bytes32 internal constant REQUEST_WITHDRAWAL_TYPEHASH =
        keccak256("RequestWithdrawal(address lender,uint256 amount,address to,uint256 nonce,uint256 deadline)");
    bytes32 internal constant ATTEST_REQUEST_TYPEHASH =
        keccak256("AttestRequest(address attester,address borrower,uint256 weight,uint256 nonce,uint256 deadline)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _deploy(uint256 effrRate, uint256 riskPremium, uint256 maxLoanAmount) internal {
        usdc = new MockUSDC();
        vm.prank(owner);
        credit = new DecentralizedMicrocredit(effrRate, riskPremium, maxLoanAmount, address(usdc), oracle);
    }

    /// @dev For suites testing other behaviour: vouching needs no stake and first loans are
    ///      uncapped. SybilResistance.t.sol runs against the defaults.
    function _relaxSybilGuards() internal {
        vm.startPrank(owner);
        credit.setMinVouchStake(0);
        credit.setFirstLoanCap(type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address lender, uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(credit), amount);
        credit.depositFunds(amount);
        vm.stopPrank();
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + DEADLINE_OFFSET;
    }

    // ───────────────────────────── EIP-712 signing ─────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(credit)
            )
        );
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signLoanRequest(uint256 pk, DecentralizedMicrocredit.LoanRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        return
            _sign(pk, keccak256(abi.encode(LOAN_REQUEST_TYPEHASH, req.borrower, req.amount, req.nonce, req.deadline)));
    }

    function _signDisburseRequest(uint256 pk, DecentralizedMicrocredit.DisburseRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(abi.encode(DISBURSE_REQUEST_TYPEHASH, req.borrower, req.loanId, req.to, req.nonce, req.deadline))
        );
    }

    function _signRepayRequest(uint256 pk, DecentralizedMicrocredit.RepayRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(abi.encode(REPAY_REQUEST_TYPEHASH, req.borrower, req.loanId, req.amount, req.nonce, req.deadline))
        );
    }

    function _signBorrowAndDisburse(uint256 pk, DecentralizedMicrocredit.BorrowAndDisburse memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(
                abi.encode(
                    BORROW_AND_DISBURSE_TYPEHASH,
                    req.borrower,
                    req.amount,
                    req.to,
                    req.repaymentPeriod,
                    req.maxAprBps,
                    req.nonce,
                    req.deadline
                )
            )
        );
    }

    function _signDepositRequest(uint256 pk, DecentralizedMicrocredit.DepositRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(
                abi.encode(DEPOSIT_REQUEST_TYPEHASH, req.lender, req.amount, req.receiver, req.nonce, req.deadline)
            )
        );
    }

    function _signRequestWithdrawal(uint256 pk, DecentralizedMicrocredit.RequestWithdrawal memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(abi.encode(REQUEST_WITHDRAWAL_TYPEHASH, req.lender, req.amount, req.to, req.nonce, req.deadline))
        );
    }

    function _signAttestRequest(uint256 pk, DecentralizedMicrocredit.AttestRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            keccak256(
                abi.encode(ATTEST_REQUEST_TYPEHASH, req.attester, req.borrower, req.weight, req.nonce, req.deadline)
            )
        );
    }

    /// @dev EIP-2612 permit from `pk`'s address to the microcredit contract.
    function _signPermit(uint256 pk, uint256 value, uint256 deadline)
        internal
        view
        returns (DecentralizedMicrocredit.PermitData memory permit)
    {
        address holder = vm.addr(pk);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(credit), value, usdc.nonces(holder), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        permit = DecentralizedMicrocredit.PermitData({ value: value, deadline: deadline, v: v, r: r, s: s });
    }

    function _noPermit() internal pure returns (DecentralizedMicrocredit.PermitData memory permit) { }
}
