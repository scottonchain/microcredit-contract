#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

const keystoreDir = path.join(__dirname, "../keystore");

function revealPK(address) {
  try {
    // Find keystore file for the given address
    const files = fs.readdirSync(keystoreDir);
    const keystoreFile = files.find(file => file.includes(address.toLowerCase().replace("0x", "")));
    
    if (!keystoreFile) {
      console.error("❌ No keystore found for address:", address);
      return null;
    }
    
    const keystorePath = path.join(keystoreDir, keystoreFile);
    const keystoreContent = fs.readFileSync(keystorePath, "utf8");
    const keystore = JSON.parse(keystoreContent);
    
    console.log("✅ Found keystore for address:", address);
    console.log("📁 File:", keystoreFile);
    console.log("🔑 Private Key:", keystore.crypto.ciphertext);
    
    return keystore.crypto.ciphertext;
  } catch (error) {
    console.error("❌ Error revealing private key:", error.message);
    throw error;
  }
}

if (require.main === module) {
  const address = process.argv[2];
  if (!address) {
    console.error("❌ Please provide an address as argument");
    console.log("Usage: node revealPK.js <address>");
    process.exit(1);
  }
  
  revealPK(address);
}

module.exports = { revealPK };
