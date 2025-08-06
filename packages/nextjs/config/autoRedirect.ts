/**
 * Auto-redirect configuration
 * 
 * This file contains configuration options for the automatic redirection
 * feature that sends users to appropriate pages based on their role.
 */

export const AUTO_REDIRECT_CONFIG = {
  // Enable/disable the auto-redirect feature globally
  enabled: true,
  
  // Delay before redirecting (in milliseconds)
  redirectDelay: 1000,
  
  // Show loading and redirect notifications
  showNotifications: true,
  
  // Default page for users with both borrower and lender roles
  defaultPageForBoth: "lender" as "borrower" | "lender",
  
  // Pages to redirect to for each role
  redirectPages: {
    borrower: "/borrower",
    lender: "/lender",
    both: "/lender", // This will be overridden by defaultPageForBoth
  },
  
  // Pages that should not trigger redirects (user can stay on these pages)
  allowedPages: ["/", "/borrower", "/lender", "/admin", "/oracle-setup", "/attest", "/fund", "/borrow", "/repay"],
} as const;

export type AutoRedirectConfig = typeof AUTO_REDIRECT_CONFIG; 