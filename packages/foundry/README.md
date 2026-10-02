# Foundry package

Contracts, Forge tests and deploy tooling. Run commands from the repo root (`yarn foundry:test`,
`yarn deploy`) or from this directory with `forge`.

| Path | Contents |
| ---- | -------- |
| `contracts/DecentralizedMicrocredit.sol` | Lending pool, loans, attestations, meta-transactions |
| `contracts/PageRank.sol` | On-chain PageRank, inherited by the main contract |
| `contracts/MockUSDC.sol` | 6-decimal ERC20 + ERC20Permit with open minting (local/test only) |
| `script/Deploy.s.sol` | Local deploy and demo seed (pool, background loans, personas) |
| `script/VerifyAll.s.sol` | Submits the latest deploy's contracts for explorer verification |
| `script/UpdateOracle.s.sol` | Points the contract's oracle at the caller |
| `scripts-js/` | `yarn deploy` (`parseArgs.js`), keystore helpers, ABI generator |
| `scripts-py/` | NetworkX baseline for `test/PageRankVerification.t.sol` |
| `test/` | Forge tests; shared fixture in `test/utils/MicrocreditTestBase.sol` |

## Deploying

```sh
yarn deploy
```

`yarn deploy` targets the local Anvil chain from `yarn chain`, creating the well-known
`scaffold-eth-default` keystore on first use. It writes `deployment.json` and regenerates
`../nextjs/contracts/deployedContracts.ts`.

`Deploy.s.sol` is local-only: it broadcasts with Anvil's published private keys. For a public
network, write a separate script whose contract is named `DeployScript` and run
`yarn deploy --file <Script>.s.sol --network <name>` with a keystore (`yarn account:generate`).

## USDC

`Deploy.s.sol` reuses the token recorded in `deployment-config.json` (`{"usdcAddress": "0x..."}`)
when that address has code on the target chain, for example after reloading a saved Anvil
state. Otherwise it deploys a fresh MockUSDC and records it there. The script mints MockUSDC to
seed the pool, so it only works with MockUSDC as written.
