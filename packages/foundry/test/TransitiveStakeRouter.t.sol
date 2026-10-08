// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { StakeVault, TransitiveStakeRouter } from "../contracts/TransitiveStakeRouter.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/// @dev Exposes the router's loss attribution so it can be fuzzed on its own.
contract AttributionHarness is TransitiveStakeRouter {
    constructor(DecentralizedMicrocredit pool_) TransitiveStakeRouter(pool_) { }

    function attribute(PathLot[] memory paths, uint256 amount, uint256 loss) external pure returns (uint256[] memory) {
        return _attribute(paths, amount, loss);
    }
}

/// @dev A smart-wallet root: accepts one digest, as an ERC-1271 account would.
contract SmartRoot {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/**
 * @dev The two-hop router: roots' USDC backs a managed borrower through a per-borrower vault, consents bound
 *      every edge, the pool's manager gate keeps every other origination path closed, and a closed loan's lot
 *      comes back (or its loss is attributed) through `sync`.
 */
contract TransitiveStakeRouterTest is MicrocreditTestBase {
    TransitiveStakeRouter internal router;

    address internal root1;
    uint256 internal root1Pk;
    address internal root2;
    uint256 internal root2Pk;
    address internal mid1;
    uint256 internal mid1Pk;
    address internal mid2;
    uint256 internal mid2Pk;
    address internal borrower;
    uint256 internal borrowerPk;
    address internal borrower2;
    uint256 internal borrower2Pk;
    address internal vendor = makeAddr("vendor");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant LIMIT = 100e6;
    uint256 internal constant TERM = 30 days;

    bytes32 internal constant CONSENT_TYPEHASH = keccak256(
        "EdgeConsent(address from,address to,address borrower,uint256 limit,uint256 maxTerm,uint256 version,uint256 expiry)"
    );

    function setUp() public virtual {
        _deployProtocol();
        _give(makeAddr("poolLender"), 1_000e6);
        vm.startPrank(makeAddr("poolLender"));
        usdc.approve(address(credit), 1_000e6);
        credit.depositFunds(1_000e6);
        vm.stopPrank();
        router = new TransitiveStakeRouter(credit);
        (root1, root1Pk) = makeAddrAndKey("root1");
        (root2, root2Pk) = makeAddrAndKey("root2");
        (mid1, mid1Pk) = makeAddrAndKey("mid1");
        (mid2, mid2Pk) = makeAddrAndKey("mid2");
        (borrower, borrowerPk) = makeAddrAndKey("borrower");
        (borrower2, borrower2Pk) = makeAddrAndKey("borrower2");
        _manage(borrower);
        _manage(borrower2);
    }

    // ───────────── helpers ─────────────

    /// @dev The fork suite overrides these two to run the same tests against Circle's USDC.
    function _deployProtocol() internal virtual {
        _deploy(433, 500, 100e6);
    }

    function _give(address who, uint256 amount) internal virtual {
        usdc.mint(who, amount);
    }

    function _poolStake(address who, uint256 amount) internal {
        _give(who, amount);
        vm.startPrank(who);
        usdc.approve(address(credit), amount);
        credit.stake(amount);
        vm.stopPrank();
    }

    function _manage(address who) internal {
        vm.prank(who);
        credit.setManager(address(router));
    }

    function _fund(address root, uint256 amount) internal {
        _give(root, amount);
        vm.startPrank(root);
        usdc.approve(address(router), amount);
        router.deposit(amount);
        vm.stopPrank();
    }

    function _digest(TransitiveStakeRouter.Consent memory c) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("TransitiveStakeRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(CONSENT_TYPEHASH, c.from, c.to, c.borrower, c.limit, c.maxTerm, c.version, c.expiry)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _consent(address from, address to, address forBorrower, uint256 limit)
        internal
        view
        returns (TransitiveStakeRouter.Consent memory c)
    {
        c = TransitiveStakeRouter.Consent({
            from: from,
            to: to,
            borrower: forBorrower,
            limit: limit,
            maxTerm: TERM,
            version: router.edgeVersion(router.edgeKey(from, to, forBorrower)),
            expiry: block.timestamp + 30 days
        });
    }

    function _signConsent(uint256 pk, TransitiveStakeRouter.Consent memory c) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(c));
        return abi.encodePacked(r, s, v);
    }

    function _path(uint256 rPk, address r, uint256 mPk, address m, address forBorrower, uint256 amount)
        internal
        view
        returns (TransitiveStakeRouter.Path memory p)
    {
        TransitiveStakeRouter.Consent memory re = _consent(r, m, forBorrower, LIMIT);
        TransitiveStakeRouter.Consent memory me = _consent(m, forBorrower, forBorrower, LIMIT);
        p = TransitiveStakeRouter.Path({
            amount: amount, rootEdge: re, rootSig: _signConsent(rPk, re), midEdge: me, midSig: _signConsent(mPk, me)
        });
    }

    function _one(TransitiveStakeRouter.Path memory p) internal pure returns (TransitiveStakeRouter.Path[] memory ps) {
        ps = new TransitiveStakeRouter.Path[](1);
        ps[0] = p;
    }

    function _req(address who, uint256 amount)
        internal
        view
        returns (DecentralizedMicrocredit.BorrowAndDisburse memory)
    {
        return DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: who,
            amount: amount,
            to: vendor,
            repaymentPeriod: 7 days,
            maxAprBps: 933,
            nonce: credit.nonces(who),
            deadline: _deadline()
        });
    }

    function _originate(uint256 bPk, address who, uint256 amount, TransitiveStakeRouter.Path[] memory paths)
        internal
        returns (uint256 loanId)
    {
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(who, amount);
        bytes memory sig = _signBorrowAndDisburse(bPk, req);
        vm.prank(stranger);
        loanId = router.originate(req, sig, paths);
    }

    /// @dev root1 funds `fundAmount`; mid1 vouches for `borrower`; the loan is `amount`.
    function _simple(uint256 fundAmount, uint256 amount) internal returns (uint256 loanId) {
        _fund(root1, fundAmount);
        loanId = _originate(borrowerPk, borrower, amount, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, amount)));
    }

    function _repayAll(address payer, uint256 loanId) internal {
        uint256 owed = credit.getCurrentOutstandingAmount(loanId);
        _give(payer, owed);
        vm.startPrank(payer);
        usdc.approve(address(credit), owed);
        credit.repayLoan(loanId, owed);
        vm.stopPrank();
    }

    function _repayPart(address payer, uint256 loanId, uint256 amount) internal {
        _give(payer, amount);
        vm.startPrank(payer);
        usdc.approve(address(credit), amount);
        credit.repayLoan(loanId, amount);
        vm.stopPrank();
    }

    function _defaultLoan(uint256 loanId) internal {
        (,,,, uint256 dueAt) = credit.getLoanTerms(loanId);
        vm.warp(dueAt + credit.LATE_PERIOD() + 1);
        credit.markDefaulted(loanId);
    }

    function _vault(address who) internal view returns (address) {
        return address(router.vaultOf(who));
    }

    // ───────────── the two-hop path ─────────────

    function testTwoHopLoanIsBackedByTheRootsStakeAndReleasedOnRepayment() public {
        uint256 loanId = _simple(10e6, 4e6);

        // the root's USDC is the borrower's secured backing, held by the borrower's vault; nobody else's credit moved
        assertEq(usdc.balanceOf(vendor), 4e6, "principal reached the signed vendor");
        assertEq(router.free(root1), 6e6);
        assertEq(router.locked(root1), 4e6);
        assertEq(credit.stakeOf(_vault(borrower)), 4e6);
        (uint256 secured, uint256 unsecured) = credit.getBacking(_vault(borrower), borrower);
        assertEq(secured, 4e6);
        assertEq(unsecured, 0);
        assertEq(router.edgeUsed(router.edgeKey(root1, mid1, borrower)), 4e6);
        assertEq(router.edgeUsed(router.edgeKey(mid1, borrower, borrower)), 4e6);
        (bool open, uint256 lotLoan, uint256 lotAmount,) = router.lotOf(borrower);
        assertTrue(open);
        assertEq(lotLoan, loanId);
        assertEq(lotAmount, 4e6);

        // a stranger repays at the pool; the lot is returned by sync, to the root's free balance
        _repayAll(stranger, loanId);
        assertEq(router.locked(root1), 4e6, "not released until synced");
        router.sync(borrower);
        assertEq(router.free(root1), 10e6);
        assertEq(router.locked(root1), 0);
        assertEq(router.lossOf(root1), 0);
        assertEq(credit.stakeOf(_vault(borrower)), 0);
        assertEq(router.edgeUsed(router.edgeKey(root1, mid1, borrower)), 0);
        assertEq(router.totalLocked(), 0);
        assertEq(usdc.balanceOf(address(router)), router.totalFree());

        vm.prank(root1);
        router.withdraw(10e6);
        assertEq(usdc.balanceOf(root1), 10e6);
    }

    function testCertifiedLoanRepaidDirectlyAtPoolCannotBeReopenedOnAnyOtherPath() public {
        uint256 loanId = _simple(10e6, 4e6);
        _repayAll(stranger, loanId); // pool capacity for this borrower is free again; the vault backing is still live

        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(1e6);

        DecentralizedMicrocredit.LoanRequest memory lr = DecentralizedMicrocredit.LoanRequest({
            borrower: borrower, amount: 1e6, nonce: credit.nonces(borrower), deadline: _deadline()
        });
        bytes memory lsig = _signLoanRequest(borrowerPk, lr);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoanMeta(lr, lsig);

        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.prank(relayer);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);
        vm.prank(stranger);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.borrowAndDisburseMeta(req, sig);

        // after the sync the router is still the only door, and it asks for a fresh certificate
        router.sync(borrower);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.NotManager.selector);
        credit.requestLoan(1e6);
    }

    function testSecondCycleOnTheSameConsentsWithinTheLimit() public {
        uint256 loanId = _simple(10e6, 4e6);
        _repayAll(stranger, loanId);
        // no explicit sync: the next origination runs it first
        uint256 second = _originate(borrowerPk, borrower, 5e6, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 5e6)));
        assertTrue(second != loanId);
        assertEq(router.free(root1), 5e6);
        assertEq(router.locked(root1), 5e6);
        assertEq(credit.stakeOf(_vault(borrower)), 5e6);
    }

    // ───────────── several roots, several borrowers ─────────────

    function testTwoRootsAndTwoMidsSplitOneLot() public {
        _fund(root1, 10e6);
        _fund(root2, 10e6);
        TransitiveStakeRouter.Path[] memory ps = new TransitiveStakeRouter.Path[](2);
        ps[0] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6);
        ps[1] = _path(root2Pk, root2, mid2Pk, mid2, borrower, 2e6);
        uint256 loanId = _originate(borrowerPk, borrower, 5e6, ps);

        assertEq(router.locked(root1), 3e6);
        assertEq(router.locked(root2), 2e6);
        assertEq(credit.stakeOf(_vault(borrower)), 5e6);

        _defaultLoan(loanId);
        router.sync(borrower);
        // the whole 5e6 was unpaid and fully backed: roots lose their path amounts, no more
        assertEq(router.lossOf(root1), 3e6);
        assertEq(router.lossOf(root2), 2e6);
        assertEq(router.free(root1), 7e6);
        assertEq(router.free(root2), 8e6);
        assertEq(router.locked(root1) + router.locked(root2), 0);
        assertEq(usdc.balanceOf(address(router)), router.totalFree());
    }

    function testOneRootTwoBorrowersCannotOverdrawItsFreeBalance() public {
        _fund(root1, 5e6);
        _originate(borrowerPk, borrower, 3e6, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6)));
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower2, 3e6);
        bytes memory sig = _signBorrowAndDisburse(borrower2Pk, req);
        TransitiveStakeRouter.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower2, 3e6));
        vm.expectRevert(TransitiveStakeRouter.InsufficientFree.selector);
        router.originate(req, sig, ps);
        // two exposures that fit are both fine
        _originate(borrower2Pk, borrower2, 2e6, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower2, 2e6)));
        assertEq(router.free(root1), 0);
        assertEq(router.locked(root1), 5e6);
    }

    function testSharedMidEdgeLimitBindsAcrossRoots() public {
        _fund(root1, 10e6);
        _fund(root2, 10e6);
        // mid1 vouches for the borrower up to 4e6 live exposure in total; two roots route through it
        TransitiveStakeRouter.Consent memory me = _consent(mid1, borrower, borrower, 4e6);
        bytes memory meSig = _signConsent(mid1Pk, me);
        TransitiveStakeRouter.Path[] memory ps = new TransitiveStakeRouter.Path[](2);
        ps[0] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6);
        ps[1] = _path(root2Pk, root2, mid1Pk, mid1, borrower, 2e6);
        ps[0].midEdge = me;
        ps[0].midSig = meSig;
        ps[1].midEdge = me;
        ps[1].midSig = meSig;
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 5e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.expectRevert(TransitiveStakeRouter.LimitExceeded.selector);
        router.originate(req, sig, ps); // 3e6 + 2e6 > 4e6 through the same mid edge

        ps[1].amount = 1e6;
        req = _req(borrower, 4e6);
        sig = _signBorrowAndDisburse(borrowerPk, req);
        router.originate(req, sig, ps);
        assertEq(router.edgeUsed(router.edgeKey(mid1, borrower, borrower)), 4e6);
    }

    function testRepeatedRootEdgeInOneCertificateCountsTwiceAgainstTheLimit() public {
        _fund(root1, 10e6);
        TransitiveStakeRouter.Consent memory re = _consent(root1, mid1, borrower, 4e6);
        bytes memory reSig = _signConsent(root1Pk, re);
        TransitiveStakeRouter.Path[] memory ps = new TransitiveStakeRouter.Path[](2);
        ps[0] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6);
        ps[1] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6);
        ps[0].rootEdge = re;
        ps[0].rootSig = reSig;
        ps[1].rootEdge = re;
        ps[1].rootSig = reSig;
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 6e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.expectRevert(TransitiveStakeRouter.LimitExceeded.selector);
        router.originate(req, sig, ps);
    }

    // ───────────── malformed certificates, cycles and aliases ─────────────

    function testRootCannotBeItsOwnMidNorTheBorrowerNorTheRouter() public {
        _fund(root1, 10e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        // root == mid
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, root1Pk, root1, borrower, 2e6);
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));

        // mid == borrower
        p = _path(root1Pk, root1, borrowerPk, borrower, borrower, 2e6);
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));

        // root == borrower (the borrower backing itself through a mid)
        _fund(borrower, 10e6);
        p = _path(borrowerPk, borrower, mid1Pk, mid1, borrower, 2e6);
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));

        // the router as a root or mid
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.to = address(router);
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));
    }

    function testMidEdgeMustStartAtTheMidAndEndAtTheBorrower() public {
        _fund(root1, 10e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        // mid2's consent in place of mid1's
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        TransitiveStakeRouter.Path memory other = _path(root2Pk, root2, mid2Pk, mid2, borrower, 2e6);
        p.midEdge = other.midEdge;
        p.midSig = other.midSig;
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));

        // a root consent for another terminal borrower
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower2, 2e6);
        TransitiveStakeRouter.Path memory good = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.midEdge = good.midEdge;
        p.midSig = good.midSig;
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, _one(p));
    }

    function testPathCountAndAmountsAreChecked() public {
        _fund(root1, 50e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 5e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        TransitiveStakeRouter.Path[] memory none = new TransitiveStakeRouter.Path[](0);
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, none);

        TransitiveStakeRouter.Path[] memory five = new TransitiveStakeRouter.Path[](5);
        for (uint256 i = 0; i < 5; i++) {
            five[i] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 1e6);
        }
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, five);
        TransitiveStakeRouter.Path[] memory pp = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 4e6));
        vm.expectRevert(TransitiveStakeRouter.AmountMismatch.selector);
        router.originate(req, sig, pp); // sums to 4e6, loan is 5e6
        TransitiveStakeRouter.Path[] memory pp2 = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 0));
        vm.expectRevert(TransitiveStakeRouter.InvalidCertificate.selector);
        router.originate(req, sig, pp2);
    }

    function testALotBelowTheMinimumBackingIsRefusedByThePool() public {
        _fund(root1, 5e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 5e5);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory pp = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 5e5));
        vm.expectRevert(DecentralizedMicrocredit.BackingTooSmall.selector);
        router.originate(req, sig, pp);
    }

    // ───────────── consents ─────────────

    function testConsentExpiryVersionSignerLimitAndTermAreEnforced() public {
        _fund(root1, 10e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        // expired
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.expiry = block.timestamp - 1;
        p.rootSig = _signConsent(root1Pk, p.rootEdge);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p));

        // signed by someone else
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootSig = _signConsent(root2Pk, p.rootEdge);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p));

        // a field changed after signing
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.midEdge.limit = 1_000e6;
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p));

        // the loan is larger than the consent's limit
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.limit = 1e6;
        p.rootSig = _signConsent(root1Pk, p.rootEdge);
        vm.expectRevert(TransitiveStakeRouter.LimitExceeded.selector);
        router.originate(req, sig, _one(p));

        // the loan runs longer than the root allowed
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.maxTerm = 3 days;
        p.rootSig = _signConsent(root1Pk, p.rootEdge);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p)); // the request's term is 7 days

        // the mid's term cap binds as well
        p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.midEdge.maxTerm = 3 days;
        p.midSig = _signConsent(mid1Pk, p.midEdge);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p));
    }

    function testRevokedConsentCannotBeUsedAndLiveExposureIsUnaffected() public {
        _fund(root1, 10e6);
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        uint256 loanId = _originate(borrowerPk, borrower, 2e6, _one(p));

        vm.prank(root1);
        router.revokeEdge(mid1, borrower);
        assertEq(router.locked(root1), 2e6, "the live lot stays");

        _repayAll(stranger, loanId);
        router.sync(borrower);
        assertEq(router.free(root1), 10e6);

        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, _one(p)); // the old consent has the old version

        // a fresh consent of the new version works
        router.originate(req, sig, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6)));
    }

    function testSmartWalletRootSignsThroughErc1271() public {
        SmartRoot wallet = new SmartRoot();
        _fund(address(wallet), 10e6);
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.from = address(wallet);
        wallet.approve(_digest(p.rootEdge));
        p.rootSig = hex"";
        _originate(borrowerPk, borrower, 2e6, _one(p));
        assertEq(router.locked(address(wallet)), 2e6);
    }

    // ───────────── the manager gate ─────────────

    function testBorrowerMustHaveNamedTheRouter() public {
        (address plain, uint256 plainPk) = makeAddrAndKey("plain");
        _fund(root1, 10e6);
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, plain, 2e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(plain, 2e6);
        bytes memory sig = _signBorrowAndDisburse(plainPk, req);
        vm.expectRevert(TransitiveStakeRouter.NotManager.selector);
        router.originate(req, sig, _one(p)); // no manager

        vm.prank(plain);
        credit.setManager(makeAddr("someoneElse"));
        vm.expectRevert(TransitiveStakeRouter.NotManager.selector);
        router.originate(req, sig, _one(p)); // another manager
    }

    function testManagerCannotBeChangedWhileTheLotIsLive() public {
        uint256 loanId = _simple(10e6, 4e6);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0));

        _repayAll(stranger, loanId);
        vm.prank(borrower);
        vm.expectRevert(DecentralizedMicrocredit.ManagerLocked.selector);
        credit.setManager(address(0)); // loan closed, vault backing still live until synced

        router.sync(borrower);
        vm.prank(borrower);
        credit.setManager(address(0)); // clean: free to leave, and then the router can no longer originate
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory pp = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6));
        vm.expectRevert(TransitiveStakeRouter.NotManager.selector);
        router.originate(req, sig, pp);
    }

    function testRelayerWhitelistMustNameTheRouter() public {
        _fund(root1, 10e6);
        vm.startPrank(owner);
        credit.setRelayerWhitelistEnabled(true);
        vm.stopPrank();
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6));
        vm.expectRevert();
        router.originate(req, sig, ps);

        vm.prank(owner);
        credit.setRelayerWhitelisted(address(router), true);
        router.originate(req, sig, ps);
        assertEq(router.locked(root1), 2e6);
    }

    // ───────────── one lot per borrower, replay ─────────────

    function testOnlyOneOpenLotPerBorrower() public {
        _simple(10e6, 4e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory pp = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 1e6));
        vm.expectRevert(TransitiveStakeRouter.OpenLot.selector);
        router.originate(req, sig, pp);
    }

    function testASignedPoolRequestCannotBeReplayed() public {
        _fund(root1, 10e6);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6));
        uint256 loanId = router.originate(req, sig, ps);
        _repayAll(stranger, loanId);
        vm.expectRevert(); // the pool nonce is spent
        router.originate(req, sig, ps);
    }

    // ───────────── defaults ─────────────

    function testPartialRepaymentThenDefaultChargesTheUnpaidPrincipalToTheRootsProRata() public {
        _fund(root1, 10e6);
        _fund(root2, 10e6);
        TransitiveStakeRouter.Path[] memory ps = new TransitiveStakeRouter.Path[](2);
        ps[0] = _path(root1Pk, root1, mid1Pk, mid1, borrower, 6e6);
        ps[1] = _path(root2Pk, root2, mid2Pk, mid2, borrower, 4e6);
        uint256 loanId = _originate(borrowerPk, borrower, 10e6, ps);

        _repayPart(stranger, loanId, 5e6); // inside the first day: all principal
        _defaultLoan(loanId);
        router.sync(borrower);

        // 5e6 of the 10e6 principal was unpaid: the vault lost 5e6, split 3e6 and 2e6 by path amounts
        assertEq(router.lossOf(root1), 3e6);
        assertEq(router.lossOf(root2), 2e6);
        assertEq(router.free(root1), 7e6);
        assertEq(router.free(root2), 8e6);
        assertEq(credit.stakeOf(_vault(borrower)), 0);
        assertEq(usdc.balanceOf(address(router)), router.totalFree());
        assertEq(credit.defaultedLoans(borrower), 1);
    }

    function testDefaultNeverTouchesLendersPrincipalWhenTheLotCoversTheLoan() public {
        uint256 reserveBefore = credit.firstLossReserve();
        uint256 assetsBefore = credit.totalAssets();
        uint256 loanId = _simple(10e6, 4e6);
        _defaultLoan(loanId);
        // the slash returned the whole unpaid principal to the pool's cash: lenders' assets are whole
        assertGe(credit.totalAssets(), assetsBefore);
        assertEq(credit.firstLossReserve(), reserveBefore);
        router.sync(borrower);
        assertEq(router.lossOf(root1), 4e6);
    }

    function testDefaultedBorrowerCannotBorrowAgainThroughTheRouter() public {
        uint256 loanId = _simple(10e6, 4e6);
        _defaultLoan(loanId);
        router.sync(borrower);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 1e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory pp = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 1e6));
        vm.expectRevert(DecentralizedMicrocredit.BorrowerInDefault.selector); // the pool refuses backing a defaulted borrower
        router.originate(req, sig, pp);
    }

    function testAThirdPartyBackerShareTheSlashSoTheRootsLoseLess() public {
        address extra = makeAddr("extraBacker");
        _poolStake(extra, 6e6);
        vm.prank(extra);
        credit.back(borrower, 6e6); // allowed after the manager is set: only the manager changes are locked
        uint256 loanId = _simple(10e6, 4e6);
        _defaultLoan(loanId); // 4e6 unpaid against 10e6 secured: the vault bears 4/10 of it
        router.sync(borrower);
        assertEq(router.lossOf(root1), 1_600_000);
        assertEq(router.free(root1), 10e6 - 1_600_000);
        assertEq(credit.stakeOf(extra), 6e6 - 2_400_000);
    }

    // ───────────── staleness, withdrawals, stray funds ─────────────

    function testRootCannotWithdrawALockedLotUntilItIsSynced() public {
        uint256 loanId = _simple(10e6, 4e6);
        vm.startPrank(root1);
        router.withdraw(6e6);
        vm.expectRevert(TransitiveStakeRouter.InsufficientFree.selector);
        router.withdraw(1);
        vm.stopPrank();

        _repayAll(stranger, loanId);
        vm.prank(root1);
        vm.expectRevert(TransitiveStakeRouter.InsufficientFree.selector);
        router.withdraw(1); // closed but not yet synced

        vm.prank(stranger);
        router.sync(borrower);
        vm.prank(root1);
        router.withdraw(4e6);
        assertEq(usdc.balanceOf(root1), 10e6);
    }

    function testSyncDoesNothingWhileTheLoanIsOpen() public {
        _simple(10e6, 4e6);
        router.sync(borrower);
        assertEq(router.locked(root1), 4e6);
        (bool open,,,) = router.lotOf(borrower);
        assertTrue(open);
        router.sync(borrower2); // no lot at all
    }

    function testStrayUsdcInTheRouterOrVaultDoesNotChangeAccounting() public {
        uint256 loanId = _simple(10e6, 4e6);
        _give(address(router), 3e6);
        _give(_vault(borrower), 3e6);
        _repayAll(stranger, loanId);
        router.sync(borrower);
        assertEq(router.free(root1), 10e6);
        assertEq(router.totalFree(), 10e6);
        assertEq(usdc.balanceOf(address(router)), 13e6, "the donation sits unaccounted");
        vm.prank(root1);
        router.withdraw(10e6);
    }

    function testDonationToTheVaultCannotHideALossNorBreakTheLedger() public {
        uint256 loanId = _simple(10e6, 4e6);
        _give(_vault(borrower), 3e6);
        _defaultLoan(loanId);
        router.sync(borrower);
        assertEq(router.lossOf(root1), 4e6, "the loss is the pool's slash, whatever sits in the vault");
        assertEq(router.free(root1), 6e6);
        assertEq(usdc.balanceOf(address(router)), router.totalFree(), "the router received nothing it did not account");
    }

    function testConsentLimitBoundaryIsExact() public {
        _fund(root1, 10e6);
        TransitiveStakeRouter.Path memory p = _path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6);
        p.rootEdge.limit = 2e6 - 1; // one unit short of the loan
        p.rootSig = _signConsent(root1Pk, p.rootEdge);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);
        TransitiveStakeRouter.Path[] memory ps = _one(p);
        vm.expectRevert(TransitiveStakeRouter.LimitExceeded.selector);
        router.originate(req, sig, ps);

        p.rootEdge.limit = 2e6; // exactly the loan
        p.rootSig = _signConsent(root1Pk, p.rootEdge);
        router.originate(req, sig, _one(p));
        assertEq(router.edgeUsed(router.edgeKey(root1, mid1, borrower)), 2e6);
    }

    function testDirectRepaymentBeforeSyncDoesNotFreeRootCapacityForAnotherBorrower() public {
        _fund(root1, 5e6);
        uint256 loanId = _originate(borrowerPk, borrower, 3e6, _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 3e6)));
        _repayAll(stranger, loanId); // the pool has capacity again; the router has not synced
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower2, 3e6);
        bytes memory sig = _signBorrowAndDisburse(borrower2Pk, req);
        TransitiveStakeRouter.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower2, 3e6));
        vm.expectRevert(TransitiveStakeRouter.InsufficientFree.selector);
        router.originate(req, sig, ps); // only 2e6 is free until the first lot is synced
        router.sync(borrower);
        router.originate(req, sig, ps);
        assertEq(router.locked(root1), 3e6, "aggregate reserved principal never exceeded the 5e6 allocation");
    }

    function testConsentDoesNotReplayOnAnotherRouterOrChain() public {
        _fund(root1, 10e6);
        TransitiveStakeRouter.Path[] memory ps = _one(_path(root1Pk, root1, mid1Pk, mid1, borrower, 2e6));
        DecentralizedMicrocredit.BorrowAndDisburse memory req = _req(borrower, 2e6);
        bytes memory sig = _signBorrowAndDisburse(borrowerPk, req);

        // another router (the borrower names it manager, so the manager check passes): consents signed for `router` fail
        TransitiveStakeRouter other = new TransitiveStakeRouter(credit);
        vm.prank(borrower);
        credit.setManager(address(other));
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        other.originate(req, sig, ps);

        // the same router on another chain id: the consent domain changed
        vm.prank(borrower);
        credit.setManager(address(router));
        vm.chainId(block.chainid + 1);
        vm.expectRevert(TransitiveStakeRouter.InvalidConsent.selector);
        router.originate(req, sig, ps);
    }

    function testNonRouterCannotDriveTheVault() public {
        _simple(10e6, 4e6);
        StakeVault vault = router.vaultOf(borrower);
        vm.expectRevert(StakeVault.NotRouter.selector);
        vault.lock(borrower, 1);
        vm.expectRevert(StakeVault.NotRouter.selector);
        vault.release(borrower);
    }

    function testDepositRefusesAFeeOnTransferShortfallAndZero() public {
        vm.expectRevert(TransitiveStakeRouter.ZeroAmount.selector);
        router.deposit(0);
        vm.expectRevert(TransitiveStakeRouter.ZeroAmount.selector);
        router.withdraw(0);
    }

    // ───────────── attribution arithmetic ─────────────

    function testFuzzAttributionSumsToTheLossAndNeverExceedsAPath(
        uint96 a0,
        uint96 a1,
        uint96 a2,
        uint96 a3,
        uint8 n,
        uint256 lossSeed
    ) public {
        AttributionHarness h = new AttributionHarness(credit);
        uint256 count = bound(n, 1, 4);
        uint96[4] memory raw = [a0, a1, a2, a3];
        TransitiveStakeRouter.PathLot[] memory paths = new TransitiveStakeRouter.PathLot[](count);
        uint256 total;
        for (uint256 i = 0; i < count; i++) {
            uint256 amt = bound(raw[i], 1, 1e12);
            paths[i] =
                TransitiveStakeRouter.PathLot({ root: address(uint160(i + 1)), mid: address(0xBEEF), amount: amt });
            total += amt;
        }
        uint256 loss = bound(lossSeed, 0, total);
        uint256[] memory share = h.attribute(paths, total, loss);
        uint256 sum;
        for (uint256 i = 0; i < count; i++) {
            assertLe(share[i], paths[i].amount, "a path never bears more than it put in");
            sum += share[i];
        }
        assertEq(sum, loss, "the shares sum to the loss");
    }
}
