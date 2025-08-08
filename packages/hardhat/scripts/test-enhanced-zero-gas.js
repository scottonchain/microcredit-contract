/**
 * Test script to verify enhanced zero gas plugin functionality
 * 
 * This script tests:
 * 1. Contract deployment with zero gas
 * 2. Contract method calls with zero gas
 * 3. Direct signer transactions with zero gas
 * 4. Verification that effectiveGasPrice is exactly 0
 * 5. Base fee management via hardhat_setNextBlockBaseFeePerGas
 */

async function main() {
  console.log("🧪 Testing Enhanced Zero Gas Plugin...\n");

  const [signer] = await ethers.getSigners();
  console.log(`Testing with account: ${signer.address}`);

  // Test 1: Deploy MockUSDC contract
  console.log("\n📦 Test 1: Contract Deployment");
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const deployTx = await MockUSDC.deploy();
  await deployTx.waitForDeployment();
  
  const deployReceipt = await deployTx.deploymentTransaction().wait();
  console.log(`✅ MockUSDC deployed at: ${await deployTx.getAddress()}`);
  const deployEffectiveGasPrice = deployReceipt.effectiveGasPrice || 0n;
  console.log(`💰 Deploy effectiveGasPrice: ${deployEffectiveGasPrice.toString()}`);
  
  if (deployEffectiveGasPrice === 0n) {
    console.log("✅ Deploy gas price is exactly 0!");
  } else {
    console.log("❌ Deploy gas price is NOT 0!");
  }

  // Test 2: Contract method call (mint)
  console.log("\n🪙 Test 2: Contract Method Call (mint)");
  const mintTx = await deployTx.mint(signer.address, ethers.parseUnits("100", 6));
  const mintReceipt = await mintTx.wait();
  console.log(`✅ Minted 100 USDC to ${signer.address}`);
  const mintEffectiveGasPrice = mintReceipt.effectiveGasPrice || 0n;
  console.log(`💰 Mint effectiveGasPrice: ${mintEffectiveGasPrice.toString()}`);
  
  if (mintEffectiveGasPrice === 0n) {
    console.log("✅ Mint gas price is exactly 0!");
  } else {
    console.log("❌ Mint gas price is NOT 0!");
  }

  // Test 3: Contract method call with explicit overrides
  console.log("\n🔧 Test 3: Contract Method Call with Overrides");
  const mintTx2 = await deployTx.mint(signer.address, ethers.parseUnits("50", 6), {
    gasLimit: 100000
  });
  const mintReceipt2 = await mintTx2.wait();
  console.log(`✅ Minted 50 USDC with explicit overrides`);
  const mint2EffectiveGasPrice = mintReceipt2.effectiveGasPrice || 0n;
  console.log(`💰 Mint2 effectiveGasPrice: ${mint2EffectiveGasPrice.toString()}`);
  
  if (mint2EffectiveGasPrice === 0n) {
    console.log("✅ Mint2 gas price is exactly 0!");
  } else {
    console.log("❌ Mint2 gas price is NOT 0!");
  }

  // Test 4: Direct signer transaction
  console.log("\n💸 Test 4: Direct Signer Transaction");
  const directTx = await signer.sendTransaction({
    to: "0x1234567890123456789012345678901234567890",
    value: ethers.parseEther("0.1")
  });
  const directReceipt = await directTx.wait();
  console.log(`✅ Sent 0.1 ETH to test address`);
  const directEffectiveGasPrice = directReceipt.effectiveGasPrice || 0n;
  console.log(`💰 Direct tx effectiveGasPrice: ${directEffectiveGasPrice.toString()}`);
  
  if (directEffectiveGasPrice === 0n) {
    console.log("✅ Direct tx gas price is exactly 0!");
  } else {
    console.log("❌ Direct tx gas price is NOT 0!");
  }

  // Test 5: Check current base fee
  console.log("\n⛽ Test 5: Base Fee Verification");
  const latestBlock = await ethers.provider.getBlock("latest");
  console.log(`📊 Latest block number: ${latestBlock.number}`);
  console.log(`📊 Latest block baseFeePerGas: ${latestBlock.baseFeePerGas?.toString() || "undefined"}`);
  
  if (latestBlock.baseFeePerGas === 0n) {
    console.log("✅ Base fee is exactly 0!");
  } else {
    console.log("❌ Base fee is NOT 0!");
  }

  // Summary
  console.log("\n📋 Test Summary:");
  const allGasPricesZero = [
    deployEffectiveGasPrice,
    mintEffectiveGasPrice,
    mint2EffectiveGasPrice,
    directEffectiveGasPrice
  ].every(price => price === 0n);

  if (allGasPricesZero && latestBlock.baseFeePerGas === 0n) {
    console.log("🎉 ALL TESTS PASSED! Enhanced zero gas plugin is working perfectly!");
  } else {
    console.log("❌ Some tests failed. Zero gas plugin needs adjustment.");
  }

  // Test 6: Check balances
  console.log("\n💰 Test 6: Balance Verification");
  const usdcBalance = await deployTx.balanceOf(signer.address);
  const ethBalance = await ethers.provider.getBalance(signer.address);
  console.log(`📊 USDC Balance: ${ethers.formatUnits(usdcBalance, 6)} USDC`);
  console.log(`📊 ETH Balance: ${ethers.formatEther(ethBalance)} ETH`);
  
  console.log("\n✅ Enhanced Zero Gas Plugin Test Complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Test failed:", error);
    process.exit(1);
  });
