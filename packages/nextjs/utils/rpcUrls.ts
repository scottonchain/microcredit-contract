/**
 * The RPC endpoints a chain's reads go through, in order, from one comma-separated setting
 * (`NEXT_PUBLIC_RPC_URL_<chain id>` at build time, or the default in scaffold.config.ts). Blank entries, anything that is
 * not an http(s) URL and repeats are dropped; the first entry that answers serves the read and the next one is tried when
 * it fails or rate-limits (viem's fallback transport).
 */
export function parseRpcUrls(value: string | undefined): string[] {
  const seen = new Set<string>();
  const urls: string[] = [];
  for (const part of (value ?? "").split(/[,\s]+/)) {
    const url = part.trim();
    if (!/^https?:\/\/\S+$/i.test(url)) continue;
    const key = url.replace(/\/+$/, "").toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    urls.push(url);
  }
  return urls;
}
