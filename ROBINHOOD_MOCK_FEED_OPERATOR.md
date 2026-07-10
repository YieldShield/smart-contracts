# Robinhood synthetic mock-feed operator

This tool monitors and refreshes only the promoted ten-feed synthetic fixture on
Robinhood testnet (chain 46630). It does not fetch live market data, change adapter
maximum ages, update bounds, or operate on Robinhood mainnet.

## Required manifest metadata

The deployment manifest must contain this exact object at
`fixtureMetadata.robinhoodStandardMockFeeds`:

```json
{
  "schemaVersion": 1,
  "fixtureId": "robinhood-standard-mock-feeds-v1",
  "chainId": 46630,
  "synthetic": true,
  "maxPriceAgeSeconds": 86400,
  "nearExpirySeconds": 3600,
  "expiresAt": 1780000000,
  "expectedRuntimeCodehash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "expectedOwner": "0x0000000000000000000000000000000000000000",
  "feeds": {
    "USDG": {
      "address": "0x...",
      "deploymentName": "RobinhoodUSDGMockChainlinkFeed",
      "description": "USDG / USD",
      "decimals": 8
    },
    "WETH": {
      "address": "0x...",
      "deploymentName": "RobinhoodWETHMockChainlinkFeed",
      "description": "WETH / USD",
      "decimals": 8
    },
    "SGOV": {
      "address": "0x...",
      "deploymentName": "RobinhoodSGOVMockChainlinkFeed",
      "description": "SGOV / USD",
      "decimals": 8
    },
    "SPY": {
      "address": "0x...",
      "deploymentName": "RobinhoodSPYMockChainlinkFeed",
      "description": "SPY / USD",
      "decimals": 8
    },
    "QQQ": {
      "address": "0x...",
      "deploymentName": "RobinhoodQQQMockChainlinkFeed",
      "description": "QQQ / USD",
      "decimals": 8
    },
    "TSLA": {
      "address": "0x...",
      "deploymentName": "RobinhoodTSLAMockChainlinkFeed",
      "description": "TSLA / USD",
      "decimals": 8
    },
    "AMZN": {
      "address": "0x...",
      "deploymentName": "RobinhoodAMZNMockChainlinkFeed",
      "description": "AMZN / USD",
      "decimals": 8
    },
    "PLTR": {
      "address": "0x...",
      "deploymentName": "RobinhoodPLTRMockChainlinkFeed",
      "description": "PLTR / USD",
      "decimals": 8
    },
    "NFLX": {
      "address": "0x...",
      "deploymentName": "RobinhoodNFLXMockChainlinkFeed",
      "description": "NFLX / USD",
      "decimals": 8
    },
    "AMD": {
      "address": "0x...",
      "deploymentName": "RobinhoodAMDMockChainlinkFeed",
      "description": "AMD / USD",
      "decimals": 8
    }
  }
}
```

The feed inventory is exact: missing, extra, duplicate, renamed, or incorrectly
described feeds are rejected. `expiresAt` is the earliest live feed expiration
(`updatedAt + maxPriceAgeSeconds`) and is rewritten after a successful refresh.

## Health check

```sh
npm run robinhood:mock-feeds -- health --manifest deployments/46630.json
```

The command uses `ROBINHOOD_TESTNET_RPC_URL`, unless `--rpc-url` is supplied. It exits
nonzero if the chain is not 46630, manifest inventory is incomplete, runtime codehash
or owner differs, a feed is stale/near expiry, round data is invalid, or manifest
`expiresAt` differs from the earliest live expiration.

## Refresh

Refresh requires the exact fixture identifier as an explicit acknowledgement and a
Foundry keystore whose address equals both the manifest owner and every live feed owner:

```sh
npm run robinhood:mock-feeds -- refresh \
  --manifest deployments/46630.json \
  --keystore test \
  --confirm-synthetic-fixture robinhood-standard-mock-feeds-v1
```

By default each feed's current synthetic answer is preserved; `setAnswer` is called
only to advance its round timestamps. Explicit synthetic answer changes use raw
8-decimal positive integers and may be repeated:

```sh
npm run robinhood:mock-feeds -- refresh \
  --manifest deployments/46630.json \
  --keystore test \
  --confirm-synthetic-fixture robinhood-standard-mock-feeds-v1 \
  --answer TSLA=33200000000 \
  --answer AMD=17500000000
```

The ten refreshes are separate transactions. If a network failure interrupts the
sequence, rerun health and then repeat the same confirmed refresh; preserving current
answers makes retries idempotent for feeds without explicit updates.
