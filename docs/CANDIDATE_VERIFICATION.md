# Verifying a candidate deployment

`scripts/verify_candidate_deployment.py` (read-only, standard library plus `curl`) checks that what is on chain is the reviewed build:

```
python3 scripts/verify_candidate_deployment.py --rpc <url> --pool 0x.. --lens 0x.. --escrow 0x.. --router 0x.. [--json]
```

Run `forge build` at the reviewed commit first (`packages/foundry/out`). For each contract it fetches the code, zeroes the immutable slots on both sides (the constructor writes them into the runtime code), and compares: `match_strict`, and `match_ignoring_metadata` (the CBOR trailer can differ between hosts). It reports size against EIP-170 and the immutable values found, then reads the wiring through getters (pool token and parameters, `lens.pool`, `escrow.pool/token`, `router.pool/token`). Exit 0 only if every contract matches without metadata and every wiring check holds.

## Rehearsal (2026-10-08, local fork of Base Sepolia, head c79ec53)

`anvil --fork-url https://sepolia.base.org --chain-id 84532`, then `forge script script/DeployBootstrapCandidate.s.sol --broadcast --unlocked` with a placeholder oracle: all four contracts strict-match, every wiring check passes. Build fingerprints (sha256 of the code with immutables zeroed), by contract: pool `cc979baa0d5e9c8f...`, lens `36f7956df62569da...`, escrow `63ed22a87ed80c76...`, router `cac9cc548bfabd0b...` (first 16 hex digits; the script prints them at any head and in `--json` in full). Sizes: pool 24,538 bytes (margin 38), lens 3,287, escrow 7,852, router 11,603. Deploy gas estimate for the four contracts: about 14.0 million gas (0.000154 ETH at 0.011 gwei).

This rehearsal proves the build and the verifier, not a public deployment: no public-chain receipt exists until the reviewed packet is executed.
