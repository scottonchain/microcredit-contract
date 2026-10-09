# Production deployment

Status: **not deployed.** Nothing in this repository has been deployed to a public network. This
runbook says how to deploy once the deployment is approved. The script is
`packages/foundry/script/DeployProduction.s.sol`. Its test is
`packages/foundry/test/DeployProduction.t.sol`, which runs it in-process.

## Approval gates

No `--broadcast` happens before all three are recorded.

1. **Legal review.** Counsel signs off on the protocol and the pilot: the jurisdictions served,
   lender and borrower terms, KYC and AML (ADMIN holds the KYC role), and the status of lender
   shares.
2. **Owner approval.** The project owner approves the exact environment (the parameter values
   below) and the saved dry-run output.
3. **Signers.** The ADMIN signers confirm they control ADMIN and have read the two timelock
   operations from the dry run.

## What the script does

- Deploys an OpenZeppelin `TimelockController` with `minDelay = TIMELOCK_DELAY`,
  `proposers = [ADMIN]`, `executors = [ADMIN]` and `admin = address(0)`. The timelock administers
  itself, so role changes also wait out the delay. ADMIN also gets the canceller role.
- Deploys `DecentralizedMicrocredit` and `OracleScoreProvider` with the deployer as temporary
  owner. The lending contract's oracle role (`markKYCVerified`) goes to ADMIN. The provider gets
  no reporter. Also deploys `MicrocreditLens`, the stateless read-only views the front end uses;
  it has no owner and can be redeployed at any time.
- Configures the issuance limits, `setLending`, the CRE forwarder if one is given, the score
  provider, the reserve share, the protocol fee and the relayer whitelist if a relayer is given.
- Calls `transferOwnership(timelock)` on both contracts. Ownership moves only when the timelock
  calls `acceptOwnership`.
- Checks every value, role and owner on-chain, and reverts on any mismatch (`checkDeployment`).
- Seeds nothing: no deposits, loans, scores or score overrides.
- Writes `packages/foundry/deployment.production.json` only under `--broadcast`. The file is
  gitignored. A dry run or a test writes nothing.

## Prerequisites

- The ADMIN multisig exists on the target chain. The script refuses an ADMIN without code.
- `USDC_ADDRESS` is native USDC from Circle's published list for that chain. A bridged variant is
  not USDC for this purpose.
- The deployer is a fresh account that holds only gas and is used for nothing else. It signs from
  a hardware wallet (`--ledger`) or an encrypted keystore (`cast wallet import`). A raw key never
  goes in `.env` or shell history.
- If the CRE workflow is ready, you have the chain's forwarder address, the workflow owner and
  the workflow id. If not, leave all three unset.
- The fork tests pass against Circle's USDC:
  `BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-path 'test/fork/*'`. They
  cover what MockUSDC does not: USDC's permit domain and its blacklist (CI-27). For another chain,
  point the suite's USDC constant and RPC at that chain first.

## Step 1. Dry run

```bash
cd packages/foundry
export USDC_ADDRESS=0x... ADMIN=0x... EFFR_BPS=...   # plus any parameter that differs from the default
forge script script/DeployProduction.s.sol --rpc-url <url> --sender <deployer address>
```

There is no `--broadcast`, so nothing is sent. `--sender` makes the simulated addresses match the
deployer's real nonce. Check the output:

- The chain id is the target chain, and the deployer is the intended address.
- The USDC line names the expected token (symbol `USDC`; the name is `USD Coin` or `USDC`
  depending on the chain, e.g. `USDC` on Base Sepolia), and the address matches Circle's list.
- ADMIN is the multisig.
- Every parameter matches the approved table. "Most oracle-issued credit lent at once" is the
  approved exposure (`ISSUANCE_BUDGET_LINES x MAX_LOAN`).
- The CRE forwarder and relayer lines are what you expect.
- The run ends without a revert. The script's own checks have passed.
- The output says `Not broadcasting, so not writing ...`.

Save the whole output and attach it to the approval.

## Step 2. Broadcast (only after approval)

Use the same environment. Add the signer and `--broadcast`:

```bash
forge script script/DeployProduction.s.sol --rpc-url <url> --sender <deployer address> \
  --account <keystore name> --broadcast   # or --ledger; add --verify with an explorer API key
```

Then compare `deployment.production.json` and
`broadcast/DeployProduction.s.sol/<chainId>/run-latest.json` with the dry run. The addresses
match if the deployer sent nothing in between. If a transaction failed, stop and investigate.
Do not re-run blindly.

## Step 3. Accept ownership through the timelock

The script prints two operations, and `deployment.production.json` holds the same calldata. Both
have value 0, data `0x79ba5097` (`acceptOwnership()`), predecessor 0 and salt 0.

1. Target `DecentralizedMicrocredit`.
2. Target `OracleScoreProvider`.

