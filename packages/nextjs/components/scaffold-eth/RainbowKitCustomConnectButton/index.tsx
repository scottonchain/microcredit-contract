"use client";

// @refresh reset
import { Balance } from "../Balance";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { useBalance, useAccount } from "wagmi";
import { AddressInfoDropdown } from "./AddressInfoDropdown";
import { AddressQRCodeModal } from "./AddressQRCodeModal";
import { WrongNetworkDropdown } from "./WrongNetworkDropdown";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Address } from "viem";
import { useNetworkColor } from "~~/hooks/scaffold-eth";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";
import { getBlockExplorerAddressLink } from "~~/utils/scaffold-eth";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";

/**
 * Custom Wagmi Connect Button (watch balance + custom design)
 */
export const RainbowKitCustomConnectButton = () => {
  const networkColor = useNetworkColor();
  const { targetNetwork } = useTargetNetwork();
  const { address: connectedAddress } = useAccount();

  // Display name context (must be top-level hook)
  const { displayName } = useDisplayName();

  // USDC contract address (static) for balance display
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc" as any,
  });

  // Fetch USDC balance for connected account.
  // We disable the query until we actually know the token address to avoid
  // an initial fetch that returns the native ETH balance (which caused the
  // widget to show the ETH amount next to "USDC").
  const usdcTokenAddress = usdcAddress as Address | undefined;
  const { data: usdcBal } = useBalance({
    address: connectedAddress as Address | undefined,
    token: usdcTokenAddress,
    query: {
      refetchInterval: 4000,
    },
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
                return (
                  <button className="btn btn-primary btn-sm" onClick={openConnectModal} type="button">
                    Connect Wallet
                  </button>
                );
              }

              if (chain.unsupported || chain.id !== targetNetwork.id) {
                return <WrongNetworkDropdown />;
              }

              return (
                <>
                  <div className="flex flex-col items-center mr-1 text-xs">
                    <Balance address={account.address as Address} className="min-h-0 h-auto" />
                    {usdcTokenAddress && usdcBal && (
                      <span>{Number(usdcBal.formatted).toFixed(2)} USDC</span>
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
