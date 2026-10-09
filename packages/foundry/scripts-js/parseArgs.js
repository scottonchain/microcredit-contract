import { spawnSync } from "child_process";
import { config } from "dotenv";
import { join, dirname } from "path";
import { existsSync } from "fs";
import net from "net";
import { fileURLToPath } from "url";
import { selectOrCreateKeystore } from "./selectOrCreateKeystore.js";
import {
  deployScriptTarget,
  parseDeployArgs,
  validateKeystore,
} from "./deployConfig.js";
import { KEYSTORE_DIR, LOCAL_KEYSTORE } from "./keystores.js";
import { readRpcEndpoints } from "./foundryClient.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
config({ path: join(__dirname, "..", ".env") });

// Get all arguments after the script name
const args = process.argv.slice(2);

// Show help message if --help is provided
if (args.includes("--help") || args.includes("-h")) {
  console.log(`
Usage: yarn deploy [options]
Options:
  --file <filename>     Deployment script in script/ (default: Deploy.s.sol)
  --network <network>   Network from foundry.toml [rpc_endpoints] (default: localhost)
  --keystore <name>     Keystore account to use (bypasses selection prompt)
  --help, -h            Show this help message

Environment Variables:
  GAS_LIMIT             Per-transaction gas limit (default: 100000000)

Examples:
  yarn deploy
  yarn deploy --network sepolia --keystore my-account
  `);
  process.exit(0);
}

let options;
try {
  options = parseDeployArgs(args);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
const { fileName, network, keystoreArg } = options;
const deployScript = deployScriptTarget(fileName);
if (!existsSync(join(__dirname, "..", deployScript))) {
  console.error(`\n❌ Error: Deploy script '${deployScript}' not found`);
  process.exit(1);
}

// Check if the network exists in rpc_endpoints
try {
  if (!Object.hasOwn(readRpcEndpoints(), network)) {
    console.log(
      `\n❌ Error: Network '${network}' not found in foundry.toml!`,
      "\nPlease check `foundry.toml` for available networks in the [rpc_endpoints] section or add a new network."
    );
    process.exit(1);
  }
} catch (error) {
  console.error("\n❌ Error reading Foundry configuration:", error.message);
  process.exit(1);
}

let selectedKeystore;
try {
  selectedKeystore =
    keystoreArg ??
    (network === "localhost"
      ? process.env.LOCALHOST_KEYSTORE_ACCOUNT || LOCAL_KEYSTORE
      : await selectOrCreateKeystore());
  if (selectedKeystore === null) process.exit(0); // Created an unfunded account; no deployment attempted.
  if (!validateKeystore(selectedKeystore))
    throw new Error(
      `Keystore '${selectedKeystore}' not found in ~/.foundry/keystores/.`
    );
} catch (error) {
  console.error("\n❌ Error selecting keystore:", error.message);
  process.exit(1);
}
console.log(`\n🔑 Using keystore: ${selectedKeystore} on ${network}`);

// Check for default account on live network
if (selectedKeystore === LOCAL_KEYSTORE && network !== "localhost") {
  console.log(`
❌ Error: Cannot deploy to live network using default keystore account!

To deploy to ${network}, please follow these steps:

1. If you haven't generated a keystore account yet:
   $ yarn account:generate

2. Run the deployment command again.

The default account (scaffold-eth-default) can only be used for localhost deployments.
`);
  process.exit(1);
}

// For localhost deployments, verify Anvil is reachable before invoking forge
if (network === "localhost") {
  const port = 8545;
  const anvilReachable = await new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(1000);
    socket
      .once("connect", () => {
        socket.destroy();
        resolve(true);
      })
      .once("timeout", () => {
        socket.destroy();
        resolve(false);
      })
      .once("error", () => resolve(false))
      .connect(port, "127.0.0.1");
  });
  if (!anvilReachable) {
    console.error(`
❌ Anvil is not running on localhost:${port}.

Start the local chain in a separate terminal first:
  yarn chain

Then re-run your deploy command.
`);
    process.exit(1);
  }
}

// The default localhost keystore wraps Anvil's well-known account 9 (the same key
// Deploy.s.sol broadcasts with). forge refuses to run when ETH_KEYSTORE_ACCOUNT
// names a keystore that does not exist, so create it on first use.
const LOCAL_KEYSTORE_PK =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";
const LOCAL_KEYSTORE_PASSWORD = "localhost";

if (
  selectedKeystore === LOCAL_KEYSTORE &&
  !existsSync(join(KEYSTORE_DIR, LOCAL_KEYSTORE))
) {
  const imported = spawnSync(
    "cast",
    [
      "wallet",
      "import",
      LOCAL_KEYSTORE,
      "--private-key",
      LOCAL_KEYSTORE_PK,
      "--unsafe-password",
      LOCAL_KEYSTORE_PASSWORD,
    ],
    { stdio: "inherit" }
  );
  if (imported.status !== 0) process.exit(imported.status ?? 1);
}

const forgeArgs = [
  "script",
  deployScript,
  "--rpc-url",
  network,
  "--broadcast",
  "--legacy",
  "--gas-limit",
  process.env.GAS_LIMIT || "100000000",
];
if (selectedKeystore === LOCAL_KEYSTORE) {
  forgeArgs.push("--password", LOCAL_KEYSTORE_PASSWORD);
}

const deployed = spawnSync("forge", forgeArgs, {
  cwd: join(__dirname, ".."),
  stdio: "inherit",
  env: {
    ...process.env,
    ETH_KEYSTORE_ACCOUNT: selectedKeystore,
    FOUNDRY_AUTO_CONFIRM: "1",
  },
});
if (deployed.status !== 0) process.exit(deployed.status ?? 1);

const generated = spawnSync("node", [join(__dirname, "generateTsAbis.js")], {
  stdio: "inherit",
});
process.exit(generated.status ?? 1);
