import { useCallback, useEffect } from "react";
// import { useTargetNetwork } from "./useTargetNetwork"; // No longer needed since we removed price fetching logic
import { useInterval } from "usehooks-ts";
import scaffoldConfig from "~~/scaffold.config";
import { useGlobalState } from "~~/services/store/store";
// import { fetchPriceFromUniswap } from "~~/utils/scaffold-eth"; // Removed: file deleted in cleanup

const enablePolling = false;

/**
 * Get the price of Native Currency based on Native Token/DAI trading pair from Uniswap SDK
 *
 * NOTE: fetchPriceFromUniswap was removed in project cleanup. This hook now sets a default price (1) or does nothing.
 */
export const useInitializeNativeCurrencyPrice = () => {
  const setNativeCurrencyPrice = useGlobalState(state => state.setNativeCurrencyPrice);
  const setIsNativeCurrencyFetching = useGlobalState(state => state.setIsNativeCurrencyFetching);
  // const { targetNetwork } = useTargetNetwork(); // Not used in current simplified logic

  const fetchPrice = useCallback(async () => {
    setIsNativeCurrencyFetching(true);
    // const price = await fetchPriceFromUniswap(targetNetwork); // Removed
    const price = 1; // Default fallback price
    setNativeCurrencyPrice(price);
    setIsNativeCurrencyFetching(false);
  }, [setIsNativeCurrencyFetching, setNativeCurrencyPrice]);

  // Get the price of ETH from Uniswap on mount (now just sets default)
  useEffect(() => {
    fetchPrice();
  }, [fetchPrice]);

  // Get the price of ETH from Uniswap at a given interval (now just sets default)
  useInterval(fetchPrice, enablePolling ? scaffoldConfig.pollingInterval : null);
};
