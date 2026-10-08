// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditLens } from "../../contracts/MicrocreditLens.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { ICreditUsage, OracleScoreProvider } from "../../contracts/OracleScoreProvider.sol";
import { MicrocreditTestBase } from "../utils/MicrocreditTestBase.sol";

/// @dev The parts of Circle's FiatToken (v2.2) these tests use beyond ERC-20 and EIP-2612.
interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

/**
 * @dev The protocol against Circle's USDC on a Base Sepolia fork, where MockUSDC differs: the
 *      EIP-2612 domain (name "USDC", version "2") and the blacklist. Skipped unless
 *      BASE_SEPOLIA_RPC_URL is set:
 *        BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-path 'test/fork/*'
 *      Nothing is broadcast; every transaction runs on the local fork.
 */
contract BaseSepoliaUsdcForkTest is MicrocreditTestBase {
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant POOL = 1_000e6;

    uint256 internal lenderPk = 0x1E4D;
    address internal lender = vm.addr(lenderPk);
    uint256 internal borrowerPk = 0xB0B;
    address internal borrower = vm.addr(borrowerPk);
    bool internal forked;

    modifier onFork() {
        vm.skip(!forked, "set BASE_SEPOLIA_RPC_URL to run fork tests");
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        usdc = MockUSDC(BASE_SEPOLIA_USDC); // only ERC-20 and EIP-2612 functions are called on it
        vm.prank(owner);
        credit = new DecentralizedMicrocredit(433, 500, 100e6, BASE_SEPOLIA_USDC, oracle, address(0));
        lens = new MicrocreditLens(credit);
        scores = new OracleScoreProvider(owner, oracle, MAX_SCORE_AGE, ISSUANCE_BUDGET);
        vm.startPrank(owner);
        credit.setScoreProvider(scores);
        scores.setLending(ICreditUsage(address(credit)));
        credit.setScoreOverride(borrower, SCALE); // a 100 USDC line
        vm.stopPrank();

        deal(BASE_SEPOLIA_USDC, lender, POOL);
        vm.prank(relayer);
        credit.depositPermitOnlyMeta(lender, _signPermit(lenderPk, POOL, _deadline()));
    }

    /// The front end must sign USDC permits in this domain; MockUSDC's is ("USD Coin", "1").
    function testUsdcPermitDomainIsUsdcVersion2() public onFork {
        bytes32 expected = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("USDC"), keccak256("2"), block.chainid, BASE_SEPOLIA_USDC)
        );
        assertEq(usdc.DOMAIN_SEPARATOR(), expected);
        assertEq(usdc.decimals(), 6);
    }

    function testPermitDepositBorrowAndPermitRepay() public onFork {
        assertEq(credit.lenderBalance(lender), POOL);

        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(50e6);
        credit.disburseLoan(loanId);
        assertEq(usdc.balanceOf(borrower), 50e6);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = lens.getOutstandingRoundedToCent(loanId);
        deal(BASE_SEPOLIA_USDC, borrower, owed);
        DecentralizedMicrocredit.PermitData memory p = _signPermit(borrowerPk, owed, _deadline());
        vm.prank(relayer);
        credit.repayWithPermit(borrower, loanId, 0, p.value, p.deadline, p.v, p.r, p.s);

        assertEq(credit.getCurrentOutstandingAmount(loanId), 0);
        assertGt(credit.lenderBalance(lender), POOL, "the lender earned the interest");
    }

    /// A queued payout to an address Circle blacklists must not block repayments.
    function testBlacklistedQueueRecipientDoesNotBlockRepayments() public onFork {
        vm.prank(borrower);
        uint256 loanId = credit.requestLoan(100e6);
        credit.disburseLoan(loanId);

        // Take everything liquid now; the rest (the lent 100 USDC) waits in the queue.
        address payout = makeAddr("payout");
        DecentralizedMicrocredit.RequestWithdrawal memory req = DecentralizedMicrocredit.RequestWithdrawal({
            lender: lender, amount: type(uint256).max, to: payout, nonce: credit.nonces(lender), deadline: _deadline()
        });
        bytes memory sig = _signRequestWithdrawal(lenderPk, req);
        vm.prank(relayer);
        credit.requestWithdrawalMeta(req, sig);
        assertGt(credit.queuedWithdrawals(lender), 0, "part of the request is queued");
        uint256 paidNow = usdc.balanceOf(payout);

        IFiatToken fiat = IFiatToken(BASE_SEPOLIA_USDC);
        vm.prank(fiat.blacklister());
        fiat.blacklist(payout);

        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        deal(BASE_SEPOLIA_USDC, borrower, owed);
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();

        assertEq(credit.getCurrentOutstandingAmount(loanId), 0, "the repayment went through");
        uint256 held = credit.unclaimedPayouts(payout);
        assertGt(held, 0, "the queued payout is held");
        assertEq(usdc.balanceOf(payout), paidNow, "and not delivered while blacklisted");

        vm.prank(fiat.blacklister());
        fiat.unBlacklist(payout);
        credit.claimPayout(payout);
        assertEq(usdc.balanceOf(payout), paidNow + held);
    }
}
