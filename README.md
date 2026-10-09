# Microcredit contracts and app

This repository maintains the Solidity lending contracts, the Next.js wallet interface, and local verification tools. The project's goal is measurable human benefit through useful work that independent customers accept and pay for. Credit is an optional way to cover a necessary input gap; evaluate it alongside customer prepayment, direct advance and no-loan alternatives. The current direction and decisions live in the [shared world model](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/world-model/README.md); [Credit Among Strangers](https://github.com/scottonchain/microcredit-vision) explains the work in plain language.

## What is live and what is under review

The existing Base Sepolia pool and its published app are a testnet demonstration. The bootstrap candidate binds origination to a customer-funded order and a one-use officer approval. It remains under review in [PR #28](https://github.com/scottonchain/microcredit-contract/pull/28); its G3 permission and public execution holds remain in place. A successful local test or build is not a new deployment or a release authorization.

Use the [canonical deployment record](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/deployments/current.json) for the live addresses and source identity. [Candidate verification](docs/CANDIDATE_VERIFICATION.md) and the [execution packet](docs/BOOTSTRAP_EXECUTION_PACKET.md) describe the separate candidate and its evidence. Historical receipts retain the revision they verified.

## Run the local demo

Use Git, Node **22.18 or newer**, the repository's pinned Yarn **3.2.3**, and Foundry. Initialize the OpenZeppelin submodule, install dependencies, then start the demo from this repository's root:

```bash
git submodule update --init --recursive
corepack enable
yarn install --immutable
yarn demo --manual
```

Open <http://localhost:3000>. The command starts Anvil, deploys and seeds the local contracts, and starts the app with switchable demo personas. Stop it with Ctrl-C. `yarn demo` adds the scripted browser walkthrough; `yarn demo --manual --reuse` resumes saved demo state. See [DEMO.md](DEMO.md) for personas, wallet modes, funding and troubleshooting.

For separate terminals, run `yarn chain`, then `yarn deploy`, then `yarn start`. `Deploy.s.sol` is the one local seeding implementation. `/fund` adds local ETH or MockUSDC; `/populate-test-data` points to this workflow. The local script uses published Anvil keys and must stay on the local chain.

## Source and commands

| Task | Maintained source or command |
| --- | --- |
| Contract implementation and Forge tests | `packages/foundry/contracts/`, `packages/foundry/test/`; `yarn foundry:test` |
| Local deployment and seed | `packages/foundry/script/Deploy.s.sol`; `yarn deploy` |
| Deployment CLI, keystores, generated app ABIs | `packages/foundry/scripts-js/`; [package guide](packages/foundry/README.md) |
| Wallet interface and optional server relayer | `packages/nextjs/app/`, `packages/nextjs/utils/` |
| App chain and address selection | `scaffold.target.ts`, `utils/microcredit.ts` and generated `contracts/deployedContracts.ts` inside `packages/nextjs/` |
| Local lifecycle and evidence verification | `scripts/`; `yarn demo`, `yarn restart`, `yarn test:scripts` |
| Economic models and reproducible results | `analysis/`; `yarn test:models` |
| Complete regression suite | `yarn test:all` |
| Lint, types and production app | `yarn lint`, `yarn next:check-types`, `yarn next:build` |
| Static app export | `yarn workspace @se-2/nextjs build:static` |

The static export targets the recorded Base Sepolia deployment and has no server relayer. The local dynamic app can use EIP-712 messages and USDC permits through `app/api/meta/`; transaction availability depends on the build and deployment. Wallet connection alone does not grant a contract role.

## Protocol and review guides

The pool accounts for lender shares, available liquidity, loan reservations and queued withdrawals. Backing commits existing credit or stake; it does not create credit by repeating endorsements. Loan APR is fixed at origination from the configured EFFR and risk premium. See the maintained documents for exact rules and assumptions:

- [Credit model and backing](docs/CREDIT_MODEL.md), [integrity findings](docs/CREDIT_INTEGRITY_ISSUES.md), and [economics](docs/ECONOMICS.md).
- [Bootstrap order router](docs/BOOTSTRAP_ORDER_ROUTER.md) and [readiness gates](docs/BOOTSTRAP_READINESS_20261009.md).
- [Existing testnet walkthrough](docs/TESTNET_WALKTHROUGH.md), [testnet setup](docs/TESTNET.md), and [deployment guide](docs/DEPLOYMENT.md).
- [Dependency security decisions](docs/DEPENDENCIES.md).

For contribution scope, verification and publication, read [CONTRIBUTING.md](CONTRIBUTING.md), the local [working instructions](CLAUDE.md), and the [shared team guide](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/README.md).

Licensed under the [MIT License](LICENCE).
