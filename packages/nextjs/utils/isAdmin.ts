export const ADDITIONAL_ADMINS = new Set<string>([
  "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
  "0xef4b3cbca9f0a6b4b80e57a12a19e7ef1124f754",
  "0xd7c5a101ee877daab1a3731cdcf316066ddccf92",
  "0xd8ffc0b6bfaab3828c0d92aed3412186ebffa5fc",
]);

export const ADMIN_PATHS = ["/admin", "/populate", "/populate_test_data"] as const;

export function isWhitelisted(addr?: string) {
  return !!addr && ADDITIONAL_ADMINS.has(addr.toLowerCase());
}
