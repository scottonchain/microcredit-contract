# Testnet deployment (Base Sepolia)

A deployment for persona testing by agents and people. It is a testnet with a free-mint token: nothing here has value, and this is not the production deployment (`DEPLOYMENT.md`).

Three deployments of the same contract code exist. The **live deployment** is the one agents use: it is run by Hermes, which holds every role. The **reference run** came first and is kept for its record, and a **duplicate run** by Hermes is recorded below. The contracts are identical in all three: `73cb3f6` and `main` `489f01a` differ only outside `packages/foundry/contracts`.

## Live deployment (operated by Hermes)

Chain: Base Sepolia (84532), RPC `https://sepolia.base.org`. Deployed 2026-10-03 from `main` `489f01a` with `script/DeployTestnet.s.sol` (`MAX_LOAN=100000000`). Broadcast logs: `packages/foundry/broadcast/DeployTestnet.s.sol/84532/run-1791065984302.json` and `TestnetScenarios.s.sol/84532/run-1791066260981.json`.

| Contract | Address |
| --- | --- |
| `DecentralizedMicrocredit` (pool) | `0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8` |
| `MicrocreditLens` | `0x090543B6C41a6029660D464c584c0310A74A525d` |
| `OracleScoreProvider` | `0x392503b73E9d628a6bb33EDC9e22De6ac2C1A017` |
| `MockUSDC` (public `mint`) | `0x7C46870111257d8A3aaF846BC6D2F7DA7FBb76f1` |

Parameters:
- EFFR 433 bps plus a 500 bps risk premium: 933 bps APR.
- A full line is 100 USDC.
- The reserve share is 30% of interest.
- The issuance budget is 50 full lines, with the same cap per report.
- Scores go stale after 7 days.

Roles: owner, oracle, score reporter and guardian are all Hermes's testnet account `0x5e4dC7639D2b94006c51aD5373173f5e01c248F9`.

To get a credit line, comment on an issue in this repo starting with `@HermesCRBot`, giving the addresses and line sizes. Hermes checks the repo every few minutes.

Verified independently from chain state after deployment:
- The pool's code is 24,400 bytes, the same as the reference run.
- The wiring matches: token, score provider, `lending`, and the lens.
- The parameters above match.
- Every role is held by `0x5e4d…48F9`.

Deploy transactions: pool `0x69e91d6d…409e`, lens `0xbb10325a…12ba`, score provider `0xebe36262…00ad`, MockUSDC `0x6990ab9b…f2d7`. The configuration transactions end at `0x4b492520…7772`.

## Persona scenarios (real transactions)

`script/TestnetScenarios.s.sol` ran on each deployment as 72 transactions, all successful. Each claim is checked with `require`, refusals are simulated against the same state, and the results below were re-read from chain state afterwards.

| Scenario | Claim | Result |
| --- | --- | --- |
| Liquidity | Lena deposits 5,000 | pool `totalAssets` 5,000 |
| Credit moves, not copies (CI-4, the demo video) | The issuer grants Avery 92 and Brighton 25. Avery backs Brighton 50 | Avery's limit is 42 and Brighton's 75: 117 = 92 + 25 issued. Brighton borrows 40 and repays inside the first day |
| Fresh ring (CI-1, CI-2) | Ten fresh accounts try to back each other and to borrow | 10 backings refused (`InsufficientCredit`), 10 loans refused (`NoCredit`) |
| Staked ring | Rex stakes 25 and backs five members with 5 each | They borrow exactly 25. More backing, passing backing on, and more borrowing are all refused. The five loans are left open for the default test |
| Recycled-seed farm (Theorem 3) | Sam stakes 25. The stake backs one farm account, which borrows and repays 25 four times inside the interest-free day, then moves on to a second | Both farm accounts have 4 completed loans and 0 granted credit |
| Issuance budget (CI-22) | The reporter tries to issue 49 more full lines past the remaining budget | refused (`IssuanceBudgetExceeded`) |

Persona addresses on the live deployment:

| Persona | Address |
| --- | --- |
| Lena | `0x70374adB39E6314672C86E45eca6dA5637A0bDa2` |
| Avery | `0xc5E42B0fB0c109E55f4A40CccfCF3fed1Fc39009` |
| Brighton | `0x53A7347715d4e572C2D519234e72136E609368Ff` |
| Rex | `0x563D424087ed949456c425281D8F21042d8C13aB` |
| Sam | `0x2fB26cF284f4B58a553D62e5CE80D9a9Db6905c6` |

The persona keys derive from the deploy key. Rerunning the script skips steps that are already done.

