# Microcredit contract and application

Read the testbed's [shared team operating guide](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/README.md)
and its current [world model](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/world-model/model.json)
at a named `main` commit before planning. Shared roles, privacy, public-content,
Git leases and communication live there. Ordinary internal messages go on board
#15 using TM2; email is sensitive-only. Local code and build guidance follows.

## Repository map

| Path | Owns |
| --- | --- |
| `packages/foundry/contracts/` | Pool, lens, score provider and router implementations |
| `packages/foundry/test/` | Contract unit, invariant and explicitly enabled fork tests |
| `packages/foundry/script/` | Local, testnet, candidate and production deployment/rehearsal entrypoints |
| `packages/foundry/scripts-js/` | CLI arguments, account helpers and ABI generation |
| `packages/nextjs/` | Next.js app and optional gasless relayer |
| `scripts/` | Local dev tools and candidate verification/evidence tools |
| `analysis/` | Four model suites behind the papers; each has a README and independent tests |
| `docs/` | Design, economics, integrity issues, deployment records and runbooks |
| `evidence/` | Immutable historical verification packets, corrections and receipts |

## Commands

Use the pinned Yarn release (`corepack yarn`, or
`node .yarn/releases/yarn-3.2.3.cjs`) and the Node version in `.nvmrc`.
Install with `yarn install --immutable`; initialize the pinned submodule with
`git submodule update --init --recursive`. Foundry and solc are required for
contract builds. Python model dependencies are in `analysis/requirements.txt`.
Dependency ownership, security overrides and the wallet URI backport are in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

| Purpose | Command from the root |
| --- | --- |
| Local node | `yarn chain` |
| Local deployment and generated ABI | `yarn deploy` |
| Development app | `yarn start` |
| Guided local demo | `yarn demo` |
| Contract tests | `yarn foundry:test` |
| All offline test suites | `yarn test:all` |
| Lint and types | `yarn lint`; `yarn next:check-types` |
| Production app build | `yarn next:build` |
| Static Base Sepolia app | `yarn workspace @se-2/nextjs build:static` |
| Local relayer crash rehearsal | `yarn workspace @se-2/nextjs relayer:crash-check` |

The static build writes `packages/nextjs/out/`; it does not publish. The site repo's
`pool/` is a generated release. Change this source, verify a new build and preserve
release holds before updating delivery files. Existing evidence is not regenerated
as a side effect of checks. Fork suites require the explicit RPC variables named
in their docs; skipped suites are not successful fork runs.

## Design sources

- [CREDIT_MODEL.md](docs/CREDIT_MODEL.md): conserved credit and its proofs.
- [CREDIT_INTEGRITY_ISSUES.md](docs/CREDIT_INTEGRITY_ISSUES.md): known issues and their
  exact dispositions; update this when behavior or a technical claim changes.
- [ECONOMICS.md](docs/ECONOMICS.md): accounting, returns and parameter choices.
- [TESTNET.md](docs/TESTNET.md): the recorded live deployment and receipts.
- [DEPLOYMENT.md](docs/DEPLOYMENT.md): production runbook and release gates.
- [BOOTSTRAP_ORDER_ROUTER.md](docs/BOOTSTRAP_ORDER_ROUTER.md),
  [TRANSITIVE_STAKE_ROUTER.md](docs/TRANSITIVE_STAKE_ROUTER.md), and
  [CANDIDATE_VERIFICATION.md](docs/CANDIDATE_VERIFICATION.md): candidate design and checks.
- [BOOTSTRAP_EXECUTION_PACKET.md](docs/BOOTSTRAP_EXECUTION_PACKET.md): the held
  execution draft, scope, ordered steps and unresolved operator decisions.

The main branch, candidate source, local test results and live bytecode are distinct.
Read each record's exact revision; do not replace old receipt hashes after a refactor.
The pool is close to EIP-170's size limit. Put derived views in `MicrocreditLens`;
contract edits require size, ABI, behavior and evidence review. Cleanup of scripts
or the app does not extend prior acceptance to newly changed contract code.

## Application boundaries

`utils/microcredit.ts` resolves the configured target chain, addresses and ABIs
from `contracts/deployedContracts.ts`; `scaffold.target.ts` fixes the target at
build time. ABI generation owns that file. The live deployment descriptor is
maintained in testbed `deployments/current.json`; the workspace checker verifies
that addresses, token and card mirrors agree with the generated app configuration.
`utils/metaTypes.ts` is the shared EIP-712 field schema; `eip712.ts` derives and
checks the token's permit domain. `utils/amounts.ts` owns exact USDC parsing and
rounding. Pages do not invent credit policy beyond the contract's own limit.

A static build has no server relayer: wallet-direct flows retain signer/chain,
mined-hash, stable-allowance and origination-intent checks. Local MockUSDC stays a
test fixture. Base Sepolia uses Circle test USDC and its faucet; no free-mint call
belongs in that live-token path. Admin/demo funding tools stay local.

The optional server relayer is in `app/api/meta/relayer.ts`. `relayerRequest.ts`
validates the request before it reaches chain code; all five routes share its
parsers. `relayerResponse.ts` accepts only a mined successful receipt: HTTP 202
is an unresolved transaction. The relayer checks the actual RPC chain before
using an account and requires a configured RPC for a public chain.

With `RELAYER_JOURNAL_PATH`, the journal persists the intent and signed bytes
before broadcasting. Same-intent concurrent calls share one operation; different
requests under the same nonce conflict. Recovery cannot abandon an operation
still active in that process, and receipt absence remains unknown. One process
owns a journal and relayer key: its queues and rate limiter are process-local.
A multi-instance deployment requires shared coordination; this repo does not
claim it. Keep raw transaction bytes and journal files outside public artifacts.

## Contribution rules specific to this repo

Run `scripts/check-public-content.sh` on the actual staged changes and commit
range. Only the published Anvil fixture keys in `script/Deploy.s.sol` and
`scripts-js/parseArgs.js` are permitted in their existing designated locations.
Commit with explicit noreply author and committer. Merge only from an authorized
checkout with a reviewed parent; do not use a merge that exposes personal email.
PR descriptions identify the actual AI writer and contain no session links.
