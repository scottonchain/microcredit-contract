// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { TransitiveStakeRouter } from "../../contracts/TransitiveStakeRouter.sol";

/**
 * @dev Drives the two-hop router for the allocation-certificate invariants with a fixed cast: three roots,
 *      three mids and six managed borrowers (each has named the router as its pool manager), plus a stranger
 *      that repays. Every call is wrapped in try/catch, so the handler never reverts; a revert that is not
 *      one of the two documented refusals (a root without free funds, a consent limit reached) is counted and
 *      fails the suite. Next to the router the handler keeps an independent model built from the documented
 *      rules, not from the router's storage: each open lot with its paths, each loan's principal and
 *      interest-first repayments (so the unpaid principal at a default is known without asking the pool),
 *      each root's deposits, withdrawals and losses. The borrowers are the only borrowers, so every pool loan
 *      is a router loan, fully covered by the vault's stake.
 */
contract RouterHandler is CommonBase, StdCheats, StdUtils {
    uint256 public constant NR = 3;
    uint256 public constant NM = 3;
    uint256 public constant NB = 6;
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant CENT = 10_000;
    uint256 internal constant GRACE_PERIOD = 1 days;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant BORROW_AND_DISBURSE_TYPEHASH = keccak256(
        "BorrowAndDisburse(address borrower,uint256 amount,address to,uint256 repaymentPeriod,uint256 maxAprBps,uint256 nonce,uint256 deadline)"
    );

    struct PathM {
        address root;
        address mid;
        uint256 amount;
    }

    struct LotM {
        bool open;
        uint256 loanId;
        uint256 amount;
        uint256 term;
        uint256 disbursedAt;
        uint256 rate;
        uint256 repaid;
        uint256 principalRepaid;
        PathM[] paths;
    }

    DecentralizedMicrocredit public immutable credit;
    MockUSDC public immutable usdc;
    TransitiveStakeRouter public immutable router;
    address public immutable stranger = address(0x57A4);
    address public immutable vendor = address(0x7E4D);

    address[] public roots;
    address[] public mids;
    address[] public borrowers;
    uint256[] internal _rootKeys;
    uint256[] internal _midKeys;
    uint256[] internal _borrowerKeys;

    mapping(address => LotM) internal _lots;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public modelLoss;
    uint256 public strayInRouter;

    // coverage and failure counters
    uint256 public unexpectedReverts;
    uint256 public violations;
    uint256 public originations;
    uint256 public refusals;
    uint256 public repaidLots;
    uint256 public defaultedLots;
    uint256 public partialRepayDefaults;
    uint256 public multiPathLots;
    uint256 public totalLossAttributed;
    uint256 public revocations;

    constructor(DecentralizedMicrocredit credit_, MockUSDC usdc_, TransitiveStakeRouter router_) {
        credit = credit_;
        usdc = usdc_;
        router = router_;
        for (uint256 i = 0; i < NR; i++) {
            uint256 k = uint256(keccak256(abi.encode("root", i)));
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
            uint256 k = uint256(keccak256(abi.encode("mid", i)));
            _midKeys.push(k);
            mids.push(vm.addr(k));
        }
        for (uint256 i = 0; i < NB; i++) {
            uint256 k = uint256(keccak256(abi.encode("borrower", i)));
            _borrowerKeys.push(k);
            address b = vm.addr(k);
            borrowers.push(b);
            vm.prank(b);
            credit_.setManager(address(router_));
        }
    }

    // ───────────── actions ─────────────

    function deposit(uint256 seed, uint256 amount) external {
        address r = roots[seed % NR];
        amount = bound(amount, 1e6, 40e6);
        usdc.mint(r, amount);
        vm.startPrank(r);
        usdc.approve(address(router), amount);
        try router.deposit(amount) {
            deposited[r] += amount;
        } catch {
            unexpectedReverts++;
        }
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address r = roots[seed % NR];
        uint256 free = router.free(r);
        vm.startPrank(r);
        // asking for more than the free balance must always fail
        try router.withdraw(free + 1) {
            violations++;
        } catch { }
        if (free != 0) {
            amount = bound(amount, 1, free);
            try router.withdraw(amount) {
                withdrawn[r] += amount;
            } catch {
                unexpectedReverts++;
            }
        }
        vm.stopPrank();
    }

    function revoke(uint256 seed) external {
        address b = borrowers[seed % NB];
        if ((seed >> 8) % 2 == 0) {
            address r = roots[(seed >> 16) % NR];
            vm.prank(r);
            router.revokeEdge(mids[(seed >> 24) % NM], b);
        } else {
            address m = mids[(seed >> 16) % NM];
            vm.prank(m);
            router.revokeEdge(b, b);
        }
        revocations++;
    }

    function originate(uint256 seed) external {
        uint256 bi = seed % NB;
        address b = borrowers[bi];
        if (credit.defaultedLoans(b) != 0) return;
        _syncModel(b);
        if (_lots[b].open) return;

        uint256 n = 1 + ((seed >> 8) % 4);
        uint256 term = bound(seed >> 16, 1 days, 30 days);
        TransitiveStakeRouter.Path[] memory paths = new TransitiveStakeRouter.Path[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 ri = h % NR;
            uint256 mi = (h >> 8) % NM;
            uint256 amount = 3e5 + ((h >> 16) % 3e6);
            if (i == 0 && n == 1 && amount < 1e6) amount = 1e6;
            bool tightRoot = (h >> 40) % 3 == 0;
            bool tightMid = (h >> 48) % 3 == 0;
            paths[i] = _path(ri, mi, bi, amount, tightRoot, tightMid);
            total += amount;
        }
        if (total < 1e6) {
            paths[0].amount += 1e6 - total;
            total = 1e6;
            // limits are rebuilt for the larger amount
            uint256 h0 = uint256(keccak256(abi.encode(seed, uint256(0))));
            paths[0] = _path(h0 % NR, (h0 >> 8) % NM, bi, paths[0].amount, false, false);
        }

        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: b,
            amount: total,
            to: vendor,
            repaymentPeriod: term,
            maxAprBps: 933,
            nonce: credit.nonces(b),
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        bytes memory sig = _signPool(_borrowerKeys[bi], req);

        try router.originate(req, sig, paths) returns (uint256 loanId) {
            originations++;
            LotM storage lot = _lots[b];
            lot.open = true;
            lot.loanId = loanId;
            lot.amount = total;
            lot.term = term;
            (,,, uint256 rate,) = credit.getLoan(loanId);
            lot.rate = rate;
            (,,, uint256 disbursedAt,) = credit.getLoanTerms(loanId);
            lot.disbursedAt = disbursedAt;
            for (uint256 i = 0; i < n; i++) {
                lot.paths
                    .push(PathM({ root: paths[i].rootEdge.from, mid: paths[i].rootEdge.to, amount: paths[i].amount }));
            }
            if (n > 1) multiPathLots++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (
                sel == TransitiveStakeRouter.InsufficientFree.selector
                    || sel == TransitiveStakeRouter.LimitExceeded.selector
            ) {
                refusals++;
            } else {
                unexpectedReverts++;
            }
        }
    }

    function repay(uint256 seed, uint256 fraction) external {
        address b = borrowers[seed % NB];
        LotM storage lot = _lots[b];
        if (!lot.open) return;
        (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(lot.loanId);
        if (status != DecentralizedMicrocredit.LoanStatus.Active) return;
        uint256 owed = credit.getCurrentOutstandingAmount(lot.loanId);
        uint256 amount = fraction % 3 == 0 ? owed : bound(fraction, 1, owed);
        usdc.mint(stranger, amount);
        vm.startPrank(stranger);
        usdc.approve(address(credit), amount);
        try credit.repayLoan(lot.loanId, amount) {
            _modelRepay(lot, owed, amount);
        } catch {
            unexpectedReverts++;
        }
        vm.stopPrank();
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1 hours, 40 days));
    }

    function defaultOne(uint256 seed) external {
        address b = borrowers[seed % NB];
        LotM storage lot = _lots[b];
        if (!lot.open) return;
        (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(lot.loanId);
        if (status != DecentralizedMicrocredit.LoanStatus.Active) return;
        if (vm.getBlockTimestamp() <= lot.disbursedAt + lot.term + credit.LATE_PERIOD()) return;
        try credit.markDefaulted(lot.loanId) {
            defaultedLots++;
            if (lot.principalRepaid != 0) partialRepayDefaults++;
        } catch {
            unexpectedReverts++;
        }
    }

    function syncOne(uint256 seed) external {
        _syncModel(borrowers[seed % NB]);
    }

    function donate(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 5e6);
        if (seed % 2 == 0) {
            usdc.mint(address(router), amount);
            strayInRouter += amount;
        } else {
            // prefer a vault whose lot is open, so a donation can meet a default
            address b = borrowers[(seed >> 1) % NB];
            for (uint256 i = 0; i < NB && !_lots[b].open; i++) {
                b = borrowers[(seed + i) % NB];
            }
            address v = address(router.vaultOf(b));
            if (v != address(0)) usdc.mint(v, amount);
        }
    }

    // ───────────── model ─────────────

    function _modelRepay(LotM storage lot, uint256 owed, uint256 amount) internal {
        uint256 elapsed = vm.getBlockTimestamp() - lot.disbursedAt;
        uint256 accrued =
            elapsed < GRACE_PERIOD ? 0 : (((lot.amount * lot.rate) / BASIS_POINTS) * elapsed) / SECONDS_PER_YEAR;
        uint256 interestDue = accrued - (lot.repaid - lot.principalRepaid);
        uint256 paid = amount < owed ? amount : owed;
        uint256 rest = owed - paid;
        bool closes = rest < CENT && rest <= interestDue;
        uint256 interest = closes ? interestDue - rest : (paid < interestDue ? paid : interestDue);
        lot.repaid += paid;
        lot.principalRepaid += paid - interest;
    }

    /// @dev Syncs a closed lot through the router and checks the result against the model.
    function _syncModel(address b) internal {
        LotM storage lot = _lots[b];
        if (!lot.open) return;
        (DecentralizedMicrocredit.LoanStatus status,,,,) = credit.getLoanTerms(lot.loanId);
        if (
            status == DecentralizedMicrocredit.LoanStatus.Active
                || status == DecentralizedMicrocredit.LoanStatus.Requested
        ) return;

        uint256 expectedLoss =
            status == DecentralizedMicrocredit.LoanStatus.Defaulted ? lot.amount - lot.principalRepaid : 0;
        uint256[3] memory freeBefore;
        uint256[3] memory lossBefore;
        uint256[3] memory lotted; // path amounts per root
        uint256[3] memory floors; // sum of floor(loss * amount / total) per root
        for (uint256 i = 0; i < NR; i++) {
            freeBefore[i] = router.free(roots[i]);
            lossBefore[i] = router.lossOf(roots[i]);
        }
        for (uint256 i = 0; i < lot.paths.length; i++) {
            uint256 ri = _rootIndex(lot.paths[i].root);
            lotted[ri] += lot.paths[i].amount;
            floors[ri] += (expectedLoss * lot.paths[i].amount) / lot.amount;
        }

        try router.sync(b) { }
        catch {
            unexpectedReverts++;
            return;
        }

        uint256 sumLoss;
        for (uint256 i = 0; i < NR; i++) {
            uint256 dLoss = router.lossOf(roots[i]) - lossBefore[i];
            uint256 dFree = router.free(roots[i]) - freeBefore[i];
            sumLoss += dLoss;
            modelLoss[roots[i]] += dLoss;
            // each root gets back exactly what it put in less its share of the loss
            if (dFree + dLoss != lotted[i]) violations++;
            // and bears no more than its own paths, and no less than the floor of its pro rata share
            if (dLoss > lotted[i] || dLoss < floors[i] || dLoss > floors[i] + lot.paths.length) violations++;
        }
        // the loss attributed is exactly the unpaid principal that was charged to the vault's stake
        if (sumLoss != expectedLoss) violations++;
        totalLossAttributed += sumLoss;
        if (status == DecentralizedMicrocredit.LoanStatus.Repaid) repaidLots++;
        delete _lots[b];
    }

    // ───────────── views for the invariants ─────────────

    function lotOpen(address b) external view returns (bool) {
        return _lots[b].open;
    }

    function lotAmount(address b) external view returns (uint256) {
        return _lots[b].amount;
    }

    function lotLoan(address b) external view returns (uint256) {
        return _lots[b].loanId;
    }

    function expectedLocked(address root) external view returns (uint256 sum) {
        for (uint256 i = 0; i < NB; i++) {
            LotM storage lot = _lots[borrowers[i]];
            for (uint256 j = 0; j < lot.paths.length; j++) {
                if (lot.paths[j].root == root) sum += lot.paths[j].amount;
            }
        }
    }

    /// @dev Live exposure the model expects on the edge (from, to, borrower): the root edge when `from` is a
    ///      root and `to` a mid, the mid edge when `from` is a mid and `to` the borrower.
    function expectedEdgeUsed(address from, address to, address borrower) external view returns (uint256 sum) {
        LotM storage lot = _lots[borrower];
        for (uint256 j = 0; j < lot.paths.length; j++) {
            PathM storage p = lot.paths[j];
            if (p.root == from && p.mid == to) sum += p.amount;
            if (p.mid == from && borrower == to) sum += p.amount;
        }
    }

    function _rootIndex(address root) internal view returns (uint256) {
        for (uint256 i = 0; i < NR; i++) {
            if (roots[i] == root) return i;
        }
        revert("unknown root");
    }

    // ───────────── builders ─────────────

    function _path(uint256 ri, uint256 mi, uint256 bi, uint256 amount, bool tightRoot, bool tightMid)
        internal
        view
        returns (TransitiveStakeRouter.Path memory p)
    {
        address b = borrowers[bi];
        TransitiveStakeRouter.Consent memory re = TransitiveStakeRouter.Consent({
            from: roots[ri],
            to: mids[mi],
            borrower: b,
            limit: tightRoot ? amount : 100e6,
            maxTerm: 30 days,
            version: router.edgeVersion(router.edgeKey(roots[ri], mids[mi], b)),
            expiry: vm.getBlockTimestamp() + 60 days
        });
        TransitiveStakeRouter.Consent memory me = TransitiveStakeRouter.Consent({
            from: mids[mi],
            to: b,
            borrower: b,
            limit: tightMid ? amount : 100e6,
            maxTerm: 30 days,
            version: router.edgeVersion(router.edgeKey(mids[mi], b, b)),
            expiry: vm.getBlockTimestamp() + 60 days
        });
        p.amount = amount;
        p.rootEdge = re;
        p.rootSig = _signConsent(_rootKeys[ri], re);
        p.midEdge = me;
        p.midSig = _signConsent(_midKeys[mi], me);
    }

    function _signConsent(uint256 pk, TransitiveStakeRouter.Consent memory c) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.consentDigest(c));
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
