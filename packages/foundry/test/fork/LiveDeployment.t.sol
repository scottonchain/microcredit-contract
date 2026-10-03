// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";

/**
 * @dev The time-dependent half of the live persona scenarios (script/TestnetScenarios.s.sol):
 *      interest, due dates and defaults cannot be waited out on a testnet, so these run on a fork
 *      of the live deployment with the clock moved forward. Nothing is broadcast. Skipped unless
 *      LIVE_RPC_URL is set:
 *        LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0x... LIVE_AVERY=0x... LIVE_BRIGHTON=0x... \
 *        LIVE_REX=0x... forge test --match-path test/fork/LiveDeployment.t.sol -vv
 *      (the addresses are the ones TestnetScenarios logs).
 */
contract LiveDeploymentForkTest is Test {
    DecentralizedMicrocredit internal credit;
    address internal avery;
    address internal brighton;
    address internal rex;
    bool internal forked;

    modifier onFork() {
        vm.skip(!forked, "set LIVE_RPC_URL and the LIVE_* addresses to run");
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("LIVE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        credit = DecentralizedMicrocredit(vm.envAddress("LIVE_POOL"));
        avery = vm.envAddress("LIVE_AVERY");
        brighton = vm.envAddress("LIVE_BRIGHTON");
        rex = vm.envAddress("LIVE_REX");
        forked = true;
    }

    /// Every open loan on the live pool, defaulted once it is past due plus the late period.
    function _defaultEveryOpenLoan() internal returns (uint256 defaulted) {
        uint256[] memory ids = credit.getAllLoanIds();
        uint256 latest;
        for (uint256 i; i < ids.length; i++) {
            (DecentralizedMicrocredit.LoanStatus status,,,, uint256 dueAt) = credit.getLoanTerms(ids[i]);
            if (status == DecentralizedMicrocredit.LoanStatus.Active && dueAt > latest) latest = dueAt;
        }
        if (latest == 0) return 0;
        vm.warp(latest + credit.LATE_PERIOD() + 1);
        for (uint256 i; i < ids.length; i++) {
            (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(ids[i]);
            if (status != DecentralizedMicrocredit.LoanStatus.Active) continue;
            credit.markDefaulted(ids[i]); // anyone may
            defaulted++;
        }
    }

    /// The staked ring's loans are fully secured by Rex's stake: when they all default, the stake
    /// pays and lenders lose nothing.
    function testStakedRingDefaultIsPaidByTheStake() public onFork {
        uint256 assetsBefore = credit.totalAssets();
        uint256 rexStake = credit.stakeOf(rex);
        assertGt(rexStake, 0, "Rex's stake is live");

        assertGt(_defaultEveryOpenLoan(), 0, "the ring's loans were open");

        assertEq(credit.stakeOf(rex), 0, "the stake that backed them is slashed");
        assertGe(credit.totalAssets(), assetsBefore, "lenders lose nothing");
    }

    /// The demo-video case played to default: Brighton borrows his whole limit (his own 25 line plus
    /// Avery's 50) and never repays. Avery loses the credit she committed; nothing is created and
    /// the pool's loss is bounded by the lines that were issued. (Moving the clock also lets the
    /// oracle's scores go stale, which zeroes issued lines; the checks therefore read creditLoss.)
    function testUnsecuredDefaultBurnsTheBackersCredit() public onFork {
        (, uint256 available) = credit.getBorrowLimit(brighton);
        assertEq(available, 75e6, "25 of his own plus 50 from Avery");
        uint256 averyLossBefore = credit.creditLoss(avery);
        uint256 assetsBefore = credit.totalAssets();

        vm.startPrank(brighton);
        uint256 loanId = credit.requestLoan(available);
        credit.disburseLoan(loanId);
        vm.stopPrank();

        _defaultEveryOpenLoan(); // Brighton's loan and the staked ring's
        (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(loanId);
        assertEq(uint256(status), uint256(DecentralizedMicrocredit.LoanStatus.Defaulted));
        assertEq(credit.creditLoss(avery) - averyLossBefore, 50e6, "Avery's committed 50 is burned");
        // Burning Avery's credit recovers no cash (unsecured backing lowers default risk, not loss
        // given default), so lenders bear the 75 net of the reserve: within Theorem 2's bound, the
        // lines issued to the two of them (92 + 25). The staked ring's defaults cost lenders nothing.
        uint256 loss = assetsBefore > credit.totalAssets() ? assetsBefore - credit.totalAssets() : 0;
        assertLe(loss, 75e6, "lenders lose at most the unpaid principal");
        assertLe(loss, 92e6 + 25e6, "Theorem 2: at most the lines issued");

        vm.prank(brighton);
        vm.expectRevert(DecentralizedMicrocredit.BorrowerInDefault.selector);
        credit.requestLoan(1e6);
    }
}
