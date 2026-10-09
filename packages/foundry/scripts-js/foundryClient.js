import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const FOUNDRY_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Let Forge interpret its configuration, including profiles and environment overrides. */
export function readRpcEndpoints(run = execFileSync) {
  try {
    const config = JSON.parse(
      run("forge", ["config", "--json"], {
        cwd: FOUNDRY_DIR,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15000,
      })
    );
    const endpoints = config.rpc_endpoints;
    if (
      !endpoints ||
      typeof endpoints !== "object" ||
      Array.isArray(endpoints) ||
      Object.values(endpoints).some((value) => typeof value !== "string")
    )
      throw new Error("invalid endpoints");
    return endpoints;
  } catch {
    // Forge's full output can contain provider credentials; never forward it to a log or error.
    throw new Error(
      "Cannot read RPC endpoints with forge config --json. Check Foundry and foundry.toml."
    );
  }
}

export function resolveRpcEndpoint(endpoint, env = process.env) {
  const resolved = endpoint.replace(
    /\$\{([A-Z0-9_]+)\}/g,
    (placeholder, name) => env[name] || placeholder
  );
  if (resolved.includes("${")) return undefined;
  try {
    return ["http:", "https:"].includes(new URL(resolved).protocol)
      ? resolved
      : undefined;
  } catch {
    return undefined;
  }
}

/** These are read-only commands. Preserve decimal output instead of coercing balances to floating point. */
export function readAccount(address, endpoint, run = execFileSync) {
  const options = {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 15000,
    env: { ...process.env, ETH_RPC_URL: endpoint, ETH_RPC_TIMEOUT: "10" },
  };
  try {
    return {
      balance: run("cast", ["balance", address, "--ether"], options).trim(),
      nonce: run("cast", ["nonce", address], options).trim(),
    };
  } catch {
    throw new Error("Cannot read this account from the RPC endpoint.");
  }
}
