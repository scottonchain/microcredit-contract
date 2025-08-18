// USDC / ERC-2612 related helpers for the Next.js frontend
// Keep minimal and dependency-free to avoid circular imports

export const splitSignature = (sig: `0x${string}`) => {
  const hex = sig.slice(2);
  const r = ("0x" + hex.slice(0, 64)) as `0x${string}`;
  const s = ("0x" + hex.slice(64, 128)) as `0x${string}`;
  const v = Number("0x" + hex.slice(128, 130));
  return { v, r, s } as const;
};
