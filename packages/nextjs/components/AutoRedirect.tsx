"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAccount } from "wagmi";
import { useIsAdmin } from "~~/hooks/useIsAdmin";
import { ADMIN_PATHS } from "~~/utils/isAdmin";

export default function AutoRedirect() {
  const pathname = usePathname();
  const router = useRouter();
  const { isConnected } = useAccount();
  const { admin, loading } = useIsAdmin();

  useEffect(() => {
    // Don’t redirect until we know the truth
    if (!isConnected || loading) return;

    const wantsAdminArea = ADMIN_PATHS.some(
      (p) => pathname === p || pathname.startsWith(p + "/"),
    );

    if (wantsAdminArea && !admin) {
      router.replace("/lender");
    }
  }, [pathname, isConnected, admin, loading, router]);

  return null;
};