# Decentralized Microcredit Frontend

A comprehensive frontend for the decentralized microcredit system built with Scaffold-ETH 2, featuring social reputation-based lending powered by PageRank algorithms.

## 🚀 Features

### Core Functionality
- **Social Attestations**: Users can attest to others' creditworthiness with confidence levels
- **Credit Scoring**: PageRank-based reputation system for calculating credit scores
- **Loan Management**: Request, fund, and repay loans with dynamic interest rates
- **Lending Pool**: Deposit funds and earn yield from loan interest
- **Admin Panel**: Oracle functions for system management

### Pages & Components
- **Dashboard** (`/`): Overview with pool statistics and user profile
- **Attest** (`/attest`): Make attestations to build trust networks
- **Borrow** (`/borrow`): Request loans based on credit score
- **Lend** (`/lend`): Deposit funds and fund loan requests
- **Repay** (`/repay`): Manage and repay outstanding loans
- **Scores** (`/scores`): View credit scores and reputation data
- **Admin** (`/admin`): Oracle functions and system management

## 🛠 Tech Stack

- **Framework**: Next.js 14 with App Router
- **Styling**: Tailwind CSS
- **Web3**: Wagmi + RainbowKit
- **Smart Contracts**: Foundry + Solidity
- **UI Components**: Heroicons, custom Scaffold-ETH components

## 📋 Prerequisites

Before running the frontend, ensure you have:

1. **Node.js** (v18 or higher)
2. **Yarn** package manager
3. **Foundry** for smart contract compilation
4. **Git** for version control

## 🚀 Quick Start

### 1. Clone and Install Dependencies

```bash
# Clone the repository
git clone <your-repo-url>
cd microcredit-contract

# Install dependencies
yarn install
```

### 2. Start Local Blockchain

```bash
# Start local Anvil blockchain
yarn chain
```

This will start a local blockchain on `http://localhost:8545`

### 3. Deploy Smart Contracts

```bash
# Deploy contracts to local blockchain
yarn deploy
```

This will deploy the microcredit contract and mock USDC token.

### 4. Start Frontend

```bash
# Start the Next.js development server
yarn start
```

The frontend will be available at `http://localhost:3000`

## 🔧 Configuration

### Environment Variables

Create a `.env.local` file in the `packages/nextjs` directory:

```env
NEXT_PUBLIC_TARGET_NETWORK=localhost
NEXT_PUBLIC_CONTRACT_ADDRESS=0x... # Your deployed contract address
NEXT_PUBLIC_USDC_ADDRESS=0x... # Your deployed USDC address
```

### Contract Configuration

The frontend automatically reads contract addresses from:
- `packages/nextjs/contracts/deployedContracts.ts` (for deployed contracts)
- `packages/nextjs/contracts/externalContracts.ts` (for external contracts)

## 🎯 Usage Guide

### For Borrowers

1. **Build Reputation**: Get attested by others in your community
2. **Check Credit Score**: View your PageRank-based credit score
3. **Request Loan**: Submit loan requests with amount and terms
4. **Repay Loans**: Make timely repayments to maintain good standing

### For Lenders

1. **Deposit Funds**: Add USDC to the lending pool
2. **Fund Loans**: Your funds are automatically allocated to loan requests
3. **Earn Yield**: Receive interest payments when loans are repaid
4. **Claim Earnings**: Withdraw your earned yield

### For Attesters

1. **Make Attestations**: Provide confidence ratings for others
2. **Build Network**: Create trust relationships in the community
3. **Earn Rewards**: Receive rewards for successful loan attestations

### For Admins/Oracles

1. **Update Scores**: Manually update credit scores when needed
2. **Run PageRank**: Trigger PageRank computation
3. **System Management**: Monitor and manage the platform

## 🔍 Smart Contract Integration

The frontend uses Scaffold-ETH 2 hooks for seamless contract interaction:

```typescript
// Reading contract data
const { data: creditScore } = useScaffoldReadContract({
  contractName: "DecentralizedMicrocredit",
  functionName: "getCreditScore",
  args: [address],
});

// Writing to contracts
const { writeAsync: recordAttestation } = useScaffoldContractWrite({
  contractName: "DecentralizedMicrocredit",
  functionName: "recordAttestation",
});
```