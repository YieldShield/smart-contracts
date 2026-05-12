.PHONY: build deploy generate-abis get-address account chain compile flatten fork format lint test verify slither aderyn security coverage coverage-lcov

DEPLOY_SCRIPT ?= script/Deploy.s.sol
LOCALHOST_ANVIL_PRIVATE_KEY ?= 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6

# setup wallet for anvil
setup-anvil-wallet:
	rm -f ~/.foundry/keystores/scaffold-eth-default 2>/dev/null; rm -rf broadcast/Deploy.s.sol/31337
	cast wallet import --private-key $(LOCALHOST_ANVIL_PRIVATE_KEY) --unsafe-password 'localhost' scaffold-eth-default

# Start local chain
chain: setup-anvil-wallet
	anvil

# Start a fork
fork: setup-anvil-wallet
	anvil --fork-url ${FORK_URL} --chain-id 31337

# Deploy the contracts
deploy:
	@if [ ! -f "$(DEPLOY_SCRIPT)" ]; then 		echo "Error: Deploy script '$(DEPLOY_SCRIPT)' not found"; 		exit 1; 	fi
	@if [ -z "$(ETH_KEYSTORE_ACCOUNT)" ]; then 		echo "Error: ETH_KEYSTORE_ACCOUNT is required"; 		exit 1; 	fi
	@if [ "$(RPC_URL)" = "localhost" ]; then 		if [ "$(ETH_KEYSTORE_ACCOUNT)" = "scaffold-eth-default" ]; then 			forge script "$(DEPLOY_SCRIPT)" --rpc-url localhost --private-key $(LOCALHOST_ANVIL_PRIVATE_KEY) --broadcast --legacy; 		else 			forge script "$(DEPLOY_SCRIPT)" --rpc-url localhost --account "$(ETH_KEYSTORE_ACCOUNT)" --broadcast --legacy; 		fi 	else 		forge script "$(DEPLOY_SCRIPT)" --rpc-url "$(RPC_URL)" --account "$(ETH_KEYSTORE_ACCOUNT)" --broadcast --gas-estimate-multiplier 200; 	fi

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
	forge fmt && npx prettier --write "scripts-js/**/*.{js,cjs}"

# Lint code
lint:
	forge fmt --check && npx prettier --check "scripts-js/**/*.{js,cjs}"

# Run tests
test:
	forge test

# Verify contracts
verify:
	forge script script/VerifyAll.s.sol --ffi --rpc-url $(RPC_URL)

# Security analysis — Slither
slither:
	slither . --foundry-out-dir out --config-file slither.config.json --checklist > slither-report.md 2>&1 || true
	@echo "Report written to slither-report.md"

# Security analysis — Aderyn
aderyn:
	aderyn --output aderyn-report.md --no-snippets --skip-update-check
	@echo "Report written to aderyn-report.md"

# Run all security analysis
security: slither aderyn
	@echo "All security analysis complete"

# Coverage summary (text table to stdout)
coverage:
	forge coverage --ffi --report summary

# Coverage with lcov output (for local tooling)
coverage-lcov:
	forge coverage --ffi --report lcov
