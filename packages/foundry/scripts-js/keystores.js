import { readdirSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { spawn } from "child_process";
import readline from "readline";

export const LOCAL_KEYSTORE = "scaffold-eth-default";
export const KEYSTORE_DIR = join(homedir(), ".foundry", "keystores");

export function validateKeystoreName(name, { allowLocal = false } = {}) {
  if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
    throw new Error(
      "Use a keystore name containing letters, numbers, dots, underscores or hyphens; no paths or spaces."
    );
  }
  if (!allowLocal && name === LOCAL_KEYSTORE) {
    throw new Error(`${LOCAL_KEYSTORE} is reserved for local development.`);
  }
  return name;
}

export function availableKeystores(
  directory = KEYSTORE_DIR,
  { includeLocal = false } = {}
) {
  try {
    return readdirSync(directory, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isFile() && (includeLocal || entry.name !== LOCAL_KEYSTORE)
      )
      .map((entry) => entry.name)
      .sort();
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

export function parseSelection(answer, count, { allowCreate = false } = {}) {
  const text = answer.trim();
  const selection = Number(text);
  if (
    !/^\d+$/.test(text) ||
    !Number.isSafeInteger(selection) ||
    selection < (allowCreate ? 0 : 1) ||
    selection > count
  ) {
    throw new Error("Invalid keystore selection.");
  }
  return selection;
}

export function prompt(question) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return new Promise((resolve, reject) => {
    rl.once("close", () =>
      reject(new Error("Input ended before a keystore was selected."))
    );
    rl.question(question, (answer) => {
      resolve(answer);
      rl.close();
    });
  });
}

export function runCast(args) {
  return new Promise((resolve, reject) => {
    // Argument arrays preserve account names literally; never pass a wallet command through a shell.
    const child = spawn("cast", args, { stdio: "inherit" });
    child.once("error", () =>
      reject(new Error("Could not start cast; install Foundry and check PATH."))
    );
    child.once("close", (code) => {
      if (code === 0) resolve();
      else
        reject(
          new Error(`cast wallet command failed (exit ${code ?? "signal"}).`)
        );
    });
  });
}

export function walletFromJson(output) {
  let value;
  try {
    value = JSON.parse(output);
  } catch {
    // The parser's native error may echo the offending input, including a private key.
    throw new Error("cast returned an invalid wallet response.");
  }
  // Foundry 1.5 returns a list; 1.8 wraps that list in a data property.
  if (value && !Array.isArray(value) && Object.hasOwn(value, "data"))
    value = value.data;
  const wallet = Array.isArray(value) ? value[0] : value;
  if (
    !wallet ||
    !/^0x[0-9a-fA-F]{40}$/.test(wallet.address) ||
    !/^0x[0-9a-fA-F]{64}$/.test(wallet.private_key)
  ) {
    throw new Error("cast returned an invalid wallet response.");
  }
  return wallet;
}
