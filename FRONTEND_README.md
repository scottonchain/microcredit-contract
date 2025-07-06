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
  contractName: "YourContract",
  functionName: "getCreditScore",
  args: [address],
});

// Writing to contracts
const { writeAsync: recordAttestation } = useScaffoldContractWrite({
  contractName: "YourContract",
  functionName: "recordAttestation",
});
```

## 🎨 UI Components

### Scaffold-ETH Components
- `<Address />`: Display Ethereum addresses
- `<AddressInput />`: Input field for addresses
- `<Balance />`: Display token balances
- `<RainbowKitCustomConnectButton />`: Wallet connection

### Custom Components
- Credit score displays with color coding
- Loan management forms
- Attestation interfaces
- Admin panels

## 🧪 Testing

### Run Frontend Tests

```bash
# Run Next.js tests
cd packages/nextjs
yarn test
```

### Run Contract Tests

```bash
# Run Foundry tests
cd packages/foundry
forge test
```

## 🚀 Deployment

### Deploy to Vercel

```bash
# Deploy frontend
yarn vercel
```

### Deploy to IPFS

```bash
# Build and deploy to IPFS
yarn ipfs
```

## 🔧 Development

### Project Structure

```
packages/nextjs/
├── app/                    # Next.js App Router pages
│   ├── page.tsx           # Dashboard
│   ├── attest/            # Attestation page
│   ├── borrow/            # Loan request page
│   ├── lend/              # Lending page
│   ├── repay/             # Repayment page
│   ├── scores/            # Credit scores page
│   └── admin/             # Admin panel
├── components/            # React components
│   ├── scaffold-eth/      # Scaffold-ETH components
│   └── Header.tsx         # Navigation header
├── hooks/                 # Custom React hooks
└── contracts/             # Contract ABIs and addresses
```

### Adding New Features

1. **Create Page**: Add new page in `packages/nextjs/app/`
2. **Add Navigation**: Update `Header.tsx` menu links
3. **Contract Integration**: Use Scaffold-ETH hooks
4. **Styling**: Use Tailwind CSS classes

## 🐛 Troubleshooting

### Common Issues

1. **Contract Not Found**: Ensure contracts are deployed and addresses are correct
2. **Wallet Connection**: Check if MetaMask is installed and connected
3. **Network Issues**: Verify you're on the correct network (localhost for development)
4. **Build Errors**: Clear `.next` cache and reinstall dependencies

### Debug Mode

Access the debug page at `/debug` to:
- View contract state
- Test contract functions
- Monitor transactions
- Debug contract interactions

## 📚 Additional Resources

- [Scaffold-ETH 2 Documentation](https://docs.scaffoldeth.io/)
- [Next.js Documentation](https://nextjs.org/docs)
- [Tailwind CSS Documentation](https://tailwindcss.com/docs)
- [Wagmi Documentation](https://wagmi.sh/)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🆘 Support

For support and questions:
- Open an issue on GitHub
- Check the documentation
- Join our community discussions

---

**Happy Building! 🚀** 