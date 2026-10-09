# Contributing

Start with the [README](README.md) for setup and the [shared team guide](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/README.md) for the current goal, source ownership and coordination. [CLAUDE.md](CLAUDE.md) records this repository's commands and boundaries. Keep changes tied to a concrete user need, defect or review gate.

## Change the maintained source

Use `packages/foundry/contracts/` for Solidity and `packages/nextjs/` for the app. The published site's `pool/` directory is a generated release, not a second app to edit. `scripts/demo.sh` and `script/Deploy.s.sol` own the local demo; extend them instead of creating another seed implementation.

The app reads generated contract declarations through `utils/microcredit.ts`. Regenerate declarations with `packages/foundry/scripts-js/generateTsAbis.js` from the appropriate compiled artifacts and broadcast records. The generator shares identical ABI constants across chains while preserving every chain's addresses and contract entries. Verify a generated diff against the intended deployment before committing it.

Reuse the existing amount, typed-data, wallet, relayer and evidence parsers. Add an abstraction only when it removes maintained duplication and preserves useful behavior. Preserve historical fixtures, receipts, source pins and unfavorable evidence; a new test result belongs to the revision tested.

## Verify the changed behavior

Run commands from the repository root:

```bash
yarn test:all
yarn lint
yarn next:check-types
yarn next:build
yarn workspace @se-2/nextjs build:static
```

`test:all` runs Forge, Python tooling, deployment CLI, app utilities and all four economic model suites. Install the model dependencies from `analysis/requirements.txt` when running those suites. Fork tests require the RPC/block inputs described in the [candidate verification guide](docs/CANDIDATE_VERIFICATION.md); report skips and their limits rather than counting them as passes. Changes to the server relayer also need `yarn workspace @se-2/nextjs relayer:crash-check`, which uses a disposable local chain.

Use focused regressions for actual failure modes. Report the tested revision, command results and remaining limitations in the PR. For Solidity changes, include the applicable invariant/rehearsal evidence and runtime-size result: the reviewed pool is close to the EIP-170 limit.

## Review and publication

Use one focused branch and explain the problem, the resulting behavior and verification. Keep generated artifacts and their producing source in the same review. Follow the shared guide's author/committer identity and public-content rules before publishing. Run `scripts/check-public-content.sh --range BASE..HEAD` with the actual review base, and `--text` with the proposed PR description file.

The bootstrap candidate remains subject to its G3 permission and execution gates. Merging maintenance code does not authorize contract deployment, parameter changes, public-chain transactions or replacement of the published app. Use the [execution packet](docs/BOOTSTRAP_EXECUTION_PACKET.md) for that separate decision.
