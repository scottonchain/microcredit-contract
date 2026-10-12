# Trust for new members: a conserved-trust design for the revolving first-job guarantee

Status: **revision 5, after Codex's devil's-advocate reviews and the polling session's non-author
review** (contract PR 28, reviews 5484296919 and 5484377736; board 15 `c-20261011-guaranteetrust-review-r1`;
section 12 records each finding and fix). Written by Claude Code (AI agent) on 2026-10-11
at the operator's direction. Testnet only. No real money, no outreach, no live guarantee. The
operator's questions, the answer, every parameter and its reason, and what the contract
(`GuaranteeTrust`) and the agentic simulations must show. Revision 5 is deployed on Base Sepolia
with MockUSDC, and its seven scenarios ran there on 2026-10-12; [TESTNET.md](TESTNET.md) has the
addresses, transactions and final ledger.

## 1. The questions

The operator asked for a trust network for new members: an existing member who has or had trust can
attest to a new member. Determine every parameter:

- Does paying the first-job commission (the revolving guarantee's replenishment contribution) give
  trust?
- Does staking in the common pool?
- Do second- or third-degree attestations?
- If a trust network is not the right solution, find the right one.

## 2. The answer in one paragraph

A plain attestation network is the wrong primitive. An attestation that costs nothing can be
manufactured: a ring of fake members can attest to each other without limit, and no rule that reads
the shape of the graph can tell a ring of fakes from a real community (Douceur 2002; Cheng and
Friedman 2005; `CREDIT_MODEL.md`, the spine). The right primitive is the one this project already
proved for lending: **trust is a liability of someone**. Every unit of guarantee capacity a newcomer
holds must be underwritten by someone's cash at stake, by dues irrevocably paid into the reserve, or
by an accountable issuer's budgeted line. An attestation moves underwriting from the attester to the
newcomer; it never creates it. Then a ring of fakes can take at most the trust that real stake,
real dues or a real issuer put into it, and a thousand fake accounts take no more than one.

## 3. Roles

| Role | Who | What it can do |
| --- | --- | --- |
| Sponsor | anyone, typically the operator | funds the reserve and holds shares of the sponsor capital; a line-backed loss lowers every funder's shares pro rata; the owner can return capital only to a funder, up to its shares' current value, never dues, never the capital behind lines and never while a guarantee is open |
| Member | a newcomer or an established worker | holds trust; consents to its attesters; signs its acceptance of each guarantee; remits contributions |
| Attester | any member with free trust of their own | backs a newcomer with part of that trust |
| Issuer | an accountable programme that vets newcomers | sets small lines within an on-chain budget |
| Adjudicator | the operator or a programme it names | submits guarantees the worker has signed; records client payment or nonpayment with an evidence hash before the settle-by date. A single adjudicator is acceptable only for synthetic, root-controlled testnet mechanics; human use needs independent confirmation and appeal |
| Client | an independent payer, identified by a hash, with a canonical group (a common parent or payer) named in the worker-signed terms | owes the wage; at most one open guarantee; its group carries at most `maxGroupShareBps` of the reserve; one default blocks the client and its whole group |
| Guardian | the operator | pauses new guarantees |

## 4. Where trust comes from: the parameters

`T(m) = stake(m) + dues(m) + line(m)` is a member's own trust; `B(m)` is backing received.

| Source | Gives capacity? | How much | Why |
| --- | --- | --- | --- |
| **Issuer line** (programme vetting) | Yes, **only for the member's own guarantees** | at most `lineCap` per member (testnet: 20 USDC, one guarantee), within the issuer's total budget `issuerBudget` | an accountable party bears the misjudgement of the person it vetted, and no one else: a line cannot be attested onward, or the issuer would stand behind people it never saw; the budget holds every line, a line can be lowered only to what is committed, and claims spend budget permanently, so it cannot be rotated away from open exposure (`CREDIT_MODEL.md`, Theorem 2') |
| **Stake in the common pool** | Yes, 1:1, but **only to back others** | the member's locked stake | stake is cash at risk; using a worker's own stake for their own guarantee would charge them cash for their client's default, which the operator ruled out |
| **First-job commission** (contribution paid after a client pays) | Yes, exactly 1:1 for what is paid, usable both for the member's own guarantees and to back others | `r` per paid job: `contributionBps` of the wage, capped at `contributionCap` (testnet: 5%, 3 USDC) | it is irrevocably in the reserve, so it is the dues bound: history earns no more than it put out of reach (Theorem 3); a colluding client and worker buy capacity only at its full price |
| **Repayment and paid-job history** (counts) | **No** capacity; information only | appears in the score | any rule granting more than dues for history can be farmed with recycled capital (Theorem 3) |
| **Attestation** from a member with free trust, **with the member's consent** | Yes, conserved | up to the attester's free trust; at most `attestCap` per newcomer (20 USDC) and `maxOpenAttestees` newcomers per attester (5) | trust is risk; the attester's backing absorbs claim losses first, so it works through selection and monitoring (Stiglitz 1990; Ghatak and Guinnane 1999) |
| **Second- or third-degree** (passing on received backing) | **No** | 0 | relaying multiplies what the same attack edges can take by 3.3 to 7 times and charges people who never chose the borrower (`CREDIT_MODEL.md` section 6, `analysis/liquidity`); a newcomer backs others only with trust of their own |
| **"Had" trust** (a past member) | Only trust still held | current free `T` | spent or lost trust is gone; past conduct is in the score |

## 5. The guarantee and the loss order

**Capacity.** A member's guarantee capacity is free received backing + free line + free dues (dues not
already standing behind backing the member gave). Stake is not counted for the member's own guarantees,
and only stake and dues can back others (section 4).

**Opening a guarantee.** The worker signs an EIP-712 acceptance of the exact terms: client, client group,
amount `G`, the most of its own dues it agrees may stand behind `G`, the terms hash, the contribution
policy in force, a settle-by date (at most `maxTerm`, 60 days), a nonce and a signature deadline. The
adjudicator submits it; a gasless relay may carry it, but no role can open a guarantee the worker did
not sign, and the worker can revoke the nonce before use. The contract then requires:

- `G ≤ capacity(w)`, with the dues part no larger than the worker's pledge;
- `G ≤ maxShareBps` of the reserve (testnet: 20%, a fifth);
- outstanding exposure plus `G` leaves at least `floorMultiple × G` in the reserve (testnet: 2);
- the client has no open guarantee, and neither the client nor its group has a recorded nonpayment;
- the group's open guarantees plus `G` stay within `maxGroupShareBps` of the reserve (testnet: 30%);
- the worker has no unpaid contribution.

`G` is committed against the worker's capacity, backing first, then the issuer line, then pledged dues.
Each attester's share of the backing is fixed when the guarantee opens, pro rata to its unlocked
backing, and stays locked until the guarantee ends. A later attester neither takes on that risk nor
unlocks an earlier attester's share.

**Client pays.** The adjudicator records the wage. The contribution due is
`min(wage × contributionBps, contributionCap)`, at the policy the worker signed, even if the owner has
changed the parameters since. The worker (or anyone for them) remits it within
`remitWindow` (14 days). It goes to the reserve and adds the same amount to the worker's dues. The
commitment is released.

**Worker does not remit.** After the window anyone may mark it lapsed. The worker cannot receive a
new guarantee until it is paid. It is never pursued as a debt (`NORTH_STAR`: a pledge, not a loan).

**Nobody settles.** After the settle-by date the adjudicator can no longer mark the job paid or pay a
claim, and anyone may expire the guarantee: everything is released, no claim is paid and no
contribution falls due. A lost adjudicator therefore locks capacity for at most `maxTerm`.

**Client does not pay** (claim). The adjudicator confirms with an evidence hash. The reserve pays the
worker `G`, and the worker owes nothing. The capacity that underwrote `G` is consumed in the order it
was committed:

1. each attester's share, fixed at opening (its stake first, which returns that cash to the reserve,
   then its dues);
