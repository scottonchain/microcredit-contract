"use client";

import Link from "next/link";
import { Address } from "~~/components/scaffold-eth";
import { useIsAdmin } from "~~/hooks/useIsAdmin";

export default function OracleSetupPage() {
  const { address, owner, oracle, admin, loading } = useIsAdmin();
  return (
    <main className="w-full max-w-2xl mx-auto p-6 space-y-5">
      <h1 className="text-3xl font-bold">Oracle and admin access</h1>
      <dl className="bg-base-100 rounded-lg p-6 space-y-3">
        <dt className="font-semibold">Contract owner</dt>
        <dd>{owner ? <Address address={owner} /> : "Loading…"}</dd>
        <dt className="font-semibold">Current oracle</dt>
        <dd>{oracle ? <Address address={oracle} /> : "Loading…"}</dd>
      </dl>
      <p>
        {!address
          ? "Connect your wallet to check admin access."
          : loading
            ? "Checking your roles…"
            : admin
              ? "Your wallet can open the admin page. Each action still requires its contract role."
              : "Your wallet has no configured admin access. Contact the contract owner if you need a role."}
      </p>
      <p>
        Only an authorized contract role can change the oracle. Connecting a wallet or opening the debug page grants no
        permissions.
      </p>
      <Link href="/admin" className="btn btn-primary">
        Open admin
      </Link>
    </main>
  );
}