ADMIN sends the two printed `schedule` calldatas to the timelock. One Safe batch is fine. After
at least `TIMELOCK_DELAY`, ADMIN sends the two `execute` calldatas. Then verify read-only:

```bash
cast call <contract> "owner()(address)" --rpc-url <url>          # must be the timelock
cast call <contract> "pendingOwner()(address)" --rpc-url <url>   # must be 0x0
```

From then on every owner action is a timelock operation: ADMIN schedules it, waits the delay,
then executes it.

## The ownership window

From the broadcast until step 3 executes, the deployer is still owner of both contracts. That is
at least `TIMELOCK_DELAY` plus the time to collect signatures. In that window the deployer key
could change any parameter, set score overrides, or redirect the pending owner. So:

- Keep the deployer key offline and use it for nothing.
- Do not deposit, publish scores or announce the pool.
- After step 3, list the owner events on both contracts (`ParameterUpdated`, `ScoreOverrideSet`,
  `ScoreProviderUpdated`, `OracleUpdated`, `RelayerWhitelisted`, `OwnershipTransferStarted`,
  `ForwarderUpdated`, `ReporterUpdated`, `IssuanceLimitsUpdated`, `MaxScoreAgeUpdated`,
  `LendingUpdated`). Each must come from a transaction in `run-latest.json`. If one does not, do
  not open the pool.

## Emergency pause

The ADMIN multisig is also the guardian of the lending contract. It can call `pause()` at once,
without the timelock, if the oracle, an issuer or the relayer is compromised. Pausing stops new
loans and disbursements only: borrowers can still repay, overdue loans can still be impaired and
defaulted, and lenders can still exit. Unpausing is an owner action, so it goes through the
timelock like any other change.

## Parameters

Every parameter is an environment variable. An empty value counts as unset. A malformed number
reverts; it never falls back to the default.

| Variable | Default | Meaning | Source |
| --- | --- | --- | --- |
| `USDC_ADDRESS` | required | Circle USDC, 6 decimals | Circle's published addresses |
| `ADMIN` | required | Multisig: timelock proposer, executor and canceller; KYC oracle role | Governance decision |
| `EFFR_BPS` | required | Effective Federal Funds Rate, bps | New York Fed, on deployment day |
| `TIMELOCK_DELAY` | 172800 (2 days) | Delay on every governance action, 1 to 30 days | Governance decision |
| `RISK_PREMIUM_BPS` | 800 | Added to EFFR for each loan's fixed APR | Calibration, annual PD 5% ([analysis/credit_risk](../analysis/credit_risk/README.md), bottom line 2) |
| `MAX_LOAN` | 25000000 (25 USDC) | A full line, at score 100% | Pilot size |
| `RESERVE_BPS` | 4500 | Share of repaid interest that funds the first-loss reserve | Owner's interim decision, pending the reserve-equilibrium analysis ([ECONOMICS.md](ECONOMICS.md), "The reserve share") |
| `PROTOCOL_FEE_BPS` | 0 | Protocol's share of repaid interest | The calibration assumes no fee |
| `ISSUANCE_BUDGET_LINES` | 20 | `maxTotalScore = lines x 1e6` | 20 x 25 USDC: at most 500 USDC of oracle-issued credit |
| `MAX_INCREASE_PER_REPORT_LINES` | 5 | `maxIncreasePerReport`: how much one report may add | Limits how fast a bad report can issue |
| `MAX_SCORE_AGE` | 604800 (7 days) | Scores read 0 after this long without a report | Oracle liveness |
| `CRE_FORWARDER` | unset | CRE forwarder. Unset: nothing can publish scores until governance sets one | Chainlink, per chain |
| `CRE_WORKFLOW_OWNER`, `CRE_WORKFLOW_ID` | unset | The one workflow the provider accepts. Required with a forwarder | The CRE workflow |
| `RELAYER` | unset | If set, the whitelist is enabled and this is the only relayer | Operations |

The 800 premium assumes an annual PD of 5%. For PD 3% the calibration gives 600, and for PD 10%
it gives 1400. Pick the row for the riskiest borrowers the pilot admits.

The reserve share is a separate decision. The calibration recommended 6500 at PD 5% (5500 at 3%,
7500 at 10%) on the assumption that the reserve above a cap is released to lenders. The contract
never releases interest-funded reserve (`releaseReserve` keeps all dues, ce99679), so under that
rule 6500 leaves lenders about 3.7% a year in the long run, below the 4.33% funding rate
(`ECONOMICS.md`). The owner set the default to 4500 on 2026-10-05, just above the share that
covers expected loss (about 4200 at PD 5%), and it stays an interim value until the equilibrium
analysis has been reviewed and finalized. Only capital added through `fundReserve` can be
released, and only above all dues ever paid.

