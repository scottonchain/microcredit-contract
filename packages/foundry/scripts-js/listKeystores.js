import { fileURLToPath } from "url";
import { availableKeystores, parseSelection, prompt } from "./keystores.js";

export async function listKeystores(
  selectMessage = "Select a keystore (enter its number): "
) {
  const keystores = availableKeystores();
  if (keystores.length === 0) {
    throw new Error(
      "No keystores found. Create one with yarn account:generate."
    );
  }
  keystores.forEach((name, i) => console.log(`${i + 1}. ${name}`));
  const selection = parseSelection(
    await prompt(`\n${selectMessage}`),
    keystores.length
  );
  return keystores[selection - 1];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  listKeystores()
    .then((name) => console.log(`Selected keystore: ${name}`))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
}
