import { listKeystores } from "./listKeystores.js";
import { execFileSync } from "child_process";
import dotenv from "dotenv";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { toString } from "qrcode";
import {
  readAccount,
  readRpcEndpoints,
  resolveRpcEndpoint,
} from "./foundryClient.js";

// Load environment variables
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
dotenv.config({ path: join(__dirname, "..", ".env") });

async function getBalanceForEachNetwork(address) {
  try {
    const rpcEndpoints = readRpcEndpoints();

    console.log(await toString(address, { type: "terminal", small: true }));
    console.log(`\n📊 Address: ${address}`);

    for (const [networkName, endpoint] of Object.entries(rpcEndpoints)) {
      const networkUrl = resolveRpcEndpoint(endpoint);
      if (!networkUrl) continue; // This endpoint has no URL or lacks a configured credential.
      console.log(`\n--${networkName}-- 📡`);

      try {
        const { balance, nonce } = readAccount(address, networkUrl);
        console.log("   Balance:", balance);
        console.log("   Nonce:", nonce);
      } catch (e) {
        console.log(
          `   ❌ Can't connect to network ${networkName}: ${e.message}`
        );
      }
    }
  } catch (error) {
    console.error("Error reading foundry.toml:", error);
  }
}

async function checkAccountBalance() {
  try {
    // Step 1: List accounts and let user select one
    console.log("📋 Listing available accounts...");
    const selectedKeystore = await listKeystores(
      "Select a keystore to display its balance (enter the number, e.g., 1): "
    );

    if (!selectedKeystore) {
      console.error("❌ No keystore selected");
      process.exit(1);
    }

    // Step 2: Get the address of the selected account
    console.log(`\n🔍 Getting address for keystore: ${selectedKeystore}`);
    let address;
    try {
      address = execFileSync(
        "cast",
        ["wallet", "address", "--account", selectedKeystore],
        {
          encoding: "utf-8",
          stdio: ["inherit", "pipe", "inherit"],
        }
      ).trim();
      console.log("\n💰 Checking balances across networks...");
      console.log("\n");
      await getBalanceForEachNetwork(address);
    } catch (error) {
      console.error(`❌ Error getting address: ${error.message}`);
      process.exit(1);
    }
  } catch (error) {
    console.error(`\n❌ Error: ${error.message}`);
    process.exit(1);
  }
}

// Run the function if this script is called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  checkAccountBalance().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

export { checkAccountBalance };
