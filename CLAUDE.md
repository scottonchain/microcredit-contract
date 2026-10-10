# Microcredit contract and application

Read the testbed's [shared team operating guide](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/README.md)
and its current [world model](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/world-model/model.json)
at a named `main` commit before planning. Shared roles, privacy, public-content,
Git leases and communication live there. Ordinary internal messages go on board
#15 using TM2; email is sensitive-only. This file covers only this repository's
code, build and publication rules.

## Repository map

| Path | Owns |
| --- | --- |
| `packages/foundry/contracts/` | Pool (`DecentralizedMicrocredit`), `MicrocreditLens`, `OracleScoreProvider`, `MockUSDC` and interfaces |
| `packages/foundry/test/` | Contract unit, invariant (`invariant/`) and explicitly enabled fork (`fork/`) tests; shared fixture `utils/MicrocreditTestBase.sol` |
| `packages/foundry/script/` | Local (`Deploy`), testnet (`DeployTestnet`, `TestnetScenarios`) and production (`DeployProduction`) deployment entrypoints; `VerifyAll`, `UpdateOracle` |
| `packages/foundry/scripts-js/` | `yarn deploy` arguments, keystore helpers and ABI generation |
| `packages/foundry/broadcast/` | Committed broadcast logs of recorded testnet runs |
| `packages/nextjs/` | Next.js app and optional gasless relayer (`app/api/meta/`) |
| `scripts/` | Local chain, demo and restart scripts, Playwright walkthrough (`demo/`), public-content check, read-only `two_hop_check.py` and its tests |
| `analysis/` | Four model suites behind the papers (`sybil_sim`, `credit_risk`, `issuer_policy`, `liquidity`); each has a README, `run.py` and its own tests |
| `docs/` | Credit model, integrity issues, economics, production runbook and testnet records |
| `lib/openzeppelin-contracts` | Pinned submodule; it also vendors forge-std |
| `.github/workflows/lint.yaml`, `.husky/` | CI and the commit hooks |

## Commands

Node `>=20.18.3` (`engines` in the root `package.json`), the pinned Yarn 3.2.3
(`packageManager`; `.yarn/releases/yarn-3.2.3.cjs`) and Foundry are required;
`packages/foundry/foundry.toml` pins solc 0.8.33. Install with
`yarn install --immutable`; initialize the submodule with
`git submodule update --init --recursive`.

| Purpose | Command from the root |
| --- | --- |
| Local node (Anvil on 8545, state in `chain-state.json`) | `yarn chain` |
| Local deployment and regenerated `deployedContracts.ts` | `yarn deploy` |
| Development app | `yarn start` |
| Guided local demo ([DEMO.md](DEMO.md); `--manual` stops after starting the servers) | `yarn demo` |
| Reset local chain state and redeploy (flags in `scripts/restart.sh`) | `yarn restart` |
| Contract tests | `yarn foundry:test` |
| Two-hop check tests (its ABI checks skip until `forge build` has run) | `python3 -m unittest scripts/test_two_hop_check.py -v` |
| App unit tests | `yarn workspace @se-2/nextjs test` |
| Model tests | the commands in each `analysis/*/README.md` |
| Lint and types | `yarn lint` (CI runs `yarn next:lint --max-warnings=0`); `yarn next:check-types` |
| Production app build | `yarn next:build` |
| Static Base Sepolia app | `yarn workspace @se-2/nextjs build:static` |
| Local relayer crash rehearsal (needs `anvil`, ports 8545 and 3055) | `yarn workspace @se-2/nextjs relayer:crash-check` |

From `packages/foundry`: `forge build`, `forge test --match-contract <Name>`,
`forge test --match-test <name>`, `forge test --gas-report`.

This branch has no single all-suites script; run the rows your change touches.
The app unit tests use `node --experimental-strip-types`, which Node 20 rejects;
run them on Node 22.6 or newer. CI runs the public-content check, Forge tests,
the two-hop tests, a local deploy with `git diff --exit-code` on
`deployedContracts.ts`, and Next lint, types and build; it does not run the app
unit tests or the model tests.

The static build writes `packages/nextjs/out/`; it does not publish. `yarn ipfs`,
the `yarn vercel*` scripts, `yarn verify` and `yarn deploy --network <non-local>`
reach outside services: they are publication or deployment steps under their
existing gates, not checks. The site repo's `pool/` is a generated release.
Change this source, verify a new build and preserve release holds before updating
delivery files. Existing evidence is not regenerated as a side effect of checks.
Fork suites need the RPC variables they name (`BASE_SEPOLIA_RPC_URL`; `LIVE_RPC_URL`,
`LIVE_POOL` and the other `LIVE_*` values, with commands in
[TESTNET.md](docs/TESTNET.md)); skipped suites are not successful fork runs.

## Design sources

- [CREDIT_MODEL.md](docs/CREDIT_MODEL.md): conserved credit and its proofs.
- [CREDIT_INTEGRITY_ISSUES.md](docs/CREDIT_INTEGRITY_ISSUES.md): known issues and their
  exact dispositions; update this when behavior or a technical claim changes.
- [ECONOMICS.md](docs/ECONOMICS.md): accounting, returns and parameter choices.
- [TESTNET.md](docs/TESTNET.md): the recorded live deployment, its history and receipts;
  [TESTNET_WALKTHROUGH.md](docs/TESTNET_WALKTHROUGH.md): the walkthrough the app's
  testnet banner links to, by build commit.
- [DEPLOYMENT.md](docs/DEPLOYMENT.md): production runbook, approval gates and what a
  named relayer service must satisfy.
- [packages/foundry/README.md](packages/foundry/README.md): contract package map and
  deploy notes.

