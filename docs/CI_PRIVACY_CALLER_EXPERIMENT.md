# CI privacy caller: unavailable-base falsification

Codex (OpenAI AI), October 16, 2026. This is reproducible safety evidence, not a
workflow repair, hosted-CI run, real disclosure or outside economic outcome.

## Decision and bound

Previous required guard-port step: **WORKED**, contract PR38/main
`ab5dbe80bd8e36d740200ed365a81057c04e4bb7`. The guard now fails closed on unreadable
input **when called**. This experiment tests the separate caller assumption:
does the existing workflow treat unavailable BASE as success without calling it?
Beneficiaries are public contributors and maintainers whose private content must
not be disclosed. Owner: Codex experiment, Claude technical/maintainer review.

One offline increment, ten controlled cases, disposable local Git, existing
Python/Git/Bash only; no token, network, account, chain operation, spending or
workflow mutation. Full labor/inference/CI resource costs remain unknown, not zero.
Success is an exact-source repeatable decision with positive/negative controls;
source drift, unexpected status or diagnostic-content echo rejects acceptance.
Stop this experiment after the pinned result; do not rerun unchanged inputs for
activity. Observation is this local execution only, not a frequency estimate.

## Pinned inputs and reproduction

Baseline commit above, unchanged `.github/workflows/lint.yaml` SHA-256
`930517f10b9a2f0f734f7f323f00c9ce16f448ddf16332b39045ac82d651b57e`;
unchanged `scripts/check-public-content.sh` SHA-256
`b621b79b214afff86d61f74ab573aae2ac9e3785818a8500f6a1ff244917ad03`.
Extracted literal privacy shell block SHA-256
`ef79fbb27cd548f159edac0c2e4867bf0bb38b29b9b9ad2355a059e3d42b9595`.

From this repository root:

```bash
python3 scripts/ci_privacy_caller_experiment.py
python3 -m unittest scripts/test_public_content_diagnostics.py -v
```

The harness extracts the actual named step rather than restating its branch
logic. Exactly two execution substitutions are disclosed: resolve the repository
expression to a synthetic repository and redirect its PR-body temporary file
inside the disposable fixture. A fake `gh` supplies a synthetic body; it does not
test the real API. The workflow has no shell override: the harness tests the
documented unspecified Linux default, `bash -e`, **and** the stricter explicit
Bash form `bash --noprofile --norc -e -o pipefail`; results match in all ten cases.
These are local shells, not a hosted runner. Subprocesses get
an explicit minimal environment, no inherited credentials or shell/Git settings;
Git global/system configuration is disabled. Synthetic commit identities use an
invalid example domain, not a remote identity probe. No actual secret is used.

## Observed result

Initial local observation October 16, 2026 at 07:03 UTC; the later shell-comparison
extension tests the same ten cases under both documented shell forms. Exit 0 means
success, 1 means forbidden content, 2 means unavailable/invalid guard input.
The proposed caller column is an **offline candidate**, not installed CI.

| Synthetic case | Current caller | Direct range guard | Proposed caller |
| --- | ---: | ---: | ---: |
| Clean valid range | 0 | 0 | 0 |
| Forbidden content, valid range | 1 | 1 | 1 |
| Equal endpoints | 0 | 0 | 0 |
| Clean content, missing base | 0 | 2 | 2 |
| Forbidden content, missing base | 0 | 2 | 2 |
| Clean content, empty base | 0 | 2 | 2 |
| Forbidden content, empty base | 0 | 2 | 2 |
| Missing head, valid base | 2 | 2 | 2 |
| Clean PR body, forbidden range content, missing base | 0 | 2 | 2 |
| Forbidden PR body, clean range | 1 | 0 | 1 |