2. the issuer line (its budget stays spent);
3. the worker's dues, only up to what it pledged in the signed terms. Prior contributions absorb a claim
   only with that explicit, informed agreement, and no new worker debt is ever created.

The client and its group are recorded as nonpayers. Consuming capacity is not a debt: the worker keeps the `G`,
and no cash is taken from them. It is what keeps the loss bound. Without it, the same capacity could
be claimed against again and again.

**Loss bound.** Total claims are at most issuer budgets spent + dues paid + backing from real
attesters' trust, which itself comes from their stake, dues and lines. A ring that controls workers,
clients and attesters can extract only the trust rooted in it from outside: issued lines and stake
it put up. The dues it paid come back at most one for one.

## 6. Scores: information, never capacity

The contract keeps per-member history:

- guarantees opened, paid and claimed;
- contributions remitted and lapsed;
- attestations given, with the outcomes of the members attested;
- attestations received.

A `score` view returns these components and a simple composite for display and for the issuer's
off-chain policy. Capacity never reads the score. That is the dues bound again: a score anyone can
raise by repetition cannot be allowed to create capacity.

## 7. Attacks and what stops them

| Attack | Bound |
| --- | --- |
| Ring of fake workers and clients claiming nonpayment | claims consume capacity that only stake, dues or an issuer can create; a ring with none gets nothing |
| Farming dues with a fake client | buys capacity 1:1 for what it pays; claiming it back returns at most what it paid |
| Unsolicited attestations filling a newcomer's attester slots | the member's consent is required, by its own transaction or its own signature (a relay may submit it); no role can consent for a member |
| Adjudicator or issuer opening a guarantee, or creating a contribution duty, the worker never accepted | a guarantee opens only on the worker's EIP-712 acceptance of its exact terms; forged, altered, replayed, revoked and expired signatures are refused |
| A later attester unlocking an earlier attester's share | shares are fixed per guarantee at opening |
| Attester backing its own sock puppet | loses its own backing; extraction ≤ its own trust |
| Rotating an issuer line through many accounts | budget charged on the highest line held until released |
| One client failing many workers at once | one open guarantee per client; one group cap across a parent's branches; a default blocks the whole group; attester cap on open attestees |
| A client returning under a new id | caught only if the signed terms bind it to its group: client identity is checked off chain by whoever writes the terms (tested as a stated limit) |
| A lost or stalled adjudicator | settle-by date in the signed terms; anyone may expire an unsettled guarantee after it |
| Compromised adjudicator approving false claims | bounded by committed capacity and the reserve; the main trust assumption, stated; a two-of-n adjudicator is the next step |
| One address holding owner, issuer and adjudicator | held lines never exceed the sponsor capital (net of line-backed losses), so even a captured issuer and adjudicator together can pay claims only from sponsor capital and committed backing, never from members' dues; the simulations use three distinct keys (owner and sponsor, adjudicator, issuer) |
| Releasing sponsor capital that stands behind issuer lines, or the loading behind open guarantees | nothing is released while any guarantee is open, and never the capital behind held lines |
| A later funder's deposit repaying an earlier funder's loss | funders hold shares of the sponsor capital; a line-backed loss lowers every share, and a release burns shares at current value |
| A former owner keeping pause power | a guardian that was the old owner follows ownership on transfer |
| Reserve run | exposure cap per guarantee, floor, outstanding ≤ reserve |

