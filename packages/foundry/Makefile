SHELL := /bin/bash
.SHELLFLAGS := -ec

.PHONY: deploy deposit-funds seeddemo

# ──────────────────────────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────────────────────────

RPC_URL      := http://localhost:8545
GAS_LIMIT    := 100000000
# Default mnemonic for local Anvil/Hardhat nodes
export MNEMONIC     := test test test test test test test test test test test junk

# Derive private keys from the mnemonic using `cast`. This is more robust.
# The deployer is account 9 from the mnemonic.
DEPLOYER_INDEX := 9
DEPLOYER_PK    := $(shell cast wallet private-key --mnemonic "$(MNEMONIC)" --mnemonic-index $(DEPLOYER_INDEX))

# After `deploy`, deployment.json looks like:
#   { "MICRO_ADDRESS":"0x...", "USDC_ADDRESS":"0x..." }
# Extract via sed so we don't need jq:
MICRO_ADDR := $(shell sed -n 's/.*"MICRO_ADDRESS":"\([^"]*\)".*/\1/p' deployment.json)
USDC_ADDR  := $(shell sed -n 's/.*"USDC_ADDRESS":"\([^"]*\)".*/\1/p' deployment.json)

# Amounts in USDC's 6-decimal units
LENDER_DEPOSIT := 3000000000   # 3,000 USDC
LOAN_AMOUNT    := 50000000     #    50 USDC

# setup wallet for anvil
setup-anvil-wallet:
	rm -f ~/.foundry/keystores/scaffold-eth-default 2>/dev/null; rm -rf broadcast/Deploy.s.sol/31337
	cast wallet import --private-key 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 --unsafe-password 'localhost' scaffold-eth-default



# ──────────────────────────────────────────────────────────────────────────────
# 2) Deposit USDC into pool for each of the 10 lenders
# ──────────────────────────────────────────────────────────────────────────────

deposit-funds:
	@echo "💰 Depositing USDC for 10 lenders…"
	@for idx in $$(seq 0 9); do \
		LENDER_PK=$$(cast wallet private-key --mnemonic "$(MNEMONIC)" --mnemonic-index $$idx); \
		echo " • lender $$idx"; \
		env MICRO_ADDRESS=$(MICRO_ADDR) USDC_ADDRESS=$(USDC_ADDR) DEPOSIT_AMOUNT=$(LENDER_DEPOSIT) \
		forge script script/DepositFunds.s.sol:DepositFunds --rpc-url $(RPC_URL) --private-key $${LENDER_PK} --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
	done

# ──────────────────────────────────────────────────────────────────────────────
# 3) Full SeedDemo pipeline: borrowers, attestations, loan-requests
# ──────────────────────────────────────────────────────────────────────────────

seeddemo: deploy deposit-funds
	@echo "🚀 Seeding 300 borrowers…"
	@for i in $$(seq 0 299); do \
		echo " • borrower $$i"; \
		env MICRO_ADDRESS=$(MICRO_ADDR) BORROWER_INDEX=$$i \
		forge script script/SeedDemo.s.sol:SeedBorrower --rpc-url $(RPC_URL) --private-key $(DEPLOYER_PK) --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
	done

	@echo "🚀 Seeding 3,000 attestations…"
	@for i in $$(seq 0 299); do \
		for j in $$(seq 0 9); do \
			LENDER_PK=$$(cast wallet private-key --mnemonic "$(MNEMONIC)" --mnemonic-index $$j); \
			echo " • attest borrower $$i by lender $$j"; \
			env MICRO_ADDRESS=$(MICRO_ADDR) BORROWER_INDEX=$$i LENDER_INDEX=$$j \
			forge script script/SeedDemo.s.sol:SeedAttestation --rpc-url $(RPC_URL) --private-key $${LENDER_PK} --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
		done; \
	done

	@echo "🚀 Seeding 300 loan requests…"
	@for i in $$(seq 0 299); do \
		echo " • loan request for borrower $$i"; \
		env MICRO_ADDRESS=$(MICRO_ADDR) USDC_ADDRESS=$(USDC_ADDR) BORROWER_INDEX=$$i LOAN_AMOUNT=$(LOAN_AMOUNT) \
		forge script script/SeedDemo.s.sol:SeedLoanRequest --rpc-url $(RPC_URL) --private-key $(DEPLOYER_PK) --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
	done


	# Start local chain
chain: setup-anvil-wallet
	anvil


# Start a fork
fork: setup-anvil-wallet
	anvil --fork-url ${FORK_URL} --chain-id 31337

# Deploy the contracts
deploy:
	@if [ ! -f "$(DEPLOY_SCRIPT)" ]; then \
		echo "Error: Deploy script '$(DEPLOY_SCRIPT)' not found"; \
		exit 1; \
	fi
	@if [ "$(RPC_URL)" = "localhost" ]; then \
		if [ "$(ETH_KEYSTORE_ACCOUNT)" = "scaffold-eth-default" ]; then \
			forge script $(DEPLOY_SCRIPT):DeployScript --rpc-url localhost --password localhost --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
		else \
			forge script $(DEPLOY_SCRIPT):DeployScript --rpc-url localhost --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
		fi \
	else \
		forge script $(DEPLOY_SCRIPT):DeployScript --rpc-url $(RPC_URL) --broadcast --legacy --ffi --gas-limit $(GAS_LIMIT); \
	fi

# Deploy and generate ABIs
deploy-and-generate-abis: deploy generate-abis 

# Generate TypeScript ABIs
generate-abis:
	node scripts-js/generateTsAbis.js

# List account
account:
	@node scripts-js/checkAccountBalance.js

# Get address of a keystore
get-address:
	@cast wallet address --account $(ACCOUNT_NAME)

# Compile contracts
compile:
	forge compile

# Flatten contracts
flatten:
	forge flatten

# Format code
format:
	forge fmt && prettier --write ./scripts-js/**/*.js

# Lint code
lint:
	forge fmt --check && prettier --check ./scripts-js/**/*.js

# Run tests
test:
	forge test

# Verify contracts
verify:
	forge script script/VerifyAll.s.sol --ffi --rpc-url $(RPC_URL)