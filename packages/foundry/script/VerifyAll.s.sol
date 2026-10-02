//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

/**
 * @notice Submits every contract created by the latest Deploy.s.sol broadcast
 *         on the current chain to the block explorer for verification.
 * @dev Usage: yarn verify --network <network>
 */
contract VerifyAll is Script {
    uint96 currTransactionIdx;

    function run() external {
        string memory root = vm.projectRoot();
        string memory path =
            string.concat(root, "/broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/run-latest.json");
        string memory content = vm.readFile(path);

        while (this.nextTransaction(content)) {
            _verifyIfContractDeployment(content);
            currTransactionIdx++;
        }
    }

    function _verifyIfContractDeployment(string memory content) internal {
        string memory txType =
            abi.decode(vm.parseJson(content, searchStr(currTransactionIdx, "transactionType")), (string));
        if (keccak256(bytes(txType)) == keccak256(bytes("CREATE"))) {
            _verifyContract(content);
        }
    }

    function _verifyContract(string memory content) internal {
        string memory contractName =
            abi.decode(vm.parseJson(content, searchStr(currTransactionIdx, "contractName")), (string));
        address contractAddr =
            abi.decode(vm.parseJson(content, searchStr(currTransactionIdx, "contractAddress")), (address));
        bytes memory deployedBytecode =
            abi.decode(vm.parseJson(content, searchStr(currTransactionIdx, "transaction.input")), (bytes));
        bytes memory compiledBytecode =
            abi.decode(vm.parseJson(_getCompiledBytecode(contractName), ".bytecode.object"), (bytes));
        bytes memory constructorArgs = _tail(deployedBytecode, compiledBytecode.length);

        string[] memory inputs = new string[](9);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(contractAddr);
        inputs[3] = contractName;
        inputs[4] = "--chain";
        inputs[5] = vm.toString(block.chainid);
        inputs[6] = "--constructor-args";
        inputs[7] = vm.toString(constructorArgs);
        inputs[8] = "--watch";

        VmSafe.FfiResult memory f = vm.tryFfi(inputs);

        if (f.stderr.length != 0) {
            console.logString(string.concat("Submitting verification for contract: ", vm.toString(contractAddr)));
            console.logString(string(f.stderr));
        } else {
            console.logString(string(f.stdout));
        }
    }

    function nextTransaction(string memory content) external view returns (bool) {
        try this.getTransactionFromRaw(content, currTransactionIdx) {
            return true;
        } catch {
            return false;
        }
    }

    function _getCompiledBytecode(string memory contractName) internal view returns (string memory compiledBytecode) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/out/", contractName, ".sol/", contractName, ".json");
        compiledBytecode = vm.readFile(path);
    }

    function getTransactionFromRaw(string memory content, uint96 idx) external pure {
        abi.decode(vm.parseJson(content, searchStr(idx, "hash")), (bytes32));
    }

    function searchStr(uint96 idx, string memory searchKey) internal pure returns (string memory) {
        return string.concat(".transactions[", vm.toString(idx), "].", searchKey);
    }

    /// @dev Returns `data[start:]` (the ABI-encoded constructor args appended to creation code).
    function _tail(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }
}
