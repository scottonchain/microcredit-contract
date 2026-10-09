import { fileURLToPath } from "url";
import { prompt, runCast, validateKeystoreName } from "./keystores.js";

export async function importAccount(name) {
  const account = validateKeystoreName(
    name ?? (await prompt("\nEnter account name: "))
  );
  await runCast(["wallet", "import", account, "--interactive"]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  importAccount(process.argv[2]).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
