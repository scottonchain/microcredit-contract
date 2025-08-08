import { spawn } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Path to the chain state file (in the root of the project)
const CHAIN_STATE_PATH = path.join(__dirname, "../../../chain-state.json");
const DEPLOYMENTS_DIR = path.join(__dirname, "../deployments");
const CACHE_DIR = path.join(__dirname, "../cache");

async function createChainStateSnapshot() {
  try {
    const stateData = {
      timestamp: new Date().toISOString(),
      deployments: {},
      cache: {}
    };

    // Save deployment information if it exists
    if (fs.existsSync(DEPLOYMENTS_DIR)) {
      const deploymentFiles = fs.readdirSync(DEPLOYMENTS_DIR);
      for (const file of deploymentFiles) {
        if (file.endsWith('.json')) {
          const deploymentPath = path.join(DEPLOYMENTS_DIR, file);
          stateData.deployments[file] = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
        }
      }
    }

    // Save cache information if it exists
    if (fs.existsSync(CACHE_DIR)) {
      stateData.cache.exists = true;
      const cacheStats = fs.statSync(CACHE_DIR);
      stateData.cache.modified = cacheStats.mtime.toISOString();
    }

    // Save deployment.json if it exists
    const deploymentJsonPath = path.join(__dirname, "../deployment.json");
    if (fs.existsSync(deploymentJsonPath)) {
      stateData.latestDeployment = JSON.parse(fs.readFileSync(deploymentJsonPath, 'utf8'));
    }

    fs.writeFileSync(CHAIN_STATE_PATH, JSON.stringify(stateData, null, 2));
    console.log(`💾 Chain state snapshot saved (${Math.round(JSON.stringify(stateData).length / 1024)}KB)`);
  } catch (error) {
    console.error("❌ Failed to create chain state snapshot:", error.message);
  }
}

async function startHardhatNode() {
  console.log("🚀 Starting Hardhat node with deployment persistence...");
  
  // Check if chain state file exists
  const stateExists = fs.existsSync(CHAIN_STATE_PATH);
  const hardhatDbPath = path.join(__dirname, "../hardhat-db");
  
  if (stateExists) {
    console.log("📁 Found existing chain state file");
    try {
      const stateData = JSON.parse(fs.readFileSync(CHAIN_STATE_PATH, "utf8"));
      console.log(`📊 Previous state from: ${stateData.timestamp}`);
      if (stateData.latestDeployment) {
        console.log(`📋 Last deployment: ${Object.keys(stateData.latestDeployment).filter(k => k !== 'timestamp' && k !== 'network' && k !== 'deployer').join(', ')}`);
      }
    } catch (error) {
      console.log("⚠️ Chain state file exists but couldn't be parsed");
    }
  } else {
    console.log("📝 No existing chain state found, starting fresh");
  }

  console.log("🔧 Starting Hardhat node...");

  // Prepare arguments for hardhat node with state persistence
  const hardhatArgs = ["hardhat", "node"];
  
  // If we have existing state and want to preserve it, use a persistent database
  if (stateExists && fs.existsSync(hardhatDbPath)) {
    console.log("💾 Using persistent blockchain database");
    hardhatArgs.push("--db", hardhatDbPath);
  }

  // Start the Hardhat node process
  const hardhatProcess = spawn("npx", hardhatArgs, {
    stdio: "inherit",
    cwd: path.join(__dirname, ".."),
    env: {
      ...process.env,
      HARDHAT_NETWORK: "hardhat",
      HARDHAT_DB_PATH: hardhatDbPath
    }
  });

  // Handle process termination
  const cleanup = async (signal) => {
    console.log(`\n🛑 Received ${signal}, shutting down Hardhat node...`);
    
    // Create state snapshot before shutdown
    await createChainStateSnapshot();
    
    if (!hardhatProcess.killed) {
      hardhatProcess.kill("SIGTERM");
      
      // Give it time to shutdown gracefully
      setTimeout(() => {
        if (!hardhatProcess.killed) {
          console.log("🔪 Force killing Hardhat node...");
          hardhatProcess.kill("SIGKILL");
        }
      }, 3000);
    }
  };

  // Handle various termination signals
  process.on("SIGINT", () => cleanup("SIGINT"));
  process.on("SIGTERM", () => cleanup("SIGTERM"));
  
  // Handle uncaught exceptions
  process.on("uncaughtException", (error) => {
    console.error("❌ Uncaught exception:", error);
    cleanup("uncaughtException");
  });

  hardhatProcess.on("error", (error) => {
    console.error("❌ Failed to start Hardhat node:", error);
    process.exit(1);
  });

  hardhatProcess.on("exit", async (code, signal) => {
    if (code !== null) {
      console.log(`\n🏁 Hardhat node exited with code ${code}`);
    } else {
      console.log(`\n🏁 Hardhat node terminated by signal ${signal}`);
    }
    
    // Final state snapshot
    if (code === 0 || signal === "SIGTERM") {
      await createChainStateSnapshot();
    }
    
    process.exit(code || 0);
  });

  console.log(`📡 Hardhat node started with PID: ${hardhatProcess.pid}`);
  console.log("🌐 JSON-RPC server available at http://127.0.0.1:8545");
  console.log("💾 Deployment state will be saved to chain-state.json on shutdown");
  console.log("🔄 Use Ctrl+C to gracefully shutdown and save state");
  console.log("ℹ️ Note: Hardhat doesn't support full blockchain state persistence");
  console.log("   Only deployment information and cache state are preserved");
}

// Start the node
startHardhatNode().catch((error) => {
  console.error("❌ Failed to start chain:", error);
  process.exit(1);
});
