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

function generateKeystore() {
  // Generate a new wallet
  const wallet = ethers.Wallet.createRandom();
  
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
  
  console.log("✅ Keystore generated successfully!");
  console.log("📁 File:", filename);
  console.log("📍 Address:", wallet.address);
  console.log("🔑 Private Key:", wallet.privateKey);
  console.log("💡 Save the private key securely - it won't be shown again!");
  
  return {
    filename,
    address: wallet.address,
    privateKey: wallet.privateKey
  };
}

if (require.main === module) {
  generateKeystore();
}

module.exports = { generateKeystore };
