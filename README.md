# Decentralized Microcredit Platform

![Frontend Vision](front_end_vision.png)

## Introduction (read first)

This project delivers a full-stack **peer-to-peer micro-lending application** on the Ethereum network.  
Lenders earn yield on USDC deposits while borrowers obtain collateral-free loans backed by their **social reputation**, not a traditional credit history.

Key ideas for crypto-aware readers:

1. **Reputation via PageRank** – users create weighted social attestations; an on-chain PageRank algorithm turns the network graph into a 0–100 credit score.
2. **Fixed-rate loans** – the base APR follows the Effective Federal Funds Rate (EFFR) published by the Pyth oracle, plus a configurable risk premium.
3. **Single liquidity pool** – deposits are pooled; liquidity is reserved when a loan is approved and released when repaid, balancing lender withdrawals with borrower demand.
4. **Attester incentives** – those who vouch for reliable borrowers share an attester-reward pot when repayments succeed.

---

## Feature Highlights

• Social attestations and PageRank-based credit scoring (all on-chain)  
• Request, approve, disburse and repay USDC loans at a fixed rate  
• Unified lending pool with proportional yield distribution  
• Oracle / admin panel to update EFFR, risk premium and other parameters  
• Next.js 14 front-end with live pool statistics and user dashboards

---

## Architecture & Tech Stack

| Layer           | Technology |
| --------------- | ---------- |
| Smart contracts | Solidity 0.8.x, Foundry, OpenZeppelin |
| Front-end       | Next.js 14 App Router, Tailwind CSS |
| Wallet / Web3   | Wagmi, RainbowKit, Viem |
| Local dev       | Anvil, Forge scripts |

---

## Quick Start (local sandbox)

Prerequisites: `git`, `node >=18`, `yarn`, and Foundry (`curl -L https://foundry.paradigm.xyz | bash`).

1. **Clone & install**
```bash
git clone <repository-url>
cd microcredit-contract
yarn install
```
2. **Run a local chain**
```bash
yarn chain
```
3. **Deploy contracts & seed demo users**
```bash
# For testing with MockUSDC (recommended for first deployment)
DEPLOY_MOCK_USDC=true yarn deploy

# Or deploy without MockUSDC (production-like)
yarn deploy
```
4. **Launch the front-end**
```bash
yarn start
```
Visit http://localhost:3000

### Environment variables (front-end)
Create `packages/nextjs/.env.local` if you need to override defaults:
```env
NEXT_PUBLIC_TARGET_NETWORK=localhost
NEXT_PUBLIC_CONTRACT_ADDRESS=<DecentralizedMicrocredit address>
NEXT_PUBLIC_USDC_ADDRESS=<MockUSDC address>
```
The deployment script writes these addresses to `deployment.json`, which the front-end imports automatically.

---

## Interest-Rate Source (EFFR)

The contract stores two basis-point values:
- `effrRate` – Effective Federal Funds Rate, fetched from the Pyth Network oracle in production (manually set during local testing).
- `riskPremium` – additional spread to cover platform risk.

The borrower’s APR is simply `effrRate + riskPremium`.

---

## Wallet Support

The application supports multiple wallet providers including:
- **MetaMask** - Most popular browser extension
- **WalletConnect** - Mobile/desktop bridge for any wallet
- **Ledger** - Hardware wallet security
- **Coinbase Wallet** - User-friendly mobile app
- **Rainbow Wallet** - Beautiful mobile interface
- **Rabby Wallet** - Security-focused browser extension
- **Safe Wallet** - Multi-signature team wallets

For detailed wallet setup and troubleshooting, see [Wallet Support Documentation](packages/nextjs/docs/WALLET_SUPPORT.md).

## User Guides

### Borrowers
1. Ask contacts for attestations to raise your credit score.  
2. Check the *Scores* page for your current score and max loan amount.  
3. Submit a loan request; the UI previews repayments.  
4. Repay via the *Repay* page before the due date.

### Lenders
1. Deposit USDC through the *Lend* page.  
2. Your funds are allocated automatically when loans are approved.  
3. Withdraw principal plus interest whenever sufficient liquidity is available.

### Attesters
1. Create an attestation for a borrower, choosing a confidence weight.  
2. Earn a share of the attester-reward pool when that borrower repays.

### Oracle / Admin
1. Trigger PageRank computation after new attestations.  
2. Update `effrRate`, `riskPremium`, `maxLoanAmount` as needed.  
3. Monitor pool metrics and reserved liquidity.

---

## Development

• Smart-contract sources: `packages/foundry/contracts/`  
• Tests: `packages/foundry/test/`  
• Front-end code: `packages/nextjs/`  

Common tasks:
```bash
# Run Solidity tests
yarn foundry:test

# Type-check & lint the front-end
yarn next:check-types && yarn next:lint
```

---

## Contributing
See `CONTRIBUTING.md` for guidelines.  Pull requests are welcome.

---

© 2024 — Licensed under the MIT License

---

## Implementation Notes

**TODO: Loan Amount Calculation** - The current implementation reduces the borrowable amount by 1% for each additional week beyond 1 week. This approach should be reviewed and made consistent with industry best practices for loan amount calculation, risk assessment, and borrower qualification criteria. Consider factors such as:

- Risk-based pricing models
- Borrower income verification
- Debt-to-income ratios
- Collateral requirements for longer-term loans
- Regulatory compliance requirements
- Industry standard loan-to-value ratios

The current weekly reduction model is a simplified approach for demonstration purposes and should be enhanced for production use.
