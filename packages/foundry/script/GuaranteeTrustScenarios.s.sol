// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { GuaranteeTrust } from "../contracts/GuaranteeTrust.sol";

/**
 * @notice Agentic scenarios against a deployed GuaranteeTrust (testnet only, MockUSDC units, no value).
 * @dev The broadcaster is the deployer, owner and sponsor; the adjudicator and the issuer are personas 1 and 2
 *      (DeployGuaranteeTrust assigns them from SIM_MNEMONIC). Every guarantee opens on the
 *      worker persona's own EIP-712 acceptance, and every consent is the member persona's own signature; the
 *      adjudicator only submits them, and the broadcaster relays consents as a gasless relay would. Personas are keys derived from
 *      SIM_MNEMONIC (private to the runner); the broadcaster tops each up with ETH for gas and mints MockUSDC to it.
 *      A client pays the wage off chain; the script stands for that payment by minting the wage to the worker, so
 *      each contribution is remitted out of the wage itself.
 *      Env: GT (contract), SIM_MNEMONIC, SCENARIO (0 setup, 1 to 6), RUN_TAG (any string; client ids and the
 *      scenario draws depend on it), FUND_ETH (wei per gas top-up, default 0.0001 ether; a persona is topped up
 *      before each of its transactions when it holds less than half of that).
 *      Each scenario prints its read-backs; the runner posts the transaction hashes from the broadcast file.
 *
 *      0 setup: fund the reserve with 100, set the remit window to one day.
 *      1 honest newcomer: an issuer line and an attester; three paid jobs; contributions grow capacity by dues only.
 *      2 client nonpayment: the reserve pays the worker; the loss falls on the attester's stake and the issuer line.
 *      3 non-remitter: a paid worker does not remit and is refused the next guarantee; remitting clears it.
 *      4 collusion ring: fake workers, clients and attesters with nothing rooted get nothing; one real staker
 *        backing the ring is the most the ring can take.
 *      5 one client group: five workers with five clients that share one parent; the group cap refuses what
 *        would overload the parent, then the parent defaults and every open guarantee on it is claimed.
 *      6 community run: twelve jobs among four workers and two attesters who back the best-scored workers;
 *        clients default and workers remit by seeded draws. Prints the reserve's change, claims, wages and
 *        contributions; the benefit multiplier needs a counterfactual that a simulation cannot supply.
 */
