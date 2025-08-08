/**
 * Hardhat Plugin: Zero Gas Override
 * 
 * This plugin automatically injects { maxFeePerGas: 0n, maxPriorityFeePerGas: 0n }
 * into all transactions and deployments on the Hardhat network only.
 * 
 * It monkey-patches Ethers.js v6 methods to apply gas overrides globally
 * without requiring manual changes to individual transaction calls.
 */

const { extendEnvironment } = require("hardhat/config");

// Gas override object for zero fees (Ethers v6 syntax)
const ZERO_GAS_OVERRIDE = {
  maxFeePerGas: 0n,
  maxPriorityFeePerGas: 0n,
};

/**
 * Sets the next block's base fee to 0 to ensure zero gas costs
 * Only applies to Hardhat network (chainId 31337)
 */
async function setNextBlockBaseFeeToZero(provider, chainId) {
  if (chainId === 31337) {
    try {
      await provider.send("hardhat_setNextBlockBaseFeePerGas", ["0x0"]);
    } catch (error) {
      // Silently ignore if the method is not available
      console.warn("Warning: hardhat_setNextBlockBaseFeePerGas not available");
    }
  }
}

/**
 * Merges gas overrides with existing transaction options
 * Only applies to Hardhat network (chainId 31337)
 */
function mergeGasOverrides(originalOptions = {}, chainId) {
  // Only apply zero gas on Hardhat network (chainId 31337)
  if (chainId !== 31337) {
    return originalOptions;
  }

  return {
    ...originalOptions,
    ...ZERO_GAS_OVERRIDE,
  };
}

/**
 * Wraps a signer method to automatically inject gas overrides
 */
function wrapSignerMethod(originalMethod, methodName) {
  return async function (...args) {
    const chainId = await this.provider.getNetwork().then(n => Number(n.chainId));
    
    if (chainId === 31337) {
      // Set next block base fee to 0 before any transaction
      await setNextBlockBaseFeeToZero(this.provider, chainId);
      
      // For sendTransaction, the first argument is the transaction request
      if (methodName === 'sendTransaction' && args[0]) {
        args[0] = mergeGasOverrides(args[0], chainId);
      }
      // For contract method calls, we need to handle the overrides parameter
      else if (args.length > 0 && typeof args[args.length - 1] === 'object' && args[args.length - 1] !== null) {
        // Check if the last argument looks like transaction overrides
        const lastArg = args[args.length - 1];
        if ('gasLimit' in lastArg || 'gasPrice' in lastArg || 'maxFeePerGas' in lastArg || 'value' in lastArg || Object.keys(lastArg).length === 0) {
          args[args.length - 1] = mergeGasOverrides(lastArg, chainId);
        } else {
          // Add overrides as a new parameter
          args.push(mergeGasOverrides({}, chainId));
        }
      } else {
        // Add overrides as a new parameter
        args.push(mergeGasOverrides({}, chainId));
      }
    }

    return originalMethod.apply(this, args);
  };
}

/**
 * Wraps ContractFactory.deploy method to inject gas overrides
 */
function wrapContractFactoryDeploy(originalDeploy) {
  return async function (...args) {
    const chainId = await this.runner.provider.getNetwork().then(n => Number(n.chainId));
    
    if (chainId === 31337) {
      // Set next block base fee to 0 before deployment
      await setNextBlockBaseFeeToZero(this.runner.provider, chainId);
      
      // The last argument to deploy() is typically the overrides object
      // If it doesn't exist, we add it. If it exists, we merge our gas settings.
      const lastArgIndex = args.length - 1;
      const lastArg = args[lastArgIndex];
      
      // Check if last argument is overrides object
      if (lastArg && typeof lastArg === 'object' && !Array.isArray(lastArg) && 
          ('gasLimit' in lastArg || 'gasPrice' in lastArg || 'maxFeePerGas' in lastArg || 'value' in lastArg || Object.keys(lastArg).length === 0)) {
        args[lastArgIndex] = mergeGasOverrides(lastArg, chainId);
      } else {
        // Add overrides as new parameter
        args.push(mergeGasOverrides({}, chainId));
      }
    }

    return originalDeploy.apply(this, args);
  };
}

