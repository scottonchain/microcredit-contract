import { TYPES } from "./metaTypes.ts";

type Hex = `0x${string}`;
const MAX_UINT256 = (1n << 256n) - 1n;

export class RelayerError extends Error {
  readonly status: number;
  constructor(message: string, status = 500) {
    super(message);
    this.name = "RelayerError";
    this.status = status;
  }
}

export function requestObject(value: unknown, name = "body"): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new RelayerError(`${name} must be a JSON object`, 400);
  return value as Record<string, any>;
}

export function uint(value: unknown, name: string): bigint {
  if (typeof value === "number" && (!Number.isSafeInteger(value) || value < 0))
    throw new RelayerError(`${name} must be an unsigned integer; send large values as decimal strings`, 400);
  if (typeof value !== "number" && (typeof value !== "string" || !/^\d{1,78}$/.test(value)))
    throw new RelayerError(`${name} must be an unsigned decimal integer`, 400);
  const result = BigInt(value);
  if (result > MAX_UINT256) throw new RelayerError(`${name} exceeds uint256`, 400);
  return result;
}

export function address(value: unknown, name: string): Hex {
  if (typeof value !== "string" || !/^0x[0-9a-f]{40}$/i.test(value))
    throw new RelayerError(`${name} must be an Ethereum address`, 400);
  return value as Hex;
}

function hex(value: unknown, name: string, bytes?: number): Hex {
  if (typeof value !== "string" || !/^0x(?:[0-9a-f]{2})*$/i.test(value) || (bytes !== undefined && value.length !== 2 + bytes * 2))
    throw new RelayerError(`${name} must be ${bytes === undefined ? "even-length" : bytes + "-byte"} hex`, 400);
  return value as Hex;
}

// Contract-wallet (ERC-1271) signatures may have any byte length, including zero.
export const signature = (value: unknown) => hex(value, "signature");

export function requireFields(body: Record<string, unknown>, ...fields: string[]) {
  if (fields.some(field => body[field] === undefined || body[field] === null || body[field] === ""))
    throw new RelayerError("Missing parameters", 400);
}

export function requestBody(value: unknown) {
  const body = requestObject(value);
  const id = uint(body.chainId, "chainId");
  if (id === 0n || id > BigInt(Number.MAX_SAFE_INTEGER)) throw new RelayerError("Invalid chainId", 400);
  return { ...body, chainId: Number(id), contractAddress: address(body.contractAddress, "contractAddress") };
}

type ParsedRequest<K extends keyof typeof TYPES> = {
  [F in (typeof TYPES)[K][number] as F["name"]]: F["type"] extends "address" ? Hex : bigint;
};

export function typedRequest<K extends keyof typeof TYPES>(kind: K, value: unknown): ParsedRequest<K> {
  const body = requestObject(value, "req");
  return Object.fromEntries(TYPES[kind].map(field => [
    field.name,
    field.type === "address" ? address(body[field.name], `req.${field.name}`) : uint(body[field.name], `req.${field.name}`),
  ])) as ParsedRequest<K>;
}

export function permitArg(value: unknown) {
  const permit = requestObject(value, "permit");
  const v = uint(permit.v, "permit.v");
  if (v !== 27n && v !== 28n) throw new RelayerError("permit.v must be 27 or 28", 400);
  return {
    value: uint(permit.value, "permit.value"),
    deadline: uint(permit.deadline, "permit.deadline"),
    v: Number(v),
    r: hex(permit.r, "permit.r", 32),
    s: hex(permit.s, "permit.s", 32),
  };
}

export function relayerRpcUrl(chainId: number, env: Record<string, string | undefined>): string {
  const url = chainId === 31337 ? env.LOCAL_RPC_URL || "http://127.0.0.1:8545" : env.RPC_URL;
  if (!url) throw new RelayerError(`RPC_URL is required for chain ${chainId}`, 503);
  try {
    if (!["http:", "https:"].includes(new URL(url).protocol)) throw new Error("protocol");
  } catch {
    throw new RelayerError("The relayer RPC URL must use HTTP or HTTPS", 503);
  }
  return url;
}