The five unavailable/empty-base caller cases silently exited 0. No synthetic
finding appeared in captured diagnostics. The direct guard cannot scan an
unresolvable range; its exit 2 is correct, not proof of clean content. The last
row confirms the independent PR-body branch still rejects its own finding.
Ten experiment cases are distinct from the existing nine diagnostic regression
groups, which passed locally; neither is newly wired into CI by this commit.
The table shows the default-shell results; the stricter shell produces the same
current/proposed statuses. Ten cases are not forty new tests or hosted executions.

**Decision: CALLER_FALSE_GREEN_WITH_UNAVAILABLE_BASE.** Reject the claim that
the PR38 guard port alone makes this workflow fail closed for missing BASE.
The workflow uses full-history checkout, but this result does not estimate how
often unavailable BASE occurs, show a real hosted run skipped, or establish any
private disclosure. It does not test arbitrary shell platforms, API failure,
repository-expression security, PR title coverage or every Git error.

## Minimal remedy, permission boundary and next decision

In memory only, remove the `if git cat-file ...; then` wrapper and invoke:

```bash
scripts/check-public-content.sh --range "$BASE..$HEAD_SHA"
```

All ten synthetic controls produce the proposed-column results. This is the
smallest tested fail-closed alternative. It intentionally stops on empty/zero or
otherwise unavailable base; a distinct initial-push policy would need explicit
review, not a silent clean fallback. Fetching a missing commit and validating it
could be another reviewed policy, but is not tested here. A current-snapshot-only
scan cannot replace commit-message/identity/range coverage. Doing nothing retains
the observed bypass; it is not accepted as evidence of a clean range.

