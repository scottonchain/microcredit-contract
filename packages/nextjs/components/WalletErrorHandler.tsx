"use client";

import { useEffect } from "react";
import { toast } from "react-hot-toast";

export const WalletErrorHandler = () => {
  useEffect(() => {
    // Handle WalletConnect connection errors
    const handleWalletConnectError = (event: ErrorEvent) => {
      if (
        event.error?.message?.includes("Connection interrupted") ||
        event.error?.message?.includes("subscribe") ||
        event.error?.message?.includes("WalletConnect")
      ) {
        console.log("WalletConnect connection error detected");
        toast.error(
          "Wallet connection interrupted. Please refresh the page and try connecting again.",
          {
            duration: 5000,
            position: "top-center",
          }
        );
      }
    };

    // Handle unhandled promise rejections
    const handleUnhandledRejection = (event: PromiseRejectionEvent) => {
      if (
        event.reason?.message?.includes("Connection interrupted") ||
        event.reason?.message?.includes("subscribe") ||
        event.reason?.message?.includes("WalletConnect")
      ) {
        console.log("WalletConnect promise rejection detected");
        toast.error(
          "Wallet connection issue detected. Please refresh the page and try again.",
          {
            duration: 5000,
            position: "top-center",
          }
        );
      }
    };

    // Add event listeners
    window.addEventListener("error", handleWalletConnectError);
    window.addEventListener("unhandledrejection", handleUnhandledRejection);

    // Cleanup
    return () => {
      window.removeEventListener("error", handleWalletConnectError);
      window.removeEventListener("unhandledrejection", handleUnhandledRejection);
    };
  }, []);

  return null;
}; 