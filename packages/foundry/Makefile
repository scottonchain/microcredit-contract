.PHONY: generate-abis get-address account compile flatten fork format lint test verify

# The local chain is started from the repo root with `yarn chain` (scripts/start-anvil.sh).

# Start a fork
fork:
	anvil --fork-url ${FORK_URL} --chain-id 31337

# Generate TypeScript ABIs from the latest broadcasts (yarn deploy runs this automatically)
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
