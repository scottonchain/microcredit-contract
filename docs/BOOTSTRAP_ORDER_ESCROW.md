> **SUPERSEDED (2026-10-08).** `BootstrapOrderEscrow` depended on the per-borrower manager (`setManager`, `managerOf`), which the pool no longer has: the pool now names one immutable originator (CI-31, CI-32) and `BootstrapOrderRouter` composes this adapter's funded exact order, debt-first settlement and refund with the two-hop stake and the officer gate. The contract and its tests were removed; this note stays as the record of the first design (its acceptance criteria were met by the router's tests).

# Funded-order adapter (`BootstrapOrderEscrow`)

An external testnet adapter that lets a consenting customer's funded order pay a worker's pool loan first. It is the
reworked form of the Codex lane's prototype (contract issue 7, comment 6060173729): the two admission races found in
its review (contract issue 27, comments 6060247713 and 6061224570) are closed by the pool's manager gate, not by
convention. Not a human-lending release; no economic-demand claim.

## Flow, in order

1. The worker names the adapter as its manager: `pool.setManager(escrow)`. This must come **before any backing exists**;
   it is one direct transaction by the worker (a one-time onboarding gas cost, counted as a subsidy in the receipts).
2. A sponsor stakes and backs the worker (`stake`, `back`). The sponsor should read `pool.managerOf(worker)` first.
3. The customer funds an order: `fund(intent, price, maxDebt, settleBy)`. The intent is the pool request, field for field
   (worker, vendor, amount, term, max APR, the worker's pool nonce, the pool request deadline) plus a job hash. The funding
   commits to its EIP-712 hash, which binds the pool and the token.
4. The worker signs two things: the pool's `BorrowAndDisburse` for exactly that intent, and the adapter's `AcceptOrder`
   (customer, price, cap, window, intent hash). The adapter's domain binds the chain and the adapter.
5. Anyone submits `originate(orderId, request, poolSig, orderSig)`. The adapter checks the order is funded and in window,
   every request field equals the intent, the pool names it as the worker's manager and the worker's consent is valid
   (ERC-1271 accepted), marks the order bound, calls `pool.borrowAndDisburseMeta` as the manager and checks the new loan
   (borrower, principal). The worker needs no ETH.
6. On delivery the customer calls `settle`: the debt is repaid first from the escrow, the worker receives the remainder.
   If the debt has grown past the cap or the price, settlement is refused and the funds stay escrowed.
7. Or the customer calls `refund` at any time; anyone may call it after `settleBy`.

## What the gate buys

- A loan made before the order cannot be attached to it: no loan for the worker can exist outside `originate`.
- After a refund the commitment is consumed (`originate` reverts `InvalidOrder`), and the signed advance cannot be
  broadcast anywhere else: the pool refuses any caller but the manager (`NotManager`).
- Direct repayment by anyone frees pool capacity for the worker, but nothing but the adapter can use it.

## Limits, stated

- Refund after origination leaves the worker's debt and the sponsor's exposure in place; the customer may reject, the
  worker and sponsor carry that risk. A late settlement is refused above the cap and the customer can refund.
- The relayer whitelist, if enabled, must name the adapter (`setRelayerWhitelisted`); the deploy script does not enable it.
- Onboarding (`setManager`) is a direct worker transaction. A relayed variant did not fit the pool's size headroom.
- One adapter per worker. The adapter trusts only the pool's own `usdc`.
- This is the one-hop mechanism. It does not implement transitive trust.