## 8. What stays off-chain

- identity checks (the issuer's);
- the evidence of payment and nonpayment (only its hash goes on-chain);
- the randomised offer, seeded and published (by job, client or worker, never by competing
  applications);
- the legal check that a worker-paid contribution is permitted (ILO Convention 181, article 7, where
  it applies).

## 9. Is a trust network the right solution?

Not as attestation alone. As conserved trust with three roots and one hop, yes: it is the minimum
that keeps a bound. For a true newcomer the decisive root is the accountable issuer, because a
newcomer has no stake and no dues. Attestation adds capacity only where a real member is willing to
bear the risk. If no programme will act as issuer, the sponsor can be the issuer: the reserve is
then also the issuer's first-loss capital, and the line budget is a fraction of it.

## 10. What the contract and the simulations must show

`GuaranteeTrust` encodes:
- stake, dues, lines, backing, capacity and commitments;
- guarantees and their lifecycle;
- the history counters and the score;
- events for every change, so the full history of backing, payment, contribution and claims can be
  rebuilt from the chain.

The agentic simulations on Base Sepolia run:
- honest newcomers with an issuer line and an attester;
- a client nonpayment, paid by the reserve with the loss falling on the backing;
- a non-remitting worker;
- a collusion ring trying to claim against a fake client;
- five clients that are branches of one parent: the group cap, then the parent's default.

Each run reports both scorecards and the receipts.

## 11. Questions for the devil's advocate

1. Is consuming a worker's dues on a genuine client default fair, or should only backing and lines be
   consumed, with the reserve absorbing the rest?
2. Should a newcomer's first guarantee require both an issuer line and an attester, or either?
3. Is one hop too strict for newcomers in tight communities? Is two-hop with opt-in relaying worth its
   larger loss constant?
4. Is the adjudicator an acceptable trust assumption for a testnet, and what is the cheapest credible
   second check?
5. What does this design get wrong that a ring of agents will find first?

## 12. Codex's devil's-advocate review and revision 2

Codex reviewed the design and the contract at `ef8dec8` (source `c150af0`) and required changes before any
public-testnet deployment. Each finding and its fix:

| Finding | Fix in revision 2 | Regression |
| --- | --- | --- |
| P0: the worker never opts in; the issuer can assert attestation consent | EIP-712 `Acceptance` signed by the worker binds client, group, amount, dues pledge, terms hash, contribution policy, settle-by, nonce and deadline; `setConsentFor` removed, consent by the member's transaction or `setConsentBySig` | `testAdjudicatorCannotOpenAGuaranteeTheWorkerDidNotSign`, `testNoRoleCanFabricateConsent`, `testWorkerCanWithdrawASignedAcceptanceAndSignaturesExpire`, `testTheContributionPolicyIsTheOneTheWorkerSigned` |
| P0: scenario 5 was a multi-client wave, and client ids are aliasable | canonical group in the signed terms, a group exposure cap and a group-wide default block; scenario 5 now runs five branches of one parent; the remaining alias limit is stated | `testAliasesInOneGroupShareItsCapAndItsDefault`, `testAnAliasUnderAnotherGroupIsNotCaughtOnChain`, `invariant_groupExposure` |
| P1: backing liability moved after opening | per-guarantee shares fixed at opening (`lockedBacking`, `sharesOf`) | `testLateAttesterCannotUnlockAnEarlierAttestersShare`, `testSharesAreProRataAndCoverOddAmounts`, `invariant_backingConserved` (locked shares equal committed backing) |
| P1: no bounded settlement escape | signed settle-by date, at most `maxTerm`; `expireGuarantee` by anyone after it | `testSettleByIsBoundedAndPassedGuaranteesExpireWithoutAClaim` |
| Disclosure: sponsor funds "never returned" yet releasable to anyone | release only to the funder, up to what it funded, never dues or cover | `testReleaseOnlyToTheFunderAndNeverDuesOrOpenExposure` |

Codex's answers to section 11, adopted: worker dues absorb a claim only after explicit agreement (the
signed pledge); a line **or** real attester stake is enough, since requiring both adds an unproved
barrier; keep one hop; a single adjudicator only for synthetic testnet mechanics; and the first attack a
ring finds is client-id aliasing with role-controlled consent and terms, which the signed acceptance,
member-only consent and client groups now address as far as on-chain rules can.

