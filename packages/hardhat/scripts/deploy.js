import hre from "hardhat";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const { ethers } = hre;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main() {
  console.log("🚀 Starting deployment...");
  
  // Check for redeploy flag via environment variable or command line args
  const forceRedeployUsdc = process.env.REDEPLOY_USDC === 'true' || process.argv.includes('--redeploy-usdc');
  
  if (forceRedeployUsdc) {
    console.log("🔄 Flag detected: Force redeploying MockUSDC");
  }
  
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // Check if chain-state.json exists
  const chainStatePath = path.join(__dirname, "../../../chain-state.json");
  let usdcAddress;

  // For now, always deploy fresh contracts to ensure they exist on the current blockchain state
  // This addresses the issue where Hardhat starts with fresh state but we try to reuse old addresses
  console.log("🔄 Deploying fresh MockUSDC to ensure contract exists on current blockchain state...");
  usdcAddress = await deployMockUSDC();
  
  // TODO: Implement proper blockchain state persistence in the future
  // The current approach ensures contracts are always available but doesn't persist state
  // This is a temporary fix until we implement proper state management

  // Deploy the Microcredit contract
  console.log("🏗️ Deploying DecentralizedMicrocredit...");
  const DecentralizedMicrocredit = await ethers.getContractFactory("DecentralizedMicrocredit");
  
  console.log(`🔗 Using USDC address: ${usdcAddress}`);
  const microcreditContract = await DecentralizedMicrocredit.deploy(
    433,     // effrRate 4.33% (scaled 1e4) – current market rate
    500,     // riskPremium 5.0% (scaled 1e4) – platform premium
    100 * 1e6, // maxLoanAmount 100 USDC (6 decimals) – matches personalization cap
    usdcAddress,
    deployer.address // set deployer as oracle placeholder
  );

  await microcreditContract.waitForDeployment();
  const microcreditAddress = await microcreditContract.getAddress();
  
  console.log("✅ DecentralizedMicrocredit deployed at:", microcreditAddress);

  // Set basePersonalization to 0
  console.log("🔧 Setting basePersonalization to 0...");
  const setTx = await microcreditContract.setBasePersonalization(0);
  await setTx.wait();
  console.log("✅ basePersonalization set to 0");

  // Provision ETH to demo addresses
  console.log("💰 Provisioning ETH to demo addresses...");
  
  const demoAddresses = [
    "0x455EB67473a5f8Da69dbFde7eDe1d1c008C31274",
    "0xE51a60126dF85801D4C76bDAf58D6F9E81Cc26cA",
    "0xC9E2518013169a09dfE47Da38b8DA092AB68d66A"
  ];
  
  const ethAmount = ethers.parseEther("10"); // 10 ETH
  
  for (const address of demoAddresses) {
    // Use hardhat_setBalance to set the balance directly
    await ethers.provider.send("hardhat_setBalance", [
      address,
      ethers.toBeHex(ethAmount)
    ]);
    console.log("✅ Provisioned 10 ETH to:", address);
  }

  // Save deployment information
  const deploymentInfo = {
    DecentralizedMicrocredit: microcreditAddress,
    USDC: usdcAddress,
    deployer: deployer.address,
    network: (await ethers.provider.getNetwork()).name,
    timestamp: new Date().toISOString()
  };

  fs.writeFileSync(
    path.join(__dirname, "../deployment.json"),
    JSON.stringify(deploymentInfo, null, 2)
  );

  console.log("📄 Deployment info saved to deployment.json");

  // Also update deployment-config.json with USDC address
  const deploymentConfig = {
    usdcAddress: usdcAddress
  };
  
  fs.writeFileSync(
    path.join(__dirname, "../deployment-config.json"),
    JSON.stringify(deploymentConfig, null, 2)
  );

  console.log("📄 Updated deployment-config.json with USDC address");

  // Update chain-state.json with all contract addresses
  console.log("📄 Updating chain-state.json with all contract addresses...");
  await updateChainState(microcreditAddress, usdcAddress);
  
  // Update frontend contracts
  console.log("🔧 Updating frontend contract addresses...");
  await updateFrontendContracts(microcreditAddress, usdcAddress);

  // Verify contracts are properly deployed and accessible
  console.log("🔍 Verifying contract deployments...");
  await verifyContractDeployments(microcreditAddress, usdcAddress);

  console.log("🎉 Deployment completed successfully!");
  console.log("Note: Admin addresses can fund themselves using the /fund page");
  console.log("Use the web interface to populate test data (lenders, borrowers, attestations)");
}

