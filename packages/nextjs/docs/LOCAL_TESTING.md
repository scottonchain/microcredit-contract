# Local Testing Connection Information

This document provides all the necessary connection details for testing the microcredit platform locally.

## 🚀 Quick Start

### 1. Start Local Blockchain
```bash
# From project root
cd packages/foundry
yarn chain
# or
anvil
```

### 2. Deploy Contracts
```bash
# From packages/foundry
yarn deploy
# or
forge script script/Deploy.s.sol:DeployScript --rpc-url localhost --broadcast
```

### 3. Start Frontend
```bash
# From packages/nextjs
yarn dev
```

## 🔗 Network Configuration

### Completely Free Gas (Zero-Cost Transactions)
The local Anvil network is configured with completely free gas to provide the best user experience:
- **Gas Price**: 0 wei (completely free)
- **Base Fee**: 0 wei (completely free)
- **Transactions**: 100% free, no gas costs whatsoever

### Local Anvil Network
- **Network Name**: Localhost (Foundry)
- **Chain ID**: `31337`
- **RPC URL**: `http://127.0.0.1:8545`
- **Currency**: ETH
- **Block Explorer**: `http://127.0.0.1:8545`
- **Gas Price**: 0 wei (completely free)
- **Base Fee**: 0 wei (completely free)
- **Gas Limit**: 600M (very high limit for complex transactions)

### Wallet Configuration
Add this network to your wallet:

#### MetaMask
1. Open MetaMask
2. Click "Add Network"
3. Fill in:
   - **Network Name**: Localhost 8545
   - **New RPC URL**: `http://127.0.0.1:8545`
   - **Chain ID**: `31337`
   - **Currency Symbol**: ETH
   - **Block Explorer URL**: `http://127.0.0.1:8545`

#### Coinbase Wallet
1. Open Coinbase Wallet
2. Go to Settings → Networks
3. Add Custom Network:
   - **Network Name**: Localhost
   - **RPC URL**: `http://127.0.0.1:8545`
   - **Chain ID**: `31337`
   - **Currency**: ETH

#### Rabby Wallet
1. Open Rabby Wallet
2. Go to Settings → Networks
3. Add Custom Network with the same details as above

## 📋 Contract Addresses

### Mock USDC Token
- **Address**: `0x49b8e3b089d4ebf9f37b1da9b839ec013c2cd8c9`
- **Symbol**: USDC
- **Decimals**: 6
- **Type**: ERC-20 Mock Token

### DecentralizedMicrocredit Contract
- **Address**: Check `packages/foundry/deployment.json` after deployment
- **Type**: Main Microcredit Platform Contract

## 💰 Funding Your Wallet

### Method 1: Use the Fund Page
1. Navigate to `http://localhost:3000/fund`
2. Connect your wallet
3. Click "Fund 1 ETH" to get test ETH
4. Click "Mint 10,000 USDC" to get test USDC

### Method 2: Manual Funding
```bash
# Fund ETH to your address
cast rpc anvil_setBalance YOUR_ADDRESS 0x8AC7230489E80000 --rpc-url http://127.0.0.1:8545

# Mint USDC (requires deployed contracts)
cast send 0x49b8e3b089d4ebf9f37b1da9b839ec013c2cd8c9 "mint(address,uint256)" YOUR_ADDRESS 10000000000 --rpc-url http://127.0.0.1:8545
```

## 🔧 Environment Variables

### Frontend (.env.local)
Create `packages/nextjs/.env.local`:
```env
# Optional: Custom WalletConnect Project ID
NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=your_project_id_here

# Optional: Custom Alchemy API Key
NEXT_PUBLIC_ALCHEMY_API_KEY=your_alchemy_key_here

# Optional: Target Network (defaults to localhost)
NEXT_PUBLIC_TARGET_NETWORK=localhost
```

### Foundry (.env)
Create `packages/foundry/.env`:
```env
# Optional: Custom RPC URL
RPC_URL=http://127.0.0.1:8545

# Optional: Private key for deployment
PRIVATE_KEY=your_private_key_here
```

## 🧪 Testing Workflow

### 1. Setup
```bash
# Terminal 1: Start blockchain
cd packages/foundry
yarn chain

# Terminal 2: Deploy contracts
cd packages/foundry
yarn deploy

# Terminal 3: Start frontend
cd packages/nextjs
yarn dev
```

### 2. Test User Flow
1. **Connect Wallet**: Use any of the three supported wallets
2. **Get Test Tokens**: Visit `/fund` page
3. **Test Borrowing**: Visit `/borrower` page
4. **Test Lending**: Visit `/lender` page
5. **Test Attestations**: Visit `/attest` page

### 3. Reset State
```bash
# Stop anvil and restart for fresh state
# Or use the reset button in the fund page
```

## 🔍 Debugging

### Common Issues

#### 1. "Cannot connect to RPC"
- Ensure Anvil is running: `yarn chain`
- Check RPC URL: `http://127.0.0.1:8545`
- Verify port 8545 is not blocked

#### 2. "Contract not found"
- Deploy contracts: `yarn deploy`
- Check `deployment.json` for addresses
- Ensure you're on the correct network (Chain ID 31337)

#### 3. "Insufficient balance"
- Fund your wallet via `/fund` page
- Or use manual funding commands above

#### 4. "Wallet not connecting"
- Ensure wallet is on localhost network
- Check wallet permissions
- Try refreshing the page

### Useful Commands

```bash
# Check Anvil status
curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545

# Get account balance
cast balance YOUR_ADDRESS --rpc-url http://127.0.0.1:8545

# Get USDC balance
cast call 0x49b8e3b089d4ebf9f37b1da9b839ec013c2cd8c9 "balanceOf(address)" YOUR_ADDRESS --rpc-url http://127.0.0.1:8545

# View recent transactions
cast logs --rpc-url http://127.0.0.1:8545
```

## 📱 Mobile Testing

### WalletConnect Setup
1. Use WalletConnect on mobile wallets
2. Scan QR code from desktop
3. Approve connection on mobile

### Mobile-Specific Notes
- Ensure desktop and mobile are on same network
- Use WalletConnect for mobile wallet connections
- Test responsive design on mobile browsers

## 🔄 Reset and Cleanup

### Complete Reset
```bash
# Stop all processes
# Delete deployment files
rm packages/foundry/deployment.json
rm packages/foundry/broadcast/Deploy.s.sol/31337/*.json

# Restart from scratch
yarn chain
yarn deploy
yarn dev
```

### Quick Reset
```bash
# Just restart anvil for fresh state
# Keep deployment files for faster testing
```

## 📊 Monitoring

### Anvil Dashboard
- **URL**: `http://127.0.0.1:8545`
- **Features**: Block explorer, transaction history, account balances

### Frontend Monitoring
- **URL**: `http://localhost:3000`
- **Features**: Real-time pool stats, user dashboards, transaction status

### Console Logs
- Check browser console for frontend errors
- Check terminal for Anvil logs
- Check terminal for deployment logs 