contract GuaranteeTrustScenarios is Script {
    uint256 internal constant U = 1e6;
    GuaranteeTrust internal gt;
    MockUSDC internal usdc;
    string internal mnemonic;
    string internal runTag;
    uint256 internal fundEth;
    address internal me;
    uint256 internal sigCount;

    function run() external {
        gt = GuaranteeTrust(vm.envAddress("GT"));
        usdc = MockUSDC(address(gt.token()));
        mnemonic = vm.envOr("SIM_MNEMONIC", string(""));
        runTag = vm.envOr("RUN_TAG", string("r1"));
        fundEth = vm.envOr("FUND_ETH", uint256(0.0001 ether));
        uint256 scenario = vm.envUint("SCENARIO");
        vm.startBroadcast();
        (, me,) = vm.readCallers();
        vm.stopBroadcast();
        if (scenario == 0) _setup();
        else if (scenario == 1) _honest();
        else if (scenario == 2) _nonpayment();
        else if (scenario == 3) _nonRemitter();
        else if (scenario == 4) _ring();
        else if (scenario == 5) _clientGroup();
        else if (scenario == 6) _community();
        _report();
    }

    // ------------------------------------------------------------------ helpers

    function _pk(uint32 i) internal view returns (uint256) {
        require(bytes(mnemonic).length != 0, "SIM_MNEMONIC required");
        return vm.deriveKey(mnemonic, i);
    }

    function _who(uint32 i) internal view returns (address) {
        return vm.addr(_pk(i));
    }

    /// @dev Gas and MockUSDC for persona i, then approve the contract.
    function _ready(uint32 i, uint256 tokens) internal returns (address p) {
        p = _who(i);
        if (tokens != 0) {
            vm.startBroadcast();
            usdc.mint(p, tokens);
            vm.stopBroadcast();
        }
        if (usdc.allowance(p, address(gt)) < 1e30) {
            _as(i);
            usdc.approve(address(gt), type(uint256).max);
            _end();
        }
    }

    /// @dev The client's off-chain wage payment, stood for by a MockUSDC mint to the worker.
    function _wage(address worker, uint256 amount) internal {
        _asMe();
        usdc.mint(worker, amount);
        _end();
    }

    function _client(uint256 scenario, uint256 j) internal view returns (bytes32) {
        return keccak256(abi.encode(runTag, scenario, j));
    }

    function _draw(uint256 scenario, uint256 j, string memory what) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(runTag, scenario, j, what))) % 100;
    }

    function _asMe() internal {
        vm.startBroadcast();
    }

    /// @dev The adjudicator (persona 1) and the issuer (persona 2) are their own keys, apart from the owner and
    ///      sponsor (the broadcaster), so a role holder cannot act outside its role.
    function _asAdj() internal {
        _as(1);
    }

    function _asIssuer() internal {
        _as(2);
    }

    /// @dev Broadcast as persona i, topping up its gas first.
    function _as(uint32 i) internal {
        address p = _who(i);
        if (p.balance < fundEth / 2) {
            vm.startBroadcast();
            payable(p).transfer(fundEth);
            vm.stopBroadcast();
        }
        vm.startBroadcast(_pk(i));
    }

    function _end() internal {
        vm.stopBroadcast();
    }

    /// @dev The contract's own opening rules, read before acting, so a refused guarantee is never a failed transaction.
    function _canOpen(address w, bytes32 c, bytes32 group, uint256 amount) internal view returns (bool) {
        bytes32 g = group == bytes32(0) ? c : group;
        if (gt.paused() || gt.clientOpen(c) || gt.clientDefaulted(c) || gt.groupDefaulted(g)) return false;
        if (gt.memberOf(w).unpaidContributions != 0) return false;
        uint256 r = gt.reserve();
        if (amount * gt.BPS() > r * gt.maxShareBps()) return false;
        if ((gt.groupExposure(g) + amount) * gt.BPS() > r * gt.maxGroupShareBps()) return false;
        if (gt.outstanding() + amount + gt.floorMultiple() * amount > r) return false;
        return gt.capacity(w) >= amount;
    }

    function _nonce() internal returns (uint256) {
        return uint256(keccak256(abi.encode(runTag, "nonce", ++sigCount)));
    }

    /// @dev Persona i signs its consent to `attester`; the broadcaster relays it.
    function _consent(uint32 i, address attester) internal {
        address member = _who(i);
        uint256 n = _nonce();
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk(i), gt.consentDigest(member, attester, true, n, deadline));
        _asMe();
        gt.setConsentBySig(member, attester, true, n, deadline, abi.encodePacked(r, s, v));
        _end();
    }

    /// @dev Persona i signs its acceptance of exactly these terms; the broadcaster, as adjudicator, submits it.
    function _openG(uint32 i, bytes32 client, bytes32 group, uint256 amount, bytes32 terms) internal returns (uint256 id) {
        GuaranteeTrust.Acceptance memory a = GuaranteeTrust.Acceptance({
            worker: _who(i),
            clientId: client,
            groupId: group,
            amount: amount,
            maxFromDues: amount,
            termsHash: terms,
            contributionBps: gt.contributionBps(),
            contributionCap: gt.contributionCap(),
            remitWindow: gt.remitWindow(),
            settleBy: uint64(block.timestamp + 30 days),
            nonce: _nonce(),
            deadline: block.timestamp + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk(i), gt.acceptanceDigest(a));
        _asAdj();
        id = gt.openGuarantee(a, abi.encodePacked(r, s, v));
        _end();
    }

    // ------------------------------------------------------------------ scenarios

    function _setup() internal {
        _asMe();
        usdc.mint(me, 100 * U);
        usdc.approve(address(gt), type(uint256).max);
        gt.fundReserve(100 * U);
        gt.setParams(2000, 2, 500, 3 * U, 1 days, 20 * U, 20 * U, 5, 5);
        _end();
        console.log("setup: reserve funded with 100 MockUSDC; remit window 1 day");
    }

    /// @dev Personas 10 (attester Avery) and 11 (newcomer Nia).
    function _honest() internal {
        address avery = _ready(10, 20 * U);
        address nia = _ready(11, 0);
        _as(10);
        gt.stake(10 * U);
        _end();
        _consent(11, avery);
        _as(10);
        gt.attest(nia, 5 * U);
        _end();
        _asIssuer();
        gt.setLine(nia, 5 * U);
        _end();
        console.log("S1 capacity before", gt.capacity(nia));
        for (uint256 j; j < 3; j++) {
            uint256 id = _openG(11, _client(1, j), 0, 10 * U, keccak256("S1"));
            _asAdj();
            gt.markPaid(id, 60 * U, keccak256(abi.encode("paid", j)));
            _end();
            _wage(nia, 60 * U);
            _as(11);
            gt.remit(id);
            _end();
        }
        console.log("S1 capacity after three paid jobs (dues only)", gt.capacity(nia));
        console.log("S1 Nia dues", gt.memberOf(nia).dues);
    }

    /// @dev Personas 20 (attester Brighton) and 21 (newcomer Omar).
    function _nonpayment() internal {
        address brighton = _ready(20, 20 * U);
        address omar = _ready(21, 0);
        _as(20);
        gt.stake(10 * U);
        _end();
        _consent(21, brighton);
        _as(20);
        gt.attest(omar, 10 * U);
        _end();
        _asIssuer();
        gt.setLine(omar, 5 * U);
        _end();
        uint256 reserveBefore = gt.reserve();
        uint256 id = _openG(21, _client(2, 0), 0, 15 * U, keccak256("S2"));
        _asAdj();
        gt.claim(id, keccak256("S2 client did not pay"));
        _end();
        console.log("S2 Omar received", usdc.balanceOf(omar));
        console.log("S2 Brighton stake after (was 10)", gt.memberOf(brighton).stake);
        console.log("S2 issuer spent", gt.issuerSpent());
        console.log("S2 reserve before", reserveBefore);
        console.log("S2 reserve after", gt.reserve());
    }

    /// @dev Persona 30 (newcomer Priya).
    function _nonRemitter() internal {
        address priya = _ready(30, 0);
        _asIssuer();
        gt.setLine(priya, 5 * U);
        _end();
        uint256 id = _openG(30, _client(3, 0), 0, 5 * U, keccak256("S3"));
        _asAdj();
        gt.markPaid(id, 40 * U, keccak256("S3 paid"));
        _end();
        _wage(priya, 40 * U);
        if (_canOpen(priya, _client(3, 1), 0, 5 * U)) {
            console.log("S3 UNEXPECTED: next guarantee allowed while unpaid");
        } else {
            console.log("S3 next guarantee refused while the contribution is unpaid");
        }
        _as(30);
        gt.remit(id);
        _end();
        _openG(30, _client(3, 2), 0, 5 * U, keccak256("S3c"));
        console.log("S3 after remitting, the next guarantee opened; Priya dues", gt.memberOf(priya).dues);
    }

    /// @dev Personas 40 to 45 (the ring), 46 (Rafe, a real staker who backs the ring).
    function _ring() internal {
        uint256 taken;
        for (uint32 k; k < 4; k++) {
            address w = _ready(40 + k, 0);
            address a = _ready(44 + (k % 2), 0);
            _as(40 + k);
            gt.setConsent(a, true);
            _end();
            if (gt.freeToBack(a) >= 1 * U) console.log("S4 UNEXPECTED: a ring attester holds trust");
            if (_canOpen(w, _client(4, k), 0, 1 * U)) {
                uint256 id = _openG(40 + k, _client(4, k), 0, 1 * U, keccak256("S4"));
                _asAdj();
                gt.claim(id, keccak256("S4 fake default"));
                _end();
                taken += 1 * U;
            }
        }
        console.log("S4 ring with nothing rooted took", taken);
        address rafe = _ready(46, 5 * U);
        address w0 = _who(40);
        _as(46);
        gt.stake(3 * U);
        _end();
        _consent(40, rafe);
        _as(46);
        gt.attest(w0, 3 * U);
        _end();
        uint256 took;
        for (uint256 j; j < 3; j++) {
            if (_canOpen(w0, _client(4, 10 + j), 0, 3 * U)) {
                uint256 id = _openG(40, _client(4, 10 + j), 0, 3 * U, keccak256("S4b"));
                _asAdj();
                gt.claim(id, keccak256("S4 fake default"));
                _end();
                took += 3 * U;
            }
        }
        console.log("S4 with one real staker's 3 behind it, the ring took", took);
        console.log("S4 Rafe stake after (was 3)", gt.memberOf(rafe).stake);
    }

    /// @dev Personas 50 to 54 (newcomers), 55 (attester Sana). Five clients are branches of one parent (one group).
    function _clientGroup() internal {
        address sana = _ready(55, 60 * U);
        _as(55);
        gt.stake(50 * U);
        _end();
        bytes32 parent = keccak256(abi.encode(runTag, "S5 parent"));
        uint256 opened;
        uint256 refused;
        uint256[] memory ids = new uint256[](5);
        for (uint32 k; k < 5; k++) {
            address w = _ready(50 + k, 0);
            _consent(50 + k, sana);
            _as(55);
            gt.attest(w, 10 * U);
            _end();
            bytes32 c = _client(5, k);
            if (_canOpen(w, c, parent, 10 * U)) {
                ids[opened] = _openG(50 + k, c, parent, 10 * U, keccak256("S5"));
                opened += 1;
            } else {
                refused += 1;
            }
        }
        console.log("S5 parent's open exposure", gt.groupExposure(parent));
        if (_canOpen(_who(54), _client(5, 0), 0, 1 * U)) console.log("S5 UNEXPECTED: a second guarantee on one client");
        else console.log("S5 one client could not carry a second open guarantee");
        _asAdj();
        for (uint256 j; j < opened; j++) {
            gt.claim(ids[j], keccak256("S5 the parent did not pay"));
        }
        _end();
        if (_canOpen(_who(54), _client(5, 9), parent, 1 * U)) {
            console.log("S5 UNEXPECTED: a new branch of the defaulted parent was allowed");
        } else {
            console.log("S5 a new branch of the defaulted parent was refused");
        }
        console.log("S5 opened", opened);
        console.log("S5 refused by the group cap", refused);
        console.log("S5 Sana stake after the parent defaulted (was 50)", gt.memberOf(sana).stake);
    }

    /// @dev Personas 60 to 63 (workers), 64 and 65 (attesters). Twelve jobs; p = 25%, q = 75% by seeded draws.
    function _community() internal {
        address[4] memory w;
        for (uint32 k; k < 4; k++) {
            w[k] = _ready(60 + k, 0);
            _asIssuer();
            gt.setLine(w[k], 5 * U);
            _end();
        }
        for (uint32 a; a < 2; a++) {
            address att = _ready(64 + a, 30 * U);
            _as(64 + a);
            gt.stake(20 * U);
            _end();
            for (uint32 k; k < 4; k++) {
                _consent(60 + k, att);
            }
        }
        uint256 wages;
        uint256 claims;
        uint256 claimed;
        uint256 remitted;
        uint256 refused;
        uint256 reserveStart = gt.reserve();
        uint256[4] memory pendingId;
        bool[4] memory pending;
        for (uint256 j; j < 12; j++) {
            // attesters back the best-scored worker that still has room (screening on history)
            for (uint32 a; a < 2; a++) {
                address att = _who(64 + a);
                uint256 best = 4;
                int256 bestScore = type(int256).min;
                for (uint256 k; k < 4; k++) {
                    int256 sc = gt.score(w[k]).composite;
                    if (gt.backing(att, w[k]) < 10 * U && sc > bestScore) {
                        best = k;
                        bestScore = sc;
                    }
                }
                if (best < 4 && gt.freeToBack(att) >= 2 * U && gt.attestersOf(w[best]).length < 5) {
                    _as(64 + a);
                    gt.attest(w[best], 2 * U);
                    _end();
                }
            }
            uint256 k = j % 4;
            // a worker who has not remitted settles first if the draw says it will
            if (pending[k]) {
                if (_draw(6, j, "remit-late") < 50) {
                    _as(uint32(60 + k));
                    gt.remit(pendingId[k]);
                    _end();
                    remitted += 1;
                    pending[k] = false;
                }
            }
            if (!_canOpen(w[k], _client(6, j), 0, 5 * U)) {
                refused += 1;
                continue;
            }
            uint256 id = _openG(uint32(60 + k), _client(6, j), 0, 5 * U, keccak256("S6"));
            _asAdj();
            if (_draw(6, j, "default") < 25) {
                gt.claim(id, keccak256("S6 client did not pay"));
                claims += 1;
                claimed += 5 * U;
                _end();
            } else {
                gt.markPaid(id, 40 * U, keccak256("S6 paid"));
                wages += 40 * U;
                _end();
                _wage(w[k], 40 * U);
                if (_draw(6, j, "remit") < 75) {
                    _as(uint32(60 + k));
                    gt.remit(id);
                    _end();
                    remitted += 1;
                } else {
                    pending[k] = true;
                    pendingId[k] = id;
                }
            }
        }
        console.log("S6 jobs refused (no capacity, unpaid contribution or exposure)", refused);
        console.log("S6 wages recorded for paid jobs", wages);
        console.log("S6 claims", claims);
        console.log("S6 claimed", claimed);
        console.log("S6 contributions remitted", remitted);
        console.log("S6 reserve start", reserveStart);
        console.log("S6 reserve end", gt.reserve());
    }

    function _report() internal view {
        console.log("reserve", gt.reserve());
        console.log("outstanding", gt.outstanding());
        console.log("totalStake", gt.totalStake());
        console.log("totalDues", gt.totalDues());
        console.log("issuerHeld", gt.issuerHeld());
        console.log("issuerSpent", gt.issuerSpent());
        console.log("guarantees", gt.guaranteeCount());
        console.log("token balance", usdc.balanceOf(address(gt)));
    }
}
