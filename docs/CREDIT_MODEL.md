# Credit model

Why Sybil accounts cannot manufacture credit in this protocol, where credit can legitimately come
from, and what the protocol may and may not do with repayment history. Every claim here is either
proved below, enforced by a test, or reproduced by a script in `analysis/`. Issues found against
this model are tracked in [`CREDIT_INTEGRITY_ISSUES.md`](CREDIT_INTEGRITY_ISSUES.md).

## The spine

1. **Sybil-proofness is a loss bound, not a detection problem.** Identities are free (Douceur 2002),
   and no symmetric reputation function of a graph of accounts is sybilproof (Cheng and Friedman
   2005), so no rule that reads the graph's structure can tell a ring of fakes from a community.
   The protocol instead bounds what any set of accounts can take: lenders' realised plus potential
   loss never exceeds the credit that was issued plus the dues that were paid (Theorem 2). Accounts with nothing issued and nothing paid add exactly
   nothing, however many there are.
2. **Credit is a liability of someone.** Every unit of borrowing capacity is underwritten by a
   named account's issued credit, its dues, or its stake. Backing moves underwriting from one
   account to another; it never creates it. This is "trust is risk" (Litos and Zindros 2017) and
   the one-hop case of a credit network (Karlan, Möbius, Rosenblat and Szeidl 2009; Dandekar et al.
   2011), and the bound is the min-cut between the attacker's accounts and everyone else.
3. **History alone can earn only what it has put out of its own reach.** Any on-chain rule that
   grants a pseudonymous account more credit for a repayment history than the value that history
   irrevocably handed to lenders can be farmed: one seed, recycled across fresh accounts, yields
   profit linear in the number of accounts (Theorem 3). The reviewer's proposal "repayment raises
   capacity by 25% of principal" fails this way at zero cost. Interest paid to lenders is not
   enough either: an attacker who is also a lender gets its share back (found by simulation,
   attack A7). The implemented rule counts only the share of interest paid into the first-loss
   reserve, which no lender can withdraw and which absorbs the very default it could fund.
4. **Larger credit from history needs an accountable issuer.** History is information about the
   probability of default; turning it into a larger line requires someone who bears the loss if
   the information is wrong: an institution (delegated monitoring, Diamond 1984) or a costly
   identity. Issuance is therefore budgeted on-chain, charged on the highest line an account holds
   while its line is in use (Theorem 2'), so a compromised or gamed oracle can misallocate its
   budget but never has more than the budget lent against its lines.
5. **Unsecured backing lowers the probability of default, not the loss given default.** Burning a
   backer's credit recovers no cash. It works through selection and monitoring (Stiglitz 1990;
   Ghatak and Guinnane 1999). Lenders' cash recovery comes only from stake and from the first-loss
   reserve, and both are priced in `analysis/credit_risk`.

## 1. Why the previous designs failed

