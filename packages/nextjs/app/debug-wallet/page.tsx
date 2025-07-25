"use client";

import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useDisconnect } from "wagmi";

const DebugWalletPage = () => {
  const { address, isConnected, connector } = useAccount();
  const { disconnect } = useDisconnect();
  const [log, setLog] = useState<string[]>([]);

  useEffect(() => {
    setLog(l => [
      `[Effect] address: ${address}, isConnected: ${isConnected}, connector: ${connector?.name}`,
      ...l,
    ]);
    console.log("[DebugWallet] address:", address, "isConnected:", isConnected, "connector:", connector?.name);
  }, [address, isConnected, connector]);

  const handleDisconnect = () => {
    disconnect();
    setLog(l => ["[Action] disconnect() called", ...l]);
    // Also clear all local/session storage and IndexedDB for walletconnect/wagmi/rainbowkit
    Object.keys(localStorage).forEach(key => {
      if (key.toLowerCase().includes('wagmi') || key.toLowerCase().includes('walletconnect') || key.toLowerCase().includes('rainbowkit')) {
        localStorage.removeItem(key);
        setLog(l => [`[Action] Removed localStorage key: ${key}`, ...l]);
      }
    });
    Object.keys(sessionStorage).forEach(key => {
      if (key.toLowerCase().includes('wagmi') || key.toLowerCase().includes('walletconnect') || key.toLowerCase().includes('rainbowkit')) {
        sessionStorage.removeItem(key);
        setLog(l => [`[Action] Removed sessionStorage key: ${key}`, ...l]);
      }
    });
    if (window.indexedDB && indexedDB.databases) {
      indexedDB.databases().then(dbs => {
        dbs.forEach(db => {
          if (db.name && (db.name.toLowerCase().includes('walletconnect') || db.name.toLowerCase().includes('wagmi') || db.name.toLowerCase().includes('rainbowkit'))) {
            const req = indexedDB.deleteDatabase(db.name);
            req.onsuccess = () => setLog(l => [`[Action] Deleted IndexedDB database: ${db.name}`, ...l]);
            req.onerror = () => setLog(l => [`[Action] Failed to delete IndexedDB database: ${db.name}`, ...l]);
          }
        });
      });
    }
  };

  return (
    <div style={{ padding: 32 }}>
      <h1>Debug Wallet Connect/Disconnect</h1>
      <ConnectButton />
      <div style={{ marginTop: 16 }}>
        <button onClick={handleDisconnect} style={{ padding: 8, background: '#eee', borderRadius: 4 }}>
          Disconnect & Clear Storage
        </button>
      </div>
      <div style={{ marginTop: 32 }}>
        <h2>Debug Log</h2>
        <pre style={{ background: '#f8f8f8', padding: 16, borderRadius: 4, maxHeight: 400, overflow: 'auto' }}>
          {log.join('\n')}
        </pre>
      </div>
      <div style={{ marginTop: 32 }}>
        <h2>Current State</h2>
        <pre style={{ background: '#f0f0f0', padding: 16, borderRadius: 4 }}>
{JSON.stringify({ address, isConnected, connector: connector?.name }, null, 2)}
        </pre>
      </div>
    </div>
  );
};

export default DebugWalletPage; 