"use client";

import { ChevronDownIcon } from "@heroicons/react/24/outline";
import { DEMO_PERSONAS, getPersona } from "~~/constants/demoPersonas";

const PERSONAS = Object.entries(DEMO_PERSONAS);

interface Props {
  address: string;
}

/**
 * Shown in the top-right header when NEXT_PUBLIC_DEMO_WALLET=true.
 * Replaces both the WrongNetworkDropdown and the normal address dropdown.
 * Displays the active demo persona and lets the user switch accounts.
 */
export const DemoModeDropdown = ({ address }: Props) => {
  const persona = getPersona(address);

  const switchTo = (addr: string) => {
    (window as any).__demoEthereumProvider?._switchAccount(addr);
  };

  return (
    <div className="flex items-center gap-2">
      {/* "Demo mode" label sits beside the dropdown */}
      <span className="hidden sm:inline text-xs font-semibold tracking-wide text-yellow-600 bg-yellow-100 border border-yellow-300 rounded px-2 py-0.5">
        DEMO
      </span>

      <div className="dropdown dropdown-end">
        <label
          tabIndex={0}
          className="btn btn-sm btn-ghost gap-1.5 cursor-pointer border border-base-300"
        >
          {/* Persona avatar */}
          <span
            className="flex h-6 w-6 flex-shrink-0 items-center justify-center rounded-full text-[11px] font-bold text-white"
            style={{ backgroundColor: persona?.hex ?? "#6b7280" }}
          >
            {persona?.initial ?? "?"}
          </span>
          <span className="font-medium">{persona?.name ?? address.slice(0, 6)}</span>
          <ChevronDownIcon className="h-4 w-4 opacity-60" />
        </label>

        <ul
          tabIndex={0}
          className="dropdown-content menu z-50 mt-1 min-w-[200px] rounded-box bg-base-200 p-2 shadow-lg"
        >
          <li className="menu-title text-xs text-yellow-600 font-semibold mb-1">Switch demo account</li>
          {PERSONAS.map(([addr, p]) => {
            const isActive = addr.toLowerCase() === address.toLowerCase();
            return (
              <li key={addr}>
                <button
                  className={`flex items-center gap-3 rounded-xl py-2 w-full text-left ${
                    isActive ? "font-bold bg-base-300" : ""
                  }`}
                  onClick={() => switchTo(addr)}
                >
                  <span
                    className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full text-xs font-bold text-white"
                    style={{ backgroundColor: p.hex }}
                  >
                    {p.initial}
                  </span>
                  <div>
                    <div className="text-sm leading-tight">{p.name}</div>
                    <div className="text-xs text-gray-400 leading-tight">{p.role}</div>
                  </div>
                  {isActive && (
                    <span className="ml-auto text-xs text-green-500">●</span>
                  )}
                </button>
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
};
