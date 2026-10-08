// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DecentralizedMicrocredit } from "./DecentralizedMicrocredit.sol";

/**
 * @notice Read-only views derived from {DecentralizedMicrocredit}'s public state. They live here
 *         rather than in the pool to keep the pool under the EIP-170 size limit (CI-26). The lens
 *         holds no funds and no state but the pool's address, so it can be redeployed at will.
 */
contract MicrocreditLens {
    uint256 internal constant CENT = 10_000; // 0.01 USDC (6 decimals)
    /// @dev Shares 1 USDC mints in an empty pool (the pool's 6-decimal virtual offset).
    uint256 internal constant LAUNCH_SHARES_PER_USDC = 1e12;

    DecentralizedMicrocredit public immutable credit;

    constructor(DecentralizedMicrocredit credit_) {
        credit = credit_;
    }

    /// @notice Projected lender APY in BASIS_POINTS: loan rate x pool utilisation, net of the
    ///         protocol fee and the reserve share, before default losses. Realised only as
    ///         borrowers repay.
    function getFundingPoolAPY() external view returns (uint256) {
        uint256 bps = credit.BASIS_POINTS();
        uint256 grossBp = (credit.getLoanRate() * getUtilisation()) / bps;
        return (grossBp * (bps - credit.protocolFeeBps() - credit.reserveBps())) / bps;
    }

    /// @notice Principal lent out or reserved for approved loans, as a share of `totalAssets`, in
    ///         BASIS_POINTS. Can exceed the utilisation cap after losses shrink `totalAssets`.
    function getUtilisation() public view returns (uint256) {
        uint256 assets = credit.totalAssets();
        if (assets == 0) return 0;
        return ((credit.totalLentOut() + credit.reservedLiquidity()) * credit.BASIS_POINTS()) / assets;
    }

    /// @notice What the shares 1 USDC bought at launch are worth now, in USDC (6 decimals, so
    ///         1e6 means no change): the pool's realised return since launch, net of the fee, the
    ///         reserve share, losses and provisions. Interest counts only once repaid.
    function sharePrice() external view returns (uint256) {
        return credit.convertToAssets(LAUNCH_SHARES_PER_USDC);
    }

    /**
     * @return totalAssets    USDC owned by lenders (see {DecentralizedMicrocredit-totalAssets})
     * @return availableFunds Liquid USDC not reserved for loans or owed to the withdrawal queue
     * @return reservedFunds  USDC reserved for approved, undisbursed loans
     * @return lenderCount    Unique depositors
     */
    function getPoolInfo()
        external
        view
        returns (uint256 totalAssets, uint256 availableFunds, uint256 reservedFunds, uint256 lenderCount)
    {
        totalAssets = credit.totalAssets();
        reservedFunds = credit.reservedLiquidity();
        availableFunds = _liquid();
        lenderCount = credit.lenderCount();
    }

    /// @notice The most `lender` can take now with `withdrawFunds`: the value of its shares not in
    ///         the withdrawal queue, up to the cash not reserved for loans or owed to the queue.
    function maxWithdrawable(address lender) external view returns (uint256) {
        uint256 value = credit.convertToAssets(credit.sharesOf(lender) - credit.queuedShares(lender));
        return Math.min(value, _liquid());
    }

    /// @return interestRate APR in BASIS_POINTS
    /// @return payment      Weekly payment over `repaymentPeriod` (one payment if under a week)
    function previewLoanTerms(
        address,
        /* borrower */
        uint256 principal,
        uint256 repaymentPeriod
    )
        external
        view
        returns (uint256 interestRate, uint256 payment)
    {
        interestRate = credit.getLoanRate();
        uint256 interest =
            (principal * interestRate * repaymentPeriod) / (credit.BASIS_POINTS() * credit.SECONDS_PER_YEAR());
        uint256 payments = repaymentPeriod / 7 days;
        payment = (principal + interest) / (payments == 0 ? 1 : payments);
    }

    /// @notice Outstanding balance rounded up to the cent: what the UI shows and approves for a
    ///         repayment in full. The pool pulls only what is owed, so rounding up never
    ///         overpays, while rounding down could leave sub-cent principal owed and the loan open
    ///         (a loan closes short only on interest since the CI-30 fix).
    function getOutstandingRoundedToCent(uint256 loanId) external view returns (uint256) {
        return ((credit.getCurrentOutstandingAmount(loanId) + CENT - 1) / CENT) * CENT;
    }

    /// @dev Pool cash not reserved for loans or owed to the withdrawal queue.
    function _liquid() internal view returns (uint256) {
        uint256 cash = credit.lenderCash();
        uint256 committed = credit.reservedLiquidity() + credit.totalQueuedWithdrawals();
        return cash > committed ? cash - committed : 0;
    }
}
