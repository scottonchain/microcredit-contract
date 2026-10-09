import { spawnSync } from "child_process";
import { fileURLToPath } from "url";
import {
  prompt,
  runCast,
  validateKeystoreName,
  walletFromJson,
} from "./keystores.js";

export async function createKeystore() {
  const name = validateKeystoreName(
    await prompt("\nEnter name for new keystore: ")
  );
  const generated = spawnSync("cast", ["wallet", "new", "--json"], {
    encoding: "utf-8",
  });
  if (generated.error || generated.status !== 0) {
    // Wallet output can contain key material; never include it in an error.
    throw new Error(
      "Could not generate a wallet; install Foundry and check PATH."
    );
  }
  const wallet = walletFromJson(generated.stdout);
  await runCast([
    "wallet",
    "import",
    name,
    "--private-key",
    wallet.private_key,
  ]);
  console.log(
    "\nKeystore created. Fund its address and rerun deploy; yarn account checks its balance."
  );
  return name;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  createKeystore().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
