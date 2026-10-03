// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/Script.sol";
import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";

/**
 * @notice Persona scenarios against a live DeployTestnet deployment, sent as real transactions.
 *         Every claim is checked with `require`, so a run that completes is a pass. Expected
 *         refusals are simulated against the same state (never broadcast) and their errors logged.
 *         Time-dependent scenarios (interest, due dates, defaults) run on a fork of the live
 *         deployment instead: test/fork/LiveDeployment.t.sol.
 * @dev Testnets only. Env: DEPLOYER_PK (owner and score reporter of the deployment), POOL, SCORES.
 *      Persona keys are derived from DEPLOYER_PK, so they are reproducible but never printed;
 *      the deployer pays their gas.
 *        DEPLOYER_PK=... POOL=... SCORES=... forge script script/TestnetScenarios.s.sol \
 *          --rpc-url <testnet> --broadcast --non-interactive --slow --account <keystore> --sender <address>
 *      (forge needs a CLI wallet to broadcast; any keystore will do, the script signs with its own keys.)
 */
contract TestnetScenariosScript is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SCALE = 1e6;
    uint256 internal constant GAS_FLOAT = 0.0003 ether;

    DecentralizedMicrocredit internal credit;
    OracleScoreProvider internal scores;
    MockUSDC internal usdc;
    uint256 internal deployerPk;
    address internal deployer;

    function run() external {
        require(block.chainid == 84_532 || block.chainid == 11_155_111 || block.chainid == 31_337, "testnets only");
        deployerPk = vm.envUint("DEPLOYER_PK");
        deployer = vm.addr(deployerPk);
        credit = DecentralizedMicrocredit(vm.envAddress("POOL"));
        scores = OracleScoreProvider(vm.envAddress("SCORES"));
        usdc = MockUSDC(address(credit.usdc()));
        require(scores.reporter() == deployer, "DEPLOYER_PK must be the score reporter");

        _liquidity();
        _creditMovesNotCopies();
        _freshRingAndNewcomer();
        _stakedRing();
        _recycledSeedFarm();
        _issuanceBudget();
        console.log("All scenarios passed.");
        _logPersonas();
    }

    // ───────────────────────────── scenarios ─────────────────────────────

    /// A lender funds the pool so borrowers have something to draw.
    function _liquidity() internal {
        (uint256 pk, address lena) = _persona("lena");
        if (credit.lenderBalance(lena) >= 5_000e6) return;
        _gas(lena);
        vm.startBroadcast(pk);
        usdc.mint(lena, 5_000e6);
        usdc.approve(address(credit), 5_000e6);
        credit.depositFunds(5_000e6);
        vm.stopBroadcast();
        console.log("[liquidity] Lena deposited 5,000 USDC:", lena);
    }

    /// CI-4, the demo video: backing moves the backer's credit to the borrower; nothing is created.
    function _creditMovesNotCopies() internal {
        (, address avery) = _persona("avery");
        (uint256 brightonPk, address brighton) = _persona("brighton");
        (uint256 averyPk,) = _persona("avery");

        if (credit.grantedCredit(avery) == 0) _publish(_pair(avery, brighton), _pair(92e4, 25e4)); // 92 and 25 USDC lines
        require(credit.grantedCredit(avery) == 92e6 && credit.grantedCredit(brighton) == 25e6, "issued lines");
        (, uint256 backed) = credit.getBacking(avery, brighton);
        if (backed == 0) {
            (uint256 averyBefore,) = credit.getBorrowLimit(avery);
            (uint256 brightonBefore,) = credit.getBorrowLimit(brighton);
            _gas(avery);
            vm.broadcast(averyPk);
            credit.back(brighton, 50e6);
            (uint256 averyAfter,) = credit.getBorrowLimit(avery);
            (uint256 brightonAfter,) = credit.getBorrowLimit(brighton);
            require(averyAfter == averyBefore - 50e6, "backer's limit falls by the backing");
            require(brightonAfter == brightonBefore + 50e6, "borrower's limit rises by the same amount");
        }
        (uint256 averyLimit,) = credit.getBorrowLimit(avery);
        (uint256 brightonLimit,) = credit.getBorrowLimit(brighton);
        require(averyLimit == 42e6 && brightonLimit == 75e6, "limits after backing");
        require(averyLimit + brightonLimit == 117e6, "sum of limits = sum of issued lines (92 + 25)");
        console.log("[credit moves] Avery backs Brighton 50: limits 42 + 75 = 117 = 92 + 25 issued");
        if (credit.completedLoans(brighton) > 0) return;
        _gas(brighton);

        vm.startBroadcast(brightonPk);
        uint256 loanId = credit.requestLoan(40e6);
        credit.disburseLoan(loanId);
        usdc.approve(address(credit), type(uint256).max);
        credit.repayLoan(loanId, 40e6); // inside the first day: no interest
        vm.stopBroadcast();
        require(credit.getCurrentOutstandingAmount(loanId) == 0, "repaid");
        console.log("[credit moves] Brighton borrowed 40 against the backing and repaid; loan id", loanId);
    }

    /// CI-1 and CI-2: fresh accounts hold no credit, so they can neither back nor borrow.
    function _freshRingAndNewcomer() internal {
        address[] memory ring = new address[](10);
        for (uint256 i; i < ring.length; i++) {
            (, ring[i]) = _persona(string.concat("ring-", vm.toString(i)));
        }
        uint256 refused;
        for (uint256 i; i < ring.length; i++) {
            vm.prank(ring[i]);
            try credit.back(ring[(i + 1) % ring.length], 1e6) {
                revert("a fresh account backed another");
            } catch (bytes memory err) {
                require(_is(err, DecentralizedMicrocredit.InsufficientCredit.selector), "back: wrong error");
                refused++;
            }
            vm.prank(ring[i]);
            try credit.requestLoan(1e6) {
                revert("a fresh account borrowed");
            } catch (bytes memory err) {
                require(_is(err, DecentralizedMicrocredit.NoCredit.selector), "borrow: wrong error");
                refused++;
            }
        }
        require(refused == 2 * ring.length, "every attempt refused");
        console.log(
            "[fresh ring] 10 fresh accounts: 10 backings refused (InsufficientCredit), 10 loans refused (NoCredit)"
        );
    }

    /// A ring around one staked member can borrow at most the stake, and cannot pass backing on.
    function _stakedRing() internal {
        (uint256 rexPk, address rex) = _persona("rex");
        address[] memory members = new address[](5);
        uint256[] memory keys = new uint256[](5);
        for (uint256 i; i < members.length; i++) {
            (keys[i], members[i]) = _persona(string.concat("rex-ring-", vm.toString(i)));
        }

        if (credit.stakeOf(rex) == 0) {
            _gas(rex);
            vm.startBroadcast(rexPk);
            usdc.mint(rex, 25e6);
            usdc.approve(address(credit), 25e6);
            credit.stake(25e6);
            for (uint256 i; i < members.length; i++) {
                credit.back(members[i], 5e6);
            }
            vm.stopBroadcast();
            for (uint256 i; i < members.length; i++) {
                _gas(members[i]);
                vm.startBroadcast(keys[i]);
                credit.disburseLoan(credit.requestLoan(5e6)); // left open: the fork test defaults them
                vm.stopBroadcast();
            }
        }

        (, address outsider) = _persona("rex-ring-outsider");
        vm.prank(rex);
        try credit.back(outsider, 1e6) {
            revert("stake backed twice");
        } catch (bytes memory err) {
            require(_is(err, DecentralizedMicrocredit.InsufficientCredit.selector), "rex: wrong error");
        }
        vm.prank(members[0]);
        try credit.back(outsider, 1e6) {
            revert("received backing passed on");
        } catch (bytes memory err) {
            require(_is(err, DecentralizedMicrocredit.InsufficientCredit.selector), "member: wrong error");
        }
        vm.prank(members[0]);
        try credit.requestLoan(1e6) {
            revert("borrowed beyond the backing");
        } catch (bytes memory err) {
            require(_is(err, DecentralizedMicrocredit.BorrowLimitExceeded.selector), "borrow: wrong error");
        }
        console.log("[staked ring] Rex stakes 25 and backs 5 members with 5 each; they borrow 25 in all, no more");
    }

    /// Theorem 3: repayment history built on a recycled seed inside the interest-free day earns
    /// no credit. Each farmed account ends with granted credit 0.
    function _recycledSeedFarm() internal {
        (uint256 samPk, address sam) = _persona("sam");
        if (credit.stakeOf(sam) == 0) {
            _gas(sam);
            vm.startBroadcast(samPk);
            usdc.mint(sam, 25e6);
            usdc.approve(address(credit), 25e6);
            credit.stake(25e6);
            vm.stopBroadcast();
        }
        for (uint256 f; f < 2; f++) {
            (uint256 farmPk, address farm) = _persona(string.concat("farm-", vm.toString(f)));
            if (credit.completedLoans(farm) >= 4) continue;
            _gas(farm);
            vm.broadcast(samPk);
            credit.back(farm, 25e6);
            vm.startBroadcast(farmPk);
            usdc.approve(address(credit), type(uint256).max);
            for (uint256 k; k < 4; k++) {
                uint256 id = credit.requestLoan(25e6);
                credit.disburseLoan(id);
                credit.repayLoan(id, 25e6);
            }
            vm.stopBroadcast();
            vm.broadcast(samPk);
            credit.back(farm, 0); // the seed moves on to the next account
            require(credit.completedLoans(farm) == 4, "four loans repaid");
            require(credit.grantedCredit(farm) == 0 && credit.duesPaid(farm) == 0, "history earned credit");
            console.log("[recycled seed] farm account repaid 4 loans of 25 and holds 0 credit:", farm);
        }
    }

    /// CI-22: the oracle cannot issue past its budget, whatever it reports.
    function _issuanceBudget() internal {
        uint256 room = scores.maxTotalScore() - scores.totalHeld();
        uint256 n = room / SCALE + 1;
        address[] memory users = new address[](n);
        uint256[] memory values = new uint256[](n);
        for (uint256 i; i < n; i++) {
            (, users[i]) = _persona(string.concat("budget-", vm.toString(i)));
            values[i] = SCALE;
        }
        bytes memory report = abi.encode(scores.epoch() + 1, users, values);
        vm.prank(deployer);
        try scores.publishScores(report) {
            revert("issued past the budget");
        } catch (bytes memory err) {
            require(_is(err, OracleScoreProvider.IssuanceBudgetExceeded.selector), "budget: wrong error");
        }
        console.log("[budget] a report issuing", n, "full lines past the remaining budget is refused");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// Addresses only; the keys stay derived from DEPLOYER_PK. test/fork/LiveDeployment.t.sol reads these.
    function _logPersonas() internal view {
        string[5] memory names = ["lena", "avery", "brighton", "rex", "sam"];
        for (uint256 i; i < names.length; i++) {
            (, address account) = _persona(names[i]);
            console.log(names[i], account);
        }
    }

    /// @dev True when `err` is exactly the custom error `selector` (no arguments).
    function _is(bytes memory err, bytes4 selector) internal pure returns (bool) {
        return keccak256(err) == keccak256(abi.encodePacked(selector));
    }

    function _persona(string memory label) internal view returns (uint256 pk, address account) {
        pk = uint256(keccak256(abi.encode(deployerPk, label))) % (SECP256K1_N - 1) + 1;
        account = vm.addr(pk);
    }

    function _gas(address account) internal {
        if (account.balance >= GAS_FLOAT / 2) return;
        vm.broadcast(deployerPk);
        payable(account).transfer(GAS_FLOAT);
    }

    function _publish(address[] memory users, uint256[] memory values) internal {
        bytes memory report = abi.encode(scores.epoch() + 1, users, values);
        vm.broadcast(deployerPk);
        scores.publishScores(report);
    }

    function _pair(address a, address b) internal pure returns (address[] memory pair) {
        pair = new address[](2);
        (pair[0], pair[1]) = (a, b);
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory pair) {
        pair = new uint256[](2);
        (pair[0], pair[1]) = (a, b);
    }
}
