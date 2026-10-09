// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditLens } from "../../contracts/MicrocreditLens.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { ICreditUsage, OracleScoreProvider } from "../../contracts/OracleScoreProvider.sol";
import { BootstrapOrderRouter } from "../../contracts/BootstrapOrderRouter.sol";
import { StakeRouterBase } from "../../contracts/TransitiveStakeRouter.sol";
import { BootstrapOrderRouterTest } from "../BootstrapOrderRouter.t.sol";
import { BaseSepoliaFork } from "../utils/BaseSepoliaFork.sol";

/// @dev The blacklist functions of Circle's FiatToken (v2.2) used below.
interface IFiatTokenBlacklistOrder {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/**
 * @dev Every composed-router test, run against Circle's USDC on a Base Sepolia fork instead of MockUSDC, plus the
 *      cases the real token adds: a blacklisted vendor makes an origination fail atomically (no order state, no
 *      lot, no escrow movement), and a blacklisted worker cannot be paid its remainder, which keeps settlement
 *      from completing while the customer can still refund. Skipped unless BASE_SEPOLIA_RPC_URL is set:
 *        BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-contract BootstrapOrderRouterFork
 *      Nothing is broadcast; every transaction runs on the local fork.
 */
contract BootstrapOrderRouterForkTest is BootstrapOrderRouterTest {
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
        address blacklister = IFiatTokenBlacklistOrder(BASE_SEPOLIA_USDC).blacklister();
        vm.prank(blacklister);
        IFiatTokenBlacklistOrder(BASE_SEPOLIA_USDC).blacklist(who);
    }

    function testBlacklistedVendorMakesTheOriginationFailAtomically() public {
        BootstrapOrderRouter.Intent memory i = _intent(worker, INPUT_COST);
        uint256 id = _fund(i, ORDER_PRICE, 120 days);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(i);
        bytes memory poolSig = _signBorrowAndDisburse(workerKey, req);
        bytes memory orderSig = _orderSig(workerKey, id);
        StakeRouterBase.Path[] memory ps = _two(worker, INPUT_COST, 600_000);
        _blacklist(vendor);
        vm.prank(relayer);
        vm.expectRevert();
        router.originateOrder(id, req, poolSig, orderSig, ps);
        (,,,,,, BootstrapOrderRouter.State state) = router.orders(id);
        assertEq(uint8(state), uint8(BootstrapOrderRouter.State.Funded), "the order is untouched");
        assertEq(router.totalLocked(), 0, "no root was committed");
        assertEq(router.totalEscrowHeld(), ORDER_PRICE);
        assertEq(credit.nonces(worker), req.nonce, "the worker's nonce is unspent");
    }

    function testBlacklistedWorkerBlocksSettlementButNotTheCustomersRefund() public {
        (uint256 id,) = _bound();
        _blacklist(worker);
        vm.prank(customer);
        vm.expectRevert(); // the remainder cannot be paid to a blacklisted worker: settlement reverts whole
        router.settleOrder(id);
        assertEq(router.totalEscrowHeld(), ORDER_PRICE, "nothing moved");
        vm.prank(customer);
        router.refundOrder(id);
        assertEq(usdc.balanceOf(customer), CUSTOMER_BUDGET, "the customer is made whole");
    }
}
