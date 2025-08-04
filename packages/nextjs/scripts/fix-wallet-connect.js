#!/usr/bin/env node

/**
 * Script to help fix WalletConnect connection issues
 * Run this script to clear WalletConnect cache and reset connections
 */

const fs = require('fs');
const path = require('path');

console.log('🔧 Fixing WalletConnect connection issues...\n');

// Clear localStorage items related to WalletConnect
console.log('1. Clearing WalletConnect cache from localStorage...');
console.log('   - Open browser developer tools (F12)');
console.log('   - Go to Application/Storage tab');
console.log('   - Find "Local Storage" for your domain');
console.log('   - Delete any items starting with "wc_" or "walletconnect"');
console.log('   - Delete any items containing "WalletConnect"');

// Clear sessionStorage
console.log('\n2. Clearing sessionStorage...');
console.log('   - In the same Application/Storage tab');
console.log('   - Find "Session Storage" for your domain');
console.log('   - Delete any items starting with "wc_" or "walletconnect"');

// Clear IndexedDB
console.log('\n3. Clearing IndexedDB...');
console.log('   - In Application/Storage tab');
console.log('   - Find "IndexedDB"');
console.log('   - Delete any databases containing "walletconnect" or "wc"');

// Browser cache
console.log('\n4. Clearing browser cache...');
console.log('   - Press Ctrl+Shift+Delete (or Cmd+Shift+Delete on Mac)');
console.log('   - Select "Cached images and files"');
console.log('   - Click "Clear data"');

// Hard refresh
console.log('\n5. Hard refresh the page...');
console.log('   - Press Ctrl+Shift+R (or Cmd+Shift+R on Mac)');
console.log('   - Or hold Shift and click the refresh button');

// Additional steps
console.log('\n6. Additional troubleshooting steps:');
console.log('   - Try using a different browser');
console.log('   - Disable browser extensions temporarily');
console.log('   - Check if your network blocks WebSocket connections');
console.log('   - Try connecting with a different wallet first');

console.log('\n✅ WalletConnect cache clearing instructions completed!');
console.log('   After following these steps, try connecting your wallet again.'); 