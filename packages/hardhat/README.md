# Hardhat Package for Microcredit Contract

This package contains the Hardhat configuration and scripts for the microcredit contract, converted from Foundry to enable zero gas price development and testing.

## Features

- ✅ **Zero Gas Price**: Configured for completely free transactions on local network
- ✅ **TypeScript Support**: Full TypeScript integration with type-safe contract interactions
- ✅ **Modern Ethers.js**: Uses ethers.js v6 for better performance and features
- ✅ **Comprehensive Testing**: Mocha/Chai test suite with full coverage
- ✅ **Account Management**: Keystore generation and management utilities
- ✅ **Multi-Network Support**: Ready for deployment to various networks

## Quick Start

### 1. Install Dependencies

```bash
cd packages/hardhat
yarn install
```

### 2. Start Local Network (Zero Gas)

```bash
# From project root
yarn chain

# Or directly
cd packages/hardhat
yarn chain
```

### 3. Compile Contracts

```bash
yarn compile
```

### 4. Deploy Contracts

```bash
yarn deploy
```

### 5. Run Tests

```bash
yarn test
```

## Configuration

### Environment Variables

Copy `env.example` to `.env` and configure:

```bash
# Private key for deployment
PRIVATE_KEY=your_private_key_here

# RPC URLs for different networks
MAINNET_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/your_key
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/your_key

# API Keys
ETHERSCAN_API_KEY=your_etherscan_key
ALCHEMY_API_KEY=your_alchemy_key
```

### Zero Gas Configuration

The Hardhat network is configured with:

```typescript
networks: {
  hardhat: {
    chainId: 31337,
    gasPrice: 0,  // Zero gas price
    allowUnlimitedContractSize: true,
    accounts: {
      mnemonic: "test test test test test test test test test test test junk",
      accountsBalance: "10000000000000000000000", // 10,000 ETH
    },
  },
  localhost: {
    url: "http://127.0.0.1:8545",
    chainId: 31337,
    gasPrice: 0,  // Zero gas price
    allowUnlimitedContractSize: true,
  },
}
```

## Scripts

### Account Management

```bash
# Generate new keystore
yarn account:generate

# Import account with private key
yarn account:import <private-key>

# Reveal private key for address
yarn account:reveal-pk <address>

# Check account balance
node scripts/checkAccountBalance.js <address>
```

### Development

```bash
# Start local network
yarn chain

# Compile contracts
yarn compile

# Deploy contracts
yarn deploy

# Run tests
yarn test

# Format code
yarn format

# Lint contracts
yarn lint
```

### Deployment

```bash
# Deploy to localhost
yarn deploy:local

# Deploy to specific network
yarn hardhat run scripts/deploy.ts --network sepolia
```

## Project Structure

```
packages/hardhat/
├── contracts/                 # Smart contracts
│   ├── DecentralizedMicrocredit.sol
│   └── MockUSDC.sol
├── scripts/                   # Deployment and utility scripts
│   ├── deploy.ts             # Main deployment script
│   ├── generateKeystore.js   # Keystore generation
│   ├── importAccount.js      # Account import
│   ├── revealPK.js           # Private key reveal
│   └── checkAccountBalance.js # Balance checking
├── test/                     # Test files
│   └── DecentralizedMicrocredit.test.ts
├── hardhat.config.ts         # Hardhat configuration
├── package.json              # Dependencies and scripts
└── README.md                 # This file
```

## Testing

The test suite includes:

- ✅ Contract deployment verification
- ✅ Access control tests
- ✅ USDC operations
- ✅ Loan operations
- ✅ Oracle operations

Run tests with:

```bash
yarn test
```

## Migration from Foundry

This package replaces the Foundry tooling with Hardhat equivalents:

| Foundry Command | Hardhat Equivalent |
|----------------|-------------------|
| `forge build` | `yarn compile` |
| `forge test` | `yarn test` |
| `forge script` | `yarn hardhat run scripts/deploy.ts` |
| `anvil` | `yarn chain` |
| `cast` | `yarn hardhat console` |

## Frontend Integration

The frontend (Next.js) connects to the Hardhat node at `http://localhost:8545`. The `deployedContracts.ts` file is automatically updated with contract addresses after deployment.

## Troubleshooting

### Gas Price Not Zero

If you're still seeing gas prices:

1. Ensure you're using `yarn chain` (not the old Anvil script)
2. Check that `gasPrice: 0` is set in `hardhat.config.ts`
3. Restart the Hardhat node

### Contract Compilation Issues

```bash
# Clean and recompile
yarn clean
yarn compile
```

### Test Failures

```bash
# Run tests with verbose output
yarn hardhat test --verbose
```

## Contributing

1. Make changes to contracts in `contracts/`
2. Update tests in `test/`
3. Run `yarn test` to ensure all tests pass
4. Update deployment script if needed
5. Submit pull request

## License

This project is licensed under the MIT License. 