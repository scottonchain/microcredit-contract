"use client";

// @refresh reset
import { useEffect, useState } from "react";
import { Balance } from "../Balance";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { useAccount } from "wagmi";
import { AddressInfoDropdown } from "./AddressInfoDropdown";
import { AddressQRCodeModal } from "./AddressQRCodeModal";
import { WrongNetworkDropdown } from "./WrongNetworkDropdown";
import { DemoModeDropdown } from "./DemoModeDropdown";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Address } from "viem";
import { useNetworkColor } from "~~/hooks/scaffold-eth";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";
import { getBlockExplorerAddressLink } from "~~/utils/scaffold-eth";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { formatUSDC } from "~~/utils/format";

const IS_DEMO = process.env.NEXT_PUBLIC_DEMO_WALLET === "true";

/**
 * Custom Wagmi Connect Button (watch balance + custom design)
 */
export const RainbowKitCustomConnectButton = () => {
  const networkColor = useNetworkColor();
  const { targetNetwork } = useTargetNetwork();
  const { address: connectedAddress } = useAccount();

  // Display name context (must be top-level hook)
  const { displayName } = useDisplayName();

  // Track whether we've ever been connected in this session so we can keep
  // the DemoModeDropdown visible during wagmi's brief reconnecting phase
  // when the user switches demo personas (instead of flashing "Start Demo").
  const [hasConnectedOnce, setHasConnectedOnce] = useState(false);

  useEffect(() => {
    if (IS_DEMO && connectedAddress) {
      setHasConnectedOnce(true);
    }
  }, [connectedAddress]);

  // USDC contract address (static) for balance display
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc" as any,
  });

  // Fetch USDC balance for connected account using the same logic as lend/page.tsx
  const { data: usdcBalanceData } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [connectedAddress as `0x${string}`],
    query: { refetchInterval: 4000, enabled: Boolean(usdcAddress && connectedAddress) },
  });

  return (
    <ConnectButton.Custom>
      {({ account, chain, openConnectModal, mounted }) => {
        const connected = mounted && account && chain;
        const blockExplorerAddressLink = account
          ? getBlockExplorerAddressLink(targetNetwork, account.address)
          : undefined;

        return (
          <>
            {(() => {
              if (!connected) {
                // In demo mode, if we've connected before (i.e. we're in a brief
                // reconnecting phase during persona switch), show the dropdown
                // using the address directly from the demo provider so there's
                // no "Start Demo" flash.
                if (IS_DEMO && hasConnectedOnce) {
                  const demoAddr =
                    (typeof window !== "undefined" &&
                      (window as any).__demoEthereumProvider?.selectedAddress) || "";
                  if (demoAddr) return <DemoModeDropdown address={demoAddr} />;
                }
                return (
                  <button className="btn btn-primary btn-sm" onClick={openConnectModal} type="button">
                    {IS_DEMO ? "Start Demo" : "Connect Wallet"}
                  </button>
                );
              }

              // In demo mode, replace both WrongNetworkDropdown and the normal
              // address display with the persona-switcher dropdown.
              if (IS_DEMO) {
                return <DemoModeDropdown address={account.address} />;
              }

              if (chain.unsupported || chain.id !== targetNetwork.id) {
                return <WrongNetworkDropdown />;
              }

              return (
                <>
                  <div className="flex flex-col items-center mr-1 text-xs">
                    {usdcBalanceData !== undefined && (
                      <span>{formatUSDC(usdcBalanceData)} USDC</span>
                    )}
                    <span className="text-xs mt-0.5" style={{ color: networkColor }}>
                      {chain.name}
                    </span>
                  </div>
                  <AddressInfoDropdown
                    address={account.address as Address}
                    displayName={displayName || account.displayName}
                    ensAvatar={account.ensAvatar}
                    blockExplorerAddressLink={blockExplorerAddressLink}
                  />
                  <AddressQRCodeModal address={account.address as Address} modalId="qrcode-modal" />
                </>
              );
            })()}
          </>
        );
      }}
    </ConnectButton.Custom>
  );
};
