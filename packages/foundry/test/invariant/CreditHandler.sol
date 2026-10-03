// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DecentralizedMicrocredit } from "../../contracts/DecentralizedMicrocredit.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/**
 * @dev Drives DecentralizedMicrocredit for the credit-conservation invariants with a fixed cast:
 *      credited accounts (a score override, fixed for the whole run), stakers (no score; they and
 *      the credited accounts may stake), sybils (no score, never stake, never receive USDC except
 *      loan proceeds) and a second lender. Every contract call is wrapped in try/catch, so the
 *      handler itself never reverts; a revert that is not one of the protocol's own custom errors
 *      (a panic, a token error) is recorded and fails the suite.
 *
 *      Next to the contract the handler keeps an independent model built from the documented
 *      rules, not from the contract's storage: each loan's principal, interest and interest-first
 *      repayments, the dues (the reserve share of its interest) each borrower has paid, the reserve's
 *      inflows, and for every default the stake slashed, the credit charged pro rata to each
 *      unsecured backer, and the residual that fell on the reserve and the lenders.
 */
contract CreditHandler is CommonBase, StdCheats, StdUtils {
    enum Role {
        Credited,
        Staker,
        Sybil
    }

    struct Actor {
        address account;
        uint256 key;
        Role role;
        uint256 score;
    }

    struct LoanModel {
        uint256 id;
        address borrower;
        uint256 principal;
        uint256 rate;
        uint256 term;
        uint256 requestedAt;
        uint256 disbursedAt;
        uint256 repaid;
        uint256 principalRepaid;
        uint256 impaired; // provision against the loan once overdue (impairLoan)
        DecentralizedMicrocredit.LoanStatus status;
    }

    struct Stat {
        uint256 calls;
        uint256 ok;
        uint256 rejected;
        uint256 skipped;
    }

    error FixtureHasScore(address account);
    error FixtureNeedsActors();

    uint256 internal constant SCALE = 1e6;
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant CENT = 10_000;
    uint256 internal constant GRACE_PERIOD = 1 days;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_WARP = 90 days;
    uint256 internal constant MAX_STAKE = 300e6;
    uint256 internal constant MAX_DEPOSIT = 20_000e6;
    uint256 internal constant MAX_DONATION = 1_000e6;
    uint256 internal constant SYBIL_ASK = 100e6;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant BORROW_AND_DISBURSE_TYPEHASH = keccak256(
        "BorrowAndDisburse(address borrower,uint256 amount,address to,uint256 repaymentPeriod,uint256 maxAprBps,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant REQUEST_WITHDRAWAL_TYPEHASH =
        keccak256("RequestWithdrawal(address lender,uint256 amount,address to,uint256 nonce,uint256 deadline)");

    DecentralizedMicrocredit public immutable credit;
    MockUSDC public immutable usdc;
    address public immutable owner;
    address public immutable poolLender;
    address public immutable lender;
    uint256 internal immutable lenderKey;
    address public immutable feeRecipient;
    address public immutable funder;
    uint256 public immutable feeBps;
    uint256 public immutable reserveBps;

    address[] internal _actors;
    address[] internal _sybils;
    address[] internal _stakers; // accounts allowed to stake: credited accounts and stakers
    mapping(address => Role) public roleOf;
    mapping(address => uint256) internal _keyOf;

    LoanModel[] internal _loans;

    // ───────────────────────────── model ghosts ─────────────────────────────

    /// @notice I0(a): the credit line issued by the score override, maxLoanAmount x score / SCALE.
    mapping(address => uint256) public issuedLine;
    /// @notice Dues: the share of a borrower's interest paid into the first-loss reserve.
    mapping(address => uint256) public dues;
    /// @notice Granted credit charged to `a` as an unsecured backer of defaulted loans (pro rata).
    mapping(address => uint256) public charged;
    /// @notice At `a`'s own defaults: writtenOff - stake slashed - credit charged to its backers.
    mapping(address => uint256) public residual;
    /// @notice The part of `residual` that is mulDiv rounding of the pro-rata slash and charge.
    mapping(address => uint256) public roundingDust;

    uint256 public totalRoundingDust;
    /// @notice Sum over defaults of writtenOff - stake slashed: loss before the first-loss reserve.
    uint256 public lossBeforeReserve;
    /// @notice Sum over defaults of writtenOff - recovered (stake slashed and reserve used).
    uint256 public realisedLoss;
    uint256 public defaults;

    uint256 public deposited;
    uint256 public lenderMinted;
    uint256 public lenderDeposited;
    uint256 public interestPaid;
    uint256 public poolInterest; // interest - fee: into lenderCash, reserve share included
    uint256 public feesAccrued;
    uint256 public feesClaimed;
    uint256 public reserveIn;
    uint256 public reserveUsed;
    uint256 public reserveReleased;
    uint256 public reserveFunded;
    uint256 public reserveForgiven; // sub-cent balances forgiven at closing, absorbed by the reserve
    uint256 internal _reserveBeforeRepay;
    uint256 public forgiven; // unpaid principal written off when a loan closes under a cent
    uint256 public donated;

    // ───────────────────────────── health ghosts ─────────────────────────────

    uint256 public unexpectedReverts;
    string public lastUnexpectedAction;
    bytes public lastUnexpectedReason;
    uint256 public mismatches;
    string public lastMismatch;
    uint256 public sharePriceDrops;
    string public lastSharePriceDrop;

    // ───────────────────────────── observations ─────────────────────────────

    uint256 public sybilBacksAccepted; // a sybil raised a backing (possible only with dues it paid)
    uint256 public sybilBacksRejected;
    uint256 public sybilLoans;
    uint256 public disbursedAfterDefault; // reserved before the borrower defaulted, disbursed after
    uint256 public impairments;
    uint256 public defaultsSlashing; // defaults where secured backing paid
    uint256 public defaultsCharging; // defaults where unsecured backers' credit was charged
    uint256 public defaultsResidual; // defaults that left a loss beyond all backing
    uint256 public sybilDefaults;
    uint256 public backerDefaults; // defaulters that still had credit committed to others

    string[] internal _actionNames;
    mapping(bytes32 => Stat) internal _stats;

    constructor(
        DecentralizedMicrocredit credit_,
        MockUSDC usdc_,
        address owner_,
        address poolLender_,
        uint256 poolDeposit,
        address lender_,
        uint256 lenderKey_,
        Actor[] memory cast
    ) {
        require(cast.length > 1, FixtureNeedsActors());
        credit = credit_;
        usdc = usdc_;
        owner = owner_;
        poolLender = poolLender_;
        lender = lender_;
        lenderKey = lenderKey_;
        feeRecipient = makeAddr("feeRecipient");
        funder = makeAddr("reserveFunder");
        feeBps = credit_.protocolFeeBps();
        reserveBps = credit_.reserveBps();
        deposited = poolDeposit;

        uint256 maxLoan = credit_.maxLoanAmount();
        for (uint256 i = 0; i < cast.length; i++) {
            Actor memory a = cast[i];
            _actors.push(a.account);
            roleOf[a.account] = a.role;
            _keyOf[a.account] = a.key;
            issuedLine[a.account] = Math.mulDiv(maxLoan, a.score, SCALE);
            require(credit_.grantedCredit(a.account) == issuedLine[a.account], FixtureHasScore(a.account));
            if (a.role == Role.Sybil) _sybils.push(a.account);
            else _stakers.push(a.account);
        }
    }

    // ───────────────────────────── modifiers ─────────────────────────────

    /// @dev Exits and every action that is not a repayment or a default must never lower the
    ///      share price for the lenders who stay (rounding always favours the pool).
    modifier sharePriceKept(string memory action) {
        uint256 assets0 = credit.totalAssets();
        uint256 shares0 = credit.totalShares();
        _;
        uint256 assets1 = credit.totalAssets();
        uint256 shares1 = credit.totalShares();
        if (
            (assets1 + VIRTUAL_ASSETS) * (shares0 + VIRTUAL_SHARES)
                < (assets0 + VIRTUAL_ASSETS) * (shares1 + VIRTUAL_SHARES)
        ) {
            sharePriceDrops++;
            lastSharePriceDrop = action;
        }
    }

    // ───────────────────────────── credit actions ─────────────────────────────

    function back(uint256 backerSeed, uint256 borrowerSeed, uint256 amountSeed) external sharePriceKept("back") {
        address backer = _backerFor(backerSeed);
        address borrower = _actor(borrowerSeed);
        if (borrower == backer) borrower = _actor(borrowerSeed % _actors.length + 1);
        (uint256 secured, uint256 unsecured) = credit.getBacking(backer, borrower);
        uint256 current = secured + unsecured;
        (uint256 freeCredit, uint256 freeStake) = credit.getFreeCredit(backer);
        uint256 reach = current + freeCredit + freeStake;
        // Mostly within reach, sometimes beyond it, and 0 withdraws the backing.
        uint256 amount = _bound(amountSeed, 0, reach + reach / 4 + 1e6);

        _call("back");
        vm.prank(backer);
        try credit.back(borrower, amount) {
            _ok("back");
            (uint256 secured1, uint256 unsecured1) = credit.getBacking(backer, borrower);
            if (secured1 + unsecured1 != amount) _mismatch("back: edge differs from the amount set");
            if (amount > current) {
                if (roleOf[backer] == Role.Sybil) sybilBacksAccepted++;
                uint256 extra = amount - current;
                uint256 fromCredit = Math.min(extra, freeCredit);
                if (unsecured1 != unsecured + fromCredit || secured1 != secured + extra - fromCredit) {
                    _mismatch("back: new backing did not commit free credit before stake");
                }
            } else if (amount < current) {
                uint256 fromCredit = Math.min(current - amount, unsecured);
                if (unsecured1 != unsecured - fromCredit) _mismatch("back: cut did not release unsecured first");
                (uint256 limit,) = credit.getBorrowLimit(borrower);
                if (openPrincipal(borrower) > limit) _mismatch("back: backing cut below what the borrower owes");
            }
        } catch (bytes memory reason) {
            if (roleOf[backer] == Role.Sybil && amount > current) sybilBacksRejected++;
            _rejected("back", reason);
        }
    }

    function stake(uint256 stakerSeed, uint256 amountSeed) external sharePriceKept("stake") {
        address who = _stakers[stakerSeed % _stakers.length];
        uint256 amount = _bound(amountSeed, 1, MAX_STAKE);
        usdc.mint(who, amount);
        _call("stake");
        vm.prank(who);
        usdc.approve(address(credit), amount);
        vm.prank(who);
        try credit.stake(amount) {
            _ok("stake");
        } catch (bytes memory reason) {
            _rejected("stake", reason);
        }
    }

    function unstake(uint256 stakerSeed, uint256 amountSeed) external sharePriceKept("unstake") {
        address who = _stakers[stakerSeed % _stakers.length];
        uint256 staked = credit.stakeOf(who);
        uint256 committed = credit.stakeCommitted(who);
        uint256 free = staked > committed ? staked - committed : 0;
        // Sometimes more than is free, to probe StakeCommitted / InsufficientStake.
        uint256 amount = _bound(amountSeed, 1, free + 10e6);
        _call("unstake");
        vm.prank(who);
        try credit.unstake(amount) {
            _ok("unstake");
            if (amount > free) _mismatch("unstake: committed stake was withdrawn");
        } catch (bytes memory reason) {
            _rejected("unstake", reason);
        }
    }

    /// @dev Every sybil backs the next one and a beneficiary, then the beneficiary borrows.
    function sybilRing(uint256 beneficiarySeed, uint256 amountSeed) external sharePriceKept("sybilRing") {
        address beneficiary = _sybils[beneficiarySeed % _sybils.length];
        uint256 amount = _bound(amountSeed, 1, SYBIL_ASK);
        _call("sybilRing");
        for (uint256 i = 0; i < _sybils.length; i++) {
            address s = _sybils[i];
            _sybilBack(s, _sybils[(i + 1) % _sybils.length], amount);
            if (s != beneficiary) _sybilBack(s, beneficiary, amount);
        }
        (, uint256 available) = credit.getBorrowLimit(beneficiary);
        if (_borrow("sybilRing", beneficiary, available > 0 ? available : amount)) sybilLoans++;
    }

    // ───────────────────────────── loan actions ─────────────────────────────

    function borrow(uint256 borrowerSeed, uint256 amountSeed) external sharePriceKept("borrow") {
        address borrower = _borrowerFor(borrowerSeed);
        _call("borrow");
        if (_borrow("borrow", borrower, _loanAmount(borrower, amountSeed)) && roleOf[borrower] == Role.Sybil) {
            sybilLoans++;
        }
    }

    /// @dev The one-click relayed path, with a signed term of 1 to 365 days.
    function borrowWithTerm(uint256 borrowerSeed, uint256 amountSeed, uint256 termSeed)
        external
        sharePriceKept("borrowWithTerm")
    {
        address borrower = _borrowerFor(borrowerSeed);
        DecentralizedMicrocredit.BorrowAndDisburse memory req = DecentralizedMicrocredit.BorrowAndDisburse({
            borrower: borrower,
            amount: _loanAmount(borrower, amountSeed),
            to: borrower,
            // Half the loans run at most 60 days, so they can fall due and default within a run.
            repaymentPeriod: _bound(termSeed, 1 days, termSeed % 2 == 0 ? 60 days : 365 days),
            maxAprBps: credit.getLoanRate(),
            nonce: credit.nonces(borrower),
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        bytes memory sig = _sign(
            _keyOf[borrower],
            keccak256(
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
            )
        );
        _call("borrowWithTerm");
        try credit.borrowAndDisburseMeta(req, sig) {
            _ok("borrowWithTerm");
            uint256[] memory ids = credit.getBorrowerLoanIds(borrower);
            uint256 idx = _recordLoan(ids[ids.length - 1], borrower);
            _recordDisbursement(idx);
            if (roleOf[borrower] == Role.Sybil) sybilLoans++;
        } catch (bytes memory reason) {
            _rejected("borrowWithTerm", reason);
        }
    }

    /// @dev Reserve without disbursing, leaving loans to disburse or cancel later.
    function requestLoan(uint256 borrowerSeed, uint256 amountSeed) external sharePriceKept("requestLoan") {
        address borrower = _borrowerFor(borrowerSeed);
        uint256 amount = _loanAmount(borrower, amountSeed);
        _call("requestLoan");
        vm.prank(borrower);
        try credit.requestLoan(amount) returns (uint256 loanId) {
            _ok("requestLoan");
            _recordLoan(loanId, borrower);
        } catch (bytes memory reason) {
            _rejected("requestLoan", reason);
        }
    }

    function disburseLoan(uint256 loanSeed) external sharePriceKept("disburseLoan") {
        (bool found, uint256 idx) = _pickLoan(loanSeed, DecentralizedMicrocredit.LoanStatus.Requested);
        if (!found) {
            _skip("disburseLoan");
            return;
        }
        LoanModel storage m = _loans[idx];
        bool borrowerDefaulted = credit.defaultedLoans(m.borrower) != 0;
        _call("disburseLoan");
        try credit.disburseLoan(m.id) {
            _ok("disburseLoan");
            _recordDisbursement(idx);
            if (borrowerDefaulted) disbursedAfterDefault++;
        } catch (bytes memory reason) {
            _rejected("disburseLoan", reason);
        }
    }

    function cancelLoan(uint256 loanSeed, uint256 callerSeed) external sharePriceKept("cancelLoan") {
        (bool found, uint256 idx) = _pickLoan(loanSeed, DecentralizedMicrocredit.LoanStatus.Requested);
        if (!found) {
            _skip("cancelLoan");
            return;
        }
        LoanModel storage m = _loans[idx];
        address caller = callerSeed % 2 == 0 ? m.borrower : _actor(callerSeed / 2);
        bool expired = vm.getBlockTimestamp() > m.requestedAt + credit.RESERVATION_TTL();
        _call("cancelLoan");
        vm.prank(caller);
        try credit.cancelLoan(m.id) {
            _ok("cancelLoan");
            if (caller != m.borrower && !expired) _mismatch("cancel: a stranger cancelled a fresh reservation");
            m.status = DecentralizedMicrocredit.LoanStatus.Cancelled;
        } catch (bytes memory reason) {
            _rejected("cancelLoan", reason);
        }
    }

    /**
     * @dev Credited and staker borrowers are topped up so they can pay interest; sybils repay
     *      only from what they hold (their loan proceeds).
     */
    function repay(uint256 loanSeed, uint256 amountSeed) external {
        (bool found, uint256 idx) = _pickLoan(loanSeed, DecentralizedMicrocredit.LoanStatus.Active);
        if (!found) {
            _skip("repay");
            return;
        }
        LoanModel storage m = _loans[idx];
        address borrower = m.borrower;
        uint256 accrued = accruedInterest(idx);
        uint256 owed = m.principal + accrued > m.repaid ? m.principal + accrued - m.repaid : 0;
        uint256 amount = _bound(amountSeed, 1, owed + CENT);
        uint256 balance = usdc.balanceOf(borrower);
        if (roleOf[borrower] == Role.Sybil) {
            if (balance == 0) {
                _skip("repay");
                return;
            }
            amount = Math.min(amount, balance);
        } else if (balance < amount) {
            usdc.mint(borrower, amount - balance);
            balance = amount;
        }

        _call("repay");
        _reserveBeforeRepay = credit.firstLossReserve();
        vm.prank(borrower);
        usdc.approve(address(credit), amount);
        vm.prank(borrower);
        try credit.repayLoan(m.id, amount) {
            _ok("repay");
            _recordRepayment(idx, accrued, owed, amount, balance - usdc.balanceOf(borrower));
        } catch (bytes memory reason) {
            _rejected("repay", reason);
        }
    }

    function markDefaulted(uint256 loanSeed) external {
        (bool found, uint256 idx) = _pickPastDue(loanSeed, credit.LATE_PERIOD());
        if (!found) {
            _skip("markDefaulted");
            return;
        }
        LoanModel storage m = _loans[idx];
        DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(m.borrower);
        uint256 writtenOff = m.principal - m.principalRepaid;
        uint256 stakedBefore = credit.totalStaked();
        uint256 reserveBefore = credit.firstLossReserve();
        uint256 lentBefore = credit.totalLentOut();

        _call("markDefaulted");
        try credit.markDefaulted(m.id) {
            _ok("markDefaulted");
            m.status = DecentralizedMicrocredit.LoanStatus.Defaulted;
            m.impaired = 0;
            defaults++;
            if (roleOf[m.borrower] == Role.Sybil) sybilDefaults++;
            if (credit.creditCommitted(m.borrower) != 0) backerDefaults++;
            if (_drop(lentBefore, credit.totalLentOut()) != writtenOff) {
                _mismatch("default: write-off differs from the unpaid principal");
            }
            uint256 slashed = _drop(stakedBefore, credit.totalStaked());
            uint256 fromReserve = _drop(reserveBefore, credit.firstLossReserve());
            if (slashed > writtenOff) _mismatch("default: slashed more stake than the loss");
            uint256 loss = writtenOff > slashed ? writtenOff - slashed : 0;
            if (fromReserve != Math.min(loss, reserveBefore)) {
                _mismatch("default: reserve did not cover what it could");
            }
            _chargeModel(m.borrower, edges, writtenOff, slashed);
            lossBeforeReserve += loss;
            realisedLoss += loss > fromReserve ? loss - fromReserve : 0;
            reserveUsed += fromReserve;
        } catch (bytes memory reason) {
            _rejected("markDefaulted", reason);
        }
    }

    /**
     * @dev Provision against an overdue loan: its unpaid principal less the borrower's whole
     *      incoming secured backing. Lowers the share price by design, so not price-checked.
     */
    function impairLoan(uint256 loanSeed) external {
        (bool found, uint256 idx) = _pickPastDue(loanSeed, 0);
        if (!found) {
            _skip("impairLoan");
            return;
        }
        LoanModel storage m = _loans[idx];
        DecentralizedMicrocredit.Backing[] memory edges = credit.getBackings(m.borrower);
        uint256 secured = 0;
        for (uint256 i = 0; i < edges.length; i++) {
            secured += edges[i].secured;
        }
        uint256 unpaid = m.principal - m.principalRepaid;
        uint256 provision = unpaid > secured ? unpaid - secured : 0;
        uint256 impairedBefore = credit.totalImpaired();
        _call("impairLoan");
        try credit.impairLoan(m.id) {
            _ok("impairLoan");
            impairments++;
            if (credit.totalImpaired() + m.impaired != impairedBefore + provision) {
                _mismatch("impair: provision is not unpaid principal less secured backing");
            }
            m.impaired = provision;
        } catch (bytes memory reason) {
            _rejected("impairLoan", reason);
        }
    }

    function warp(uint256 secondsSeed) external sharePriceKept("warp") {
        _call("warp");
        vm.warp(vm.getBlockTimestamp() + _bound(secondsSeed, 0, MAX_WARP));
        _ok("warp");
    }

    // ───────────────────────────── pool actions ─────────────────────────────

    function deposit(uint256 amountSeed) external sharePriceKept("deposit") {
        uint256 amount = _bound(amountSeed, 1, MAX_DEPOSIT);
        usdc.mint(lender, amount);
        lenderMinted += amount;
        _call("deposit");
        vm.prank(lender);
        usdc.approve(address(credit), amount);
        vm.prank(lender);
        try credit.depositFunds(amount) {
            _ok("deposit");
            deposited += amount;
            lenderDeposited += amount;
        } catch (bytes memory reason) {
            _rejected("deposit", reason);
        }
    }

    function withdraw(uint256 amountSeed) external sharePriceKept("withdraw") {
        uint256 amount = _withdrawalAmount(amountSeed);
        _call("withdraw");
        vm.prank(lender);
        try credit.withdrawFunds(amount) {
            _ok("withdraw");
        } catch (bytes memory reason) {
            _rejected("withdraw", reason);
        }
    }

    function requestWithdrawal(uint256 amountSeed) external sharePriceKept("requestWithdrawal") {
        DecentralizedMicrocredit.RequestWithdrawal memory req = DecentralizedMicrocredit.RequestWithdrawal({
            lender: lender,
            amount: _withdrawalAmount(amountSeed),
            to: lender,
            nonce: credit.nonces(lender),
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        bytes memory sig = _sign(
            lenderKey,
            keccak256(abi.encode(REQUEST_WITHDRAWAL_TYPEHASH, req.lender, req.amount, req.to, req.nonce, req.deadline))
        );
        _call("requestWithdrawal");
        try credit.requestWithdrawalMeta(req, sig) {
            _ok("requestWithdrawal");
        } catch (bytes memory reason) {
            _rejected("requestWithdrawal", reason);
        }
    }

    function processQueue(uint256 itemsSeed) external sharePriceKept("processQueue") {
        _call("processQueue");
        try credit.processWithdrawalQueue(_bound(itemsSeed, 1, 20)) {
            _ok("processQueue");
        } catch (bytes memory reason) {
            _rejected("processQueue", reason);
        }
    }

    /// @dev USDC sent straight to the contract; it must not become anyone's asset or credit.
    function donate(uint256 amountSeed) external sharePriceKept("donate") {
        uint256 amount = _bound(amountSeed, 1, MAX_DONATION);
        _call("donate");
        usdc.mint(address(credit), amount);
        donated += amount;
        _ok("donate");
    }

    function claimFees(uint256 amountSeed) external sharePriceKept("claimFees") {
        uint256 fees = credit.protocolFees();
        if (fees == 0) {
            _skip("claimFees");
            return;
        }
        uint256 amount = _bound(amountSeed, 1, fees);
        _call("claimFees");
        vm.prank(owner);
        try credit.claimProtocolFees(feeRecipient, amount) {
            _ok("claimFees");
            feesClaimed += amount;
        } catch (bytes memory reason) {
            _rejected("claimFees", reason);
        }
    }

    /// @dev Rare: one call in four hands part of the reserve's claim to lenders (no cash moves).
    ///      Only the part not absorbing provisions can go; one release in five probes beyond it.
    function releaseReserve(uint256 amountSeed) external sharePriceKept("releaseReserve") {
        uint256 reserve = credit.firstLossReserve();
        uint256 impaired = credit.totalImpaired();
        uint256 releasable = reserve > impaired ? reserve - impaired : 0;
        if (reserve == 0 || amountSeed % 4 != 0) {
            _skip("releaseReserve");
            return;
        }
        uint256 seed = amountSeed / 4;
        uint256 amount = releasable == 0 || seed % 5 == 0
            ? _bound(seed, releasable + 1, reserve + 1e6)
            : _bound(seed, 1, releasable);
        _call("releaseReserve");
        vm.prank(owner);
        try credit.releaseReserve(amount) {
            _ok("releaseReserve");
            reserveReleased += amount;
            if (amount > releasable) _mismatch("releaseReserve: released reserve that backs provisions");
        } catch (bytes memory reason) {
            _rejected("releaseReserve", reason);
        }
    }

    /// @dev Rare: one call in four adds first-loss capital from an outside funder.
    function fundReserve(uint256 amountSeed) external sharePriceKept("fundReserve") {
        if (amountSeed % 4 != 0) {
            _skip("fundReserve");
            return;
        }
        uint256 amount = _bound(amountSeed / 4, 1, MAX_DONATION);
        usdc.mint(funder, amount);
        _call("fundReserve");
        vm.prank(funder);
        usdc.approve(address(credit), amount);
        vm.prank(funder);
        try credit.fundReserve(amount) {
            _ok("fundReserve");
            reserveFunded += amount;
        } catch (bytes memory reason) {
            _rejected("fundReserve", reason);
        }
    }

    // ───────────────────────────── views for the invariants ─────────────────────────────

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function sybils() external view returns (address[] memory) {
        return _sybils;
    }

    function loanCount() external view returns (uint256) {
        return _loans.length;
    }

    function loanAt(uint256 idx) external view returns (LoanModel memory) {
        return _loans[idx];
    }

    /// @notice Unpaid principal on `borrower`'s open loans, requested ones included.
    function openPrincipal(address borrower) public view returns (uint256 total) {
        for (uint256 i = 0; i < _loans.length; i++) {
            LoanModel storage m = _loans[i];
            if (m.borrower == borrower && _isOpen(m.status)) total += m.principal - m.principalRepaid;
        }
    }

    /// @notice Unpaid principal on `borrower`'s disbursed, active loans.
    function lentPrincipal(address borrower) public view returns (uint256 total) {
        for (uint256 i = 0; i < _loans.length; i++) {
            LoanModel storage m = _loans[i];
            if (m.borrower == borrower && m.status == DecentralizedMicrocredit.LoanStatus.Active) {
                total += m.principal - m.principalRepaid;
            }
        }
    }

    /// @notice Sum of the provisions the model tracks per loan.
    function modelImpaired() external view returns (uint256 total) {
        for (uint256 i = 0; i < _loans.length; i++) {
            total += _loans[i].impaired;
        }
    }

    function openLoans(address borrower) external view returns (uint256 count) {
        for (uint256 i = 0; i < _loans.length; i++) {
            if (_loans[i].borrower == borrower && _isOpen(_loans[i].status)) count++;
        }
    }

    /// @notice Simple interest on the original principal since disbursement; none in the first day.
    function accruedInterest(uint256 idx) public view returns (uint256) {
        LoanModel storage m = _loans[idx];
        if (m.disbursedAt == 0) return 0;
        uint256 elapsed = vm.getBlockTimestamp() - m.disbursedAt;
        if (elapsed < GRACE_PERIOD) return 0;
        return (((m.principal * m.rate) / BASIS_POINTS) * elapsed) / SECONDS_PER_YEAR;
    }

    /// @notice Everything paid out to the second lender (the pool lender never withdraws).
    function paidOut() external view returns (uint256) {
        return usdc.balanceOf(lender) + lenderDeposited - lenderMinted;
    }

    function actionNames() external view returns (string[] memory) {
        return _actionNames;
    }

    function stat(string memory action) external view returns (Stat memory) {
        return _stats[keccak256(bytes(action))];
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev Three picks in four go to an account that can borrow, chosen uniformly among them.
    function _borrowerFor(uint256 seed) internal view returns (address) {
        if (seed % 4 == 0) return _actor(seed);
        address[] memory able = new address[](_actors.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _actors.length; i++) {
            (, uint256 available) = credit.getBorrowLimit(_actors[i]);
            if (available > 0) able[count++] = _actors[i];
        }
        return count == 0 ? _actor(seed) : able[(seed / 4) % count];
    }

    /// @dev Three picks in four go to an account with free credit or stake, chosen uniformly.
    function _backerFor(uint256 seed) internal view returns (address) {
        if (seed % 4 == 0) return _actor(seed);
        address[] memory able = new address[](_actors.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _actors.length; i++) {
            (uint256 freeCredit, uint256 freeStake) = credit.getFreeCredit(_actors[i]);
            if (freeCredit + freeStake > 0) able[count++] = _actors[i];
        }
        return count == 0 ? _actor(seed) : able[(seed / 4) % count];
    }

    /// @dev Mostly within the borrower's available limit; one in five probes beyond it.
    function _loanAmount(address borrower, uint256 seed) internal view returns (uint256) {
        (, uint256 available) = credit.getBorrowLimit(borrower);
        if (available == 0) return _bound(seed, 1, 1e6);
        if (seed % 5 == 0) return _bound(seed / 5, available + 1, available + available / 4 + 1e6);
        return _bound(seed, 1, available);
    }

    function _withdrawalAmount(uint256 seed) internal view returns (uint256) {
        if (seed % 8 == 0) return type(uint256).max;
        uint256 free = credit.convertToAssets(credit.sharesOf(lender) - credit.queuedShares(lender));
        return _bound(seed, 1, free + free / 8 + 1);
    }

    /// @dev requestLoan then disburseLoan; returns whether the loan was disbursed.
    function _borrow(string memory action, address borrower, uint256 amount) internal returns (bool) {
        vm.prank(borrower);
        try credit.requestLoan(amount) returns (uint256 loanId) {
            uint256 idx = _recordLoan(loanId, borrower);
            try credit.disburseLoan(loanId) {
                _ok(action);
                _recordDisbursement(idx);
                return true;
            } catch (bytes memory reason) {
                _rejected(action, reason);
            }
        } catch (bytes memory reason) {
            _rejected(action, reason);
        }
        return false;
    }

    function _sybilBack(address sybil, address borrower, uint256 amount) internal {
        (uint256 secured, uint256 unsecured) = credit.getBacking(sybil, borrower);
        vm.prank(sybil);
        try credit.back(borrower, secured + unsecured + amount) {
            sybilBacksAccepted++;
        } catch (bytes memory reason) {
            sybilBacksRejected++;
            _classify("sybilRing", reason);
        }
    }

    function _recordLoan(uint256 loanId, address borrower) internal returns (uint256 idx) {
        (uint256 principal,, address recorded, uint256 rate,) = credit.getLoan(loanId);
        (DecentralizedMicrocredit.LoanStatus status, uint256 term, uint256 requestedAt,,) = credit.getLoanTerms(loanId);
        if (recorded != borrower) _mismatch("request: loan recorded for another borrower");
        if (requestedAt != vm.getBlockTimestamp()) _mismatch("request: wrong request time");
        idx = _loans.length;
        _loans.push(
            LoanModel({
                id: loanId,
                borrower: borrower,
                principal: principal,
                rate: rate,
                term: term,
                requestedAt: requestedAt,
                disbursedAt: 0,
                repaid: 0,
                principalRepaid: 0,
                impaired: 0,
                status: status
            })
        );
    }

    function _recordDisbursement(uint256 idx) internal {
        LoanModel storage m = _loans[idx];
        m.status = DecentralizedMicrocredit.LoanStatus.Active;
        m.disbursedAt = vm.getBlockTimestamp();
    }

    /// @dev Interest first, then principal; the loan closes once less than a cent is left.
    function _recordRepayment(uint256 idx, uint256 accrued, uint256 owed, uint256 amount, uint256 paid) internal {
        LoanModel storage m = _loans[idx];
        if (paid != Math.min(amount, owed)) _mismatch("repay: pulled other than min(amount, outstanding)");
        uint256 interestDue = accrued - (m.repaid - m.principalRepaid);
        uint256 interest = Math.min(paid, interestDue);
        uint256 fee = (interest * feeBps) / BASIS_POINTS;
        uint256 toReserve = (interest * reserveBps) / BASIS_POINTS;
        m.repaid += paid;
        m.principalRepaid += paid - interest;
        m.impaired -= Math.min(paid - interest, m.impaired);
        interestPaid += interest;
        feesAccrued += fee;
        reserveIn += toReserve;
        poolInterest += interest - fee;
        dues[m.borrower] += toReserve;
        if (owed - paid < CENT) {
            forgiven += m.principal - m.principalRepaid;
            reserveForgiven += Math.min(m.principal - m.principalRepaid, _reserveBeforeRepay + toReserve);
            m.impaired = 0;
            m.status = DecentralizedMicrocredit.LoanStatus.Repaid;
        }
    }

    /**
     * @dev The documented charging rule, from the borrower's backing before the default:
     *      secured backing pays first, pro rata, then unsecured backing is charged pro rata to
     *      its backers' granted credit; the residual falls on the reserve and the lenders.
     */
    function _chargeModel(
        address borrower,
        DecentralizedMicrocredit.Backing[] memory edges,
        uint256 writtenOff,
        uint256 slashed
    ) internal {
        uint256 totalSecured = 0;
        uint256 totalUnsecured = 0;
        for (uint256 i = 0; i < edges.length; i++) {
            totalSecured += edges[i].secured;
            totalUnsecured += edges[i].unsecured;
        }
        uint256 fromStake = Math.min(writtenOff, totalSecured);
        uint256 fromCredit = Math.min(writtenOff - fromStake, totalUnsecured);
        uint256 slashSum = 0;
        uint256 chargeSum = 0;
        for (uint256 i = 0; i < edges.length; i++) {
            if (fromStake != 0) slashSum += Math.mulDiv(fromStake, edges[i].secured, totalSecured);
            if (fromCredit != 0) {
                uint256 c = Math.mulDiv(fromCredit, edges[i].unsecured, totalUnsecured);
                charged[edges[i].backer] += c;
                chargeSum += c;
            }
        }
        if (slashSum != slashed) _mismatch("default: stake slashed differs from the pro-rata rule");
        if (fromStake != 0) defaultsSlashing++;
        if (fromCredit != 0) defaultsCharging++;
        if (writtenOff > fromStake + fromCredit) defaultsResidual++;
        uint256 dust = (fromStake - slashSum) + (fromCredit - chargeSum);
        residual[borrower] += writtenOff - slashSum - chargeSum;
        roundingDust[borrower] += dust;
        totalRoundingDust += dust;
    }

    function _pickLoan(uint256 seed, DecentralizedMicrocredit.LoanStatus status)
        internal
        view
        returns (bool found, uint256 idx)
    {
        uint256 n = _loans.length;
        for (uint256 k = 0; k < n; k++) {
            idx = (seed % n + k) % n;
            if (_loans[idx].status == status) return (true, idx);
        }
    }

    /**
     * @dev An active loan more than `grace` past its due date. When none is, half the time the
     *      handler waits (warps) until the first active loan from `seed` gets there, as anyone
     *      watching the loan could; otherwise there is nothing to do.
     */
    function _pickPastDue(uint256 seed, uint256 grace) internal returns (bool found, uint256 idx) {
        uint256 n = _loans.length;
        bool anyActive = false;
        uint256 firstActive = 0;
        for (uint256 k = 0; k < n; k++) {
            idx = (seed % n + k) % n;
            LoanModel storage m = _loans[idx];
            if (m.status != DecentralizedMicrocredit.LoanStatus.Active) continue;
            if (vm.getBlockTimestamp() > m.disbursedAt + m.term + grace) return (true, idx);
            if (!anyActive) {
                anyActive = true;
                firstActive = idx;
            }
        }
        if (!anyActive || seed % 2 != 0) return (false, 0);
        LoanModel storage chosen = _loans[firstActive];
        vm.warp(chosen.disbursedAt + chosen.term + grace + 1);
        return (true, firstActive);
    }

    function _isOpen(DecentralizedMicrocredit.LoanStatus status) internal pure returns (bool) {
        return
            status == DecentralizedMicrocredit.LoanStatus.Requested
                || status == DecentralizedMicrocredit.LoanStatus.Active;
    }

    function _drop(uint256 before, uint256 afterwards) internal returns (uint256) {
        if (afterwards > before) {
            _mismatch("a balance that can only fall rose");
            return 0;
        }
        return before - afterwards;
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("DecentralizedMicrocredit"),
                keccak256("1"),
                block.chainid,
                address(credit)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _mismatch(string memory what) internal {
        mismatches++;
        lastMismatch = what;
    }

    function _stat(string memory action) internal returns (Stat storage s) {
        s = _stats[keccak256(bytes(action))];
        if (s.calls == 0 && s.ok == 0 && s.rejected == 0 && s.skipped == 0) _actionNames.push(action);
    }

    function _call(string memory action) internal {
        _stat(action).calls++;
    }

    function _ok(string memory action) internal {
        _stat(action).ok++;
    }

    function _skip(string memory action) internal {
        _stat(action).skipped++;
    }

    function _rejected(string memory action, bytes memory reason) internal {
        _stat(action).rejected++;
        _classify(action, reason);
    }

    /// @dev A rejection must be one of the protocol's own errors; anything else (a panic from an
    ///      underflow, a token error, an empty revert) means the accounting or the handler is wrong.
    function _classify(string memory action, bytes memory reason) internal {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        if (!_isProtocolError(selector)) {
            unexpectedReverts++;
            lastUnexpectedAction = action;
            lastUnexpectedReason = reason;
        }
    }

    function _isProtocolError(bytes4 selector) internal pure returns (bool) {
        return selector == DecentralizedMicrocredit.ZeroAmount.selector
            || selector == DecentralizedMicrocredit.ZeroShares.selector
            || selector == DecentralizedMicrocredit.InsufficientBalance.selector
            || selector == DecentralizedMicrocredit.InsufficientLiquidity.selector
            || selector == DecentralizedMicrocredit.NoCredit.selector
            || selector == DecentralizedMicrocredit.BorrowLimitExceeded.selector
            || selector == DecentralizedMicrocredit.BorrowerInDefault.selector
            || selector == DecentralizedMicrocredit.UtilisationCapExceeded.selector
            || selector == DecentralizedMicrocredit.LoanNotRequested.selector
            || selector == DecentralizedMicrocredit.LoanNotActive.selector
            || selector == DecentralizedMicrocredit.NotCancellableYet.selector
            || selector == DecentralizedMicrocredit.NotYetDefaultable.selector
            || selector == DecentralizedMicrocredit.NotOverdue.selector
            || selector == DecentralizedMicrocredit.SelfBacking.selector
            || selector == DecentralizedMicrocredit.TooManyBackers.selector
            || selector == DecentralizedMicrocredit.BackingTooSmall.selector
            || selector == DecentralizedMicrocredit.InsufficientCredit.selector
            || selector == DecentralizedMicrocredit.BackingInUse.selector
            || selector == DecentralizedMicrocredit.StakeCommitted.selector
            || selector == DecentralizedMicrocredit.InsufficientStake.selector
            || selector == DecentralizedMicrocredit.ExceedsAccruedFees.selector
            || selector == DecentralizedMicrocredit.ExceedsReserve.selector;
    }
}
