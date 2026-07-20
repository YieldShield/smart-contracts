# YieldShield Smart Contracts

[![CI](https://github.com/YieldShield/smart-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/YieldShield/smart-contracts/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/YieldShield/smart-contracts)](LICENSE)

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

Deploy to Robinhood testnet from the monorepo root:

```sh
YS_PRODUCTION_MARKET_SESSION_GUARDIAN=<pause-only-guardian> ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT=test yarn deploy --network robinhoodTestnet
```

Robinhood testnet defaults to relaxed guardrails: if `YS_PRODUCTION_BOOTSTRAP_HOLDER`
is unset, the deployer receives the initial YS supply, production Safe ownership
pins are skipped, and the sequencer uptime feed is optional. Relaxed testnet
deployments require `YS_PRODUCTION_MARKET_SESSION_GUARDIAN`, but do not require
caller-supplied core runtime codehash pins. Manifest finalization observes every
core runtime through both the deployment RPC and an independent validation RPC;
the providers must agree, and the observed codehashes are persisted as testnet
evidence. These dual-RPC observations are not reviewed production pins and do not
satisfy strict guardrails. Set
`YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS=true` to rehearse the stricter
production checks on chain `46630`.

Strict testnet and production deployments must populate the reviewed runtime pins
listed in `.env.example` from a deterministic rehearsal. They cover the factory
proxy and implementation, pool implementation, YS token, timelock, governor,
composite and ERC-4626 oracles, and the selected Pyth or Chainlink path (including
the US market-session gate for Chainlink). Pin the exact deployed governor runtime:
its token and timelock immutable addresses make a generic
`type(YSGovernor).runtimeCode` hash unsuitable.

Strict Robinhood Chainlink deployments also include `RobinhoodStockOracleFeed` as
a reviewed core contract, even when demo seeding is disabled. Set
`YS_PRODUCTION_ROBINHOOD_STOCK_ORACLE_CODEHASH` to the exact rehearsed runtime;
the wrapper embeds the Chainlink feed and US market-session gate as immutables, so
its hash is deployment-specific. Deployment finalization and manifest promotion
verify those immutable addresses and the CompositeOracle's one-time wrapper pin.

Every Robinhood deployment also requires
`YS_PRODUCTION_MARKET_SESSION_GUARDIAN`. Use a nonzero operational signer or
multisig distinct from the governance timelock. The deployed gate records this
address in candidate metadata and grants it only the ability to close sessions;
reopening or changing the calendar remains timelock-controlled.

Before preflight, the deploy helper prints the selected guard, sequencer, demo,
and runner-size modes. Demo seeding is disabled by default in both relaxed and
strict testnet modes and is never inferred from the network.

Public manifest promotion requires `YS_DEPLOYMENT_VALIDATION_RPC_URL` plus the
non-secret `YS_DEPLOYMENT_RPC_OPERATOR` and
`YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR` slugs. The two URLs must use distinct
hosts, and the normalized operator slugs must identify different operating
organizations. Only the slugs—not RPC URLs or credentials—are persisted in
finality evidence. These identities are operator-attested rather than
cryptographically discovered; use an independently operated full node for one
side when possible. After a successful broadcast, manifest promotion waits up
to one hour for valid receipts to enter the agreed finalized state, polling
every 15 seconds. Override those defaults with
`YS_DEPLOYMENT_FINALITY_WAIT_TIMEOUT_MS` and
`YS_DEPLOYMENT_FINALITY_POLL_INTERVAL_MS` when a reviewed chain requires a
different window. Codehash, wiring, receipt, and RPC-disagreement failures still
fail immediately. Independent validation RPC requests are spaced 500ms apart by
default to remain compatible with common public endpoint limits; override this
with `YS_DEPLOYMENT_VALIDATION_RPC_MIN_INTERVAL_MS` when needed.

The production deploy CLI has finality policies for the checked-in `arbitrum`,
`arbitrumSepolia`, `robinhood`, and `robinhoodTestnet` aliases. A separate
checked-in deployment-target size policy runs before keystore selection,
environment validation, RPC construction, contract-size builds, Make, or Forge.
Only Robinhood aliases are currently broadcast-enabled. Other public aliases
fail closed; supporting another chain requires reviewed finality and target-size
policy entries.

Arbitrum One and Arbitrum Sepolia production broadcasts are intentionally
blocked because the current `SplitRiskPool` and `SplitRiskPoolFactory` runtimes
exceed EIP-170's 24,576-byte limit. The aliases remain available to oracle fork
tests and finality-policy validation. Re-enabling deployment requires splitting
both implementations below the standard limit and completing a full Arbitrum
fork deployment rehearsal. The Robinhood code-size override must not be used on
Arbitrum.

The Arbitrum Pyth policies also pin both sequencer adapters. Arbitrum One must
use Chainlink's documented `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
feed with the requirement enabled on both `PythOracle` and
`ERC4626OracleFeed`. Arbitrum Sepolia records an explicit zero-address,
requirement-disabled exception because no canonical Chainlink feed is
published there. Promotion reads both adapters at the agreed finalized block;
for a nonzero feed, both RPCs must also agree on its runtime code.
The production Solidity script always uses the checked-in Arbitrum One feed and
does not permit a broadcast-time override. If `YS_ARBITRUM_SEQUENCER_FEED` is
set for Arbitrum One, the CLI treats it only as an assertion and requires an
exact match before constructing either RPC provider. The variable must remain
unset for Arbitrum Sepolia's disabled-feed policy.

Arbitrum One production broadcasts also require
`YS_PRODUCTION_PYTH_UPDATER_CONFIRMED=true`. This is an explicit operator
acceptance that the configured Pyth updater is a trusted authority for accepted
price updates; missing, false, or malformed values fail before deployment.

Robinhood mainnet has no canonical sequencer uptime feed identified in the
current Chainlink registry. It therefore remains operationally blocked until an
operator supplies a documented `YS_ROBINHOOD_SEQUENCER_FEED`, its public
`YS_ROBINHOOD_SEQUENCER_FEED_SOURCE`, and a reviewed exact-runtime
`YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH`. The deploy script checks that runtime
before accepting the feed, and manifest promotion independently rechecks its
code and both oracle wiring paths at one finalized block through the two
operator-identified RPCs. This attests the operator-reviewed input; it does not
claim an undocumented address is canonical.

The Robinhood testnet path also passes `--disable-code-size-limit` to Foundry so
the current factory/pool monoliths do not make a successful testnet broadcast
exit nonzero after execution.

To explicitly create the mock demo assets, feeds, pools, and seed liquidity used
for product-loop testing, set:

```sh
YS_PRODUCTION_MARKET_SESSION_GUARDIAN=<pause-only-guardian> YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS=true ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT=test yarn deploy --network robinhoodTestnet
```

Or pass the keystore explicitly:

```sh
yarn deploy --network robinhoodTestnet --keystore test
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

CI blocks on Slither high-severity findings. Aderyn currently runs as a
report-only artifact for manual triage.

Security reports and follow-up notes are stored in the root audit files and
under `docs_ok/security/`.

## Contributing and Support

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull request
guidelines. Use [SUPPORT.md](SUPPORT.md) for support boundaries and
[SECURITY.md](SECURITY.md) for vulnerability reporting.

## Submodules

Foundry dependencies are tracked as submodules so this repository keeps a clean
history while still pinning exact dependency revisions:

- `lib/forge-std`
- `lib/openzeppelin-contracts`
- `lib/openzeppelin-contracts-upgradeable`
- `lib/solidity-bytes-utils`

Pyth Solidity interfaces are consumed from the maintained
`@pythnetwork/pyth-sdk-solidity` npm package instead of the archived
`pyth-network/pyth-sdk-solidity` repository.

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

## License

Unless otherwise noted by an SPDX identifier in a source file, project-authored
files are licensed under the MIT License. See [LICENSE](LICENSE).

The Uniswap V3 TWAP oracle path includes code derived from Uniswap v3-core and
is licensed under GPL-2.0-or-later. See [NOTICE](NOTICE) for details.
