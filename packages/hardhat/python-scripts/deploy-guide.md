# Contract Deployment Guide

## Prerequisites
1. Make sure you have Foundry installed
2. Make sure you have a local blockchain running (`yarn chain`)
3. Make sure you have the keystore set up

## Deployment Steps

### 1. Start Local Blockchain
```bash
yarn chain
```

### 2. Deploy Contracts
```bash
yarn deploy
```

**Note:** By default, MockUSDC is not deployed to reduce gas costs and deployment time. To deploy with MockUSDC for testing purposes:

```bash
DEPLOY_MOCK_USDC=true yarn deploy
```

**Important:** When deploying without MockUSDC, the contract will use `address(0)` as the USDC address. For production deployments, you'll need to manually update this to the actual USDC contract address on your target network.

### 3. Update Frontend
After deployment, the frontend should automatically pick up the new contract address and ABI.

## Environment Variables

- `DEPLOY_MOCK_USDC=true` - Deploy MockUSDC contract for testing (default: false)
- `LOCALHOST_KEYSTORE_ACCOUNT` - Set to 'scaffold-eth-default' to skip keystore password prompt on localhost

## Troubleshooting

### If you get keystore errors:
1. Set the `LOCALHOST_KEYSTORE_ACCOUNT` in your `.env` file
2. Run `make setup-anvil-wallet` to initialize the keystore

### If you get contract size errors:
The contract has been optimized to reduce size. If you still get size errors:
1. Remove more functions that aren't essential
2. Split the contract into multiple contracts
3. Use libraries for complex logic

### If you get compilation errors:
1. Make sure all dependencies are installed: `forge install`
2. Check that the contract syntax is correct
3. Verify that all imports are available

## Contract Interface

The optimized contract maintains all the core functionality:
- Loan management (request, fund, repay)
- Attestation system
- PageRank-based credit scoring
- Lending pool functionality
- Yield distribution

All frontend components should work with the optimized contract without changes. 