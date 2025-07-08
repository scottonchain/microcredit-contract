# Contract Deployment Guide

Since forge is not available in your PowerShell environment, follow these steps to deploy the updated contract:

## Step 1: Start Local Blockchain

Open a new PowerShell window and run:
```powershell
cd packages/foundry
anvil
```

## Step 2: Start Frontend

Open another PowerShell window and run:
```powershell
cd packages/nextjs
yarn dev
```

## Step 3: Deploy Contract via Debug Page

1. Go to `http://localhost:3000/debug`
2. Find the "DecentralizedMicrocredit" section
3. Look for the constructor function (it will be at the top)
4. Fill in these parameters:
   - `_rMin`: `50000` (5% interest rate minimum)
   - `_rMax`: `200000` (20% interest rate maximum)
   - `_usdc`: Use your wallet address (or `0x0000000000000000000000000000000000000000` for testing)
   - `_oracle`: Use your wallet address (this will make you the oracle)
5. Click "Write" to deploy
6. Wait for the transaction to complete

## Step 4: Update Contract Address

After deployment, the contract address will be displayed. Copy this address and update it in:
- `packages/nextjs/contracts/deployedContracts.ts` (line with `address:`)

## Step 5: Test Functions

Once deployed, you can test the new functions:
- Go to the debug page
- Try calling `getTotalLoans()`, `getPoolInfo()`, etc.
- They should now work without reverting

## Alternative: Use WSL

If you have WSL available, you can use the standard commands:
```bash
cd /home/scottonchain/microcredit-contract
yarn chain
yarn deploy
yarn start
```

## Troubleshooting

- If functions still revert, make sure the contract was deployed successfully
- Check that you're connected to the correct network (localhost:8545)
- Ensure your wallet has enough ETH for deployment
- If you get "insufficient funds" errors, use the faucet on the debug page 