# Verifying a candidate deployment

`scripts/verify_candidate_deployment.py` (read-only, standard library plus `curl`) checks that what is on chain is the reviewed build:

```
python3 scripts/verify_candidate_deployment.py --rpc <url> --pool 0x.. --lens 0x.. --escrow 0x.. --router 0x.. [--json]
```

Run `forge build` at the reviewed commit first (`packages/foundry/out`). For each contract it fetches the code, zeroes the immutable slots on both sides (the constructor writes them into the runtime code), and compares: `match_strict`, and `match_ignoring_metadata` (the CBOR trailer can differ between hosts). It reports size against EIP-170 and the immutable values found, then reads the wiring through getters (pool token and parameters, `lens.pool`, `escrow.pool/token`, `router.pool/token`). Exit 0 only if every contract matches without metadata and every wiring check holds.

## Rehearsal (2026-10-08, local fork of Base Sepolia, head c79ec53)

`anvil --fork-url https://sepolia.base.org --chain-id 84532`, then `forge script script/DeployBootstrapCandidate.s.sol --broadcast --unlocked` with a placeholder oracle: all four contracts strict-match, every wiring check passes. Build fingerprints (sha256 of the code with immutables zeroed), by contract: pool `cc979baa0d5e9c8f...`, lens `36f7956df62569da...`, escrow `63ed22a87ed80c76...`, router `cac9cc548bfabd0b...` (first 16 hex digits; the script prints them at any head and in `--json` in full). Sizes: pool 24,538 bytes (margin 38), lens 3,287, escrow 7,852, router 11,603. Deploy gas estimate for the four contracts: about 14.0 million gas (0.000154 ETH at 0.011 gwei).

This rehearsal proves the build and the verifier, not a public deployment: no public-chain receipt exists until the reviewed packet is executed.

## End-to-end rehearsal with `cast`

`scripts/candidate_rehearsal.py run` replays what a custodian does on a public chain, with the real compiled contracts and Circle's USDC, on a local fork (`anvil --fork-url https://sepolia.base.org --chain-id 84532`, then the deploy script). It generates fresh in-memory keys per role (Anvil's well-known dev accounts carry EIP-7702 code on the public chain, so their signatures fail the pool's ERC-1271 path), funds them by impersonating a USDC holder, and:

1. a lender deposits 5 USDC; the borrower names the router as manager (before any backing); a root deposits 1 USDC;
2. the root and a mid sign `EdgeConsent`, the borrower signs the pool's `BorrowAndDisburse` (`cast wallet sign --data`; `candidate_rehearsal.py typed-data` prints the exact JSON);
3. negative controls by read-only call: direct `requestLoan` by the borrower and `borrowAndDisburseMeta` by a stranger revert `NotManager`; a forged consent reverts;
4. a stranger submits `originate`: the vendor receives 1 USDC, the pool lends 1 USDC; a replay of the signed request reverts;
5. a stranger repays inside the first day; direct `requestLoan` still reverts; `sync` returns the lot; the root withdraws; the lender withdraws all;
6. the aggregate USDC of every role, the pool and the router is equal before and after (`--with-default` adds a second borrower that is never repaid and is defaulted after a fork time jump, labelled as time travel: the whole 2 USDC loss is attributed to the root and lenders lose no principal).

Result at head 4ebd1b9 on a fresh fork: both modes pass; aggregate 7,000,000 units before and after (8,000,000 with the default path). The same ordered calls on Base Sepolia, with the custodian's keystores in place of the throwaway keys, are the execution packet; the only direct borrower transaction is `setManager` (gas the borrower needs once).