| Design | What decided credit | Why Sybils won |
| --- | --- | --- |
| Vouching + on-chain PageRank (up to `21b838d`) | A symmetric function of the attestation graph, personalised by deposits | No symmetric reputation function is sybilproof (Cheng and Friedman 2005), and PageRank in particular is manipulable by Sybil strategies (Cheng and Friedman 2006). Concretely: a uniform fallback made every node a root when no deposits existed, $100 deposits were withdrawable roots, and scores were relative, so a ring of fakes scored about 0.9 and out-borrowed honest users (Hermes, PR #3, rounds 1 to 3). |
| Stake per vouch + first-loan cap | The same graph, made more expensive | Topology still turned vouches into credit; costs only scaled the attack. |
| Reviewer proposal: capacity rises 25% of each repaid principal | On-chain repayment history | Theorem 3: a repayment inside the 24-hour interest-free window costs nothing and earns 25, so one recycled seed farms unbounded capacity. |

## 2. Model

Accounts $a \in \mathcal{A}$ are free to create. For each account the contract stores:

| Symbol | Meaning | Contract |
| --- | --- | --- |
| $\ell(a)$ | issued line: score × `maxLoanAmount`, from the owner (override) or the oracle | `getCreditScore`, `maxLoanAmount` |
| $d(a)$ | dues: the share of the interest on the account's loans paid into the first-loss reserve | `duesPaid` |
| $\lambda(a)$ | credit charged to the account as a backer when borrowers it backed defaulted | `creditLoss` |
| $\delta(a)$ | 1 once the account has defaulted on a loan of its own | `defaultedLoans` |
| $G(a) = (1-\delta(a))\max(0,\ \ell(a)+d(a)-\lambda(a))$ | granted credit | `grantedCredit` |
| $s(a),\ s^c(a)$ | stake, and the part committed to backing | `stakeOf`, `stakeCommitted` |
| $c(a)$ | granted credit committed to backing | `creditCommitted` |
| $\sigma_e,\ \upsilon_e$ | secured and unsecured amount of backing edge $e=(u\to v)$ | `getBacking` |
| $o(a)$ | open principal (requested or disbursed, not repaid) | `_outstandingPrincipal` |

Commitments are edge sums: $s^c(u)=\sum_{e\ \text{out of}\ u}\sigma_e$ and $c(u)=\sum_{e\ \text{out of}\ u}\upsilon_e$.
The coverage of a backer is $\kappa(u)=\min\left(1,\ \max(0,G(u)-o(u))/c(u)\right)$ (1 when $c(u)=0$), and

$$\mathrm{Lim}(v) = (1-\delta(v))\Big[\max\big(0,\ G(v)-c(v)\big) + \sum_{e=(u\to v)} \big(\sigma_e + \upsilon_e\,\kappa(u)\big)\Big].$$

The operations and the checks the contract makes:

- **borrow** $x$: $o(v)+x \le \mathrm{Lim}(v)$.
- **back** (raise an edge by $x$): $x \le \varphi(u) + (s(u)-s^c(u))$, where the free credit
  $\varphi(u)=\min\big(G(u)-c(u),\ \mathrm{Lim}(u)-o(u)\big)$ is committed first and stake covers the rest.
  Received backing is not in $\varphi$, so it cannot be passed on. An edge is 0 or at least
  `MIN_BACKING` (1 USDC), and a defaulted borrower cannot be backed.
- **cut** an edge: unsecured first, then secured, and afterwards $o(v)\le \mathrm{Lim}(v)$
  (`BackingInUse`). Committed stake cannot be unstaked (`StakeCommitted`).
- **default** of a loan with unpaid principal $w$ (anyone, after `LATE_PERIOD`): with
  $\Sigma\sigma$ and $\Sigma\upsilon$ the borrower's incoming totals, stake
  $f_s=\min(w,\Sigma\sigma)$ is slashed pro rata and returned to lenders, then
  $f_c=\min(w-f_s,\Sigma\upsilon)$ is charged pro rata to the unsecured backers' $\lambda$, and the
  residual $w-f_s-f_c$ falls on the first-loss reserve, then on lenders. Charged backing is consumed; the rest is released once
  the borrower has no open loans. The borrower's own $G$ becomes 0.

## 3. Conservation

**Theorem 1 (capacity).** In every state, $\sum_v \mathrm{Lim}(v) \le \sum_a \big(G(a) + s^c(a)\big)$.

*Proof.* Regroup the edge terms of $\sum_v \mathrm{Lim}(v)$ by their source $u$; each $u$
contributes $\max(0,G(u)-c(u)) + s^c(u) + c(u)\kappa(u)$. If $c(u)\le G(u)$ this is at most
$G(u)-c(u)+c(u)+s^c(u)$. If $c(u)>G(u)$ it is $c(u)\kappa(u)+s^c(u)\le G(u)+s^c(u)$, because
$\kappa(u)\le G(u)/c(u)$. $\square$

Theorem 1 is about capacity at an instant. Losses happen over time, while credit is charged,
burned and released, so the statement that matters needs its own proof.

Let $\Lambda$ be the cumulative realised loss (written-off principal not recovered from stake;
the first-loss reserve then pays part of it, which only reduces what lenders bear) and $U=\sum_v \max\big(0,\ o^{\mathrm{act}}(v) - \Sigma\sigma_{\mathrm{in}}(v)\big)$ their
potential loss: disbursed principal not covered by secured backing.

**Theorem 2 (loss bound).** With issued lines fixed, in every reachable state
$$\Lambda + U \;\le\; \sum_{a}\big(\ell(a) + d(a)\big).$$

*Proof.* For each account define its own residual exposure, the part of its open principal that
neither secured nor unsecured backing received covers,
$r(a)=\max\big(0,\ o(a)-\Sigma\sigma_{\mathrm{in}}(a)-\Sigma\upsilon_{\mathrm{in}}(a)\big)$, and its
realised loss $\Lambda_a$: the credit charged to it as a backer plus the residuals lenders absorbed
at its own defaults. We show that every operation preserves the per-account invariant

$$Q(a):\qquad r(a) + c(a) + \Lambda_a \;\le\; \ell(a) + d(a).$$

It holds initially (all terms 0 on the left). For an account that has not defaulted,
$\ell+d-\Lambda_a = \ell+d-\lambda = G$ while $G>0$, so $Q(a)$ reads $r(a)+c(a)\le G(a)$.

- *Borrow.* The check gives $o \le \max(0,G-c) + \Sigma\sigma_{\mathrm{in}} + \Sigma\upsilon_{\mathrm{in}}\kappa$; since $\kappa\le1$, $r\le\max(0,G-c)$, so $r+c\le G$ (and $r=0$ when $G<c$).
- *Back by $x$ from credit.* $x\le G-c$ and $x \le \mathrm{Lim}-o$. The second gives $o-\Sigma\sigma_{\mathrm{in}}-\Sigma\upsilon_{\mathrm{in}} \le G-c-x$, so after the commitment $r+c+x\le G$.
- *Cut an incoming edge.* The `BackingInUse` check is the borrow check again. Cutting an outgoing edge lowers $c$.
- *Charge* (a borrower $u$ backed defaults): $c(u)$ falls by at least the charge and $\lambda(u)=\Lambda_u$ rises by it. The left side does not rise.
- *Default* of $v$'s loan $w$. Using $f_s,f_c$ above and $X=o-\Sigma\sigma_{\mathrm{in}}$, a case check over $X\le\Sigma\upsilon_{\mathrm{in}}$, $w-f_s\le \Sigma\upsilon_{\mathrm{in}}<X$ and $w-f_s>\Sigma\upsilon_{\mathrm{in}}$ shows $r'(v) + (w-f_s-f_c) = r(v)$: the residual lenders absorb is exactly the residual that leaves $r(v)$, and it enters $\Lambda_v$. After the default $Q(v)$ is in terms of $\ell+d$, not $G$, so burning $G(v)$ to 0 does not break it, and a defaulted account can neither borrow nor commit.
- *Repay, dues.* $r$ falls; $d$ rises.

Summing, $\Lambda=\sum_a\Lambda_a$ (slashed stake is recovered, every other unit of a default is
either charged to a backer or a residual of the defaulter), and
$U\le\sum_v\big(r(v)+\Sigma\upsilon_{\mathrm{in}}(v)\big)=\sum_a\big(r(a)+c(a)\big)$. Hence
$\Lambda+U\le\sum_a(\ell(a)+d(a))$. $\square$

Pro-rata rounding can leave a few wei per default uncharged; they fall on lenders.

**Corollary (Sybil-proofness as a min-cut).** Let an attacker control any set $S$ of accounts.
Lenders' losses on loans to $S$ are at most
$$\sum_{a\in S}\big(\ell(a)+d(a)\big) \;+\; \sum_{e:\ \mathcal{A}\setminus S\ \to\ S} \upsilon_e,$$
and honest backers lose at most what they committed to $S$ ($\sigma_e+\upsilon_e$ on those
edges). Fresh accounts have $\ell=d=0$, so the bound is independent of $|S|$: it is the capacity
of the cut between the attacker's accounts and everyone else, the same quantity that bounds
Sybil influence in credit networks and in SybilLimit-style defences, where it is the attack edges.

**Corollary (lenders pay only for issued lines).** Dues are exactly the reserve's inflow from
interest. Let $R$ be the reserve on hand, $\Lambda_L$ the part of $\Lambda$ the reserve did not pay,
$F$ the capital added with `fundReserve`, $D$ what was released to lenders and $\varphi$ the
forgiven sub-cent balances the reserve absorbed, so $R=\sum_a d(a)+F-(\Lambda-\Lambda_L)-D-\varphi$. Then
$$\Lambda_L + \max(0,\ U-R) \;\le\; \sum_a \ell(a) + D + \varphi.$$

*Proof.* Subtracting $R$ from both sides of Theorem 2 gives
$\Lambda_L + U - R \le \sum_a\ell(a) - F + D + \varphi$, which is the claim whenever $U\ge R$.
Otherwise, $\Lambda_L$ last grew at a default that exhausted the reserve; at that moment $R=0$,
so the same inequality bounded $\Lambda_L$ there, and since then $\Lambda_L$ has not moved while
$D$ and $\varphi$ can only have grown. If the reserve was never exhausted, $\Lambda_L=0$. $\square$

Lenders' realised loss plus what the reserve could not cover of their potential loss never exceeds
the issued lines (plus surplus released to them, which cannot include dues, and a few sub-cent
balances): earned credit costs lenders nothing, and while losses outrun the reserve, external
first-loss capital $F$ comes straight off their exposure. The invariant suite checks this as I8.

*The role of coverage $\kappa$.* The proof uses only $\kappa\le1$, so with fixed lines the bound
would hold even with $\kappa=1$. Coverage matters when the issuer revises a line downward, or a
backer defaults: it stops new borrowing against credit that is no longer there (CI-15).

**Theorem 2' (lines that change).** Let $\ell^*(a)$ be the highest line the account has held since
it last had no open loans and no backing commitments. Then at every time
$U \le \sum_a \big(\ell^*(a)+d(a)\big)$.

*Proof.* Count $\Lambda_a$ per cycle, from the last time the account had no open loans and no
commitments; at that point $r(a)=c(a)=0$, so $Q(a)$ holds with $\Lambda_a=0$ and any line.
Within a cycle, lowering a line does not change the left side of $Q(a)$, so $Q(a)$ keeps holding
with the cycle's highest line $\ell^*(a)$ in place of the current one, and raising it only helps.
So $r(a)+c(a)\le\ell^*(a)+d(a)$ always, and summing as before bounds $U$. $\square$

The bound is in terms of $\ell^*$, not the current line, and that difference is an attack: an
issuer that raises one account's line, lets it borrow, lowers it and raises another's keeps the
sum of current lines constant while $\sum\ell^*$ grows with every rotation. Section 4.2 shows how
the issuance budget is charged on $\ell^*$ for exactly this reason.

**Machine checks.** `test/invariant/CreditConservation.invariant.t.sol` checks Theorems 1 and 2,
the per-account invariant $Q$, Sybil independence and solvency under random interleavings of 21
operations (backing, staking, borrowing on every path, repayment, impairment, default, deposits,
queued withdrawals, the reserve), against an independent model of every loan and charge. A deep
campaign (332,800 calls, 8,104 defaults, 3,585 Sybil loans) found no counterexample; $Q$ reached
exactly 100% of an account's budget and Theorem 2 98.9% of its bound, so the bounds are tight,
not loose. Fourteen seeded bugs (coverage ignored, a charge not burned, free credit ignoring the
backer's loans, dues on interest net of fee, backing released early, and others) were all
caught. The campaign also surfaced four contract behaviours outside the theorems (CI-23 to CI-25).
`SybilResistance.t.sol` pins the named attacks.

**Simulation.** `analysis/sybil_sim` runs each attack against each mechanism with the contract's
arithmetic. Attacker net profit in USDC at 1 and 64 attacker accounts (fee 10%, reserve 30%):

| Attack | Old PageRank | "25% of principal" rule | Implemented |
| --- | --- | --- | --- |
| Ring of fresh accounts (pure ring) | 0 → 305 | 0 → 0 | 0 → 0 |
| $100 deposit roots, withdrawn (pure ring) | 0 → 5,818 | 0 → 0 | 0 → 0 |
| Recycled stake seed, interest-free repayments, 4 cycles | n/a | 100 → 6,400 | 0 → 0 |
| Recycled stake seed, 30-day repayments | n/a | 24 → 1,551 | −0.54 → −34 |
| Collusive backer with a 100 line | 190 → 886 | 100 → 100 | 100 → 100 |
| Lender who also borrows (A7), lender share 50% | n/a | 18 → 1,182 | −3.73 → −239 |

The collusive backer's 100 is its own issued line, which Theorem 2 charges to the issuer; it does
not grow with accounts.

### What is left to attack

Theorem 2 does not say nothing can go wrong. It says where an attacker has to go:

| Target | What the attacker gets | Bound |
| --- | --- | --- |
| Fresh accounts, rings, wash trades | nothing | $\ell=d=s=0$ |
| An honest backer (persuade, bribe, impersonate a friend) | what that backer commits to the attacker's accounts | the backer's own choice; charged to the backer |
| The issuer (fool its policy, buy identities it trusts, compromise the oracle) | the lines it issues to the attacker | the issuance budget (and, with CI-17, the issuer's capital first) |
| Governance (the owner key) | anything: overrides, `maxLoanAmount`, the provider | a self-administered timelock run by a multisig (`DeployProduction.s.sol`), with a guardian that can only pause; overrides and `maxLoanAmount` remain unbudgeted (CI-6) |

So the protocol's security reduces to issuance and governance, which is where it should be: those
are the only places credit is created. The rest of this document is about making issuance safe.

**A trilemma.** Free identities, unsecured credit from history beyond dues, and a bounded loss:
any protocol can have at most two (Theorem 3 for the third pair). This protocol keeps free
identities and the bound, and gets history-based credit beyond dues only through an issuer who
adds an identity cost or capital.

## 4. Where credit can come from

Theorem 2 moves the whole question to the right-hand side: $\ell$ and $d$. Whoever can raise them
can create losses. There are three candidates, and the protocol treats each according to what
backs it.

### 4.1 History: the dues bound

A history rule $f$ maps an account's on-chain record $h$ (loans taken and repaid) to extra
credit. Write $\pi(h)$ for the value the history put irrevocably on the lenders' side: value the
account paid and that neither it nor anyone it controls can recover.

**Theorem 3 (farming).** Suppose identities are free, and some history $h$ that a fresh account
can complete using recyclable capital (capital returned at the end of $h$) has $f(h) > \pi(h)$.
Then for every $n$ an attacker with that capital can complete $h$ on $n$ fresh accounts in turn and
default on all of them, for profit at least $n\,\big(f(h)-\pi(h)\big)$.

*Proof.* Secured backing makes $h$ reachable with recyclable capital: stake $K$, back fresh
account $i$ with it, let $i$ borrow and repay, withdraw the backing (allowed once $i$ owes
nothing) and repeat with $i+1$. The stake is never slashed. Each account ends with $f(h)$ of credit
of its own and has given up $\pi(h)$; borrowing $f(h)$ and defaulting nets $f(h)-\pi(h)$ per
account. $\square$

**Corollary.** Absent identity costs, no history rule may exceed $\pi(h)$. This is the on-chain
form of Friedman and Resnick's (2001) "pay your dues" result for cheap pseudonyms and of Bulow and
Rogoff's (1989) result that lending cannot rest on reputation alone, only on sanctions: here
walking away is creating a new address, and there is nothing to sanction. Friedman and Resnick
also show the dues cost disappears only with identities that cannot be replaced (issued once per
person by a trusted party), which is exactly the identity-cost route of 4.2. Resnick and Sami
(2009) show the same tension for transitive trust in general: a protocol that is sybilproof in
their sense must sometimes refuse transactions that are profitable in expectation.

*The reviewer's rule, concretely.* Under "capacity rises by 25% of repaid principal, up to 100",
seed $K=100$ of stake and four borrow-and-repay cycles inside the 24-hour interest-free window give
a fresh account 100 of its own capacity at a cost of gas. With $n$ accounts the attacker extracts
$100n$ and the seed is never at risk (`analysis/sybil_sim`, attack A4: 6,400 USDC at $n=64$).
Thirty-day cycles cost about 0.77 each and change nothing. The same holds if an oracle reads
`completedLoans` and grants credit for it: the policy, not the venue, is what is farmable.

*What counts as $\pi$.* The first version of this rule counted all interest paid net of the
protocol fee, on the reasoning that it reached lenders. The simulation found the flaw (attack A7):
an attacker that is also a lender with pool share $s$ gets $s$ of that interest back through its
shares, withdraws while its dues-funded loans are still current, and leaves the default to the
other lenders. Its profit per unit of interest is $s(1-f-r)-f$ for fee share $f$ and reserve share
$r$, positive for any $s>0$ when $f=0$. Interest to lenders is therefore not out of the payer's
reach. The reserve share is: lenders cannot withdraw it, and as a junior claim it absorbs the
default first. With $\pi$ = reserve share the attacker's profit per unit of interest is
$r-1+s(1-f-r)\le -f\le 0$ for every $s$, and the default it can fund is absorbed by the reserve it
funded (`testAttackerWhoIsAlsoALenderCannotFarmDues`, which fails under the old rule).

*The residual case.* The reserve is pooled, so an attacker that is also a lender holding share
$s$ can collect $s$ of its own contribution back if the reserve shrinks between its interest
payment and its default. The simulation derives the gain in closed form and checks it on a
256-point grid: per unit of interest it is $r-1+s(1-f)$ once the farm's contribution has fully
left the reserve, positive only when $s>(1-r)/(1-f)$ (70% of the pool at the deployed $r=0.3$,
$f=0$). The reserve can shrink two ways:

- *An owner release.* This gave an absolute profit (+1.87 per account per 100 USDC-year at
  $s=90\%$). Closed in ce99679: `releaseReserve` keeps all dues ever paid, so only external
  capital and surplus can be released.
- *Other borrowers' defaults.* Here the gain is a loss transfer under stress, not a profit: at
  $s=90\%$ the attacker still loses 0.65 per account (against 2.52 without the farm), and a
  lender who sees the defaults coming does better by exiting. Earmarking the reserve behind dues
  in use removes it in simulation, at the cost that the earmarked part stops cushioning other
  defaults (CI-21).

**What the protocol does.** `duesPaid[borrower]` accumulates the reserve share of every interest
payment and is added to granted credit; it is lost on default, like everything else the account
holds. At the deployed 30% reserve share, a borrower who pays 10 USDC of interest earns 3 USDC of
credit of their own. This is deliberately small: it is a floor anyone can reach without
permission, not the main source of credit.

### 4.2 Identity cost and institutions

If obtaining an identity costs $k$ (a proof of personhood, a KYC check, the expected penalty for
fraud), a profit-seeking attacker gains nothing from history credit up to $\pi(h)+k$ per
identity. That is an incentive bound, not a loss bound: a griefing attacker can still cost lenders
$k$ per identity. So credit beyond dues is a decision someone must be accountable for. That
someone is the issuer: the owner through overrides or, in production, the oracle that the CRE
workflow feeds. History, repayment timeliness and identity are the information the issuer uses;
the issuer converts information into lines and answers for the result.

Diamond (1984) is the standard account of why this works only if the issuer bears the loss of its
own judgement: a delegated monitor needs a contract that makes misreporting costly. The protocol
implements the first half and specifies the second:

- **Issuance budget (implemented).** A budget on the sum of current scores is not enough: by
  Theorem 2' exposure is bounded by each account's highest line since its line was last unused,
  and a compromised workflow could rotate one budget through many accounts in consecutive
  reports. So `OracleScoreProvider` charges the budget on that highest line: lowering a score cuts
  the account's credit at once, but its budget stays held (`budgetHeld`) until `releaseBudget`
  sees the account with no open loans and no backing commitments in the pool. The sum of held
  budget is capped by `maxTotalScore`, and one report may raise it by at most
  `maxIncreasePerReport`. By Theorem 2', lenders' potential loss on oracle lines is at most
  `maxTotalScore` × `maxLoanAmount` / `SCALE` at any time; realised losses can recur at most
  once per line lifetime (a loan's term plus the late period), which is what issuer capital and
  a governance response are for: the guardian multisig can `pause` new lending at once, while
  changes to the provider wait out the timelock. `testCompromisedOracleCannotRotateItsBudget` runs the rotation
  against the real pool.
- **Reference issuer policy (`analysis/issuer_policy`).** How the oracle's workflow should turn
  identity and history into lines. Unverified accounts get no line whatever their history; a
  verified tier's cap is at most the cost of a fraudulent identity of that tier, so buying
  identities does not pay; default probability is a Beta-Binomial posterior whose evidence counts
  only risk lenders actually bore (loans repaid inside the interest-free day, stake-secured
  principal, dust and self-backed loans weigh nothing, each closing a farming route); lines
  maximise expected issuer profit within the per-account cap, the held budget and the per-report
  cap, and the backing graph is never read. In simulation, 925 reports passed the contract's
  budget rules without a rejection, farms earned no line, predicted default rates matched realised
  ones in every decile, and attackers buying identities lost money in every tier unless identities
  cost far less than the issuer assumed, which is the assumption the cap rests on.
- **Pooled first-loss capital (implemented).** Anyone, typically an institution or the operator
  standing behind the lines it issues, can add to the first-loss reserve with `fundReserve`. It
  pays default losses before lenders and is never returned to the payer.
- **Issuer first-loss capital (specified, CI-17).** Losses that Theorem 2 attributes to credit an
  issuer created ($\Lambda_a$ for accounts whose $\ell$ it set) are charged to capital the issuer
  posts before they reach lenders, with the budget a governance-set multiple of that capital.
  Lenders' exposure to an issuer is then budget minus capital, priced explicitly.

### 4.3 Stake

Stake is cash. It is the only source that recovers money for lenders on default, and it carries
no identity assumption at all.

## 5. What backing is worth to lenders, and what the premium must cover

Burning a backer's credit recovers nothing. For lenders, loss given default on an
unsecured-backed loan is the same as on an unbacked one; what backing changes is the probability
of default, because a backer who loses credit when the borrower defaults screens and monitors
(Stiglitz 1990; Besley and Coate 1995; Ghatak and Guinnane 1999). How large that effect is remains
an empirical question: Giné and Karlan (2014) found that removing joint liability did not raise
default in Philippine microcredit groups. So the calibration treats unsecured backing only as a
lower PD, a hypothesis, and stake as the only loss-reducing security.

`analysis/credit_risk` calibrates the pool with the one-factor (Vasicek 2002; Gordy 2003) model,
the Basel other-retail correlation and a sensitivity grid, with LGD 100% on unsecured principal,
an explicit conversion between per-loan and annual PD for 30-day loans, and Monte Carlo checks
for small pools and for re-lending after write-offs. Base case (Basel correlation, 15% return on
risk capital, 85% utilisation):

| Annual PD | Per 30-day loan | Expected loss | 99.9% loss | Break-even premium | Recommended premium | Reserve share covering EL |
| --- | --- | --- | --- | --- | --- | --- |
| 3% | 0.25% | 3.0% | 14.2% | 467 bps | 600 bps | 29% |
| 5% | 0.42% | 5.0% | 16.8% | 677 bps | 800 bps | 41% |
| 10% | 0.86% | 10.0% | 23.4% | 1,201 bps | 1,400 bps | 55% |

Consequences for the protocol:

- The deployed 500 bps premium prices annual PD up to about 3% (2.6% once idle liquidity is
  counted). Microcredit portfolios at 5 to 10% need 800 to 1,400 bps; at correlation 0.15,
  1,100 to 1,950. The premium is a deployment decision, and this is the table to make it with.
- A reserve funded from lenders' own interest cannot raise their expected return; it moves losses
  in time and keeps the share price steady. That is why the reserve is a junior claim inside the
  pool rather than idle USDC (which would cost 0.36 to 0.56% APY): its cash is lent, and
  provisions and losses up to its size leave the share price unchanged. External first-loss
  capital (`fundReserve`) is different: it does raise lenders' expected return.
- A stake-secured share $q$ of principal scales the required premium by $(1-q)$; 26% secured makes
  500 bps adequate at PD 5%. Pricing the premium on the unsecured share is CI-18; it needs secured
  backing locked to the loan it priced, or a backer could swap stake for credit after the fact.

## 6. Generalisation: multi-hop credit

The protocol forbids passing on received backing. That is the one-hop restriction of a credit
network, where Avery's line to Brighton and Brighton's line to Carlos together let Carlos borrow
along the path: borrowing capacity between two agents is the max-flow between them, and a default
is paid along the path, each intermediary compensating the next and losing the link to the
defaulter (Karlan et al. 2009). Dandekar et al. (2011) show such networks keep liquidity within a
constant factor of a central currency on well-connected graphs; Ramseyer, Goel and Mazières (2020)
add aggregate borrowing limits per agent that bound what a defaulting coalition can cost the rest.

`analysis/liquidity` measures the price of the restriction on small-world, preferential-attachment
and community graphs (1,000 accounts, 20% holding a line, trust 25 per edge, loans of 50):

- **One hop costs about half the liquidity.** In the steady state of repeated loans, the share of
  borrowers without credit who can borrow is 0.41 under one hop and 0.83 under two hops on the
  small-world graph (2.0 to 3.1 times one-hop across graphs); two hops close 71 to 86% of the gap
  to a central pool, three hops 93 to 99%. To match two-hop liquidity, one hop needs about twice as
  much issued credit, and by Theorem 2 a proportionally larger loss bound.
- **The gain comes from relaying, and relaying moves liability to people who did not choose it.**
  About half of multi-hop volume enters the borrower through an account that holds no credit of its
  own, and a similar share is supplied by credit holders not adjacent to the borrower, who are
  charged on default for a borrower they never chose. If every intermediary must stand behind its
  hop with credit of its own, multi-hop liquidity collapses to exactly one-hop liquidity.
- **The Sybil bound holds in every regime.** Attacker extraction equals the cut and is identical for
  1 and for 1,000 Sybil accounts, at most the attack edges times the trust per edge.

So multi-hop routing is a liquidity gain bought with a different liability rule: holders must
accept charges for borrowers reached through intermediaries they trust. That is a product and
legal decision as much as a technical one (path selection on-chain or a routing proof, roughly
1.5 to 8 storage slots more per routed loan). The one-hop rule keeps every charge on an account
that chose the borrower (CI-20).

## 7. Lender fairness

Without provisioning, a loan past due is carried at full value until `markDefaulted`, 30 days
later. A lender who exits in that window escapes a loss that is already visible: with overdue
unsecured exposure $X$ in a pool of $A$, a lender holding share $w$ who exits leaves their part of
$X$, $wX$, to those who stay, and every lender who can see the overdue loan has the same incentive
to go first (the run logic of Diamond and Dybvig 1983). `impairLoan`, callable by anyone once a
loan is past due, removes the unpaid principal not covered by secured backing from `totalAssets`
(expected-loss provisioning in the IFRS 9 / CECL sense, with unsecured exposure treated as fully
lost). Exits after that pay the loss pro rata; repayment reverses the provision and the default
only confirms it. With a first-loss reserve, provisions up to its size are absorbed by the reserve
and the share price does not move at all. With several open loans per borrower each loan counts the borrower's whole
secured backing, so the provision can be low; the default settles the exact loss.

## 8. Assumptions and limits

What the theorems do not say:

- **Principal, not interest.** The bounds are on principal. Accrued interest a defaulter never pays
  is lost income, priced by the premium (section 5), not a loss the theorems bound.
- **Issuers are trusted up to their budget.** Theorem 2 bounds losses by issued lines; whether
  the issuer's lines are wise is the issuer's problem, bounded on-chain by the budget and, once
  CI-17 lands, by its capital. Owner overrides are not budgeted (CI-6).
- **Lines fixed, or Theorem 2'.** With lines that change, the bound is on each account's highest
  line in its current cycle; the oracle budget is charged that way, owner overrides are not.
- **Rounding.** Pro-rata charging leaves at most a few wei per edge per default on lenders, and
  sub-cent balances are forgiven at closing (absorbed by the reserve first). The invariant suite
  carries both explicitly.
- **The token.** USDC is assumed to transfer as specified. A blocklisted lender or borrower cannot
  move funds; a depeg moves every figure together. Neither creates credit.
- **Ordering.** A backer cutting a backing and a borrower drawing on it can race in one block;
  each transaction is checked against the state it sees, so either order keeps every invariant.
- **Information, not just incentives.** Unsecured backing lowers PD only if backers screen and
  monitor. The protocol makes them bear the loss; it cannot make them diligent (section 5).
- **The pooled reserve** leaves the stress-time loss transfer of CI-21.

## 9. Requirements mapped to results

| Requirement (Scott, Hermes) | Status |
| --- | --- |
| Borrow only with credit of your own or credit someone who has it backs you with | Theorem 1, enforced on every borrow |
| Whoever vouches must already hold credit, from previous activity or an institution, not necessarily money; vouching must not create credit (the demo video) | `back` commits the backer's own issued line, dues or stake and lowers its capacity accordingly; a backer with none is rejected (`InsufficientCredit`) |
| Credit from previous activity | Dues on-chain (Theorem 3 bound); larger lines from an issuer that reads history and answers for it (4.2) |
| Credit from an institution | An issued line within the oracle's budget, or the owner's override; institutions can also post first-loss capital (`fundReserve`) |
| A ring's credit is bounded by what enters it from outside | Corollary to Theorem 2 (min-cut) |
| Vouching locks the voucher's capacity; default costs the voucher | `back` commits; Theorem 2's charge step |
| No credit from nothing; no uniform fallback | $\ell=d=s=0 \Rightarrow$ zero capacity; no fallback exists |
| Repayment grows capacity | Only as dues (Theorem 3 shows larger on-chain rules are farmable); larger lines via issuers |
| Oracle cannot mint beyond an on-chain bound | Issuance budget charged on held lines (Theorem 2'), rotation test |
| First-loss reserve | `firstLossReserve` |
| Default plus run never favours the first exiter | `impairLoan` once past due (CI-8) |

## References

- Besley, T. and Coate, S. (1995). Group lending, repayment incentives and social collateral. *Journal of Development Economics* 46(1).
- Bulow, J. and Rogoff, K. (1989). Sovereign debt: is to forgive to forget? *American Economic Review* 79(1).
- Cheng, A. and Friedman, E. (2005). Sybilproof reputation mechanisms. *ACM SIGCOMM Workshop on Economics of Peer-to-Peer Systems (P2PECON)*.
- Cheng, A. and Friedman, E. (2006). Manipulability of PageRank under Sybil strategies. *Workshop on the Economics of Networked Systems (NetEcon)*.
- Dandekar, P., Goel, A., Govindan, R. and Post, I. (2011). Liquidity in credit networks: a little trust goes a long way. *ACM EC*.
- Diamond, D. (1984). Financial intermediation and delegated monitoring. *Review of Economic Studies* 51(3).
- Diamond, D. and Dybvig, P. (1983). Bank runs, deposit insurance, and liquidity. *Journal of Political Economy* 91(3).
- Douceur, J. (2002). The Sybil attack. *IPTPS*.
- Friedman, E. and Resnick, P. (2001). The social cost of cheap pseudonyms. *Journal of Economics and Management Strategy* 10(2).
- Ghatak, M. and Guinnane, T. (1999). The economics of lending with joint liability: theory and practice. *Journal of Development Economics* 60(1).
- Giné, X. and Karlan, D. (2014). Group versus individual liability: short and long term evidence from Philippine microcredit lending groups. *Journal of Development Economics* 107.
- Gordy, M. (2003). A risk-factor model foundation for ratings-based bank capital rules. *Journal of Financial Intermediation* 12(3).
- Karlan, D., Möbius, M., Rosenblat, T. and Szeidl, A. (2009). Trust and social collateral. *Quarterly Journal of Economics* 124(3).
- Litos, O. S. T. and Zindros, D. (2017). Trust is risk: a decentralized financial trust platform. *Financial Cryptography and Data Security*.
- Ramseyer, G., Goel, A. and Mazières, D. (2020). Liquidity in credit networks with constrained agents. *The Web Conference (WWW)*.
- Resnick, P. and Sami, R. (2009). Sybilproof transitive trust protocols. *ACM EC*.
- Stiglitz, J. (1990). Peer monitoring and credit markets. *World Bank Economic Review* 4(3).
- Vasicek, O. (2002). The distribution of loan portfolio value. *Risk* 15(12).
- Yu, H., Gibbons, P., Kaminsky, M. and Xiao, F. (2008). SybilLimit: a near-optimal social network defense against Sybil attacks. *IEEE Symposium on Security and Privacy*.
