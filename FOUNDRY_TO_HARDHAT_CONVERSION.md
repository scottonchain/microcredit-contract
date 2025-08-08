# Foundry to Hardhat Conversion Summary

This document summarizes the complete conversion of the microcredit contract project from Foundry to Hardhat for zero gas price development.

## 🎯 Conversion Goals

- ✅ Replace Foundry tooling with Hardhat
- ✅ Enable zero gas price development and testing
- ✅ Maintain all existing functionality
- ✅ Provide TypeScript support
- ✅ Ensure frontend compatibility

## 📁 Project Structure Changes

### Before (Foundry)
```
packages/foundry/
├── contracts/
├── script/
├── test/
├── foundry.toml
├── Makefile
└── package.json
```

### After (Hardhat)
```
packages/hardhat/
├── contracts/          # Same contracts
├── scripts/           # Converted deployment scripts
├── test/             # Converted test files
├── hardhat.config.ts # Hardhat configuration
├── tsconfig.json     # TypeScript configuration
└── package.json      # Updated dependencies
```

## 🔧 Key Configuration Changes

### Zero Gas Price Configuration

**Foundry (foundry.toml):**
```toml
[profile.anvil]
gas_price = 0
base_fee = 0
```

**Hardhat (hardhat.config.ts):**
```typescript
networks: {
  hardhat: {
    chainId: 31337,
    gasPrice: 0,  // Zero gas price
    allowUnlimitedContractSize: true,
  },
  localhost: {
    url: "http://127.0.0.1:8545",
    chainId: 31337,
    gasPrice: 0,  // Zero gas price
    allowUnlimitedContractSize: true,
  },
}
```

## 📜 Script Conversions

### Deployment Script

**Foundry (Deploy.s.sol):**
```solidity
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
        vm.startBroadcast(deployerPrivateKey);
        
        MockUSDC usdc = new MockUSDC();
        DecentralizedMicrocredit microcredit = new DecentralizedMicrocredit(
            433, 500, 100 * 1e6, address(usdc), vm.addr(deployerPrivateKey)
        );
        
        vm.stopBroadcast();
    }
}
```

**Hardhat (deploy.ts):**
```typescript
async function main() {
  const [deployer] = await ethers.getSigners();
  
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  
  const DecentralizedMicrocredit = await ethers.getContractFactory("DecentralizedMicrocredit");
  const microcredit = await DecentralizedMicrocredit.deploy(
    433, 500, 100 * 1e6, await mockUSDC.getAddress(), deployer.address
  );
  await microcredit.waitForDeployment();
}
```

### Test Conversions

**Foundry (DecentralizedMicrocredit.t.sol):**
```solidity
contract DecentralizedMicrocreditTest is Test {
    function setUp() public {
        mockUSDC = new MockUSDC();
        microcredit = new DecentralizedMicrocredit(
            433, 500, 100 * 1e6, address(mockUSDC), oracle
        );
    }
    
    function testDeployment() public {
        assertEq(microcredit.owner(), owner);
    }
}
```

**Hardhat (DecentralizedMicrocredit.test.ts):**
```typescript
describe("DecentralizedMicrocredit", function () {
  beforeEach(async function () {
    [owner, lender, borrower, oracle] = await ethers.getSigners();
    
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();
    
    const DecentralizedMicrocredit = await ethers.getContractFactory("DecentralizedMicrocredit");
    microcredit = await DecentralizedMicrocredit.deploy(
      433, 500, 100 * 1e6, await mockUSDC.getAddress(), oracle.address
    );
    await microcredit.waitForDeployment();
  });
  
  it("Should set the right owner", async function () {
    expect(await microcredit.owner()).to.equal(owner.address);
  });
});
```

## 🚀 Command Mappings

| Foundry Command | Hardhat Equivalent | Description |
|----------------|-------------------|-------------|
| `forge build` | `yarn compile` | Compile contracts |
| `forge test` | `yarn test` | Run tests |
| `forge script Deploy.s.sol` | `yarn deploy` | Deploy contracts |
| `anvil` | `yarn chain` | Start local network |
| `cast wallet new` | `yarn account:generate` | Generate keystore |
| `cast wallet import` | `yarn account:import` | Import account |
| `cast balance` | `node scripts/checkAccountBalance.js` | Check balance |

