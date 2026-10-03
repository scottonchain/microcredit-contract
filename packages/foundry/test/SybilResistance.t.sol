// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Regression tests for the HermesCRBot persona findings on PR #3, run against the default
 *      configuration: vouching needs stake, trust must be anchored, first loans are capped.
 *      Persona 1: a ring of fake accounts vouching for each other and for Sam gave Sam a 90.9%
 *      score and pushed an honest borrower below him. Persona 6: an attester with no history
 *      and nothing at stake lifted a borrower from 0 to 90.9%.
 */
contract SybilResistanceTest is MicrocreditTestBase {
    uint256 internal constant STAKE = 50e6; // default minVouchStake
    uint256 internal constant FIRST_LOAN_CAP = 50e6; // default firstLoanCap
    uint256 internal constant RING_SIZE = 5;

    address internal avery = makeAddr("avery"); // trusted attester (KYC-verified)
    address internal brighton = makeAddr("brighton"); // honest borrower
    address internal sam = makeAddr("sam"); // the ring's beneficiary

    function setUp() public {
        _deploy(433, 500, 100e6);
        _deposit(makeAddr("poolLender"), 10_000e6);
        vm.prank(oracle);
        credit.markKYCVerified(avery);
    }

    function _stake(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(credit), amount);
        credit.stake(amount);
        vm.stopPrank();
    }

    function _vouch(address from, address to, uint256 weight) internal {
        vm.prank(from);
        credit.recordAttestation(to, weight);
    }

    /// @dev Staked fake accounts that vouch for each other in a ring and all vouch for Sam.
    function _stakedRing() internal returns (address[] memory members) {
        members = new address[](RING_SIZE);
        for (uint256 i = 0; i < RING_SIZE; i++) {
            members[i] = makeAddr(string.concat("sybil", vm.toString(i)));
            _stake(members[i], 2 * STAKE);
        }
        for (uint256 i = 0; i < RING_SIZE; i++) {
            _vouch(members[i], members[(i + 1) % RING_SIZE], SCALE);
            _vouch(members[i], sam, SCALE);
        }
    }

    function _repayInFull(address borrower, uint256 loanId) internal {
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        usdc.mint(borrower, owed);
        vm.startPrank(borrower);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
    }

    function testDefaults() public view {
        assertEq(credit.minVouchStake(), STAKE);
        assertEq(credit.firstLoanCap(), FIRST_LOAN_CAP);
    }

    // ───────────────────────────── persona 1: the ring ─────────────────────────────

    function testUnstakedAccountsCannotVouch() public {
        vm.prank(makeAddr("sybil0"));
        vm.expectRevert("Stake required");
        credit.recordAttestation(sam, SCALE);
        assertEq(credit.getCreditScore(sam), 0);
    }

    function testStakedRingWithoutTrustAnchorEarnsNoScore() public {
        _stakedRing();
        assertEq(credit.getCreditScore(sam), 0);

        vm.prank(sam);
        vm.expectRevert("Score > 0");
        credit.requestLoan(1e6);
    }

    function testRingCannotDisplaceHonestBorrower() public {
        _stake(avery, STAKE);
        _vouch(avery, brighton, 800_000);
        uint256 honestScore = credit.getCreditScore(brighton);
        assertGt(honestScore, 0);

        _stakedRing();
        assertEq(credit.getCreditScore(sam), 0, "no trust reaches the ring");
        assertApproxEqAbs(credit.getCreditScore(brighton), honestScore, SCALE / 100);
    }

    // ───────────────────────────── persona 6: unanchored attester ─────────────────────────────

    function testUnanchoredAttesterCarriesNoWeight() public {
        // Trust exists in the graph (Avery), but none of it reaches the newcomer attester.
        _stake(avery, STAKE);
        _vouch(avery, makeAddr("friend"), SCALE);

        address newcomer = makeAddr("newcomer");
        _stake(newcomer, STAKE);
        _vouch(newcomer, brighton, SCALE);
        assertEq(credit.getCreditScore(newcomer), 0);
        assertEq(credit.getCreditScore(brighton), 0);
    }

    // ───────────────────────────── first-loan cap ─────────────────────────────

    function testFirstLoanIsCappedUntilOneIsRepaid() public {
        _stake(avery, STAKE);
        _vouch(avery, brighton, SCALE);
        (uint256 scoreLimit,) = _scoreLimit(brighton);
        assertGt(scoreLimit, FIRST_LOAN_CAP, "score alone would allow more");

        (uint256 limit, uint256 available) = credit.getBorrowLimit(brighton);
        assertEq(limit, FIRST_LOAN_CAP);
        assertEq(available, FIRST_LOAN_CAP);

        vm.prank(brighton);
        vm.expectRevert("First loan cap exceeded");
        credit.requestLoan(FIRST_LOAN_CAP + 1);

        vm.startPrank(brighton);
        uint256 first = credit.requestLoan(30e6);
        vm.expectRevert("First loan cap exceeded"); // the cap covers active loans together
        credit.requestLoan(21e6);
        vm.stopPrank();
        credit.disburseLoan(first);

        _repayInFull(brighton, first);
        assertEq(credit.completedLoans(brighton), 1);
        (limit, available) = credit.getBorrowLimit(brighton);
        assertEq(limit, scoreLimit);
        assertEq(available, scoreLimit);

        vm.prank(brighton);
        credit.requestLoan(scoreLimit);
    }

    function _scoreLimit(address borrower) internal view returns (uint256 limit, uint256 score) {
        score = credit.getCreditScore(borrower);
        limit = (credit.maxLoanAmount() * score) / SCALE;
    }

    // ───────────────────────────── stake locking ─────────────────────────────

    function testEachVouchNeedsItsOwnStake() public {
        _stake(avery, STAKE);
        _vouch(avery, brighton, 500_000);
        _vouch(avery, brighton, 900_000); // raising an existing vouch needs no more stake

        vm.prank(avery);
        vm.expectRevert("Stake required");
        credit.recordAttestation(sam, SCALE);

        _stake(avery, STAKE);
        _vouch(avery, sam, SCALE);
        assertEq(credit.activeVouches(avery), 2);
    }

    function testVouchIsLockedWhileBorrowerHasActiveLoan() public {
        _stake(avery, STAKE);
        _vouch(avery, brighton, SCALE);
        vm.prank(brighton);
        uint256 loanId = credit.requestLoan(10e6);
        credit.disburseLoan(loanId);

        vm.startPrank(avery);
        vm.expectRevert("Vouch locked by active loan");
        credit.recordAttestation(brighton, 500_000);
        vm.expectRevert("Vouch locked by active loan");
        credit.recordAttestation(brighton, 0);
        vm.expectRevert("Stake locked by vouches");
        credit.unstake(1);
        vm.stopPrank();

        _repayInFull(brighton, loanId);
        _vouch(avery, brighton, 0);
        assertEq(credit.activeVouches(avery), 0);
        assertEq(credit.getVouchWeight(avery, brighton), 0);

        vm.prank(avery);
        credit.unstake(STAKE);
        assertEq(usdc.balanceOf(avery), STAKE);
        assertEq(credit.attesterStake(avery), 0);
    }

    function testStakeIsNotPoolLiquidity() public {
        uint256 assetsBefore = credit.totalAssets();
        _stake(avery, STAKE);
        assertEq(credit.totalAssets(), assetsBefore);
        assertEq(credit.totalAttesterStake(), STAKE);
        assertEq(usdc.balanceOf(address(credit)), assetsBefore + STAKE);
    }

    function testUnstakeRejectsMoreThanStaked() public {
        _stake(avery, STAKE);
        vm.prank(avery);
        vm.expectRevert("Insufficient stake");
        credit.unstake(STAKE + 1);
    }
}