/**
 * Wraps Contract method calls to inject gas overrides
 */
function wrapContractMethod(originalMethod, methodName) {
  return async function (...args) {
    const chainId = await this.runner.provider.getNetwork().then(n => Number(n.chainId));
    
    if (chainId === 31337) {
      // Set next block base fee to 0 before contract method call
      await setNextBlockBaseFeeToZero(this.runner.provider, chainId);
    }
    
    if (chainId === 31337) {
      // For contract method calls, the last argument is typically overrides
      const lastArgIndex = args.length - 1;
      const lastArg = args[lastArgIndex];
      
      // Check if last argument is overrides object
      if (lastArg && typeof lastArg === 'object' && !Array.isArray(lastArg) && 
          ('gasLimit' in lastArg || 'gasPrice' in lastArg || 'maxFeePerGas' in lastArg || 'value' in lastArg || Object.keys(lastArg).length === 0)) {
        args[lastArgIndex] = mergeGasOverrides(lastArg, chainId);
      } else {
        // Add overrides as new parameter
        args.push(mergeGasOverrides({}, chainId));
      }
    }

    return originalMethod.apply(this, args);
  };
}

/**
 * Main plugin function that extends the Hardhat environment
 */
extendEnvironment((hre) => {
  // Store original methods to avoid infinite recursion
  const originalGetSigners = hre.ethers.getSigners;
  const originalGetContractFactory = hre.ethers.getContractFactory;
  const originalGetContractAt = hre.ethers.getContractAt;

  // Override ethers.getSigners to return wrapped signers
  hre.ethers.getSigners = async function () {
    const signers = await originalGetSigners.call(this);
    
    return signers.map(signer => {
      // Only wrap if we haven't already wrapped this signer
      if (signer._zeroGasWrapped) {
        return signer;
      }

      // Wrap signer methods
      const originalSendTransaction = signer.sendTransaction;
      if (originalSendTransaction) {
        signer.sendTransaction = wrapSignerMethod(originalSendTransaction, 'sendTransaction');
      }

      // Mark as wrapped to avoid double-wrapping
      signer._zeroGasWrapped = true;
      return signer;
    });
  };

  // Override ethers.getContractFactory to return wrapped factories
  hre.ethers.getContractFactory = async function (...args) {
    const factory = await originalGetContractFactory.apply(this, args);
    
    // Only wrap if we haven't already wrapped this factory
    if (factory._zeroGasWrapped) {
      return factory;
    }

    // Wrap the deploy method
    const originalDeploy = factory.deploy;
    if (originalDeploy) {
      factory.deploy = wrapContractFactoryDeploy(originalDeploy);
    }

    // Mark as wrapped
    factory._zeroGasWrapped = true;
    return factory;
  };

  // Override ethers.getContractAt to return wrapped contracts
  hre.ethers.getContractAt = async function (...args) {
    const contract = await originalGetContractAt.apply(this, args);
    
    // Only wrap if we haven't already wrapped this contract
    if (contract._zeroGasWrapped) {
      return contract;
    }

    // Wrap all contract methods that can send transactions
    const contractInterface = contract.interface;
    
    for (const fragment of contractInterface.fragments) {
      if (fragment.type === 'function' && !fragment.constant && fragment.stateMutability !== 'view' && fragment.stateMutability !== 'pure') {
        const methodName = fragment.name;
        const originalMethod = contract[methodName];
        
        if (originalMethod && typeof originalMethod === 'function') {
          contract[methodName] = wrapContractMethod(originalMethod, methodName);
        }
      }
    }

    // Mark as wrapped
    contract._zeroGasWrapped = true;
    return contract;
  };

  console.log("🔧 Zero Gas Plugin: Loaded - All transactions on Hardhat network will use zero gas fees");
});

module.exports = {};
