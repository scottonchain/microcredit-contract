#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

const keystoreDir = path.join(__dirname, "../keystore");

async function checkAccountBalance(address, rpcUrl = "http://127.0.0.1:8545") {
  try {
    // Connect to provider
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    
    // Get ETH balance
    const ethBalance = await provider.getBalance(address);
    const ethBalanceFormatted = ethers.formatEther(ethBalance);
    
    console.log("💰 Account Balance Check");
    console.log("📍 Address:", address);
    console.log("🪙 ETH Balance:", ethBalanceFormatted, "ETH");
    console.log("🔢 Raw Balance:", ethBalance.toString(), "wei");
    
    // Check if account has enough for gas
    const minBalance = ethers.parseEther("0.01"); // 0.01 ETH minimum
    if (ethBalance < minBalance) {
      console.log("⚠️  Warning: Low balance for gas fees");
      console.log("💡 Consider funding this account with at least 0.01 ETH");
    } else {
      console.log("✅ Sufficient balance for gas fees");
    }
    
    return {
      address,
      ethBalance: ethBalance.toString(),
      ethBalanceFormatted,
      hasEnoughForGas: ethBalance >= minBalance
    };
  } catch (error) {
    console.error("❌ Error checking account balance:", error.message);
    throw error;
  }
}

function listKeystores() {
  try {
    if (!fs.existsSync(keystoreDir)) {
      console.log("📁 No keystore directory found");
      return [];
    }
    
    const files = fs.readdirSync(keystoreDir);
    const keystores = files.filter(file => file.startsWith("UTC--"));
    
    if (keystores.length === 0) {
      console.log("📁 No keystore files found");
      return [];
    }
    
    console.log("📁 Available keystores:");
    keystores.forEach((file, index) => {
      const address = file.split("--")[2];
      console.log(`${index + 1}. ${file} (${address})`);
    });
    
    return keystores;
  } catch (error) {
    console.error("❌ Error listing keystores:", error.message);
    return [];
  }
}

if (require.main === module) {
  const address = process.argv[2];
  const rpcUrl = process.argv[3] || "http://127.0.0.1:8545";
  
  if (!address) {
    console.log("📋 Listing available keystores:");
    listKeystores();
    console.log("\n💡 To check balance: node checkAccountBalance.js <address> [rpc-url]");
    process.exit(0);
  }
  
  checkAccountBalance(address, rpcUrl);
}

module.exports = { checkAccountBalance, listKeystores };
