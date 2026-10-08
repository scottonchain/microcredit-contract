# Verifying a candidate deployment

The candidate is three contracts: the pool (`DecentralizedMicrocredit`, with the manager gate), its lens, and **one**
manager, `BootstrapOrderRouter` (`BOOTSTRAP_ORDER_ROUTER.md`). `DeployBootstrapCandidate.s.sol` deploys exactly these
three; the order escrow and the unbound two-hop router are components that are not deployed.

`scripts/verify_candidate_deployment.py` (read-only, standard library plus `curl`) checks that what is on chain is the reviewed build:

```
python3 scripts/verify_candidate_deployment.py --rpc <url> --pool 0x.. --lens 0x.. --router 0x.. [--json]
```

Run `forge build` at the reviewed commit first (`packages/foundry/out`). For each contract it fetches the code, zeroes the immutable slots on both sides (the constructor writes them into the runtime code), and compares: `match_strict`, and `match_ignoring_metadata` (the CBOR trailer can differ between hosts). It reports size against EIP-170, the immutable values found and the sha256 of the compiled ABI, then reads the wiring through getters (pool token and parameters, `lens.pool`, `router.pool/token`). Exit 0 only if every contract matches without metadata and every wiring check holds.

## Build facts at the reviewed head

Evidence for one exact head is in `evidence/bootstrap-candidate-<head>/` (compiler and settings, sizes, ABI and normalized runtime hashes, complete test and invariant logs, checksums). Numbers in this document that are not in that directory are rehearsal observations, not evidence.

| Contract | Runtime bytes | EIP-170 margin | Masked-runtime sha256 (first 16) | ABI sha256 (first 16) |
| --- | ---: | ---: | --- | --- |
| `DecentralizedMicrocredit` | 24,538 | 38 | `cc979baa0d5e9c8f` | `f65f697ccfcbf964` |
| `MicrocreditLens` | 3,287 | 21,289 | `36f7956df62569da` | `cea757c169ae1215` |
| `BootstrapOrderRouter` | 16,748 | 7,828 | `0e50edf46df40f18` | `450c64afc05429c1` |

Solc 0.8.33, `via_ir`, optimizer 200 runs. The pool is byte-identical to the previous candidate (the repair touched the router only). Deploy gas for the three contracts: about 13.1 million (the script's own estimate; 0.000079 ETH at the 0.006 gwei `sepolia.base.org` quoted at about 17:15 UTC on 2026-10-08, the L1 data fee comes on top).

## Rehearsal (2026-10-08, local fork of Base Sepolia)

`anvil --fork-url https://sepolia.base.org --chain-id 84532`, then `forge script script/DeployBootstrapCandidate.s.sol --broadcast --unlocked` with a placeholder oracle: all three contracts strict-match, every wiring check passes. This rehearsal proves the build and the verifier, not a public deployment: no public-chain receipt exists until the reviewed packet is executed.

## End-to-end rehearsal with `cast`

`scripts/candidate_rehearsal.py run` replays what a custodian does on a public chain, with the real compiled contracts and Circle's USDC, on a local fork. It generates fresh in-memory keys per role (Anvil's well-known dev accounts carry EIP-7702 code on the public chain, so their signatures fail the pool's ERC-1271 path), funds them by impersonating a USDC holder, and:

1. a lender deposits 5 USDC; the worker names the router as its manager (before any backing); two roots deposit 1 USDC each;
2. a customer funds an exact order (a 1 USDC advance to a vendor, price 1.5 USDC); the roots and a mid sign `EdgeConsent`, the worker signs the pool's `BorrowAndDisburse` and the router's `AcceptOrder` (`cast wallet sign --data`; `candidate_rehearsal.py typed-data pool|consent|accept` prints the exact JSON);
3. negative controls by read-only call: direct `requestLoan` by the worker and `borrowAndDisburseMeta` by a stranger revert `NotManager`; a tampered vendor reverts `IntentMismatch`; a forged consent reverts; the unbound router's `originate` entry does not exist;
4. a stranger submits `originateOrder`: the vendor receives 1 USDC, the pool lends 1 USDC, the roots lock 0.6 and 0.4 USDC, the customer's escrow stays apart; a replay reverts;
5. the customer settles: the debt is repaid first, the worker receives the remainder (0.5 USDC), the roots' lot returns in the same transaction; roots and lender withdraw everything;
6. the aggregate USDC of every role, vault, pool and router is equal before and after (`--with-default` adds a second order that the customer refunds and nobody cures, defaulted after a fork time jump, labelled as time travel: the whole lot is attributed to the roots, 0.6 and 0.4 USDC, and lenders lose no principal).

Result at the reviewed head on fresh forks: both modes pass; aggregate 8,500,000 units before and after (10,000,000 with the default path). The same ordered calls on Base Sepolia, with the custodian's keystores in place of the throwaway keys, are the execution packet; the only direct worker transaction is `setManager` (gas the worker needs once).
