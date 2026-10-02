"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAccount } from "wagmi";
import { useIsAdmin } from "~~/hooks/useIsAdmin";
import { ADMIN_PATHS } from "~~/utils/isAdmin";

/** Sends connected non-admins away from admin-only routes. */
export default function AdminRouteGuard() {
  const pathname = usePathname();
  const router = useRouter();
  const { isConnected } = useAccount();
  const { admin, loading } = useIsAdmin();

  useEffect(() => {
    // Wait until both the wallet and the admin check have settled.
    if (!isConnected || loading) return;

    const wantsAdminArea = ADMIN_PATHS.some(
      (p) => pathname === p || pathname.startsWith(p + "/"),
    );

    if (wantsAdminArea && !admin) {
      router.replace("/lender");
    }
  }, [pathname, isConnected, admin, loading, router]);

  return null;
}