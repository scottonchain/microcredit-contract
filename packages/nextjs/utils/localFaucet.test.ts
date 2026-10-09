import {
  LOCAL_ETH_AMOUNT,
  LOCAL_USDC_AMOUNT,
  createLocalFaucetClient,
  fundLocalEth,
  mintLocalUsdc,
} from "./localFaucet.ts";
import assert from "node:assert/strict";
import test from "node:test";
import { type Address, type Hash } from "viem";

const recipient: Address = "0x1111111111111111111111111111111111111111";
const token: Address = "0x2222222222222222222222222222222222222222";
const unlocked: Address = "0x3333333333333333333333333333333333333333";
const hash: Hash = `0x${"ab".repeat(32)}`;
type Client = ReturnType<typeof createLocalFaucetClient>;
const client = (methods: Partial<Client>) => methods as Client;

test("public app targets reject funding before making any RPC call", async () => {
  await assert.rejects(fundLocalEth(client({}), 84532, recipient), /local Anvil/);
  await assert.rejects(mintLocalUsdc(client({}), 84532, recipient, token), /local Anvil/);
});

test("an unexpected RPC chain rejects both faucet writes", async () => {
  const rpc = client({ getChainId: async () => 84532 });
  await assert.rejects(fundLocalEth(rpc, 31337, recipient), /local Anvil/);
  await assert.rejects(mintLocalUsdc(rpc, 31337, recipient, token), /local Anvil/);
});

test("ETH funding adds exactly one ETH and preserves an existing large balance", async () => {
  const balance = 10n ** 25n + 123n;
  let funded = false;
  await fundLocalEth(
    client({
      getChainId: async () => 31337,
      getBalance: async args => {
        assert.equal(args.address, recipient);
        return balance;
      },
      setBalance: async args => {
        assert.deepEqual(args, { address: recipient, value: balance + LOCAL_ETH_AMOUNT });
        funded = true;
      },
    }),
    31337,
    recipient,
  );
  assert.ok(funded);
});

test("minting uses an unlocked local account and requires a successful receipt", async () => {
  let status = "reverted";
  let observedReceipt = false;
  const rpc = client({
    getChainId: async () => 31337,
    getAddresses: async () => [unlocked],
    writeContract: async args => {
      assert.equal(args.account, unlocked);
      assert.equal(args.address, token);
      assert.equal(args.functionName, "mint");
      assert.deepEqual(args.args, [recipient, LOCAL_USDC_AMOUNT]);
      return hash;
    },
    waitForTransactionReceipt: (async args => {
      assert.equal(args.hash, hash);
      observedReceipt = true;
      return { status };
    }) as Client["waitForTransactionReceipt"],
  });
  await assert.rejects(mintLocalUsdc(rpc, 31337, recipient, token), /reverted/);
  status = "success";
  observedReceipt = false;
  await mintLocalUsdc(rpc, 31337, recipient, token);
  assert.ok(observedReceipt);
});

test("minting fails when no local account is unlocked", async () => {
  await assert.rejects(
    mintLocalUsdc(
      client({
        getChainId: async () => 31337,
        getAddresses: async () => [],
      }),
      31337,
      recipient,
      token,
    ),
    /no unlocked account/,
  );
});
