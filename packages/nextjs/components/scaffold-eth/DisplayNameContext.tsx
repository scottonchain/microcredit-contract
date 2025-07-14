'use client';

import React, { createContext, useContext, useState } from "react";

/**
 * Simple in-memory store for a user display name.
 * NOTE: This is **only** for demo convenience – values are kept in
 * application memory and reset on reload. No on-chain storage.
 */
interface DisplayNameCtx {
  displayName: string;
  setDisplayName: (name: string) => void;
}

const Ctx = createContext<DisplayNameCtx>({ displayName: "", setDisplayName: () => {} });

export const DisplayNameProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [displayName, setDisplayName] = useState("");
  return <Ctx.Provider value={{ displayName, setDisplayName }}>{children}</Ctx.Provider>;
};

export const useDisplayName = () => useContext(Ctx); 