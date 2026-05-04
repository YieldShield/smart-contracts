# YieldShield Smart Contracts

Standalone Foundry workspace for the YieldShield protocol smart contracts.

This repository was initialized from the latest `packages/foundry` snapshot in
[`YieldShield/yieldshield`](https://github.com/YieldShield/yieldshield), without
carrying over the source repository's commit history.

Source snapshot:
`4105f3a91856b4d49aed20e4a8cbf91a53825c26`

## Overview

YieldShield contains Solidity contracts, tests, deployment scripts, oracle
integrations, and security reports for the protocol.

Core contracts live in `contracts/`:

- `SplitRiskPool.sol` - main split-risk pool implementation
- `SplitRiskPoolFactory.sol` - pool creation and configuration
- `ShieldReceiptNFT.sol` and `ProtectorReceiptNFT.sol` - receipt NFTs for pool positions
- `YSToken.sol` and `YSGovernor.sol` - governance token and governor contracts
- `oracles/` - composite, Chainlink, Pyth, ERC4626, and Uniswap V3 TWAP oracle feeds
- `libraries/` - validation, accounting, whitelist, constants, errors, and events helpers

## Repository Layout

```text
contracts/      Solidity contracts, interfaces, mocks, oracles, and libraries
test/           Foundry test suite
script/         Foundry deployment and verification scripts
scripts-js/     Node.js helper scripts for deployments, accounts, and ABIs
deployments/    Checked-in deployment metadata
broadcast/      Checked-in Foundry broadcast records
docs_ok/        Design notes, audit notes, and security follow-up documents
lib/            Foundry dependencies tracked as Git submodules
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18 or newer
- npm or yarn

## Setup

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/YieldShield/smart-contracts.git
cd smart-contracts
```

If you already cloned the repository:

```sh
git submodule update --init --recursive
```

Install Node.js helper dependencies:

```sh
npm install
```

Create a local environment file:

```sh
cp .env.example .env
```

Fill in `ALCHEMY_API_KEY` and `ETHERSCAN_API_KEY` in `.env` when deploying,
forking, or verifying against live networks.

## Common Commands

Build the contracts:

```sh
forge build
```

Run tests:

```sh
forge test
```

Run tests without network access:

```sh
forge test --offline
```

Format and lint:

```sh
make format
make lint
```

Check contract sizes:

```sh
npm run size-check
```

Generate TypeScript ABIs:

```sh
make generate-abis
```

## Local Development

Start a local Anvil chain:

```sh
make chain
```

Deploy to the local chain:

```sh
make deploy RPC_URL=localhost
```

Deploy a specific script:

```sh
make deploy DEPLOY_SCRIPT=script/DeployYieldShield.s.sol RPC_URL=localhost
```

Start a fork:

```sh
make fork FORK_URL=mainnet
```

## Security Tooling

Run Slither:

```sh
make slither
```

Run Aderyn:

```sh
make aderyn
```

Run both:

```sh
make security
```

Security reports and follow-up notes are stored in the root audit files and
under `docs_ok/security/`.

## Submodules

Foundry dependencies are tracked as submodules so this repository keeps a clean
history while still pinning exact dependency revisions:

- `lib/forge-std`
- `lib/openzeppelin-contracts`
- `lib/openzeppelin-contracts-upgradeable`
- `lib/pyth-sdk-solidity`
- `lib/solidity-bytes-utils`

After pulling changes, run:

```sh
git submodule update --init --recursive
```

## Verification

The initial import was checked with:

```sh
forge build --offline
```

The build completed successfully with existing compiler lint warnings and notes.
