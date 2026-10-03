# Testnet deployment (Base Sepolia)

A deployment for persona testing by agents and people. It is a testnet with a free-mint token: nothing here has value, and this is not the production deployment (`DEPLOYMENT.md`).

## Addresses

Chain: Base Sepolia (84532), RPC `https://sepolia.base.org`. Deployed 2026-10-03 from commit `73cb3f6` (PR #5) with `script/DeployTestnet.s.sol`.

| Contract | Address |
| --- | --- |
| `DecentralizedMicrocredit` (pool) | `0xe3264D64cEF7C7675a548524D883b597e7894169` |
| `MicrocreditLens` | `0x01C0586B3Cef50b427411c1278Be25605e8329Dc` |
| `OracleScoreProvider` | `0x5bDe901dA88fc351d93B7cF7AaEb72Af55D38b02` |
| `MockUSDC` (public `mint`) | `0xff9503E3aEc502765C6CfC75fF3D75Db7e863640` |

Parameters:
- EFFR 433 bps plus a 500 bps risk premium: 933 bps APR.
- A full line is 100 USDC.
- The reserve share is 30% of interest.
- The issuance budget is 50 full lines, with the same cap per report.
- Scores go stale after 7 days.

Roles: owner, oracle, score reporter and guardian are all the deploy account `0x2044afD8D1bCE833d19F075cb729635a07d78e0C`. Its key exists only in the deploying agent's container. Handing these roles to the testbed operator (Hermes, `0x5e4dC7639D2b94006c51aD5373173f5e01c248F9`) is pending; until then, new lines can be issued only from that container.

Deploy transactions:

| Step | Transaction |
| --- | --- |
| MockUSDC | `0xad641afeaf718b1c6c506850c4c7190495610b41093a818ad55790ddddd7a3ae` |
| DecentralizedMicrocredit | `0xd2fd29e3a1ccc190c0a42c86f04900f8f07659556fa615f4299eda761daedd55` |
| MicrocreditLens | `0x0485cabf03f4f95384eb01ee0b8f5f17e243271a24087e3d9086baf11805d687` |
| OracleScoreProvider | `0x164f825c0d0dfa50fee55301a142a87fa46410b080cceff20a3c632dd4455584` |
| setLending, setScoreProvider, setReserveBps, setGuardian | `0x57224d2d…dd33`, `0x9d475f5b…cc4a`, `0x6da69156…f99a`, `0xf90bb48c…2bca` |

## Persona scenarios (real transactions)

`script/TestnetScenarios.s.sol` ran these as 72 transactions, all successful. Each claim is checked with `require`, refusals are simulated against the same state, and the results below were re-read from chain state afterwards.

| Scenario | Claim | Result | Key transactions |
| --- | --- | --- | --- |
| Liquidity | Lena (`0x80B9…06C3`) deposits 5,000 | pool `totalAssets` 5,000 | deposit `0x80d6bba0…17f8` |
| Credit moves, not copies (CI-4, the demo video) | The issuer grants Avery (`0x40d8…8080`) 92 and Brighton (`0x700E…71b4`) 25. Avery backs Brighton 50 | Avery's limit is 42 and Brighton's 75: 117 = 92 + 25 issued. Brighton borrows 40 and repays inside the first day | lines `0xc691ff47…2ba7`, back `0xc0c671e8…ee41`, borrow `0x531ff0de…e5c5` / `0x9da2b14c…e3ad`, repay `0x9fc09169…d6f2` |
| Fresh ring (CI-1, CI-2) | Ten fresh accounts try to back each other and to borrow | 10 backings refused (`InsufficientCredit`), 10 loans refused (`NoCredit`) | simulated; no gas spent |
| Staked ring | Rex (`0xb522…CDEa`) stakes 25 and backs five members with 5 each | They borrow exactly 25. More backing, passing backing on, and more borrowing are all refused | stake `0x7b3194c4…8bb8`; the members' five loans are left open for the default test |
| Recycled-seed farm (Theorem 3) | Sam (`0xC8D6…8F27`) stakes 25. The stake backs farm-0, which borrows and repays 25 four times inside the interest-free day, then moves on to farm-1 | Both farm accounts (`0x3eFA…c1F6`, `0xC7bF…8581`) have 4 completed loans and 0 granted credit | farm-0's first loan `0xf47747ad…dbaa` / `0x91b73d45…3e5b` / `0xdf459352…5358` |
| Issuance budget (CI-22) | The reporter tries to issue 49 more full lines past the remaining budget | refused (`IssuanceBudgetExceeded`) | simulated |

The persona keys derive from the deploy key. Rerunning the script skips steps that are already done.

## Time-dependent scenarios (fork of the live deployment)

Due dates and defaults cannot be waited out on a testnet. `test/fork/LiveDeployment.t.sol` forks Base Sepolia at the live state, moves the clock past due date plus the late period, and defaults every open loan. Both checks pass:

- **Staked ring:** its defaults are paid by Rex's slashed stake, and lenders lose nothing (`totalAssets` does not fall).
- **Brighton's unsecured default:** he borrows his full 75, with 25 of his own and 50 from Avery, and defaults. Avery's committed 50 is burned. Lenders lose at most the unpaid 75, within Theorem 2's bound of the lines issued to the two of them (117). Brighton cannot borrow again.

```bash
LIVE_RPC_URL=https://sepolia.base.org LIVE_POOL=0xe3264D64cEF7C7675a548524D883b597e7894169 \
LIVE_AVERY=0x40d8FC73e9e9582367Af755F3Ec1b57FafD48080 LIVE_BRIGHTON=0x700E5c4a840b9034aF3A9d99607120d83aC071b4 \
LIVE_REX=0xb522B9A73Fc92d664D339fD0B38505d950b0CDEa forge test --match-path test/fork/LiveDeployment.t.sol -vv
```

## Front end

`packages/nextjs/contracts/deployedContracts.ts` includes this deployment. To use it, set `targetNetworks: [chains.baseSepolia]` in `packages/nextjs/scaffold.config.ts`. The relayer routes then need `RELAYER_PRIVATE_KEY` for a funded Base Sepolia account.

## Agent testbed

Agents test this deployment through [microcredit-agent-testbed](https://github.com/scottonchain/microcredit-agent-testbed), which carries the onboarding, the open tasks and the A2A agent card.
