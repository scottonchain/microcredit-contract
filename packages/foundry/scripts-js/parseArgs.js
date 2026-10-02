import { spawnSync } from "child_process";
import { config } from "dotenv";
import { join, dirname } from "path";
import { readFileSync, existsSync } from "fs";
import { parse } from "toml";
import net from "net";
import { fileURLToPath } from "url";
import { selectOrCreateKeystore } from "./selectOrCreateKeystore.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
config();

// Get all arguments after the script name
const args = process.argv.slice(2);
let fileName = "Deploy.s.sol";
let network = "localhost";
let keystoreArg = null;

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

// Parse arguments
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--network" && args[i + 1]) {
    network = args[i + 1];
    i++; // Skip next arg since we used it
  } else if (args[i] === "--file" && args[i + 1]) {
    fileName = args[i + 1];
    i++; // Skip next arg since we used it
  } else if (args[i] === "--keystore" && args[i + 1]) {
    keystoreArg = args[i + 1];
    i++; // Skip next arg since we used it
  }
}

// Function to check if a keystore exists
function validateKeystore(keystoreName) {
  if (keystoreName === "scaffold-eth-default") {
    return true; // Default keystore is always valid
  }

  const keystorePath = join(
    process.env.HOME,
    ".foundry",
    "keystores",
    keystoreName
  );
  return existsSync(keystorePath);
}

// Check if the network exists in rpc_endpoints
try {
  const foundryTomlPath = join(__dirname, "..", "foundry.toml");
  const tomlString = readFileSync(foundryTomlPath, "utf-8");
  const parsedToml = parse(tomlString);

  if (!parsedToml.rpc_endpoints[network]) {
    console.log(
      `\n❌ Error: Network '${network}' not found in foundry.toml!`,
      "\nPlease check \`foundry.toml\` for available networks in the [rpc_endpoints] section or add a new network."
    );
    process.exit(1);
  }
} catch (error) {
  console.error("\n❌ Error reading or parsing foundry.toml:", error);
  process.exit(1);
}

if (
  (process.env.LOCALHOST_KEYSTORE_ACCOUNT || "scaffold-eth-default") !== "scaffold-eth-default" &&
  network === "localhost"
) {
  console.log(`
⚠️ Warning: Using ${process.env.LOCALHOST_KEYSTORE_ACCOUNT} keystore account on localhost.

You can either:
1. Enter the password for ${process.env.LOCALHOST_KEYSTORE_ACCOUNT} account
   OR
2. Set the localhost keystore account in your .env and re-run the command to skip password prompt:
   LOCALHOST_KEYSTORE_ACCOUNT='scaffold-eth-default'
`);
}

let selectedKeystore = process.env.LOCALHOST_KEYSTORE_ACCOUNT || "scaffold-eth-default";
if (network !== "localhost") {
  if (keystoreArg) {
    // Use the keystore provided via command line argument
    if (!validateKeystore(keystoreArg)) {
      console.log(`\n❌ Error: Keystore '${keystoreArg}' not found!`);
      console.log(
        `Please check that the keystore exists in ~/.foundry/keystores/`
      );
      process.exit(1);
    }
    selectedKeystore = keystoreArg;
    console.log(`\n🔑 Using keystore: ${selectedKeystore}`);
  } else {
    try {
      selectedKeystore = await selectOrCreateKeystore();
    } catch (error) {
      console.error("\n❌ Error selecting keystore:", error);
      process.exit(1);
    }
  }
} else if (keystoreArg) {
  // Allow overriding the localhost keystore with --keystore flag
  if (!validateKeystore(keystoreArg)) {
    console.log(`\n❌ Error: Keystore '${keystoreArg}' not found!`);
    console.log(
      `Please check that the keystore exists in ~/.foundry/keystores/`
    );
    process.exit(1);
  }
  selectedKeystore = keystoreArg;
  console.log(
    `\n🔑 Using keystore: ${selectedKeystore} for localhost deployment`
  );
}

// Check for default account on live network
if (selectedKeystore === "scaffold-eth-default" && network !== "localhost") {
  console.log(`
❌ Error: Cannot deploy to live network using default keystore account!

To deploy to ${network}, please follow these steps:

1. If you haven't generated a keystore account yet:
   $ yarn generate

2. Run the deployment command again.

The default account (scaffold-eth-default) can only be used for localhost deployments.
`);
  process.exit(0);
}

// For localhost deployments, verify Anvil is reachable before invoking forge
if (network === "localhost") {
  const port = 8545;
  const anvilReachable = await new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(1000);
    socket
      .once("connect", () => { socket.destroy(); resolve(true); })
      .once("timeout", () => { socket.destroy(); resolve(false); })
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
const LOCAL_KEYSTORE = "scaffold-eth-default";
const LOCAL_KEYSTORE_PK =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";
const LOCAL_KEYSTORE_PASSWORD = "localhost";

if (
  selectedKeystore === LOCAL_KEYSTORE &&
  !existsSync(join(process.env.HOME, ".foundry", "keystores", LOCAL_KEYSTORE))
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

const deployScript = join("script", fileName);
if (!existsSync(join(__dirname, "..", deployScript))) {
  console.error(`\n❌ Error: Deploy script '${deployScript}' not found`);
  process.exit(1);
}

const forgeArgs = [
  "script",
  `${deployScript}:DeployScript`,
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