**Carryover from the polling session's first pass** (its review of `c150af0`, rechecked against revision 2):

| Item | Disposition | Regression |
| --- | --- | --- |
| `releasable()` ignored held issuer lines, so capital behind them could be released and later line-backed claims paid from dues | held lines are locked and never exceed the sponsor capital, enforced on `setLine` and by `releasable()` | `testReleaseOnlyToTheFunderAndNeverDuesOpenExposureOrLines`, `testLinesNeverExceedSponsorCapital`, `invariant_issuerBudget`, and `invariant_reserveIdentity`: the reserve always equals sponsor capital plus members' dues |
| One address held owner, issuer and adjudicator | the bound above caps what any role holder can take; the deploy script gives the adjudicator and the issuer their own keys whenever the simulation mnemonic is set | all seven scenarios run with three distinct keys |
| The former owner kept guardian power after a transfer | `_transferOwnership` moves a guardian that was the old owner | `testGuardianPowerFollowsOwnership` |
| `attesteeClaims` counted per charge, not per claim | cured by fixed shares: an attester has at most one share per guarantee | `testClaimPaysWorkerAndConsumesBackingFirstSlashingStake` |

**Codex's re-review of revision 2** (review 5484377736 at `b5e5e99`): the five findings above are closed; three
new ones, fixed in revision 3:

