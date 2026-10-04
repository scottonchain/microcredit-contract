// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/// HermesCRBot: can a third party repay for an offline borrower inside the 30-day grace window?
/// Question raised by merktop (Moltbook). Fork of the LIVE pool, nothing broadcast.
/// repayWithPermit is the only third-party path that needs no whitelist. It needs an EIP-2612 permit the
/// borrower signed earlier, and the permit has its own deadline. Two cases:
///  A) permit deadline BEFORE the relayer submits (inside the grace window): repayment reverts.
///  B) permit deadline AFTER the relayer submits: repayment succeeds and the loan is Repaid.
/// Written by HermesCRBot (AI agent) and posted on PR #5; kept here as documentation of the permit
/// deadline rule (CI-28).
/// Run: LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8 \
///      forge test --match-path test/fork/HermesPermitWindow.t.sol -vv
contract HermesPermitWindowForkTest is Test {
    DecentralizedMicrocredit internal credit;
    MockUSDC internal usdc;
    bool internal forked;

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        string memory rpc = vm.envOr("LIVE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        credit = DecentralizedMicrocredit(vm.envAddress("LIVE_POOL"));
        usdc = MockUSDC(address(credit.usdc()));
        forked = true;
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(credit), type(uint256).max);
    }

    function _sign(uint256 pk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(credit), value, usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    /// borrower takes a loan; returns loanId and due date
    function _setup(address staker, address borrower) internal returns (uint256 loanId, uint256 dueAt) {
        _fund(staker, 2_000e6);
        vm.startPrank(staker);
        credit.depositFunds(1_000e6);
        credit.stake(100e6);
        credit.back(borrower, 100e6);
        vm.stopPrank();
        vm.startPrank(borrower);
        loanId = credit.requestLoan(50e6);
        credit.disburseLoan(loanId);
        vm.stopPrank();
        (,,,, dueAt) = credit.getLoanTerms(loanId);
    }

    function testPermitExpiresInsideGraceWindowRepayReverts() public {
        vm.skip(!forked, "set LIVE_RPC_URL and LIVE_POOL");
        (address borrower, uint256 pk) = makeAddrAndKey("pw_borrower_A");
        address staker = makeAddr("pw_staker_A");
        address relayer = makeAddr("pw_relayer_A");
        (uint256 loanId, uint256 dueAt) = _setup(staker, borrower);
        usdc.mint(borrower, 100e6);

        uint256 permitDeadline = dueAt + 10 days; // expires before day 30 of the grace window
        uint256 value = 100e6;
        (uint8 v, bytes32 r, bytes32 s) = _sign(pk, borrower, value, permitDeadline);

        vm.warp(dueAt + 20 days); // still inside LATE_PERIOD (30 days): the loan is not yet defaultable
        vm.prank(relayer);
        vm.expectRevert();
        credit.repayWithPermit(borrower, loanId, 0, value, permitDeadline, v, r, s);

        (DecentralizedMicrocredit.LoanStatus st,,,,) = credit.getLoanTerms(loanId);
        assertEq(uint8(st), uint8(DecentralizedMicrocredit.LoanStatus.Active), "the loan is still Active");
    }

    function testPermitOutlivesGraceWindowRelayerRepays() public {
        vm.skip(!forked, "set LIVE_RPC_URL and LIVE_POOL");
        (address borrower, uint256 pk) = makeAddrAndKey("pw_borrower_B");
        address staker = makeAddr("pw_staker_B");
        address relayer = makeAddr("pw_relayer_B");
        (uint256 loanId, uint256 dueAt) = _setup(staker, borrower);
        usdc.mint(borrower, 100e6);

        uint256 permitDeadline = dueAt + 40 days; // outlives the grace window
        uint256 value = 100e6;
        (uint8 v, bytes32 r, bytes32 s) = _sign(pk, borrower, value, permitDeadline);

        vm.warp(dueAt + 20 days);
        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 0, value, permitDeadline, v, r, s);

        (DecentralizedMicrocredit.LoanStatus st,,,,) = credit.getLoanTerms(loanId);
        assertEq(uint8(st), uint8(DecentralizedMicrocredit.LoanStatus.Repaid), "the relayer repaid in the window");
    }
}
