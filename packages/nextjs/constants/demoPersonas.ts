/**
 * Demo persona definitions.
 * Maps the fixed Anvil addresses used in the demo to human-readable names,
 * roles, a Tailwind background color, and an initial letter for avatars.
 */

export interface DemoPersona {
  name: string;
  role: string;
  /** Tailwind bg color class */
  color: string;
  /** Hex color for inline styles where Tailwind classes can't be used */
  hex: string;
  initial: string;
}

export const DEMO_PERSONAS: Record<string, DemoPersona> = {
  // Anvil account 9 — deployer / admin
  "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720": {
    name: "Avery",
    role: "Admin",
    color: "bg-purple-500",
    hex: "#a855f7",
    initial: "A",
  },
  // Anvil account 2 — attester
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC": {
    name: "Brighton",
    role: "Attester",
    color: "bg-blue-500",
    hex: "#3b82f6",
    initial: "B",
  },
  // Anvil account 3 — borrower
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906": {
    name: "Casey",
    role: "Borrower",
    color: "bg-emerald-500",
    hex: "#10b981",
    initial: "C",
  },
};

/** Returns the persona for a given address (case-insensitive), or undefined. */
export function getPersona(address: string): DemoPersona | undefined {
  // Normalise: viem checksums addresses but Anvil sometimes returns lowercase
  const key = Object.keys(DEMO_PERSONAS).find(
    k => k.toLowerCase() === address.toLowerCase()
  );
  return key ? DEMO_PERSONAS[key] : undefined;
}
