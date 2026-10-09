import {
  availableKeystores,
  LOCAL_KEYSTORE,
  validateKeystoreName,
} from "./keystores.js";

export function parseDeployArgs(args) {
  const options = {
    fileName: "Deploy.s.sol",
    network: "localhost",
    keystoreArg: null,
  };
  const names = {
    "--file": "fileName",
    "--network": "network",
    "--keystore": "keystoreArg",
  };
  for (let i = 0; i < args.length; i++) {
    if (!Object.hasOwn(names, args[i]))
      throw new Error(`Unknown deploy option: ${args[i]}`);
    const option = names[args[i]];
    if (!args[i + 1] || args[i + 1].startsWith("--"))
      throw new Error(`Missing value for ${args[i]}`);
    options[option] = args[++i];
  }
  // Deployment scripts are selected only within script/, never by a relative or absolute escape.
  if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]*\.s\.sol$/.test(options.fileName)) {
    throw new Error("--file must name a .s.sol file in script/.");
  }
  if (options.keystoreArg)
    validateKeystoreName(options.keystoreArg, { allowLocal: true });
  return options;
}

export function validateKeystore(name, directory) {
  validateKeystoreName(name, { allowLocal: true });
  return (
    name === LOCAL_KEYSTORE ||
    availableKeystores(directory, { includeLocal: true }).includes(name)
  );
}

export function deployScriptTarget(fileName) {
  // Forge discovers the script's contract name; these scripts do not all define DeployScript.
  return `script/${fileName}`;
}
