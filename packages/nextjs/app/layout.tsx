import "@rainbow-me/rainbowkit/styles.css";
import { ScaffoldEthAppWithProviders } from "~~/components/ScaffoldEthAppWithProviders";
import { ThemeProvider } from "~~/components/ThemeProvider";
import AutoRedirect from "~~/components/AutoRedirect";
import "~~/styles/globals.css";
import { getMetadata } from "~~/utils/scaffold-eth/getMetadata";

export const metadata = getMetadata({
  title: "LoanLink",
  description: "Peer-to-peer social lending platform powered by on-chain social underwriting",
  imageRelativePath: "/logo.svg"
});

// ---------------------------------------------------------------------------
// Demo wallet injection
// When NEXT_PUBLIC_DEMO_WALLET=true this inline script runs synchronously
// before wagmi initialises, so the fake provider is already in place when
// RainbowKit's MetaMask connector probes window.ethereum.
//
// The provider proxies ALL RPC calls to Anvil (http://127.0.0.1:8545), which
// auto-signs with its unlocked accounts — no popup required.
// Account switching is exposed via window.__demoEthereumProvider._switchAccount().
// ---------------------------------------------------------------------------
const DEMO_WALLET_SCRIPT = `
(function () {
  var DEFAULT_ADDR = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
  var currentAddr = DEFAULT_ADDR;
  try { var s = localStorage.getItem('__demoAccount'); if (s) currentAddr = s; } catch (_) {}

  var handlers = {};

  var provider = {
    isMetaMask: true,
    isConnected: function () { return true; },
    chainId: '0x7a69',
    networkVersion: '31337',
    get selectedAddress() { return currentAddr; },

    _metamask: { isUnlocked: function () { return Promise.resolve(true); } },

    _switchAccount: function (addr) {
      currentAddr = addr;
      try { localStorage.setItem('__demoAccount', addr); } catch (_) {}
      (handlers['accountsChanged'] || []).forEach(function (fn) { fn([addr]); });
    },

    request: async function (args) {
      var method = args.method;
      var params = args.params || [];
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [currentAddr];
      if (method === 'eth_chainId')  return '0x7a69';
      if (method === 'net_version')  return '31337';
      if (method === 'wallet_switchEthereumChain') return null;
      if (method === 'wallet_addEthereumChain')    return null;
      if (method === 'wallet_getPermissions')      return [{ parentCapability: 'eth_accounts' }];
      if (method === 'wallet_requestPermissions')  return [{ parentCapability: 'eth_accounts' }];
      var resp = await fetch('http://127.0.0.1:8545', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method: method, params: params }),
      });
      var data = await resp.json();
      if (data.error) { var e = new Error(data.error.message || 'RPC error'); e.code = data.error.code; throw e; }
      return data.result;
    },

    on: function (ev, fn) { (handlers[ev] = handlers[ev] || []).push(fn); },
    removeListener: function (ev, fn) {
      if (handlers[ev]) handlers[ev] = handlers[ev].filter(function (h) { return h !== fn; });
    },
    emit: function (ev) {
      var a = Array.prototype.slice.call(arguments, 1);
      (handlers[ev] || []).forEach(function (fn) { fn.apply(null, a); });
    },
  };

  window.__demoEthereumProvider = provider;
  window.ethereum = provider;

  var info = {
    uuid: 'demo-wallet-0000-0000-0000-000000000000',
    name: 'MetaMask',
    icon: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    rdns: 'io.metamask',
  };
  function announce() {
    window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
      detail: Object.freeze({ info: info, provider: provider }),
    }));
  }
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
  window.dispatchEvent(new Event('ethereum#initialized'));
})();
`;

const isDemoWallet = process.env.NEXT_PUBLIC_DEMO_WALLET === "true";

const ScaffoldEthApp = ({ children }: { children: React.ReactNode }) => {
  return (
    <html suppressHydrationWarning>
      <body>
        {/* Inject fake provider synchronously before any JS runs */}
        {isDemoWallet && (
          <script dangerouslySetInnerHTML={{ __html: DEMO_WALLET_SCRIPT }} />
        )}
        <ThemeProvider enableSystem>
          <ScaffoldEthAppWithProviders>
            <AutoRedirect />
            {children}
          </ScaffoldEthAppWithProviders>
        </ThemeProvider>
      </body>
    </html>
  );
};

export default ScaffoldEthApp;