"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAccount } from "wagmi";
import { useIsAdmin } from "~~/hooks/useIsAdmin";
import { ADMIN_PATHS } from "~~/utils/isAdmin";

/**
 * Sends connected non-admins away from admin-only routes. Redirects only on a definite "not
 * admin"; while the check is unresolved the admin pages show their loading state.
 */
export default function AdminRouteGuard() {
  const pathname = usePathname();
  const router = useRouter();
  const { isConnected } = useAccount();
  const { admin, loading } = useIsAdmin();

  useEffect(() => {
    // Wait for a connected wallet and a resolved owner/oracle check (see useIsAdmin).
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