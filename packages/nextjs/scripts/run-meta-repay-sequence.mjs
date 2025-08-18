#!/usr/bin/env node
import { createPublicClient, createWalletClient, http, keccak256, encodePacked } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { localhost } from "viem/chains";

const RPC_URL = process.env.LOCAL_RPC_URL || "http://localhost:8545";
const API_BASE = process.env.API_BASE || "http://localhost:3000";
const CHAIN_ID = 31337;

// Addresses from packages/nextjs/contracts/deployedContracts.ts
const USDC_ADDRESS = "0x700b6a60ce7eaaea56f065753d8dcb9653dbad35";
const MICRO_ADDRESS = "0xed1db453c3156ff3155a97ad217b3087d5dc5f6e";

// Minimal ABIs for reads
const MICRO_ABI_MIN = [
  { name: "nonces", type: "function", stateMutability: "view", inputs: [{ name: "", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getLoan", type: "function", stateMutability: "view", inputs: [{ name: "", type: "uint256" }], outputs: [
    { type: "uint256" }, // principal
    { type: "uint256" }, // outstanding
    { type: "address" }, // borrower
    { type: "uint256" }, // interestRate
    { type: "bool" }     // isActive
  ]},
];
const USDC_ABI_MIN = [
  { name: "name", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "nonces", type: "function", stateMutability: "view", inputs: [{ name: "", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "mint", type: "function", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "value", type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
];
const MICRO_ABI_WRITE = [
  { name: "depositFunds", type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { name: "recordAttestation", type: "function", stateMutability: "nonpayable", inputs: [{ name: "borrower", type: "address" }, { name: "weight", type: "uint256" }], outputs: [] },
  { name: "setRelayerWhitelistEnabled", type: "function", stateMutability: "nonpayable", inputs: [{ name: "enabled", type: "bool" }], outputs: [] },
  { name: "setRelayerWhitelisted", type: "function", stateMutability: "nonpayable", inputs: [{ name: "relayer", type: "address" }, { name: "allowed", type: "bool" }], outputs: [] },
];

// EIP-712 Types
const MICRO_DOMAIN = (verifyingContract) => ({
  name: "DecentralizedMicrocredit",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract,
});
const TYPES = {
  LoanRequest: [
    { name: "borrower", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  DisburseRequest: [
    { name: "borrower", type: "address" },
    { name: "loanId", type: "uint256" },
    { name: "to", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  // RepayRequest removed — repayment uses permit-only flow via API /api/meta/repay-one
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

const publicClient = createPublicClient({ chain: { ...localhost, id: CHAIN_ID }, transport: http(RPC_URL) });

// Borrower key used only for off-chain signing in local dev (matches Foundry style small int pk)
const BORROWER_PK = BigInt("0xA11CE").toString(16).padStart(64, "0");
const borrowerPkHex = "0x" + BORROWER_PK;
const borrower = privateKeyToAccount(borrowerPkHex);

const wallet = createWalletClient({ account: borrower, chain: { ...localhost, id: CHAIN_ID }, transport: http(RPC_URL) });

function domainSeparator(name, verifying) {
  const nameHash = keccak256(encodePacked(["string"],[name]));
  const versionHash = keccak256(encodePacked(["string"],["1"]));
  const encoded = encodePacked(
    ["bytes32","bytes32","bytes32","uint256","address"],
    [EIP712_DOMAIN_TYPEHASH, nameHash, versionHash, BigInt(CHAIN_ID), verifying]
  );
  return keccak256(encoded);
}

async function signTyped(account, domain, types, primaryType, message) {
  return account.signTypedData({ domain, types, primaryType, message });
}

async function fundBorrowerEth() {
  const amtHex = '0x56BC75E2D63100000'; // 100 ETH
  try {
    await publicClient.request({ method: 'anvil_setBalance', params: [borrower.address, amtHex] });
    return;
  } catch {}
  try {
    await publicClient.request({ method: 'hardhat_setBalance', params: [borrower.address, amtHex] });
  } catch (e) {
    console.warn('Could not set ETH balance via anvil/hardhat RPC; proceeding (may fail if no ETH).');
  }
}

async function signLoanRequest(amount, nonce, deadline) {
  return signTyped(borrower, MICRO_DOMAIN(MICRO_ADDRESS), TYPES, "LoanRequest", {
    borrower: borrower.address,
    amount,
    nonce,
    deadline,
  });
}

async function signDisburseRequest(loanId, to, nonce, deadline) {
  return signTyped(borrower, MICRO_DOMAIN(MICRO_ADDRESS), TYPES, "DisburseRequest", {
    borrower: borrower.address,
    loanId,
    to,
    nonce,
    deadline,
  });
}

// No signRepayRequest — not needed anymore

async function signPermit(value, deadline) {
  const tokenName = await publicClient.readContract({ address: USDC_ADDRESS, abi: USDC_ABI_MIN, functionName: "name", args: [] });
  const usdcNonce = await publicClient.readContract({ address: USDC_ADDRESS, abi: USDC_ABI_MIN, functionName: "nonces", args: [borrower.address] });
  const domain = { name: tokenName, version: "1", chainId: CHAIN_ID, verifyingContract: USDC_ADDRESS };
  const signature = await signTyped(borrower, domain, TYPES, "Permit", {
    owner: borrower.address,
    spender: MICRO_ADDRESS,
    value,
    nonce: usdcNonce,
    deadline,
  });
  const r = "0x" + signature.slice(2, 66);
  const s = "0x" + signature.slice(66, 130);
  const v = parseInt(signature.slice(130, 132), 16);
  return { value, deadline, v, r, s };
}

async function main() {
  const amount = 1_000_000n; // 1 USDC in 6 decimals for quick flow
  const now = BigInt(Math.floor(Date.now() / 1000));
  const ttl = 3600n;

  // Pre-step: ensure lending pool has liquidity (borrower acts as lender)
  const depositAmount = 10_000_000n; // 10 USDC
  console.log("Funding pool: mint, approve, deposit...");
  await fundBorrowerEth();
  // Mint to borrower (open mint in MockUSDC)
  await wallet.writeContract({ address: USDC_ADDRESS, abi: USDC_ABI_MIN, functionName: "mint", args: [borrower.address, depositAmount + amount], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
  // Approve microcredit to spend depositAmount
  await wallet.writeContract({ address: USDC_ADDRESS, abi: USDC_ABI_MIN, functionName: "approve", args: [MICRO_ADDRESS, depositAmount], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
  // Deposit into pool
  await wallet.writeContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_WRITE, functionName: "depositFunds", args: [depositAmount], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
  const bal = await publicClient.readContract({ address: USDC_ADDRESS, abi: USDC_ABI_MIN, functionName: "balanceOf", args: [borrower.address] });
  console.log("Borrower USDC after deposit:", bal.toString());

  // Pre-step: add attestation from first unlocked account to give non-zero credit score
  try {
    const accounts = await (publicClient).request({ method: 'eth_accounts', params: [] });
    const attester = accounts && accounts.length ? accounts[0] : null;
    if (!attester) throw new Error('no unlocked account');
    const unlocked = createWalletClient({ account: attester, chain: { ...localhost, id: CHAIN_ID }, transport: http(RPC_URL) });
    const weight = 500_000n; // <= SCALE (1e6)
    await unlocked.writeContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_WRITE, functionName: 'recordAttestation', args: [borrower.address, weight], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
    console.log('Attestation recorded from', attester);
    // Disable whitelist or whitelist relayer (attester) to ensure API relays succeed
    try {
      await unlocked.writeContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_WRITE, functionName: 'setRelayerWhitelistEnabled', args: [false], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
      console.log('Relayer whitelist disabled');
    } catch {}
    try {
      await unlocked.writeContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_WRITE, functionName: 'setRelayerWhitelisted', args: [attester, true], maxFeePerGas: 0n, maxPriorityFeePerGas: 0n });
      console.log('Relayer whitelisted:', attester);
    } catch {}
  } catch (e) {
    console.warn('Could not record attestation (may already exist):', e?.message || String(e));
  }

  // Step 1: request loan (meta)
  const nonce1 = await publicClient.readContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_MIN, functionName: "nonces", args: [borrower.address] });
  const deadline1 = now + ttl;
  const sig1 = await signLoanRequest(amount, nonce1, deadline1);
  const req1Body = {
    chainId: CHAIN_ID,
    contractAddress: MICRO_ADDRESS,
    req: {
      borrower: borrower.address,
      amount: amount.toString(),
      nonce: nonce1.toString(),
      deadline: deadline1.toString(),
    },
    signature: sig1,
  };
  let resp = await fetch(`${API_BASE}/api/meta/request-loan`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(req1Body) });
  const res1 = await resp.json();
  if (!resp.ok) throw new Error(`request-loan failed: ${res1.error || JSON.stringify(res1)}`);
  const loanId = BigInt(res1.loanId || res1.result?.loanId || res1.data?.loanId || 0);
  if (loanId === 0n) throw new Error(`could not parse loanId from response: ${JSON.stringify(res1)}`);
  console.log("request-loan ok -> loanId", loanId.toString(), res1.txHash || res1.hash || "");

  // Step 2: disburse loan (meta)
  const nonce2 = await publicClient.readContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_MIN, functionName: "nonces", args: [borrower.address] });
  const deadline2 = now + ttl;
  const sig2 = await signDisburseRequest(loanId, borrower.address, nonce2, deadline2);
  const req2Body = {
    chainId: CHAIN_ID,
    contractAddress: MICRO_ADDRESS,
    req: {
      borrower: borrower.address,
      loanId: loanId.toString(),
      to: borrower.address,
      nonce: nonce2.toString(),
      deadline: deadline2.toString(),
    },
    signature: sig2,
  };
  resp = await fetch(`${API_BASE}/api/meta/disburse-loan`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(req2Body) });
  const res2 = await resp.json();
  if (!resp.ok) throw new Error(`disburse-loan failed: ${res2.error || JSON.stringify(res2)}`);
  console.log("disburse-loan ok ->", res2.txHash || res2.hash || "");

  // Step 3: repay loan (permit-only via /api/meta/repay-one)
  const deadline3 = now + ttl;
  const permit = await signPermit(amount, deadline3);
  const repayReq = {
    chainId: CHAIN_ID,
    contractAddress: MICRO_ADDRESS,
    borrower: borrower.address,
    loanId: loanId.toString(),
    amount: amount.toString(), // use "0" to repay-all up to permit value if desired
    permit: { value: permit.value.toString(), deadline: permit.deadline.toString(), v: permit.v, r: permit.r, s: permit.s },
  };
  resp = await fetch(`${API_BASE}/api/meta/repay-one`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(repayReq) });
  const res3 = await resp.json();
  if (!resp.ok) throw new Error(`repay-one failed: ${res3.error || JSON.stringify(res3)}`);
  console.log("repay-one ok ->", res3.txHash || res3.hash || "");

  // Verify on-chain state
  const loan = await publicClient.readContract({ address: MICRO_ADDRESS, abi: MICRO_ABI_MIN, functionName: "getLoan", args: [loanId] });
  const outstanding = loan[1];
  const isActive = loan[4];
  console.log("Post-repay -> outstanding:", outstanding.toString(), "isActive:", isActive);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
