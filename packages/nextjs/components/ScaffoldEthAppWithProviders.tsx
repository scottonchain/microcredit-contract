"use client";

import { useEffect, useState } from "react";
import { RainbowKitProvider, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AppProgressBar as ProgressBar } from "next-nprogress-bar";
import { useTheme } from "next-themes";
import { Toaster } from "react-hot-toast";
import { WagmiProvider } from "wagmi";
import { Footer } from "~~/components/Footer";
import { Header } from "~~/components/Header";
import { TestnetBanner } from "~~/components/TestnetBanner";
import { BlockieAvatar } from "~~/components/scaffold-eth";
import { useInitializeNativeCurrencyPrice } from "~~/hooks/scaffold-eth";
import { wagmiConfig } from "~~/services/web3/wagmiConfig";
import { DisplayNameProvider } from "~~/components/scaffold-eth/DisplayNameContext";
import { WalletErrorHandler } from "~~/components/WalletErrorHandler";

const ScaffoldEthApp = ({ children }: { children: React.ReactNode }) => {
  useInitializeNativeCurrencyPrice();

  return (
    <>
      <div className={`flex flex-col min-h-screen `}>
        <Header />
        <main className="relative flex flex-col flex-1">{children}</main>
        <Footer />
        <TestnetBanner />
      </div>
      <Toaster />
    </>
  );
};

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
    },
  },
});

export const ScaffoldEthAppWithProviders = ({ children }: { children: React.ReactNode }) => {
  const { resolvedTheme } = useTheme();
  const isDarkMode = resolvedTheme === "dark";
  const [mounted, setMounted] = useState(false);
  const useDarkPalette = mounted && isDarkMode;
  const walletTheme = (useDarkPalette ? darkTheme : lightTheme)({
    accentColor: useDarkPalette ? "#78a9ff" : "#0f62fe",
    accentColorForeground: useDarkPalette ? "#161616" : "#ffffff",
  });
  walletTheme.colors.modalTextSecondary = useDarkPalette ? "#c6c6c6" : "#525252";
  walletTheme.colors.modalTextDim = walletTheme.colors.modalTextSecondary;

  useEffect(() => {
    setMounted(true);
  }, []);

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ProgressBar height="3px" color="var(--color-primary)" />
        <RainbowKitProvider
          avatar={BlockieAvatar}
          theme={walletTheme}
        >
          <DisplayNameProvider>
            <WalletErrorHandler />
            <ScaffoldEthApp>{children}</ScaffoldEthApp>
          </DisplayNameProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
};
