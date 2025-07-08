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

### 3. Update Frontend
After deployment, the frontend should automatically pick up the new contract address and ABI.

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