"use client";

import { useEffect, useState } from "react";
import { DEMO_PERSONAS } from "~~/constants/demoPersonas";

// Addresses in insertion order from demoPersonas.ts
const PERSONAS = Object.entries(DEMO_PERSONAS);
const DEFAULT_ADDR = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // Brighton / Bob

/**
 * Floating account-switcher shown only when NEXT_PUBLIC_DEMO_WALLET=true.
 * Calls window.__demoEthereumProvider._switchAccount() which emits
 * accountsChanged so wagmi picks up the new address without a page reload.
 */
export default function DemoWalletSwitcher() {
  const [activeAddr, setActiveAddr] = useState<string>("");

  useEffect(() => {
    // Read the active account injected by the inline script
    let stored: string | null = null;
    try {
      stored = localStorage.getItem("__demoAccount");
    } catch (_) {
      /* ignore */
    }
    setActiveAddr((stored || DEFAULT_ADDR).toLowerCase());
  }, []);

  const switchTo = (addr: string) => {
    const provider = (window as any).__demoEthereumProvider;
    if (!provider) return;
    provider._switchAccount(addr);
    setActiveAddr(addr.toLowerCase());
  };

  return (
    <div className="fixed bottom-4 right-4 z-[9999] rounded-lg border-2 border-yellow-400 bg-yellow-50 p-3 shadow-xl text-xs font-mono select-none">
      <div className="mb-2 font-bold text-yellow-800 tracking-wide">⚠ DEMO MODE</div>
      <div className="flex flex-col gap-1">
        {PERSONAS.map(([addr, persona]) => {
          const isActive = addr.toLowerCase() === activeAddr;
          return (
            <button
              key={addr}
              onClick={() => switchTo(addr)}
              className={`flex items-center gap-1.5 rounded px-2 py-1 text-left transition-colors ${
                isActive
                  ? "bg-yellow-400 font-bold text-yellow-900"
                  : "bg-white text-gray-700 hover:bg-yellow-100"
              }`}
            >
              <span
                className="flex h-5 w-5 items-center justify-center rounded-full text-white text-[10px] font-bold flex-shrink-0"
                style={{ backgroundColor: persona.hex }}
              >
                {persona.initial}
              </span>
              {persona.name}
              <span className="text-gray-400">({persona.role})</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
