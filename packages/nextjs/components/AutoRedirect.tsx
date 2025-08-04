"use client";

import { useEffect } from "react";
import { useUserRole } from "~~/hooks/useUserRole";
import { usePathname } from "next/navigation";
import { AUTO_REDIRECT_CONFIG } from "~~/config/autoRedirect";

/**
 * AutoRedirect Component
 * 
 * Automatically redirects users to appropriate pages based on their role:
 * - Borrowers are redirected to /borrower
 * - Lenders are redirected to /lender  
 * - Users with both roles are redirected to /borrower (default)
 * - New users (no role) are not redirected
 * 
 * The component shows loading and redirect notifications to provide
 * user feedback during the process.
 */

interface AutoRedirectProps {
  enabled?: boolean;
  redirectDelay?: number;
  showNotifications?: boolean;
}

export const AutoRedirect: React.FC<AutoRedirectProps> = ({ 
  enabled = AUTO_REDIRECT_CONFIG.enabled, 
  redirectDelay = AUTO_REDIRECT_CONFIG.redirectDelay,
  showNotifications = AUTO_REDIRECT_CONFIG.showNotifications
}) => {
  const { userRole, isLoading, redirectToAppropriatePage } = useUserRole();
  const pathname = usePathname();

  // Determine if the current user *needs* to be redirected
  const isOnBorrowerPage = pathname === AUTO_REDIRECT_CONFIG.redirectPages.borrower;
  const isOnLenderPage = pathname === AUTO_REDIRECT_CONFIG.redirectPages.lender;
  const isOnHomePage = pathname === "/";

  const needsRedirect = (userRole === "borrower" && !isOnBorrowerPage) ||
                        (userRole === "lender" && !isOnLenderPage) ||
                        (userRole === "both" && isOnHomePage);

  useEffect(() => {
    if (!enabled || isLoading) return;

    // Don't redirect if user has no role (new user)
    if (userRole === "none") return;

    // Check if user is on an allowed page (no redirect needed)
    const isOnAllowedPage = AUTO_REDIRECT_CONFIG.allowedPages.includes(pathname as any);
    
    // If user is on an allowed page, don't redirect
    if (isOnAllowedPage) return;

    // Trigger redirect when needed
    if (needsRedirect) {
      const timer = setTimeout(() => {
        redirectToAppropriatePage();
      }, redirectDelay);
      return () => clearTimeout(timer);
    }
  }, [userRole, isLoading, pathname, enabled, redirectDelay, redirectToAppropriatePage, needsRedirect]);

  // Show loading indicator if checking user role
  if (isLoading && showNotifications) {
    return (
      <div className="fixed top-4 right-4 z-50">
        <div className="bg-blue-100 border border-blue-400 text-blue-700 px-4 py-3 rounded">
          <div className="flex items-center">
            <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-blue-700 mr-2"></div>
            <span className="text-sm">Checking your account...</span>
          </div>
        </div>
      </div>
    );
  }

  // Show role indicator for debugging (can be removed in production)
  if (enabled && needsRedirect && showNotifications) {
    return (
      <div className="fixed top-4 right-4 z-50">
        <div className="bg-green-100 border border-green-400 text-green-700 px-4 py-3 rounded">
          <div className="flex items-center">
            <span className="text-sm">
              {userRole === "borrower" && "Redirecting to borrower page..."}
              {userRole === "lender" && "Redirecting to lender page..."}
              {userRole === "both" && "Redirecting to lender page..."}
            </span>
          </div>
        </div>
      </div>
    );
  }

  return null;
}; 