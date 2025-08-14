"use client";

import { useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";

export default function AttestRedirectPage() {
  const router = useRouter();
  const params = useSearchParams();

  useEffect(() => {
    const query = params?.toString();
    const target = query ? `/lend?${query}` : "/lend";
    router.replace(target);
  }, [params, router]);

  return (
    <div className="flex items-center justify-center min-h-[60vh]">
      <div className="text-center">
        <p className="mb-3">Redirecting to the lender page…</p>
        <Link href={params?.toString() ? `/lend?${params?.toString()}` : "/lend"} className="underline">
          Click here if you are not redirected
        </Link>
      </div>
    </div>
  );
}