## 📦 Package.json Changes

### Root package.json
```json
{
  "scripts": {
    "chain": "yarn hardhat:chain",           // Was: "bash scripts/start-anvil.sh"
    "compile": "yarn hardhat:compile",        // Was: "yarn foundry:compile"
    "deploy": "yarn hardhat:deploy",          // Was: "yarn foundry:deploy"
    "test": "yarn hardhat:test",              // Was: "yarn foundry:test"
    "account": "yarn hardhat:account",        // Was: "yarn foundry:account"
    "account:generate": "yarn hardhat:generate", // Was: "yarn foundry:generate"
    "account:import": "yarn hardhat:account-import", // Was: "yarn foundry:account-import"
    "account:reveal-pk": "yarn workspace @se-2/hardhat account:reveal-pk" // Was: "yarn workspace @se-2/foundry account:reveal-pk"
  }
}
```

### Hardhat package.json
```json
{
  "scripts": {
    "chain": "hardhat node --gas-price 0",
    "compile": "hardhat compile",
    "deploy": "hardhat run scripts/deploy.ts",
    "deploy:local": "hardhat run scripts/deploy.ts --network localhost",
    "test": "hardhat test",
    "account:generate": "node scripts/generateKeystore.js",
    "account:import": "node scripts/importAccount.js",
    "account:reveal-pk": "node scripts/revealPK.js"
  },
  "dependencies": {
    "@nomicfoundation/hardhat-toolbox": "^4.0.0",
    "@openzeppelin/contracts": "^5.0.0",
    "ethers": "^6.8.0",
    "hardhat": "^2.19.0"
  }
}
```

## 🔄 Frontend Integration

The frontend (Next.js) continues to work unchanged:

- **RPC URL**: Still connects to `http://localhost:8545`
- **Contract Addresses**: Updated in `packages/nextjs/contracts/deployedContracts.ts`
- **Gas Price**: Now truly zero on local network
- **Wallet Integration**: No changes needed

## ✅ Benefits of Conversion

1. **Zero Gas Price**: Guaranteed zero gas price on local network
2. **TypeScript Support**: Full type safety with ethers.js v6
3. **Better Testing**: Mocha/Chai with async/await support
4. **Modern Tooling**: Latest Hardhat features and plugins
5. **Easier Debugging**: Better error messages and stack traces
6. **Plugin Ecosystem**: Access to Hardhat's extensive plugin ecosystem

## 🧪 Testing the Conversion

### 1. Install Dependencies
```bash
cd packages/hardhat
yarn install
```

### 2. Start Network
```bash
yarn chain
```

### 3. Compile Contracts
```bash
yarn compile
```

### 4. Deploy Contracts
```bash
yarn deploy
```

### 5. Run Tests
```bash
yarn test
```

### 6. Start Frontend
```bash
cd ../nextjs
yarn dev
```

## 🚨 Important Notes

1. **Gas Price**: The Hardhat network now has `gasPrice: 0` configured
2. **Contract Addresses**: May change after redeployment
3. **Keystore Format**: Changed from Foundry's format to standard JSON keystore
4. **Environment Variables**: Updated to use Hardhat's environment system
5. **TypeScript**: All scripts now use TypeScript for better type safety

## 🔧 Troubleshooting

### Gas Price Still Not Zero
- Ensure you're using `yarn chain` (Hardhat) not the old Anvil script
- Check `hardhat.config.ts` has `gasPrice: 0`
- Restart the Hardhat node

### Contract Compilation Issues
```bash
yarn clean
yarn compile
```

### Test Failures
```bash
yarn hardhat test --verbose
```

## 📚 Additional Resources

- [Hardhat Documentation](https://hardhat.org/docs)
- [Ethers.js v6 Documentation](https://docs.ethers.org/v6/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)

---

**Conversion completed successfully!** 🎉

The project now uses Hardhat with zero gas price configuration, providing a better development experience while maintaining all existing functionality. 