async function deployMockUSDC() {
  console.log("🏗️ Deploying MockUSDC...");
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  const address = await mockUSDC.getAddress();
  console.log("✅ MockUSDC deployed at:", address);
  
  // Verify the contract was actually deployed
  const deployedCode = await ethers.provider.getCode(address);
  if (deployedCode === "0x") {
    throw new Error(`Failed to deploy MockUSDC contract at ${address}`);
  }
  console.log("✅ MockUSDC contract bytecode verified at:", address);

  // Update chain-state.json
  const chainStatePath = path.join(__dirname, "../../../chain-state.json");
  let chainState = {};
  
  // Read existing chain state if it exists
  if (fs.existsSync(chainStatePath)) {
    try {
      const chainStateContent = fs.readFileSync(chainStatePath, "utf8");
      chainState = JSON.parse(chainStateContent);
    } catch (error) {
      console.log("⚠️ Error reading existing chain-state.json, creating new one");
    }
  }
  
  // Update USDC address in chain state
  if (!chainState.contracts) chainState.contracts = {};
  chainState.contracts.MockUSDC = { address };
  chainState.timestamp = new Date().toISOString();
  
  fs.writeFileSync(chainStatePath, JSON.stringify(chainState, null, 2));
  console.log("📄 Updated chain-state.json with new USDC address");

  // Also update deployment-config.json immediately
  const deploymentConfig = {
    usdcAddress: address
  };
  
  fs.writeFileSync(
    path.join(__dirname, "../deployment-config.json"),
    JSON.stringify(deploymentConfig, null, 2)
  );
  console.log("📄 Updated deployment-config.json with new USDC address");

  return address;
}

async function updateChainState(microcreditAddress, usdcAddress) {
  try {
    const chainStatePath = path.join(__dirname, "../../../chain-state.json");
    let chainState = {};
    
    // Read existing chain state if it exists
    if (fs.existsSync(chainStatePath)) {
      try {
        const chainStateContent = fs.readFileSync(chainStatePath, "utf8");
        chainState = JSON.parse(chainStateContent);
      } catch (error) {
        console.log("⚠️ Error reading existing chain-state.json, creating new one");
      }
    }
    
    // Update timestamp and deployment info
    chainState.timestamp = new Date().toISOString();
    
    // Update latest deployment info
    const [deployer] = await ethers.getSigners();
    chainState.latestDeployment = {
      DecentralizedMicrocredit: microcreditAddress,
      USDC: usdcAddress,
      deployer: deployer.address,
      network: (await ethers.provider.getNetwork()).name,
      timestamp: new Date().toISOString()
    };
    
    // Update all contract addresses in chain state
    if (!chainState.contracts) chainState.contracts = {};
    chainState.contracts.MockUSDC = { address: usdcAddress };
    chainState.contracts.DecentralizedMicrocredit = { address: microcreditAddress };
    
    fs.writeFileSync(chainStatePath, JSON.stringify(chainState, null, 2));
    console.log("✅ Updated chain-state.json with all contract addresses:");
    console.log(`   MockUSDC: ${usdcAddress}`);
    console.log(`   DecentralizedMicrocredit: ${microcreditAddress}`);
    
  } catch (error) {
    console.error("❌ Failed to update chain-state.json:", error.message);
  }
}