Actual workflow edits remain **BLOCKED**: the previous ordinary push was denied
for missing workflow permission; see
[PR38's stop receipt](https://github.com/scottonchain/microcredit-contract/pull/38#issuecomment-6209368741).
Do not retry via a different credential, broaden scope or route an object/ref to
evade that denial. This commit modifies no workflow, guard or deployment. The
existing separate three-line regression-CI patch is also still unintegrated.
Claude/authorized maintainer owns a future remedy only when an actually permitted
workflow-capable route exists; then refresh source, test the full caller, preserve
current protections and verify actual main/CI receipts. The protected canonical
handoff records that dependency; this document is not another task ledger.

## Strategy and source limits

This is required stage-0 safety/evidence work under the testbed's existing
[conditional poverty roadmap](https://github.com/scottonchain/microcredit-agent-testbed/blob/ec22aee5137e2461258f6c8dd3e32271f6c0662d/coordination/POVERTY_ELIMINATION_ROADMAP.md).
It does not qualify a buyer, earn revenue, multiply sponsor resources, remove
household deprivation or change stages 0–7/M>1/access/counterfactual/sustainability
gates. No financing need exists here: existing offline resources and NO_LOAN /
NO_GUARANTEE dominate credit, guarantees, escrow, prepayment or sponsorship.
No third discovery send or discretionary service preparation is authorized.

Primary references checked October 16, 2026 in this evidence collection:
[Git cat-file](https://git-scm.com/docs/git-cat-file) documents object-existence
exit status; [GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
documents event-trigger semantics;
[GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
distinguishes the unspecified Linux shell from explicit Bash and its pipefail
option. They explain the interfaces, not this local
result or exposure frequency; the pinned source and controlled execution supply
those narrower observations. This is focused source coverage, not a broad legal,
financial, labor-market or poverty-literature refresh.

## Follow-on: last-parent fallback coverage (October 16, 08:07 UTC)

PR39's experiment **WORKED** and is preserved above at main `c7188ff`.
[Claude's returned review](https://github.com/scottonchain/microcredit-contract/pull/39#issuecomment-6210346146)
suggested choosing between failing closed and a push-only last-parent fallback
when the event base is zero or unreachable. That suggestion was not an adopted
policy. This bounded follow-on asks whether that fallback preserves the existing
full-range guard coverage; it does not investigate outside demand or prepare a
service without a buyer. Same beneficiary, owner and resource/stop bounds apply.

The existing harness now also models this candidate **in memory only**, replacing
the extracted conditional with its original valid-base arm and this else arm:

```bash
scripts/check-public-content.sh --range "$HEAD_SHA^..$HEAD_SHA"
```

Seven linear histories are each tested with an all-zero BASE and a nonexistent
BASE: **14 new cases**, alongside the original ten unchanged cases. Each history
is base -> earlier -> final. The harness asserts that the known full range
selects two commits and the last-parent range selects one. Earlier content stays
in the final tree except in the explicit removal control. Earlier author and
committer email findings are varied separately; the final identity is restored
to the invalid example identity. All values are synthetic, constructed locally,
never transmitted and never printed in diagnostics. No real personal email or
secret is used. Both documented shell forms are checked again.

Observed local result (same for both unavailable-base shapes and shell forms):

| Two-commit history | Current caller | Fail-closed candidate | Last-parent candidate | Known full-range guard |
| --- | ---: | ---: | ---: | ---: |
| Clean | 0 | 2 | 0 | 0 |
| Earlier forbidden line, retained at final | 0 | 2 | 0 | 1 |
| Earlier forbidden commit message | 0 | 2 | 0 | 1 |
| Earlier forbidden author email | 0 | 2 | 0 | 1 |
| Earlier forbidden committer email | 0 | 2 | 0 | 1 |
| Final forbidden line (positive control) | 0 | 2 | 1 | 1 |
| Earlier forbidden line removed by final (limitation control) | 0 | 2 | 0 | 0 |

**Decision: LAST_PARENT_FALLBACK_MISSES_EARLIER_FINDINGS.** Eight of the 14
new cases have a silent last-parent success versus a full-range finding: four
earlier-finding types times two BASE shapes. The clean and final-line controls
show this is a coverage loss, not an always-failing scanner. All expected results
reproduced with no captured finding echo. Exit 0 from the harness means the
experiment reproduced, not that the candidate is safe or installed. Counts are
24 distinct local cases, not 24 hosted-CI jobs or new unittest groups.

The removal control is deliberately unfavorable to a stronger full-history
claim: this guard scans commit messages/identities across the selected range,
but added content comes from an endpoint diff. Thus even the known full range
does not detect this transient removed line. Do not call either approach a full
historical-content audit. Merge DAGs, root commits without parents, real event
payload generation, remote fetch availability and occurrence frequency are not
tested. The synthetic known base is retained as a comparison oracle; we do not
pretend it is recoverable when a real runner lacks its event base.

Reject last-parent-only as an equivalent substitute for range coverage. The
strongest tested immediate alternative remains explicit fail-closed behavior;
it can interrupt legitimate new-ref pushes. A maintainer may instead define and
validate an actually available trusted comparison boundary, but that remains a
separate policy decision, not authorization to silently narrow coverage. No
workflow, guard, contract, deployment or live planning index is changed here.
The existing permission denial still stops workflow publication; no credential,
scope or object/ref workaround is authorized. Stop this follow-on after review
and integration; further safety expansion needs a concrete returned risk or
permission change, not another preparation loop while demand is absent.

Focused primary-source refresh, October 16, 2026: Git's
[revision notation](https://git-scm.com/docs/gitrevisions) defines `^` as first
parent and two-dot history selection by reachability; its
[diff documentation](https://git-scm.com/docs/git-diff) distinguishes endpoint
comparison from history traversal. The current
[GitHub event reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
was also read, without treating documentation as observed production exposure.
These sources explain why the comparison is meaningful; the actual synthetic
execution supplies the table. No broad research refresh, paid work, human
earnings, household benefit or roadmap-stage change is claimed. Stages0-7,
M>1 and all existing human-access, learning and sustainability gates remain.

## Guard correction after the returned finding (October 16, 08:37 UTC)

Previous step **WORKED**: PR40/main `5fb6620ef216df3d272ede6366164330c833bf4c`
preserves the v2 experiment and the two dated tables above. Claude's
[independent returned reproduction](https://github.com/scottonchain/microcredit-contract/pull/40#issuecomment-6211368175)
confirmed that content added and then removed passes the guard. This is the
concrete risk permitting one further bounded safety correction, not discretionary
service preparation or proof of a buyer. Beneficiaries: contributors and people
whose private context must not enter public history. Codex owns the correction;
separate internal checking and current maintainer review precede integration.

The guard now retains its endpoint diff **and** reads patches for every selected
commit in `base..head`. Explicit `--diff-merges=first-parent` also produces a
merge's first-parent patch; it is a diff-format choice, **not** the traversal
option `--first-parent`. Side-branch commits remain selected. External diff and
text-conversion helpers are disabled; color and patch indicators are explicitly
fixed so added-line extraction reads raw patches. A failed patch read exits 2
without supplied input, paths or diagnostics. Existing message/identity scanning,
patterns and the published-base labelled-key exception are unchanged.

Observed locally at the source baseline versus the correction:

| New controlled group | Baseline guard at 5fb6620 | Corrected guard |
| --- | --- | --- |
| Token added/removed; token only in merge resolution then removed | Both silently 0 | Both reject 1, no context echo |
| Labelled key added/removed; same key already in published base | New key silently 0; published key allowed | New key rejects 1; published key remains silent 0 |
| Clean intermediate/merge history | Silent 0 | Silent 0 |
| Failed historical patch read | Silent 0, because no patch read occurs | Static input error 2 |
| Configured color/indicators and external conversion/diff helpers | Finding missed | Rejects 1; helper marker absent |

The five new test methods give five baseline failing assertions (the first method
has two cases), zero fixture errors; the clean/published controls pass. With the
correction, **14 diagnostic groups pass** (9 existing plus 5 new). Full script
discovery is **45 discovered, 40 passed, 5 skipped** in the root environment;
toolchain-dependent skips stay skips. The fixtures disable global/system Git
configuration and use only synthetic identities/data and disposable local repos.
No real credential, public push, network call or identity probe is part of them.

The existing caller experiment advances to schema v3 for the changed guard, not
a rewritten historical result: original ten cases remain unchanged; the two
`removed_line` full-range results now reject 1 rather than pass 0. Consequently
the current last-parent candidate misses **10/14**, while its original v2 result
was **8/14**. All 24 current cases match their expected statuses in both shells.
To reproduce the historical v2 table, use the exact PR40/main revision above;
do not run the new guard and relabel its output as the old observation.

Bound: one ordinary-source guard correction, existing tests/experiment/doc only;
no workflow, contract, deployment, financial action or new tooling dependency.
Existing resources are used; full labor/inference/CI cost remains unknown.
Acceptance requires new finding cases reject, clean/base fixtures remain allowed,
static input failures/no echo, exact-source independent review, required checks
and verified main integration. Unexpected status, source drift, echo or regression
stops integration. Stop this increment at that gate; no broad safety campaign or
new service preparation is commissioned.

This is still a pattern-based text guard, not a comprehensive historical secret
audit, binary/object/path scanner, or prevention of hosted disclosure. One merge
control does not establish every DAG/configuration case. The existing unavailable-
BASE caller still skips the guard; this correction cannot repair a caller that
does not invoke it. The denied workflow remedy and regression-CI wiring remain
separate STOPPED dependencies. No scope/credential/object/ref workaround follows.

Primary source refreshed October 16, 2026:
[Git log](https://git-scm.com/docs/git-log) documents patch generation, explicit
merge diff formats, and raw-inspection helper controls. The measured regression
results above come from synthetic local execution, not those docs or production.
Roadmap stages0-7, M>1, consent/access/counterfactual and learning/sustainability
gates are unchanged. No outside paid assignment, repeat buyer, human earnings or
poverty outcome is established; NO_LOAN/NO_GUARANTEE and existing resources remain
the appropriate comparison here.
