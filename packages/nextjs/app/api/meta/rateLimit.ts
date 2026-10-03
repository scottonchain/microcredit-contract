/**
 * Sliding-window limits for the relayer routes. The relayer pays gas for every request it
 * submits, and fresh addresses can sign valid requests for free, so requests are limited per
 * client IP, per signer and overall. Reverting requests are already rejected in simulation before
 * any gas is spent; these limits cap what valid but abusive traffic can cost.
 *
 * State is in memory, so each server instance enforces its own limits. A deployment that runs
 * several instances should move this to a shared store (e.g. Redis) behind the same function.
 */

const WINDOW_MS = Number(process.env.RELAYER_RATE_WINDOW_MS ?? 60_000);
const LIMITS = {
  ip: Number(process.env.RELAYER_MAX_PER_IP ?? 20),
  signer: Number(process.env.RELAYER_MAX_PER_SIGNER ?? 10),
  global: Number(process.env.RELAYER_MAX_GLOBAL ?? 300),
};

const hits = new Map<string, number[]>();

const MAX_KEYS = 10_000;

/** Drops keys with no hit in the current window, so memory stays bounded. */
function sweep(now: number) {
  for (const [key, times] of hits) {
    if (times.length === 0 || now - times[times.length - 1] >= WINDOW_MS) hits.delete(key);
  }
}

/** Hits for `key` within the window ending at `now`. */
function recent(key: string, now: number): number[] {
  const times = (hits.get(key) ?? []).filter(t => now - t < WINDOW_MS);
  hits.set(key, times);
  return times;
}

/**
 * Returns the name of the first limit the request exceeds, or undefined when it may proceed.
 * `signer` is the account that signed the request, when the route knows it. A rejected request
 * is not counted, so traffic over one limit (one IP, one signer) cannot use up the global one.
 */
export function rateLimited(ip: string, signer: string | undefined, now = Date.now()): string | undefined {
  if (hits.size > MAX_KEYS) sweep(now);
  const checks: [string, string, number][] = [
    ["ip", `ip:${ip}`, LIMITS.ip],
    ["signer", signer ? `signer:${signer.toLowerCase()}` : "", LIMITS.signer],
    ["global", "global", LIMITS.global],
  ];
  const active = checks.filter(([, key]) => key !== "");
  for (const [name, key, limit] of active) {
    if (recent(key, now).length >= limit) return name;
  }
  for (const [, key] of active) hits.get(key)!.push(now);
  return undefined;
}

/** For tests: forget every recorded hit. */
export function resetRateLimits() {
  hits.clear();
}
