import { listKeystores } from "./listKeystores.js";
import { fileURLToPath } from "url";
import { runCast } from "./keystores.js";

async function revealPk() {
  try {
    console.log("👀 This will reveal your private key on the console.");

    const selectedKeystore = await listKeystores(
      "Select a keystore to reveal its private key (enter the number, e.g., 1): "
    );

    if (!selectedKeystore) {
      console.error("❌ No keystore selected");
      process.exit(1);
    }

    try {
      await runCast(["wallet", "decrypt-keystore", selectedKeystore]);
    } catch (error) {
      console.error("\n❌ Failed to decrypt keystore. Wrong password?");
      process.exit(1);
    }
  } catch (error) {
    console.error("\n❌ Error revealing private key:");
    console.error(error.message);
    process.exit(1);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  revealPk().catch((error) => {
    console.error("\n❌ Unexpected error:", error.message);
    process.exitCode = 1;
  });
}
