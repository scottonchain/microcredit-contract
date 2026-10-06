# Trying the pool on Base Sepolia, step by step

The public app at https://scottonchain.github.io/pool/ talks to the project's pool on **Base Sepolia** (chain id 84532, a Base test network, not Ethereum Sepolia). Its token is Circle's Base Sepolia test USDC, which has no value, and no real person has borrowed from this pool. Your own wallet signs and pays for each transaction; nothing is relayed for you in this release.

What the app does, in one paragraph: lenders deposit test USDC into one shared pool; a borrower can draw from it only against credit that someone holding credit has backed them with, or a line an issuer granted; loans are repaid with interest, and backers are charged if a borrower defaults. `docs/CREDIT_MODEL.md` has the rules; this page only gets you through the screens.

## 1. What you need

- A browser wallet: MetaMask, Rabby or Coinbase Wallet (the three the app's connect button offers).
- The Base Sepolia network in that wallet. Most wallets add it when the app asks; otherwise add it by hand: chain id `84532`, RPC `https://sepolia.base.org`, currency ETH, explorer `https://sepolia.basescan.org`.
- A little Base Sepolia ETH for gas. Each step below is one or two transactions; a few thousandths of an ETH covers a whole run.
- Some test USDC from Circle's faucet (section 3).

## 2. Test gas

We have not verified a faucet from this project's own environment, so this section names routes rather than promising one:

- Public faucets for Base Sepolia ETH exist from Coinbase (Coinbase Developer Platform), Alchemy, QuickNode and thirdweb. Each needs an account with that provider, and some require a small mainnet balance or a social login. Search "Base Sepolia faucet"; use only the provider's own domain.
- Manual fallback, in the words of the project's testnet operator (an agent, HermesCRBot): if no faucet works for you, comment on [contract issue 7](https://github.com/scottonchain/microcredit-contract/issues/7) with your address and the word "gas". It may send 0.002 ETH, once per address, from its deployer wallet, as a disclosed manual step, with no guarantee of speed.

Gas is not credit. Having ETH lets you send transactions; it does not let you borrow (section 5).

## 3. Test USDC

The pool's token is Circle's Base Sepolia test USDC, `0x036CbD53842c5426634e7929541eC2318f3dCF7e`. The app cannot mint it; get it from Circle's faucet at https://faucet.circle.com: choose Base Sepolia, paste your address, submit. The amount and cooldown shown on that page were read by a team member as 20 USDC per address every two hours; this project has not verified them, so read the page. Add the token to your wallet by that address to see the balance; the app shows it on the Lend and Borrow pages once you connect.

## 4. Lend

On **Lend**, enter an amount and press deposit. Two wallet prompts: `approve` (the pool may take that much USDC) and `depositFunds`. The page reports success only after the second transaction is mined; if you reject either prompt, nothing is deposited and no success message appears. Withdrawals are one transaction (`withdrawFunds`) for what the pool can pay at once; the withdrawal queue for the rest exists only in the relayed version of the app.

## 5. Credit: why a new wallet cannot borrow yet

A fresh wallet has a borrow limit of 0. Credit is conserved: it is never created by holding tokens, depositing or holding ETH. There are two ways to get some:

- **Backing.** Someone who holds credit backs you with part of theirs, on the **Back** page (the Borrow page gives you a link to send them). Their free credit goes down by what they commit; your limit goes up by the same amount. If you default, they are charged.
- **An issued line.** The pool's score oracle can grant a line. On this test deployment the oracle's reporter is held by the project's testnet operator.

Fresh-address route for this test, in the testnet operator's words: comment on [contract issue 7](https://github.com/scottonchain/microcredit-contract/issues/7) with your address and the word "credit". It may back you with about 10 test USDC of credit, or issue a small line, once per address, on this pool only, at its discretion and revocable, as a disclosed manual step; this is not instant self-service. The **Scores** page shows your limit once it changes.

## 6. Borrow

On **Borrow**, with credit in place, enter an amount within your limit and press **Borrow (two wallet transactions)**. The loan runs for the pool's default term of 30 days; chosen periods exist only in the relayed version.

- Prompt 1, `requestLoan`: reserves the amount for you. The page records what it is doing before it asks you to sign, and keeps the transaction hash as soon as your wallet returns one.
- Prompt 2, `disburseLoan`: pays the amount to your wallet. The page sends it only for the loan that prompt 1 created, identified from that transaction's receipt, and only if the same wallet on the same network is still connected.

The app shows "Loan requested, not yet disbursed" whenever a loan of yours is reserved but not paid out, with **Disburse** and **Cancel request** buttons. Nothing else can be requested until one of the two is done.

## 7. Repay

On **Borrow**, the active loan shows what is owed. Repay in full or in part: two prompts, `approve` and `repayLoan`. Interest is settled before principal; a balance under one cent is forgiven. You need enough USDC for the interest as well as the principal; the faucet covers it.

## 8. If something goes wrong

| What happened | What the page does | What you do |
| --- | --- | --- |
| You rejected the first borrow prompt | Nothing was sent; the form is back | Try again when ready |
| You rejected the second borrow prompt | The loan stays requested; the page offers Disburse or Cancel for that loan | Press one of them |
| The page lost the connection, or you closed it, while a borrow was in flight | On reload it checks the request's receipt and shows either the Disburse/Cancel card or "Checking a loan request" until the chain answers; it never offers a new request while that is unresolved | Wait for the card, then choose |
| Your wallet returned no transaction hash and nothing matching appears on chain | After ten minutes the page offers "Dismiss: no matching loan was found" | Check the explorer for your address first, then dismiss |
| You opened the page in two tabs | Both tabs see the same pending request and neither offers a new one | Finish it in one tab |
| Your wallet is on another network | The app asks you to switch; nothing is sent, no success is shown | Switch to Base Sepolia |
| You switched accounts between the two prompts of a step | The second transaction is not sent; the page says the wallet changed | Switch back and repeat the step |
| The banner shows "Token mismatch" | The build's token is not the pool's token; every write is disabled | Report it on contract issue 7; nothing you do can go wrong meanwhile |
| A transaction reverted | The page shows the error text from the contract | Read it; the usual causes are a limit, a paused pool or an already settled loan |

Every transaction you send appears under your address on https://sepolia.basescan.org.

## 9. What this release does not do

Gasless (relayed) transactions, the withdrawal queue, chosen loan terms and the admin pages. The pool was deployed from contract commit 1812e7d; the app may be built from a later commit, and the banner at the bottom of every page names both. The earlier mock-token pool is history (`docs/TESTNET.md`).
