# Wallet Support

This application supports multiple wallet providers through RainbowKit integration.

## Supported Wallets

The following wallets are currently supported:

### 1. MetaMask
- **Type**: Browser Extension
- **Website**: https://metamask.io/
- **Features**: Most popular Ethereum wallet, supports multiple networks

### 2. WalletConnect
- **Type**: Mobile/Desktop Bridge
- **Website**: https://walletconnect.com/
- **Features**: Connect any wallet to any dApp, mobile-friendly

### 3. Ledger
- **Type**: Hardware Wallet
- **Website**: https://www.ledger.com/
- **Features**: Cold storage security, supports multiple cryptocurrencies

### 4. Coinbase Wallet
- **Type**: Mobile App/Browser Extension
- **Website**: https://www.coinbase.com/wallet
- **Features**: User-friendly interface, integrated with Coinbase exchange

### 5. Rainbow Wallet
- **Type**: Mobile App
- **Website**: https://rainbow.me/
- **Features**: Beautiful UI, built-in DEX integration

### 6. Rabby Wallet
- **Type**: Browser Extension
- **Website**: https://rabby.io/
- **Features**: Security-focused wallet with transaction simulation and risk detection

### 7. Safe Wallet (formerly Gnosis Safe)
- **Type**: Multi-sig Wallet
- **Website**: https://safe.global/
- **Features**: Multi-signature security, team wallet management

## Adding New Wallets

To add support for a new wallet:

1. **Check RainbowKit Support**: Verify the wallet is supported in RainbowKit v2
2. **Import the Wallet**: Add the wallet import to `services/web3/wagmiConnectors.tsx`
3. **Add to Wallet List**: Include the wallet in the `wallets` array
4. **Test Integration**: Verify the wallet connects properly

### Example: Adding a New Wallet

```typescript
// In wagmiConnectors.tsx
import { newWallet } from "@rainbow-me/rainbowkit/wallets";

const wallets = [
  metaMaskWallet,
  walletConnectWallet,
  // ... other wallets
  newWallet, // Add the new wallet here
];
```

## Wallet Configuration

The wallet configuration is handled in:
- `services/web3/wagmiConnectors.tsx` - Wallet list and configuration
- `services/web3/wagmiConfig.tsx` - Wagmi client configuration
- `scaffold.config.ts` - Network and project settings

### WalletConnect Setup

WalletConnect requires a project ID from [WalletConnect Cloud](https://cloud.walletconnect.com):

1. **Get Project ID**: Sign up at https://cloud.walletconnect.com
2. **Create Project**: Create a new project and copy the project ID
3. **Set Environment Variable**: Add to `packages/nextjs/.env.local`:
   ```env
   NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=your_project_id_here
   ```

**Note**: The application will work without a custom WalletConnect project ID, but it's recommended for production use.

## Testing Wallet Integration

To test wallet integration:

1. **Start Development Server**: `yarn dev`
2. **Open Browser**: Navigate to the application
3. **Click Connect Wallet**: Verify all supported wallets appear
4. **Test Connection**: Connect with each wallet type
5. **Test Functionality**: Ensure wallet can sign transactions

## Troubleshooting

### Common Issues

1. **Wallet Not Appearing**: Check if the wallet is properly imported and added to the list
2. **Connection Fails**: Verify the wallet is installed and unlocked
3. **Transaction Errors**: Check network compatibility and gas settings
4. **WalletConnect Errors**: 
   - Ensure WalletConnect project ID is valid
   - Check browser console for specific error messages
   - Try refreshing the page or clearing browser cache
   - Verify WalletConnect Cloud project is active

### Debug Steps

1. Check browser console for errors
2. Verify wallet extension is installed and enabled
3. Ensure the wallet supports the target network
4. Check if the wallet requires additional setup

## Security Considerations

- Always verify transaction details before signing
- Use hardware wallets for large transactions
- Keep wallet software updated
- Be cautious of phishing attempts
- Consider using multi-sig wallets for team operations 