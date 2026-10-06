"use client";

import { BUILD_COMMIT, IS_LIVE_TESTNET, LIVE_DEPLOYMENT, MICROCREDIT_ADDRESS, RELAYER_ENABLED } from "~~/utils/microcredit";

/**
 * Shown on every page of a build that targets the live Base Sepolia pool: what network this is, that the
 * tokens have no value, which deployment the page talks to, and how transactions are paid for.
 */
export const TestnetBanner = () => {
  if (!IS_LIVE_TESTNET) return null;
  const poolUrl = `${LIVE_DEPLOYMENT.explorer}/address/${MICROCREDIT_ADDRESS}`;
  const walkthroughUrl = `https://github.com/scottonchain/microcredit-contract/blob/${BUILD_COMMIT || "main"}/docs/TESTNET_WALKTHROUGH.md`;
  return (
    <div className="bg-warning text-warning-content text-sm px-4 py-2">
      <div className="max-w-5xl mx-auto space-y-1">
        <p>
          <strong>Test network.</strong> This app talks to the project&apos;s pool on {LIVE_DEPLOYMENT.chainName} (chain
          id {LIVE_DEPLOYMENT.chainId}, a Base test network, not Ethereum Sepolia). Every token here is a test token with
          no value, and no real person has borrowed from this pool.
        </p>
        <p>
          Pool{" "}
          <a className="link" href={poolUrl} target="_blank" rel="noreferrer">
            {MICROCREDIT_ADDRESS}
          </a>
          , deployed from contract commit {LIVE_DEPLOYMENT.deployedCommit}
          {BUILD_COMMIT ? `; this page was built from commit ${BUILD_COMMIT}` : ""}.{" "}
          {RELAYER_ENABLED
            ? "Transactions are relayed for you."
            : "Your wallet signs and pays for each transaction: you need a little Base Sepolia ETH for gas, and test USDC is minted free on the lend and borrow pages. A new wallet has no credit to borrow against until someone who holds credit backs it or an issuer grants it a line."}{" "}
          <a className="link" href={walkthroughUrl} target="_blank" rel="noreferrer">
            Step-by-step walkthrough
          </a>
          : test gas, test USDC, credit, the wallet prompts and what to do after a rejected or lost transaction.
        </p>
      </div>
    </div>
  );
};
