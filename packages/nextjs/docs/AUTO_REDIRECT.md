# Auto-Redirect Feature

## Overview

The auto-redirect feature automatically sends users to the appropriate page based on their role in the microcredit platform. This provides a seamless user experience by taking users directly to their relevant dashboard.

## How It Works

### User Role Detection

The system determines user roles by checking:

1. **Borrower**: User has active loans (checked via `getBorrowerLoanIds`)
2. **Lender**: User has deposits in the lending pool (checked via `lenderDeposits`)
3. **Both**: User has both loans and deposits
4. **None**: New user with no active participation

### Redirection Logic

- **Borrowers** → `/borrower` page
- **Lenders** → `/lender` page  
- **Both roles** → Default to `/lender` (configurable)
- **New users** → Stay on current page (typically home page)

### Timing

- Redirection happens after a 1-second delay (configurable)
- Users see loading and redirect notifications
- No redirection if already on appropriate page

## Configuration

The feature is configured in `config/autoRedirect.ts`:

```typescript
export const AUTO_REDIRECT_CONFIG = {
  enabled: true,                    // Enable/disable globally
  redirectDelay: 1000,             // Delay before redirect (ms)
  showNotifications: true,          // Show loading/redirect notifications
  defaultPageForBoth: "lender",   // Default for users with both roles
  redirectPages: {
    borrower: "/borrower",
    lender: "/lender",
    both: "/lender",
  },
  allowedPages: ["/", "/borrower", "/lender", "/admin", "/oracle-setup"],
};
```

## Components

### useUserRole Hook

```typescript
const { userRole, isLoading, isBorrower, isLender, redirectToAppropriatePage } = useUserRole();
```

**Returns:**
- `userRole`: Current user role ("borrower" | "lender" | "both" | "none")
- `isLoading`: Whether role detection is in progress
- `isBorrower`: Boolean indicating if user is a borrower
- `isLender`: Boolean indicating if user is a lender
- `redirectToAppropriatePage`: Function to manually trigger redirection

### AutoRedirect Component

Automatically handles redirection based on user role. Used in the main layout:

```tsx
<AutoRedirect 
  enabled={true}
  redirectDelay={1000}
  showNotifications={true}
/>
```

## Usage Examples

### Manual Redirection

```tsx
import { useUserRole } from "~~/hooks/useUserRole";

function MyComponent() {
  const { userRole, redirectToAppropriatePage } = useUserRole();
  
  const handleContinue = () => {
    redirectToAppropriatePage();
  };
  
  return (
    <button onClick={handleContinue}>
      Continue to Dashboard
    </button>
  );
}
```

### Conditional Rendering

```tsx
import { useUserRole } from "~~/hooks/useUserRole";

function Dashboard() {
  const { userRole, isLoading } = useUserRole();
  
  if (isLoading) return <div>Loading...</div>;
  
  switch (userRole) {
    case "borrower":
      return <BorrowerDashboard />;
    case "lender":
      return <LenderDashboard />;
    case "both":
      return <CombinedDashboard />;
    default:
      return <NewUserOnboarding />;
  }
}
```

## Disabling the Feature

To disable auto-redirect globally, set `enabled: false` in the config:

```typescript
export const AUTO_REDIRECT_CONFIG = {
  enabled: false,  // Disable auto-redirect
  // ... other config
};
```

Or disable for specific components:

```tsx
<AutoRedirect enabled={false} />
```

## Customization

### Changing Default Page for Both Roles

```typescript
export const AUTO_REDIRECT_CONFIG = {
  // ... other config
  defaultPageForBoth: "borrower",  // Default to borrower page instead
};
```

### Custom Redirect Pages

```typescript
export const AUTO_REDIRECT_CONFIG = {
  // ... other config
  redirectPages: {
    borrower: "/my-borrower-page",
    lender: "/my-lender-page",
    both: "/my-lender-page",
  },
};
```

### Adjusting Timing

```typescript
export const AUTO_REDIRECT_CONFIG = {
  // ... other config
  redirectDelay: 2000,  // 2 second delay
};
```

## Testing

The feature can be tested by:

1. Connecting with a wallet that has loans → Should redirect to `/borrower`
2. Connecting with a wallet that has deposits → Should redirect to `/lender`
3. Connecting with a wallet that has both → Should redirect to default page
4. Connecting with a new wallet → Should stay on current page

## Troubleshooting

### Common Issues

1. **No redirection happening**: Check if `enabled` is true in config
2. **Infinite redirects**: Ensure redirect pages are in `allowedPages`
3. **Wrong page**: Verify `redirectPages` configuration
4. **Loading forever**: Check contract connection and role detection logic

### Debug Mode

Enable notifications to see what's happening:

```tsx
<AutoRedirect showNotifications={true} />
```

This will show loading and redirect status messages. 