// cd packages/foundry/scripts-js 
// node scripts-js/populateParticipants.js
import { ethers } from "ethers";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import dotenv from "dotenv";

// Load environment variables
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
dotenv.config({ path: join(__dirname, "..", ".env") });

// DecentralizedMicrocredit ABI - only including methods that actually exist in the contract
const YOUR_CONTRACT_ABI = [
  "function depositFunds(uint256 amount) external",
  "function recordAttestation(address borrower, uint256 weight) external",
  "function updateCreditScore(address user, uint256 newScore) external",
  "function getCreditScore(address user) external view returns (uint256 score)",
  "function getPageRankScore(address node) external view returns (uint256)",
  "function getAllPageRankScores() external view returns (address[] memory nodes, uint256[] memory scores)",
  "function computePageRank() external returns (uint256 iterations)",
  "function oracle() external view returns (address)",
  "function owner() external view returns (address)"
];

async function populateParticipants() {
  try {
    // Connect to local chain
    const provider = new ethers.providers.JsonRpcProvider("http://localhost:8545");
    
    // Get the deployer account (first account in Anvil)
    const accounts = await provider.listAccounts();
    const deployerAddress = accounts[0];
    
    console.log("🔗 Connected to local chain");
    console.log("📋 Deployer address:", deployerAddress);
    
    // Read deployment info
    const deploymentPath = join(__dirname, "..", "deployment.json");
    const deploymentData = JSON.parse(readFileSync(deploymentPath, "utf-8"));
    
    const creditAddress = deploymentData.DecentralizedMicrocredit;
    console.log("📄 DecentralizedMicrocredit address:", creditAddress);
    
    // Create contract instance
    const credit = new ethers.Contract(creditAddress, YOUR_CONTRACT_ABI, provider);
    
    // Check oracle and owner addresses
    const oracleAddress = await credit.oracle();
    const ownerAddress = await credit.owner();
    console.log("🔐 Oracle address:", oracleAddress);
    console.log("👑 Owner address:", ownerAddress);
    console.log("📋 Deployer address:", deployerAddress);
    
    // Check if deployer is oracle or owner
    if (deployerAddress.toLowerCase() !== oracleAddress.toLowerCase()) {
      console.log("⚠️  Warning: Deployer is not the oracle. Credit score updates may fail.");
      console.log("💡 We'll need to impersonate the oracle to update credit scores.");
    }
    
    // Create participant addresses (same as in tests)
    const testParticipants = [];
    const lenders = [];
    const borrowers = [];
    const attesters = [];
    
    console.log("👥 Creating participant addresses...");
    
    for (let i = 0; i < 20; i++) {
      // Derive deterministic addresses the same way as in tests
      const address = ethers.utils.getAddress(
        ethers.utils.hexlify(
          ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`participant${i}`))
        ).slice(0, 42)
      );
      testParticipants.push(address);
      
      if (i < 7) {
        lenders.push(address);
      } else if (i < 14) {
        borrowers.push(address);
      } else {
        attesters.push(address);
      }
    }
    
    console.log(`✅ Created ${testParticipants.length} participants:`);
    console.log(`   - ${lenders.length} lenders`);
    console.log(`   - ${borrowers.length} borrowers`);
    console.log(`   - ${attesters.length} attesters`);
    
    // Check initial PageRank scores (instead of getAllParticipants which doesn't exist)
    const initialPageRankScores = await credit.getAllPageRankScores();
    console.log(`📊 Initial PageRank nodes in contract: ${initialPageRankScores.nodes.length}`);
    
    // Create signer for transactions
    const signer = provider.getSigner(deployerAddress);
    const creditWithSigner = credit.connect(signer);
    
    console.log("\n🚀 Starting participant population...");
    
    // Step 1: Add borrowers through credit score updates (oracle function)
    console.log("\n📈 Step 1: Adding borrowers via credit score updates...");
    for (let i = 0; i < borrowers.length; i++) {
      const borrower = borrowers[i];
      const creditScore = 300000 + (i * 100000); // 30% to 90% credit score
      
      console.log(`   Updating credit score for borrower ${i + 1}: ${borrower} -> ${creditScore}`);
      
      try {
        // Impersonate oracle if needed
        if (deployerAddress.toLowerCase() !== oracleAddress.toLowerCase()) {
          // Fund the oracle account first
          await provider.send("anvil_setBalance", [oracleAddress, "0x1000000000000000000"]); // 1 ETH
          
          await provider.send("anvil_impersonateAccount", [oracleAddress]);
          const oracleSigner = provider.getSigner(oracleAddress);
          const creditWithOracleSigner = credit.connect(oracleSigner);
          
          const tx = await creditWithOracleSigner.updateCreditScore(borrower, creditScore);
          await tx.wait();
          console.log(`   ✅ Credit score updated for ${borrower}`);
          
          await provider.send("anvil_stopImpersonatingAccount", [oracleAddress]);
        } else {
          const tx = await creditWithSigner.updateCreditScore(borrower, creditScore);
          await tx.wait();
          console.log(`   ✅ Credit score updated for ${borrower}`);
        }
      } catch (error) {
        console.log(`   ⚠️  Error updating credit score for ${borrower}: ${error.message}`);
        // Stop impersonating if there was an error
        try {
          await provider.send("anvil_stopImpersonatingAccount", [oracleAddress]);
        } catch (e) {
          // Ignore error if already stopped
        }
      }
    }
    
    // Step 2: Add attesters and borrowers through attestations
    console.log("\n🤝 Step 2: Adding participants via attestations...");
    for (let i = 0; i < attesters.length && i < borrowers.length; i++) {
      const attester = attesters[i];
      const borrower = borrowers[i];
      const attestationWeight = 500000 + (i * 50000); // 50% to 95% confidence
      
      console.log(`   Recording attestation ${i + 1}: ${attester} -> ${borrower} (weight: ${attestationWeight})`);
      
      try {
        // Fund the attester account first
        await provider.send("anvil_setBalance", [attester, "0x1000000000000000000"]); // 1 ETH
        
        // Impersonate attester
        await provider.send("anvil_impersonateAccount", [attester]);
        const attesterSigner = provider.getSigner(attester);
        const creditWithAttesterSigner = credit.connect(attesterSigner);
        
        const tx = await creditWithAttesterSigner.recordAttestation(borrower, attestationWeight);
        await tx.wait();
        console.log(`   ✅ Attestation recorded`);
        
        // Stop impersonating
        await provider.send("anvil_stopImpersonatingAccount", [attester]);
      } catch (error) {
        console.log(`   ⚠️  Error recording attestation: ${error.message}`);
        // Stop impersonating even if there's an error
        try {
          await provider.send("anvil_stopImpersonatingAccount", [attester]);
        } catch (e) {
          // Ignore error if already stopped
        }
      }
    }
    
    // Step 3: Compute PageRank scores
    console.log("\n🧮 Step 3: Computing PageRank scores...");
    try {
      const iterations = await creditWithSigner.computePageRank();
      console.log(`   ✅ PageRank computed in ${iterations} iterations`);
    } catch (error) {
      console.log(`   ⚠️  Error computing PageRank: ${error.message}`);
    }
    
    // Step 4: Add lenders through deposits (if MockUSDC was deployed)
    console.log("\n💰 Step 4: Attempting to add lenders via deposits...");
    console.log("   ⚠️  Note: This step requires MockUSDC to be deployed");
    console.log("   💡 Run 'yarn deploy' first to deploy MockUSDC if needed");
    
    // Check final PageRank scores
    const finalPageRankScores = await credit.getAllPageRankScores();
    console.log(`\n📊 Final PageRank nodes in contract: ${finalPageRankScores.nodes.length}`);
    
    if (finalPageRankScores.nodes.length > 0) {
      console.log("\n📋 Participant addresses with PageRank scores:");
      for (let i = 0; i < finalPageRankScores.nodes.length; i++) {
        const participant = finalPageRankScores.nodes[i];
        const pageRankScore = finalPageRankScores.scores[i];
        const creditScore = await credit.getCreditScore(participant);
        
        console.log(`   ${i + 1}. ${participant}`);
        console.log(`      - Credit Score: ${creditScore}`);
        console.log(`      - PageRank Score: ${pageRankScore}`);
      }
    }
    
    console.log("\n✅ Participant population completed!");
    console.log(`📈 Total PageRank nodes added: ${finalPageRankScores.nodes.length - initialPageRankScores.nodes.length}`);
    
  } catch (error) {
    console.error("❌ Error:", error);
    process.exit(1);
  }
}

// Run the function if this script is called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  populateParticipants().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

export { populateParticipants }; 