// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { BootstrapOrderRouter } from "../../contracts/BootstrapOrderRouter.sol";
import { StakeRouterBase } from "../../contracts/TransitiveStakeRouter.sol";

/**
 * @dev Drives the bootstrap router for the ledger-separation invariants with a fixed cast: three roots, two mids,
 *      four workers (each has named the router as its only pool manager), two customers and a stranger that repays.
 *      Roots deposit and withdraw, customers fund, refund and settle orders, anyone originates, repays, defaults and
 *      syncs, and strays are donated to the router. Every call is wrapped in try/catch so the handler never reverts:
 *      the invariants read the router and the pool, and what a refused call would have done is not modelled. The
 *      handler records only what an outside observer can: root deposits and withdrawals that succeeded, USDC donated
 *      straight to the router, and the USDC it created.
 */
contract OrderRouterHandler is CommonBase, StdCheats, StdUtils {
    uint256 public constant NR = 3;
    uint256 public constant NM = 2;
    uint256 public constant NW = 4;
    uint256 public constant NC = 2;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant BORROW_AND_DISBURSE_TYPEHASH = keccak256(
        "BorrowAndDisburse(address borrower,uint256 amount,address to,uint256 repaymentPeriod,uint256 maxAprBps,uint256 nonce,uint256 deadline)"
    );

    DecentralizedMicrocredit public immutable credit;
    MockUSDC public immutable usdc;
    BootstrapOrderRouter public immutable router;
    address public immutable stranger = address(0x57A4);
    address public immutable vendor = address(0x7E4D);
    uint256 public constant OFFICER_KEY = 0x0FF1CE;

    address[] public roots;
    address[] public mids;
    address[] public workers;
    address[] public customers;
    uint256[] internal _rootKeys;
    uint256[] internal _midKeys;
    uint256[] internal _workerKeys;

    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    uint256 public strayInRouter;
    uint256 public created; // USDC the handler minted after construction

    // coverage counters
    uint256 public funded;
    uint256 public originated;
    uint256 public settled;
    uint256 public refunded;
    uint256 public defaulted;
    uint256 public multiPath;

    constructor(DecentralizedMicrocredit credit_, MockUSDC usdc_, BootstrapOrderRouter router_) {
        credit = credit_;
        usdc = usdc_;
        router = router_;
        for (uint256 i = 0; i < NR; i++) {
            uint256 k = uint256(keccak256(abi.encode("oroot", i)));
            _rootKeys.push(k);
            address r = vm.addr(k);
            roots.push(r);
            usdc_.mint(r, 30e6);
            vm.startPrank(r);
            usdc_.approve(address(router_), 30e6);
            router_.deposit(30e6);
            vm.stopPrank();
            deposited[r] = 30e6;
        }
        for (uint256 i = 0; i < NM; i++) {
            uint256 k = uint256(keccak256(abi.encode("omid", i)));
            _midKeys.push(k);
            mids.push(vm.addr(k));
        }
        for (uint256 i = 0; i < NW; i++) {
            uint256 k = uint256(keccak256(abi.encode("oworker", i)));
            _workerKeys.push(k);
            address w = vm.addr(k);
            workers.push(w);
            vm.prank(w);
            credit_.setManager(address(router_));
        }
        for (uint256 i = 0; i < NC; i++) {
            customers.push(address(uint160(0xC057 + i)));
        }
    }

    // ───────────── actions ─────────────

    function rootDeposit(uint256 seed, uint256 amount) external {
        address r = roots[seed % NR];
        amount = bound(amount, 1, 10e6);
        usdc.mint(r, amount);
        created += amount;
        vm.startPrank(r);
        usdc.approve(address(router), amount);
        try router.deposit(amount) {
            deposited[r] += amount;
        } catch { }
        vm.stopPrank();
    }

    function rootWithdraw(uint256 seed, uint256 amount) external {
        address r = roots[seed % NR];
        uint256 free = router.free(r);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(r);
        try router.withdraw(amount) {
            withdrawn[r] += amount;
        } catch { }
    }

    function stray(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 1e6);
        usdc.mint(address(router), amount);
        created += amount;
        strayInRouter += amount;
        seed;
    }

    function fund(uint256 seed) external {
        address c = customers[seed % NC];
        address w = workers[(seed >> 8) % NW];
        uint256 amount = bound(seed >> 16, 1e6, 2e6);
        uint256 price = bound(seed >> 40, amount, 3e6);
        uint256 cap = bound(seed >> 64, amount, price);
        uint256 settleIn = bound(seed >> 88, 1 days, 90 days);
        BootstrapOrderRouter.Intent memory i = BootstrapOrderRouter.Intent({
            worker: w,
            vendor: vendor,
            amount: amount,
            term: bound(seed >> 112, 1 days, 30 days),
            maxAprBps: 933,
            nonce: credit.nonces(w),
            deadline: vm.getBlockTimestamp() + 60 days,
            jobHash: keccak256(abi.encode(seed))
        });
        usdc.mint(c, price);
        created += price;
        vm.startPrank(c);
        usdc.approve(address(router), price);
        try router.fund(i, price, cap, vm.getBlockTimestamp() + settleIn) {
            funded++;
            _approveOrder(router.nextOrderId() - 1, amount, i.deadline);
        } catch { }
        vm.stopPrank();
    }

    /// @dev The officer approves the order for exactly its amount (any account may submit the signed approval).
    function _approveOrder(uint256 id, uint256 amount, uint256 expiry) internal {
        (,,,, bytes32 ih,,) = router.orders(id);
        BootstrapOrderRouter.JobApproval memory a = BootstrapOrderRouter.JobApproval({
            orderId: id,
            intentHash: ih,
            maxAmount: amount,
            expiry: expiry,
            policyVersion: router.policyVersion(),
            officerEpoch: router.officerEpoch()
        });
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(OFFICER_KEY, router.approvalDigest(a));
        try router.approveOrder(a, abi.encodePacked(r, sg, v)) { } catch { }
    }

    /// @dev The admin rotates or revokes the officer, the way an operator would: unused approvals die, no ledger moves.
    function rotateOfficer(uint256 seed) external {
        if (seed % 3 == 0 && router.officer() != address(0)) {
            vm.prank(vm.addr(OFFICER_KEY)); // the officer revokes itself
            router.revokeOfficer();
        } else {
            router.setOfficer(vm.addr(OFFICER_KEY), 1 + (seed % 5)); // the handler is the router's officer admin (set in the suite's setUp)
        }
    }

    /// @dev The officer re-approves a funded order under the current epoch and policy (a stranger records it).
    function reapprove(uint256 seed) external {
        uint256 n = router.nextOrderId();
        if (n <= 1) return;
        uint256 id = 1 + (seed % (n - 1));
        (,,,,,, BootstrapOrderRouter.State st) = router.orders(id);
        if (st != BootstrapOrderRouter.State.Funded) return;
        BootstrapOrderRouter.Intent memory i = router.intentOf(id);
        _approveOrder(id, i.amount, i.deadline);
    }

    function originate(uint256 seed) external {
        uint256 n = router.nextOrderId();
        if (n <= 1) return;
        uint256 id = 1 + (seed % (n - 1));
        for (uint256 step = 0; step < n - 1; step++) {
            uint256 cand = 1 + ((id - 1 + step) % (n - 1));
            (,,,,,, BootstrapOrderRouter.State st) = router.orders(cand);
            if (st == BootstrapOrderRouter.State.Funded) {
                _originate(cand, seed >> 8);
                return;
            }
        }
    }

    function settle(uint256 seed) external {
        uint256 id = _find(seed, BootstrapOrderRouter.State.Bound);
        if (id == 0) return;
        (address payer,,,,,,) = router.orders(id);
        vm.prank(payer);
        try router.settleOrder(id) {
            settled++;
        } catch { }
    }

    function refund(uint256 seed) external {
        uint256 id = _find(seed, seed % 2 == 0 ? BootstrapOrderRouter.State.Funded : BootstrapOrderRouter.State.Bound);
        if (id == 0) return;
        (address payer,,,,,,) = router.orders(id);
        vm.prank(payer);
        try router.refundOrder(id) {
            refunded++;
        } catch { }
    }

    function repay(uint256 seed, uint256 amount) external {
        address w = workers[seed % NW];
        (bool open, uint256 loanId,,) = router.lotOf(w);
        if (!open) return;
        (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(loanId);
        if (status != DecentralizedMicrocredit.LoanStatus.Active) return;
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        amount = (seed >> 8) % 3 == 0 ? owed : bound(amount, 1, owed);
        usdc.mint(stranger, amount);
        created += amount;
        vm.startPrank(stranger);
        usdc.approve(address(credit), amount);
        try credit.repayLoan(loanId, amount) { } catch { }
        vm.stopPrank();
    }

    function warp(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1 hours, 40 days));
    }

    function defaultOne(uint256 seed) external {
        address w = workers[seed % NW];
        (bool open, uint256 loanId,,) = router.lotOf(w);
        if (!open) return;
        (DecentralizedMicrocredit.LoanStatus status,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        if (status != DecentralizedMicrocredit.LoanStatus.Active) return;
        uint256 at = dueAt + credit.LATE_PERIOD() + 1;
        if (vm.getBlockTimestamp() < at) vm.warp(at);
        try credit.markDefaulted(loanId) {
            defaulted++;
        } catch { }
    }

    function syncOne(uint256 seed) external {
        try router.sync(workers[seed % NW]) { } catch { }
    }

    // ───────────── views for the invariants ─────────────

    function sumEscrow() external view returns (uint256 sum) {
        uint256 n = router.nextOrderId();
        for (uint256 id = 1; id < n; id++) {
            (, uint256 price,,,,, BootstrapOrderRouter.State st) = router.orders(id);
            if (st == BootstrapOrderRouter.State.Funded || st == BootstrapOrderRouter.State.Bound) sum += price;
        }
    }

    function sumOpenLots() external view returns (uint256 sum) {
        for (uint256 i = 0; i < NW; i++) {
            (bool open,, uint256 amount,) = router.lotOf(workers[i]);
            if (open) sum += amount;
        }
    }

    function sumLockedOf(address root) external view returns (uint256 sum) {
        for (uint256 i = 0; i < NW; i++) {
            (,,, StakeRouterBase.PathLot[] memory paths) = router.lotOf(workers[i]);
            for (uint256 j = 0; j < paths.length; j++) {
                if (paths[j].root == root) sum += paths[j].amount;
            }
        }
    }

    function sumRootEdge(address root, address mid) external view returns (uint256 sum) {
        for (uint256 i = 0; i < NW; i++) {
            (,,, StakeRouterBase.PathLot[] memory paths) = router.lotOf(workers[i]);
            for (uint256 j = 0; j < paths.length; j++) {
                if (paths[j].root == root && paths[j].mid == mid) sum += paths[j].amount;
            }
        }
    }

    function sumMidEdge(address mid, uint256 workerIndex) external view returns (uint256 sum) {
        (,,, StakeRouterBase.PathLot[] memory paths) = router.lotOf(workers[workerIndex]);
        for (uint256 j = 0; j < paths.length; j++) {
            if (paths[j].mid == mid) sum += paths[j].amount;
        }
    }

    function holders() external view returns (uint256 sum) {
        sum = usdc.balanceOf(address(credit)) + usdc.balanceOf(address(router)) + usdc.balanceOf(stranger)
            + usdc.balanceOf(vendor) + usdc.balanceOf(pooLender());
        for (uint256 i = 0; i < NR; i++) {
            sum += usdc.balanceOf(roots[i]);
        }
        for (uint256 i = 0; i < NC; i++) {
            sum += usdc.balanceOf(customers[i]);
        }
        for (uint256 i = 0; i < NW; i++) {
            sum += usdc.balanceOf(workers[i]);
            sum += usdc.balanceOf(address(router.vaultOf(workers[i])));
        }
    }

    function pooLender() public pure returns (address) {
        return address(0x1E4D);
    }

    // ───────────── internals ─────────────

    function _find(uint256 seed, BootstrapOrderRouter.State want) internal view returns (uint256) {
        uint256 n = router.nextOrderId();
        if (n <= 1) return 0;
        for (uint256 step = 0; step < n - 1; step++) {
            uint256 cand = 1 + (((seed % (n - 1)) + step) % (n - 1));
            (,,,,,, BootstrapOrderRouter.State st) = router.orders(cand);
            if (st == want) return cand;
        }
        return 0;
    }

    function _originate(uint256 id, uint256 seed) internal {
        BootstrapOrderRouter.Intent memory i = router.intentOf(id);
        uint256 parts = 1 + (seed % 3);
        if (parts > 1) multiPath++;
        StakeRouterBase.Path[] memory ps = new StakeRouterBase.Path[](parts);
        uint256 remaining = i.amount;
        for (uint256 k = 0; k < parts; k++) {
            uint256 amt = k == parts - 1 ? remaining : remaining / (parts - k);
            if (amt == 0) return;
            remaining -= amt;
            ps[k] = _path(seed >> (8 * (k + 1)), k, i.worker, amt);
        }
        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: i.worker,
            amount: i.amount,
            to: i.vendor,
            repaymentPeriod: i.term,
            maxAprBps: i.maxAprBps,
            nonce: i.nonce,
            deadline: i.deadline
        });
        bytes memory poolSig = _signPool(_workerKeys[_workerIndex(i.worker)], req);
        bytes memory orderSig = _sign(_workerKeys[_workerIndex(i.worker)], router.acceptanceDigest(id));
        vm.prank(stranger);
        try router.originateOrder(id, req, poolSig, orderSig, ps) {
            originated++;
        } catch { }
    }

    function _workerIndex(address w) internal view returns (uint256) {
        for (uint256 i = 0; i < NW; i++) {
            if (workers[i] == w) return i;
        }
        revert("unknown worker");
    }

    function _path(uint256 h, uint256 k, address w, uint256 amount)
        internal
        view
        returns (StakeRouterBase.Path memory p)
    {
        uint256 ri = (h + k) % NR;
        uint256 mi = (h >> 4) % NM;
        bool wildcard = (h >> 8) % 2 == 0;
        bool tight = (h >> 9) % 3 == 0;
        StakeRouterBase.Consent memory re = StakeRouterBase.Consent({
            from: roots[ri],
            to: mids[mi],
            borrower: wildcard ? address(0) : w,
            limit: tight ? amount : 100e6,
            maxTerm: 30 days,
            version: router.edgeVersion(router.edgeKey(roots[ri], mids[mi], address(0))),
            expiry: vm.getBlockTimestamp() + 90 days
        });
        StakeRouterBase.Consent memory me = StakeRouterBase.Consent({
            from: mids[mi],
            to: w,
            borrower: w,
            limit: 100e6,
            maxTerm: 30 days,
            version: router.edgeVersion(router.edgeKey(mids[mi], w, w)),
            expiry: vm.getBlockTimestamp() + 90 days
        });
        p.amount = amount;
        p.rootEdge = re;
        p.rootSig = _sign(_rootKeys[ri], router.consentDigest(re));
        p.midEdge = me;
        p.midSig = _sign(_midKeys[mi], router.consentDigest(me));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPool(uint256 pk, DecentralizedMicrocredit.BorrowAndDisburse memory req)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(credit)
            )
        );
        bytes32 structHash = keccak256(
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
        );
        return _sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
