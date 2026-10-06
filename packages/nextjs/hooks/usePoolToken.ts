import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { USDC_ADDRESS } from "~~/utils/microcredit";

/**
 * The pool's token as the chain reports it (`usdc()`), against the token this build was configured with
 * (`USDC_ADDRESS`). A mismatch means the build points at the wrong pool or the wrong token: approvals would go to
 * one token and deposits be pulled in another, so the pages disable their writes and the banner says why.
 */
export const usePoolToken = () => {
  const { data: poolToken } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc",
  });
  const loaded = poolToken !== undefined;
  const mismatch =
    loaded && (!USDC_ADDRESS || (poolToken as string).toLowerCase() !== (USDC_ADDRESS as string).toLowerCase());
  return { poolToken: poolToken as `0x${string}` | undefined, configuredToken: USDC_ADDRESS, loaded, mismatch };
};
