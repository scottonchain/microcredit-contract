// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditLens } from "../../contracts/MicrocreditLens.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { ICreditUsage, OracleScoreProvider } from "../../contracts/OracleScoreProvider.sol";
import { StakeRouterBase, TransitiveStakeRouter } from "../../contracts/TransitiveStakeRouter.sol";
import { TransitiveStakeRouterTest } from "../TransitiveStakeRouter.t.sol";
import { BaseSepoliaFork } from "../utils/BaseSepoliaFork.sol";

/// @dev The blacklist functions of Circle's FiatToken (v2.2) used below.
interface IFiatTokenBlacklist {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/**
 * @dev Every router test, run against Circle's USDC on a Base Sepolia fork instead of MockUSDC, plus the
 *      cases the real token adds: a blacklisted root cannot withdraw but blocks no one else, and a
 *      blacklisted vendor makes an origination fail atomically. Skipped unless BASE_SEPOLIA_RPC_URL is set:
 *        BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-contract TransitiveStakeRouterFork
 *      Nothing is broadcast; every transaction runs on the local fork.
 */
contract TransitiveStakeRouterForkTest is TransitiveStakeRouterTest {
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function setUp() public override {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "set BASE_SEPOLIA_RPC_URL to run fork tests");
        BaseSepoliaFork.select(rpc);
        super.setUp();
    }

    function _deployProtocol(address originator) internal override {
        usdc = MockUSDC(BASE_SEPOLIA_USDC); // only ERC-20 functions are called on it
        vm.prank(owner);
        credit = new DecentralizedMicrocredit(433, 500, 100e6, BASE_SEPOLIA_USDC, oracle, originator);
        lens = new MicrocreditLens(credit);
        scores = new OracleScoreProvider(owner, oracle, MAX_SCORE_AGE, ISSUANCE_BUDGET);
        vm.startPrank(owner);
        credit.setScoreProvider(scores);
        scores.setLending(ICreditUsage(address(credit)));
        vm.stopPrank();
    }

    function _give(address who, uint256 amount) internal override {
        deal(BASE_SEPOLIA_USDC, who, usdc.balanceOf(who) + amount);
    }

    function _blacklist(address who) internal {
        address blacklister = IFiatTokenBlacklist(BASE_SEPOLIA_USDC).blacklister();
        vm.prank(blacklister);
        IFiatTokenBlacklist(BASE_SEPOLIA_USDC).blacklist(who);
    }

    function testBlacklistedRootCannotWithdrawButSyncStillCreditsItsFreeBalance() public {
        uint256 loanId = _simple(10e6, 4e6);
        _fund(root2, 5e6);
        _repayAll(stranger, loanId);
        _blacklist(root1);
        router.sync(borrower); // a blacklisted root does not stop the release: it only credits the ledger
        assertEq(router.free(root1), 10e6);
        vm.prank(root1);
        vm.expectRevert(); // the token refuses the transfer; the root's own balance is the only thing stuck
        router.withdraw(10e6);
        assertEq(router.free(root1), 10e6, "the failed withdrawal changed nothing");
        // another root is unaffected, and the borrower can still borrow through it
        vm.prank(root2);
        router.withdraw(5e6);
        assertEq(usdc.balanceOf(root2), 5e6);
    }

    function testBlacklistedVendorMakesOriginationFailAtomically() public {
        _fund(root1, 10e6);
        _blacklist(vendor);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        StakeRouterBase.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6));
        vm.expectRevert();
        router.originate(req, sig, ps);
        assertEq(router.free(root1), 10e6, "the failed origination left the ledger untouched");
        assertEq(router.locked(root1), 0);
        assertEq(router.edgeUsed(router.edgeKey(root1, mid1, address(0))), 0);
        assertEq(credit.nonces(borrower), 0, "and the borrower's pool nonce unspent");
    }
}
