#!/usr/bin/env node

// Script to set gas price to zero on Anvil
const RPC_URL = "http://127.0.0.1:8545";

async function setZeroGas() {
  try {
    console.log("🔧 Setting gas price to zero...");
    
    // Set gas price to 0 via RPC
    const response = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "anvil_setNextBlockBaseFeePerGas",
        params: ["0x0"]
      })
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result = await response.json();
    console.log("✅ Gas price set to zero:", result);

    // Verify the gas price is now zero
    const gasPriceResponse = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        method: "eth_gasPrice",
        params: []
      })
    });

    const gasPriceResult = await gasPriceResponse.json();
    console.log("🔍 Current gas price:", gasPriceResult.result);
    
    if (gasPriceResult.result === "0x0") {
      console.log("✅ Successfully set gas price to zero!");
    } else {
      console.log("⚠️ Gas price is still non-zero:", gasPriceResult.result);
    }

  } catch (error) {
    console.error("❌ Error setting gas price:", error);
  }
}

setZeroGas(); 