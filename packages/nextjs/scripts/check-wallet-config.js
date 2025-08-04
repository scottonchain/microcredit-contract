#!/usr/bin/env node

/**
 * Script to check WalletConnect configuration
 */

console.log('🔍 Checking WalletConnect configuration...\n');

// Check if .env.local exists
const fs = require('fs');
const path = require('path');

const envPath = path.join(__dirname, '..', '.env.local');
const envExists = fs.existsSync(envPath);

console.log('1. Environment file check:');
console.log(`   - .env.local exists: ${envExists ? '✅ Yes' : '❌ No'}`);

if (envExists) {
  const envContent = fs.readFileSync(envPath, 'utf8');
  const hasWalletConnectId = envContent.includes('NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID');
  console.log(`   - WalletConnect Project ID configured: ${hasWalletConnectId ? '✅ Yes' : '❌ No'}`);
  
  if (hasWalletConnectId) {
    const match = envContent.match(/NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=(.+)/);
    if (match) {
      const projectId = match[1].trim();
      console.log(`   - Project ID: ${projectId}`);
      console.log(`   - Project ID length: ${projectId.length} characters`);
      console.log(`   - Using default ID: ${projectId === 'c4f79cc821944d9680842e34466bfbd9' ? '⚠️ Yes (default)' : '✅ No (custom)'}`);
    }
  }
} else {
  console.log('   - Creating .env.local file with default WalletConnect Project ID...');
  const defaultEnvContent = `# WalletConnect Project ID
# Get your own at https://cloud.walletconnect.com
NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=c4f79cc821944d9680842e34466bfbd9

# Other environment variables can be added here
`;
  fs.writeFileSync(envPath, defaultEnvContent);
  console.log('   ✅ .env.local file created with default WalletConnect Project ID');
}

console.log('\n2. Network configuration:');
console.log('   - Target network: Foundry (local)');
console.log('   - RPC URL: http://localhost:8545');

console.log('\n3. Wallet support:');
console.log('   - MetaMask: ✅ Supported');
console.log('   - Coinbase Wallet: ✅ Supported');
console.log('   - Rabby Wallet: ✅ Supported');

console.log('\n4. Troubleshooting tips:');
console.log('   - If using default WalletConnect Project ID, consider getting your own');
console.log('   - Ensure your local blockchain is running (anvil/foundry)');
console.log('   - Check browser console for specific error messages');
console.log('   - Try connecting with MetaMask first, then other wallets');

console.log('\n✅ Configuration check completed!'); 