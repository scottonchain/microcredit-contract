"use client";

import { useAccount, useDisconnect, useConnect } from "wagmi";
import { injected } from "wagmi/connectors";

const WalletSwitcher = () => {
  const { address, isConnected } = useAccount();
  const { disconnect } = useDisconnect();
  const { connect, isPending } = useConnect();

  return (
    <div className="bg-base-200 rounded-lg p-4 mb-6">
      {isConnected ? (
        <>
          <div className="mb-2 break-words">Connected address: {address}</div>
          <button className="btn btn-sm btn-error" onClick={() => disconnect()}>
            Disconnect
          </button>
        </>
      ) : (
        <button
          className="btn btn-sm btn-primary"
          disabled={isPending}
          onClick={() => connect({ connector: injected() })}
        >
          Connect MetaMask
        </button>
      )}
    </div>
  );
};

export default WalletSwitcher; 