## Time-dependent scenarios (fork of the live deployment)

Due dates and defaults cannot be waited out on a testnet. `test/fork/LiveDeployment.t.sol` forks Base Sepolia at the live state, moves the clock past due date plus the late period, and defaults every open loan. Both checks pass on each deployment:

- **Staked ring:** its defaults are paid by Rex's slashed stake, and lenders lose nothing (`totalAssets` does not fall).
- **Brighton's unsecured default:** he borrows his full 75, with 25 of his own and 50 from Avery, and defaults. Avery's committed 50 is burned. Lenders lose at most the unpaid 75, within Theorem 2's bound of the lines issued to the two of them (117). Brighton cannot borrow again.

```bash
LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8 \
LIVE_AVERY=0xc5E42B0fB0c109E55f4A40CccfCF3fed1Fc39009 LIVE_BRIGHTON=0x53A7347715d4e572C2D519234e72136E609368Ff \
LIVE_REX=0x563D424087ed949456c425281D8F21042d8C13aB forge test --match-path test/fork/LiveDeployment.t.sol -vv
```

## Duplicate run (Hermes, 2026-10-04 00:21 UTC)

Hermes deployed `main` (489f01a) a second time, from a check that started without memory of the first. It is a complete, correctly wired deployment with the full scenario run, verified from chain state (24,400-byte pool; token, score provider, `lending` and lens wired; every role held by `0x5e4d…48F9`; 14 loans; Sam's 25 stake; Brighton's limit 75). It is **not** the live pool: the live addresses above are the ones every document, config and issue points at, and switching them again would split agents across pools. Its broadcast logs were not captured (the files published for it are copies of the reference run's).

| Contract | Address |
| --- | --- |
| Pool | `0xad9dEA05FD0c63cf40e9D37da56B47AEFBB38973` |
| Lens | `0x17C84412DE1E16F780cE65173932b078e3462A51` |
| Score provider | `0x4A0839979139fc9429E529196A22B797904c9b1b` |
| MockUSDC | `0x156D3D9EB9c4C88A78c499bA0c1aeCA478E25751` |

Deploy transactions: pool `0x2593902e…c635`, lens `0x7a6a043d…4832`, score provider `0x8e85c9a6…4745`, MockUSDC `0x7389980d…5cc2`. The persona addresses are the same as the live deployment's (they derive from the same key).

## Reference run (first deployment)

Deployed from `73cb3f6` by the Claude Code agent. Its admin key lived only in that agent's container, so this deployment is not administered any more. It is kept as a second, independent run of the same scenarios.

| Contract | Address |
| --- | --- |
| Pool | `0xe3264D64cEF7C7675a548524D883b597e7894169` |
| Lens | `0x01C0586B3Cef50b427411c1278Be25605e8329Dc` |
| Score provider | `0x5bDe901dA88fc351d93B7cF7AaEb72Af55D38b02` |
| MockUSDC | `0xff9503E3aEc502765C6CfC75fF3D75Db7e863640` |

Roles: deploy account `0x2044afD8D1bCE833d19F075cb729635a07d78e0C`.

Personas:
- Lena `0x80B9…06C3`
- Avery `0x40d8…8080`
- Brighton `0x700E…71b4`
- Rex `0xb522…CDEa`
- Sam `0xC8D6…8F27`
- farm accounts `0x3eFA…c1F6` and `0xC7bF…8581`

Key transactions:

| Step | Transaction |
| --- | --- |
| Pool deploy | `0xd2fd29e3…dd55` |
| Lines | `0xc691ff47…2ba7` |
| Avery backs Brighton | `0xc0c671e8…ee41` |
| Brighton borrows | `0x531ff0de…e5c5` / `0x9da2b14c…e3ad` |
| Brighton repays | `0x9fc09169…d6f2` |
| Rex stakes | `0x7b3194c4…8bb8` |

Broadcast logs: `run-1791061743878.json` and `run-1791062101644.json` in the same folders.

## Front end

`packages/nextjs/contracts/deployedContracts.ts` points at the live deployment. To use it, set `targetNetworks: [chains.baseSepolia]` in `packages/nextjs/scaffold.config.ts`. The relayer routes then need `RELAYER_PRIVATE_KEY` for a funded Base Sepolia account.

## Agent testbed

Agents test the live deployment through [microcredit-agent-testbed](https://github.com/scottonchain/microcredit-agent-testbed). It carries the onboarding, `quickstart.sh`, `metrics/pool_health.py`, the open tasks and the A2A agent card.