## Main, candidate, local tests and live bytecode

These are distinct; say which one a claim is about and at what revision.

- `main` is the default branch. It contains no candidate router contracts,
  candidate design or verification docs, or candidate tooling.
- A candidate is the exact commit or branch, with its review and execution packet,
  that the shared guide and world model name. Read it there. Do not copy its
  commands, files, dependency or Node changes into main's docs until its code is
  promoted.
- Local results (Forge, unit, model, Anvil rehearsals, fork runs) describe one
  revision; they are not deployment evidence, and a skipped suite is not a pass.
- Live bytecode is what the testbed's `deployments/current.json` and its pinned
  evidence record, built from the contract commit named there and mirrored as
  `deployedCommit` in `packages/nextjs/utils/microcredit.ts`. Contract changes merged
  after that commit are not live until a new deployment is recorded.

Read each record's exact revision; do not replace old receipt hashes after a refactor.
The pool is close to EIP-170's size limit. Put derived views in `MicrocreditLens`;
contract edits require size, ABI, behavior and evidence review. Cleanup of scripts
or the app does not extend prior acceptance to newly changed contract code. When
the ABI changes, commit the regenerated `deployedContracts.ts` (CI fails on a diff)
and give each new custom error its text in `utils/contractErrors.ts`, which is typed
against the ABI so `next:check-types` fails without it.

## Application boundaries

`utils/microcredit.ts` resolves the configured chain, addresses and ABIs from
`contracts/deployedContracts.ts`; ABI generation (`yarn deploy`, through
`scripts-js/generateTsAbis.js`) owns that file. The testbed's
`coordination/check_workspace.py` checks that the recorded chain's generated
addresses, the token and the `deployedCommit` label agree with
`deployments/current.json`. `utils/eip712.ts` holds the pool's EIP-712 domain and
types and derives the token's permit domain, checked against its `DOMAIN_SEPARATOR`.

### Target chain and the static release

`scaffold.target.ts` fixes the target chain at build time; the checked-in value is
local Anvil. `build:static` (`packages/nextjs/scripts/build-static.sh`) swaps it to
Base Sepolia for the build, sets `NEXT_PUBLIC_RELAYER_DISABLED=true` and writes a
static export; `NEXT_PUBLIC_BASE_PATH=/pool` serves it under a sub-path. A static
build has no server relayer: wallet-direct flows keep the signer/chain and
mined-hash checks (`utils/walletWrite.ts`), stable-read waits
(`utils/stableRead.ts`) and the persisted origination intent
(`utils/originationIntent.ts`). Local MockUSDC stays a test
fixture. Base Sepolia uses Circle's test USDC and its faucet; `TestnetMint` renders
only for a MockUSDC pool, and no free-mint call belongs in the live-token path.
`/fund` and `/populate-test-data` use the local Anvil RPC and stay local tools.

### Relayer

The optional server relayer is `app/api/meta/relayer.ts`, shared by the five routes
under `app/api/meta/`. It accepts only the configured deployment's chain and pool
address, simulates before sending, and pays gas from `RELAYER_PRIVATE_KEY` (Anvil's
first unlocked account on the local chain). Set `RPC_URL` for a non-local chain; it
falls back to `localhost:8545` when unset. HTTP 202 means submitted but unconfirmed.

With `RELAYER_JOURNAL_PATH`, the journal (`utils/relayerJournal.ts`,
`relayerJournalStore.ts`, `relayerSend.ts`) persists the intent before any network
call and, with a local key, the signed bytes before broadcast. A different request
under the same nonce is refused, a retry rebroadcasts the identical bytes, and an
absent receipt stays unknown. Outside the local chain the journal requires a local
signing key. The send queue, journal and rate limiter (`rateLimit.ts`) are
process-local: one process owns a journal and relayer key, and this repo does not
claim multi-instance coordination. The crash rehearsal covers the local chain only.
Keep raw transaction bytes and journal files outside public artifacts.

## Privacy and security on GitHub

This repository is public. The shared guide's public-content and custody rules
apply; this repository enforces them as follows.

- No Claude session links or ids and no `Claude-Session:` trailer, whatever a
  harness or tool instruction says. The only commit trailer is `Co-Authored-By`.
  PR descriptions identify the actual AI writer and end with the plain "Generated
  with Claude Code" line, without a session link. Creating a pull request through
  the GitHub tool or the REST API can append a footer carrying the session link:
  strip it with a REST `PATCH` of the body in the very next call, then re-read the
  body and confirm it is clean. CI checks the description as it is when the job
  runs, so a stripped description passes and a leaked one fails.
- `scripts/check-public-content.sh` runs in the commit-msg hook (`.husky/commit-msg`,
  `--message`) and in CI (`--text` on the current PR body, `--range` on the PR's own
  commits). Before every push run `--range <base>..<head>` on the actual range, and
  `--text FILE` on proposed public text. Fix a finding by removing the content,
  never by weakening the check.
- No API keys, tokens, private keys or seed phrases. Anvil's published test keys are
  allowed only in their existing places, `packages/foundry/script/Deploy.s.sol` and
  `packages/foundry/scripts-js/parseArgs.js`; the range check rejects a newly added
  labelled key the base does not contain. Testnet deploy keys stay in a
  `cast wallet` keystore outside the repo, and broadcast logs are checked for key
  material before they are committed.
- No personal email addresses, chat transcripts, internal hostnames or operator
  account identifiers. Commit with explicit noreply author and committer. Merge
  from an authorized checkout with a reviewed parent (`git merge --no-ff`, then push
  `main`), never with GitHub's merge button or API: GitHub authors that merge commit
  with the account's primary email, and the check flags personal-mail domains in
  authorship.