The script leaves three contract defaults as they are: `lendingUtilizationCap` 90%,
`liquidityBuffer` 5% and `liquidityThreshold` 0. It also rejects values that look like unit
mistakes: EFFR above 2000 bps, a premium above 5000 bps, or `MAX_LOAN` outside 1 to 10,000 USDC.

## What the oracle workflow must satisfy

- **No free credit (CREDIT_MODEL.md Theorem 3, CI-19).** Scores must not come from the backing
  graph, from repayment counts such as `completedLoans`, or from any history a fresh account can
  produce at no cost. A ring of fresh accounts can farm such a rule without limit. History may
  inform a line only through an issuer that answers for it: an identity cost, KYC, or an
  institution.
- **Issuance budget.** The budget held across all accounts stays at or below `maxTotalScore`.
  One report raises it by at most `maxIncreasePerReport`. Lowering a score cuts the account's
  credit at once, but its budget stays held until `releaseBudget` sees the account with no open
  loans and no backing commitments. Anyone may call `releaseBudget`.
- **Report format.** `abi.encode(uint64 epoch, address[] users, uint256[] scores)`, at most 500
  accounts, epochs strictly increasing, each score at most 1e6.
- **Heartbeat.** Send a report, empty if nothing changed, more often than `MAX_SCORE_AGE`.
  Otherwise every score reads 0 and lending stops.
- **Pinning.** Reports arrive only through the forwarder, from the configured workflow owner and
  id. Configuring them later is a timelock operation (`setForwarder`).

## What the relayer service must satisfy, if one is named

`RELAYER` names the one account allowed to submit meta-transactions. The contract already makes a
duplicate submission harmless (a nonce is consumed once and a second use reverts with
`InvalidNonce`), so these requirements are about the service that holds the key: what it tells a
client, what it never sends twice, and what it records before it acts. The owner checks them before
approving the address at gate 2. Each one is tied to what the code and its tests show today
(`packages/nextjs/app/api/meta/relayer.ts`; the design note is
`coordination/relayer-journal-design.md` in the testbed repository).

- **Journal on, local key.** The service runs with `RELAYER_JOURNAL_PATH` set and signs with its
  own key (`RELAYER_PRIVATE_KEY`), never through an unlocked node: the journal records the signed
  transaction's hash and bytes before the broadcast, so a hash-less entry was never sent and a retry
  rebroadcasts the identical bytes. The relayer refuses the journal on an unlocked node outside the
  local chain.
- **One process, one journal file.** The send queue is process-local and the journal has one
  writer. Two processes with the same key would race on the account nonce.
- **A restart loses nothing.** After a crash between broadcast and receipt, the same request is
  answered 202 while unmined and 200 once mined, with one transaction in all. The repeatable check
  is `yarn workspace @se-2/nextjs relayer:crash-check` (15 checks on a local chain). It has not
  been run against a public endpoint or a testnet: attach a run of that kind to the approval when
  it exists, and say so in the approval when it does not.
- **Known gaps accepted or closed.** The design note lists seven: attribution of a consumed nonce
  by decoding the consuming transaction's calldata, fee replacement of a stuck transaction, more
  than one relayer process, confirmation depth against reorganisations, the receipt being read
  from the same endpoint that took the write, permit-only routes' weaker key, and the fact that
  the service is code and tests, not yet a service anyone outside the team has used.
  A consumed sender nonce without a receipt leaves a hash-journaled intent `submitted` (HTTP 202); if receipt recovery cannot resolve it, the [documented operator reconciliation](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/relayer-journal-design.md) is required, preserving uncertainty at a liveness cost.
- **Key custody named.** Who holds the relayer key and where, how it is rotated, and what the
  service's public endpoint and uptime practice are. Gas for the key is a running cost the
  approval states.
- **Nothing here covers a person's use of it.** A relayed transaction is a convenience for a
  wallet that has no gas. It is not evidence that anyone has borrowed, repaid or benefited.

## What not to do

- Do not set score overrides (`setScoreOverride`) on pseudonymous accounts. Overrides bypass the
  issuance budget (CI-6).
- Never raise `maxLoanAmount` without re-checking the issuance budget. It scales every line. The
  oracle's worst case is `maxTotalScore x maxLoanAmount / 1e6`. Lower the budget in the same
  proposal if needed.
- Do not set a reporter in production. `publishScores` skips the workflow pinning.
- Do not grant timelock roles to an EOA. Do not open the executor role to `address(0)`.
- Do not lower the premium below the calibration without a new calibration run. Do not change the
  reserve share from the interim 4500 without the owner's decision and the reviewed analysis.
- Do not run `script/Deploy.s.sol` against a public network. It broadcasts with Anvil's published
  keys and seeds demo state.
- Do not broadcast before the approval gates. Do not commit keys or `.env` files.
