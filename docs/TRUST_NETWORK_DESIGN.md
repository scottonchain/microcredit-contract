# Trust for new members: a conserved-trust design for the revolving first-job guarantee

Status: **design draft for devil's-advocate review**, written by Claude Code (AI agent) on 2026-10-11
at the operator's direction. Testnet only. No real money, no outreach, no live guarantee. The
operator's questions, the answer, every parameter and its reason, and what the contract
(`GuaranteeTrust`) and the agentic simulations must show.

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
| Sponsor | anyone, typically the operator | funds the reserve; funds are never returned to the sponsor |
| Member | a newcomer or an established worker | holds trust; receives guarantees; remits contributions |
| Attester | any member with free trust of their own | backs a newcomer with part of that trust |
| Issuer | an accountable programme that vets newcomers | sets small lines within an on-chain budget |
| Adjudicator | the operator or a programme it names | opens guarantees; records client payment or nonpayment with an evidence hash |
| Client | an independent payer, identified by address or hash | owes the wage; at most one open guarantee |
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

**Opening a guarantee** (adjudicator) for worker `w`, client `k`, amount `G`, terms hash:

- `G ≤ capacity(w)`;
- `G ≤ maxShareBps` of the reserve (testnet: 20%, a fifth);
- outstanding exposure plus `G` leaves at least `floorMultiple × G` in the reserve (testnet: 2);
- the client has no open guarantee and no recorded nonpayment;
- the worker has no lapsed contribution.

`G` is committed against the worker's capacity, backing first, then the issuer line, then dues.

**Client pays.** The adjudicator records the wage. The contribution due is
`min(wage × contributionBps, contributionCap)`. The worker (or anyone for them) remits it within
`remitWindow` (14 days). It goes to the reserve and adds the same amount to the worker's dues. The
commitment is released.

**Worker does not remit.** After the window anyone may mark it lapsed. The worker cannot receive a
new guarantee until it is paid. It is never pursued as a debt (`NORTH_STAR`: a pledge, not a loan).

**Client does not pay** (claim). The adjudicator confirms with an evidence hash. The reserve pays the
worker `G`, and the worker owes nothing. The capacity that underwrote `G` is consumed in the order it
was committed:

1. the attesters' backing, pro rata (they lose that much trust);
2. the issuer line (its budget stays spent);
3. the worker's dues.

The client is recorded as a nonpayer. Consuming capacity is not a debt: the worker keeps the `G`,
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
| Unsolicited attestations filling a newcomer's attester slots | the member's consent is required, given by the member or by the issuer on a newcomer's behalf (found by Claude's own adversarial pass before review) |
| Attester backing its own sock puppet | loses its own backing; extraction ≤ its own trust |
| Rotating an issuer line through many accounts | budget charged on the highest line held until released |
| One client failing many workers at once | one open guarantee per client; attester cap on open attestees |
| Compromised adjudicator approving false claims | bounded by committed capacity and the reserve; the main trust assumption, stated; a two-of-n adjudicator is the next step |
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
- a correlated wave of client defaults against the exposure rules.

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
