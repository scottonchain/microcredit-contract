import assert from "node:assert/strict";
import test from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { renderContracts } from "../generateTsAbis.js";

test("ABI sharing preserves distinct deployment data and ABI versions", () => {
  const abi = [{ type: "function", name: "balance", inputs: [], outputs: [] }];
  const contracts = {
    31337: {
      Pool: {
        address: "0x01",
        abi,
        inheritedFunctions: { balance: "Token.sol" },
      },
    },
    84532: {
      Pool: {
        address: "0x02",
        abi: structuredClone(abi),
        inheritedFunctions: {},
      },
      OtherPool: {
        address: "0x03",
        abi: [...abi, { type: "error", name: "Paused", inputs: [] }],
        inheritedFunctions: {},
      },
    },
  };
  const source = renderContracts(contracts);
  assert.equal(
    source,
    renderContracts(structuredClone(contracts)),
    "generation must be deterministic"
  );
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS },
  });
  const exports = {};
  runInNewContext(outputText, { exports });
  const deployed = exports.default;
  assert.deepEqual(JSON.parse(JSON.stringify(deployed)), contracts);
  assert.equal(deployed[31337].Pool.abi, deployed[84532].Pool.abi);
  assert.notEqual(deployed[84532].Pool.abi, deployed[84532].OtherPool.abi);
});
