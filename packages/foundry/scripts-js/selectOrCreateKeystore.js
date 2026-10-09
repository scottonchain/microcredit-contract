import { fileURLToPath } from "url";
import { createKeystore } from "./generateKeystore.js";
import { availableKeystores, parseSelection, prompt } from "./keystores.js";

export async function selectOrCreateKeystore() {
  const keystores = availableKeystores();
  console.log("0. Create new keystore");
  keystores.forEach((name, i) => console.log(`${i + 1}. ${name}`));
  const selection = parseSelection(
    await prompt("\nSelect a keystore or create new (enter number): "),
    keystores.length,
    { allowCreate: true }
  );
  if (selection === 0) {
    await createKeystore();
    return null; // A new account needs funding before deployment; let the caller decide how to exit.
  }
  return keystores[selection - 1];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  selectOrCreateKeystore()
    .then((name) => {
      if (name) console.log(`Selected keystore: ${name}`);
    })
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
}
