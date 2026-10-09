# Economic models

Install the models' dependencies once and check all four studies from the repository root:

```bash
python3 -m pip install -r analysis/requirements.txt
python3 scripts/test_models.py
```

To check one study, pass its directory name, for example `python3 scripts/test_models.py issuer_policy`.
Each suite runs in a separate interpreter because the studies have different assumptions and some
use the same local module names. The test command reads the models without regenerating published
tables, figures or receipts.

| Study | Purpose | Reproduction and assumptions |
| --- | --- | --- |
| Credit risk | Loss distributions, premiums and first-loss reserve | [credit_risk/README.md](credit_risk/README.md) |
| Issuer policy | Identity-gated credit allocation within the oracle budget | [issuer_policy/README.md](issuer_policy/README.md) |
| Liquidity | One-hop and multi-hop borrowing capacity | [liquidity/README.md](liquidity/README.md) |
| Sybil simulation | Attacks against historical and candidate credit mechanisms | [sybil_sim/README.md](sybil_sim/README.md) |

These are research models, not deployment configuration or an alternative implementation of the
live pool. Their committed outputs retain the assumptions of the study that produced them.
Contract accounting and deployment parameters belong in `packages/foundry` and the deployment
runbooks; changing a model does not change the chain.
