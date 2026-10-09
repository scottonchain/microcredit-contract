import Link from "next/link";
import { CHAIN_ID } from "~~/utils/microcredit";

export default function PopulateTestDataPage() {
  return (
    <main className="w-full max-w-2xl mx-auto p-6 space-y-5">
      <h1 className="text-3xl font-bold">Local demo data</h1>
      <p>
        The local deployment seeds the pool, borrowers and backer through one maintained script. Run it from the
        repository root to get the same scenario as the demo walkthrough.
      </p>
      {(CHAIN_ID as number) === 31337 ? (
        <>
          <p>Start a fresh local demo, including Anvil and the app:</p>
          <pre className="bg-base-200 rounded-lg p-4 overflow-auto">yarn demo --manual</pre>
          <p>
            If your local chain is already running, <code>yarn deploy</code> deploys and seeds a new pool. This changes
            the local contract addresses; reload the app afterward. See <code>DEMO.md</code> for the seeded personas and{" "}
            <code>yarn demo --reuse</code> to resume saved demo state.
          </p>
          <Link href="/fund" className="btn btn-primary">
            Fund a local wallet
          </Link>
        </>
      ) : (
        <p>Demo seeding is available only on the local Anvil chain. This build targets chain {CHAIN_ID}.</p>
      )}
      <p>
        <Link href="/admin" className="link">
          Return to admin
        </Link>
      </p>
    </main>
  );
}