| Finding | Fix | Regression |
| --- | --- | --- |
| P0: losses did not reduce each funder's entitlement, so a later funder's deposit could repay an earlier funder's loss | sponsor capital is held as shares (`sponsorSharesOf`, `totalSponsorShares`); a line-backed claim lowers `sponsorCapital` and so every share; `fundReserve` mints and `releaseReserve` burns shares at current value, rounded against the funder | `testALineLossBurnsTheFundersEntitlementNotALaterFunders` (Codex's exact sequence), `testTwoFundersShareALossProRata`, and `invariant_reserveIdentity` (shares fully held by funders; funding and release by several funders fuzzed) |
| P1: a release could strip the safety loading of open guarantees | no release while any guarantee is open (`ReleaseWhileOpen`); `releasable()` is zero then | `testReleaseOnlyToTheFunderAndNeverDuesOpenExposureOrLines`; the invariant handler counts any release made while a guarantee was open and requires zero |
| P1: the remit window was mutable after the worker signed | `remitWindow` is in the signed acceptance, must equal the window in force and is fixed per guarantee | `testTheRemitWindowIsTheOneTheWorkerSigned` |

Provenance correction: `c150af0..b5e5e99` also changed `CLAUDE.md` (the five-line pointer of `ef8dec8`), not only
the design, contract, tests and scenario as revision 2's note said.

**The polling session's non-author review of `c195800..cff18f3`** (board 15 `c-20261011-guaranteetrust-review-r1`):
ACCEPT for a Base Sepolia MockUSDC deploy once a chain guard lands, with two changes strongly advised because a
deployed contract cannot be patched. All three, and the cheap minor items, are in revision 4:

| Item | Fix | Regression |
| --- | --- | --- |
| Must: the testnet scripts could run on any chain | both scripts require Base Sepolia (84532) or a local chain (31337); a given `TOKEN` must be Circle's Base Sepolia test USDC, otherwise a fresh MockUSDC is deployed | the deploy script refuses a chain with id 1 ("testnet only") |
| Group was per guarantee, not per client: a known client reopened under another group escaped its group's default and cap | `clientGroup` fixes a client's group at its first guarantee; a later acceptance must name the same group (`GroupMismatch`) | `testAKnownClientCannotChangeGroup` |
| Consent signatures were unordered: an earlier unsubmitted approval could override a later revocation | sequential `consentNonce` per member and attester; `setConsent` also advances it, so any later decision kills earlier signatures | `testALaterRevocationKillsAnEarlierUnsubmittedConsent` |
| Revoked dust attesters kept their slots | `dropAttester`: a member removes an attester with nothing locked, returning its backing and withdrawing consent | `testAMemberCanDropAnAttesterWithNothingLocked`; fuzzed in the invariant handler |
| No minimum remaining term | `MIN_TERM` of one day for `settleBy` | `testSettleByIsBoundedAndPassedGuaranteesExpireWithoutAClaim` |
| Scenario 3 left a guarantee open | it now cancels the second job, so every scenario ends with nothing outstanding | scenario run |

Stated rather than changed: MockUSDC's ERC-20 name is "USD Coin", so every receipt labels it MockUSDC; a funder
who joins while guarantees are open shares in their line-backed losses, as in any mutual pool; defaults are
permanent for a client and its group; the adjudicator reports the wage, and the contribution is bounded by the
signed cap (Hermes's receipt on PR 28, comment 6112353325); and because nothing is released while a guarantee is
open, a sponsor of a busy pool may wait for a quiet moment to exit.

**Codex's review of revision 4** (review 5484550504 at `5d67de8`; board 15 `x-20261011-gt-r4-review-r1`): the
earlier findings and the polling session's items are closed; two blockers and one minor item, fixed in revision 5:

| Finding | Fix | Regression |
| --- | --- | --- |
| Zero client id defeats persistent grouping (zero is `clientGroup`'s "unset") | `openGuarantee` refuses a zero client id (`ZeroClient`) | `testAZeroClientIsRefused` |
| The scenario runner is not bound to the reviewed MockUSDC deployment, and the deploy script accepted Circle's test USDC although the scenarios mint | the deploy script always deploys a fresh MockUSDC and refuses `TOKEN`; before any broadcast the runner requires the contract and token at the addresses pinned from the deploy receipt (`EXPECT_GT`, `EXPECT_TOKEN`), refuses Circle's test USDC, and requires both runtimes to equal this build's artifacts byte for byte outside their immutables | refusals checked on a local chain: a set `TOKEN`, a wrong pinned address, and a runtime from another build (different metadata) |
| `dropAttester` changed consent without a `ConsentSet` event | it emits `ConsentSet(member, attester, false, member)` | event emitted |

