# Dependency maintenance

The application and Foundry helpers own their dependencies in their workspace
manifests. The root owns only repository tooling, the Yarn lockfile and the
explicit compatibility resolutions below. Do not add duplicate React, Next.js
or account/RPC libraries at the root.

## Security refresh, 2026-10-09

The cleanup updates Next.js and its ESLint configuration to 15.5.27, React and
React DOM to 19.0.8, and the compatible transitive dependency ranges. The
[Next.js September release](https://nextjs.org/blog/september-2026-security-release)
identifies 15.5.27 as the patched maintenance release. The account helpers now
use Foundry's own configuration and read commands, removing their duplicate
ethers and TOML parsers. Unused IPFS, Vercel and Uniswap dependencies are removed.

Root `resolutions` keeps PostCSS at 8.5.23 and the existing WebSocket major lines
at ws 7.5.11 / 8.21.0. Some upstream dependencies pin earlier patch versions;
the overrides must be checked in the resolved lockfile, not inferred from the
manifest. Refreshing dependencies requires the application tests, types, lint,
server build, static build and local relayer crash check.

## Wallet URI decoder backport

WalletConnect's query-string 7 consumer expects decode-uri-component 0.2.2 as a
callable CommonJS export. The patched upstream 0.5.0 release is ESM-only, so a
forced version substitution breaks that consumer. The Yarn patch in
`.yarn/patches/` backports the upstream 0.5.0 linear-time decoder while preserving
the older CommonJS export and surrounding decoding behavior.

Sources: [upstream decoder](https://github.com/SamVerschueren/decode-uri-component)
and [GHSA-vcc3-ghjq-m6fr](https://github.com/advisories/GHSA-vcc3-ghjq-m6fr).
The package's license is retained. The patch is applied by Yarn from the committed
manifest and lockfile; never edit an installed node_modules copy as the fix.

`walletUriCompatibility.test.ts` exercises the actual query-string consumer's
Unicode, plus, BOM, malformed encoding and round-trip behavior. A separate child
process bounds time and memory for the malformed-input regression. Remove this
backport only when the consumer can use a compatible upstream fix and those
checks still pass. A version-only audit will continue to flag 0.2.2; the patch and
regression are required evidence for the local mitigation.

## Limits and remaining upstream work

This is a tested dependency refresh, not a claim that all dependency advisories
are closed. The audit and its exact remaining dependency paths are recorded in
the cleanup review packet. The MetaMask dependency chain retains older uuid
versions; the inspected browser entries use v4/validation, rather than the
affected output-buffer APIs. Its separate malicious-debug advisory does not
establish installation of debug 4.4.2; the resolved version is checked explicitly.
Build-tool advisories also require separate upstream tracking.

Next.js has [announced another upstream security update for October 14,
2026](https://nextjs.org/blog/upcoming-nextjs-security-update-october-2026).
That release is not available at the time of this cleanup. Review and apply the
published fixes before treating this snapshot as current release approval.
Existing deployment and publication holds remain in force.