async function updateFrontendContracts(microcreditAddress, usdcAddress) {
  try {
    const frontendContractsPath = path.join(__dirname, "../../nextjs/contracts/deployedContracts.ts");
    
    if (!fs.existsSync(frontendContractsPath)) {
      console.log("⚠️ Frontend deployedContracts.ts not found, skipping update");
      return;
    }

    // Read the current file
    let contractsContent = fs.readFileSync(frontendContractsPath, "utf8");
    
    console.log("🔍 Updating frontend contract addresses...");
    
    // Update MockUSDC address using a more flexible regex that handles multiline formatting
    const usdcRegex = /(MockUSDC:\s*{[\s\S]*?address:\s*")[^"]*(",)/;
    if (usdcRegex.test(contractsContent)) {
      contractsContent = contractsContent.replace(usdcRegex, `$1${usdcAddress}$2`);
      console.log(`\u2705 Updated MockUSDC address to: ${usdcAddress}`);
    } else {
      console.log("\u26a0\ufe0f Could not find MockUSDC address pattern to update");
    }
    
    // Update DecentralizedMicrocredit address using a more flexible regex
    const microcreditRegex = /(DecentralizedMicrocredit:\s*{[\s\S]*?address:\s*")[^"]*(",)/;
    if (microcreditRegex.test(contractsContent)) {
      contractsContent = contractsContent.replace(microcreditRegex, `$1${microcreditAddress}$2`);
      console.log(`\u2705 Updated DecentralizedMicrocredit address to: ${microcreditAddress}`);
    } else {
      console.log("\u26a0\ufe0f Could not find DecentralizedMicrocredit address pattern to update");
    }
    
    // Write the updated content back
    fs.writeFileSync(frontendContractsPath, contractsContent);
    console.log("✅ Frontend contract addresses file updated successfully");
    
  } catch (error) {
    console.error("❌ Failed to update frontend contracts:", error.message);
    console.log("⚠️ You may need to manually update the frontend contract addresses");
  }
}

async function verifyContractDeployments(microcreditAddress, usdcAddress) {
  try {
    console.log("🔍 Verifying USDC contract deployment...");
    const usdcCode = await ethers.provider.getCode(usdcAddress);
    if (usdcCode === "0x") {
      throw new Error(`No contract found at USDC address: ${usdcAddress}`);
    }
    
    // Try to interact with the USDC contract
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdcContract = MockUSDC.attach(usdcAddress);
    const usdcName = await usdcContract.name();
    console.log(`✅ USDC contract verified: ${usdcName} at ${usdcAddress}`);
    
    console.log("🔍 Verifying DecentralizedMicrocredit contract deployment...");
    const microcreditCode = await ethers.provider.getCode(microcreditAddress);
    if (microcreditCode === "0x") {
      throw new Error(`No contract found at DecentralizedMicrocredit address: ${microcreditAddress}`);
    }
    
    // Try to interact with the Microcredit contract
    const DecentralizedMicrocredit = await ethers.getContractFactory("DecentralizedMicrocredit");
    const microcreditContract = DecentralizedMicrocredit.attach(microcreditAddress);
    const usdcTokenAddress = await microcreditContract.usdc();
    console.log(`\u2705 DecentralizedMicrocredit contract verified at ${microcreditAddress}`);
    console.log(`\u2705 Contract references USDC at: ${usdcTokenAddress}`);
    
    if (usdcTokenAddress.toLowerCase() !== usdcAddress.toLowerCase()) {
      console.warn(`\u26a0\ufe0f Warning: Microcredit contract references USDC at ${usdcTokenAddress}, but deployed USDC is at ${usdcAddress}`);
    }
    
    console.log("✅ All contract deployments verified successfully!");
    
  } catch (error) {
    console.error("❌ Contract verification failed:", error.message);
    throw error;
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
