#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const ethers = require("ethers");

const keystoreDir = path.join(__dirname, "../keystore");

// Ensure keystore directory exists
if (!fs.existsSync(keystoreDir)) {
  fs.mkdirSync(keystoreDir, { recursive: true });
}

function importAccount(privateKey, password = "password") {
  try {
    // Create wallet from private key
    const wallet = new ethers.Wallet(privateKey);
    
    // Create keystore filename
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const filename = `UTC--${timestamp}--${wallet.address}`;
    const filepath = path.join(keystoreDir, filename);
    
    // Create keystore content
    const keystore = {
      address: wallet.address.toLowerCase().replace("0x", ""),
      crypto: {
        cipher: "aes-128-ctr",
        cipherparams: {
          iv: crypto.randomBytes(16).toString("hex")
        },
        ciphertext: wallet.privateKey,
        kdf: "pbkdf2",
        kdfparams: {
          c: 262144,
          dklen: 32,
          prf: "hmac-sha256",
          salt: crypto.randomBytes(32).toString("hex")
        },
        mac: crypto.createHmac("sha256", wallet.privateKey).digest("hex")
      },
      id: crypto.randomUUID(),
      version: 3
    };
    
    // Write keystore file
    fs.writeFileSync(filepath, JSON.stringify(keystore, null, 2));
    
    console.log("✅ Account imported successfully!");
    console.log("📁 File:", filename);
    console.log("📍 Address:", wallet.address);
    
    return {
      filename,
      address: wallet.address
    };
  } catch (error) {
    console.error("❌ Error importing account:", error.message);
    throw error;
  }
}

if (require.main === module) {
  const privateKey = process.argv[2];
  if (!privateKey) {
    console.error("❌ Please provide a private key as argument");
    console.log("Usage: node importAccount.js <private-key>");
    process.exit(1);
  }
  
  importAccount(privateKey);
}

module.exports = { importAccount };
