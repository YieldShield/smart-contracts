# YieldShield Smart-Contract Multi-Agent Security Review — July 13, 2026

## Executive summary

This fresh review of `main` at
`b317aa71f5933a11d409aabc76e170de77bb404b` found **no confirmed Critical or
High-severity vulnerability**. The core accounting, oracle fail-closed paths,
upgrade freeze, governance role topology, and invariant suite remain strong after the
July 10 remediation wave.

The review confirmed **three Medium**, **seven Low**, and **four Informational**
weaknesses or inconsistencies. The most important are operational rather than an
immediate permissionless fund-drain:

1. Robinhood's 24/5 feeds can exceed the protocol's hard 24-hour freshness ceiling
   during ordinary closed sessions, but ordinary shield withdrawals must price fees.
   This predictably freezes even same-asset exits until publishing resumes.
2. A production manifest can be promoted after successful receipt lookup but before
   Robinhood Chain's documented L1-posting or Ethereum-finality stages.
3. The reviewed-codehash attestation covers subordinate components but not the
   `YSToken` and `YSGovernor` contracts that define voting power and control the
   timelock.

Additional research also **refuted two material assumptions in the July 11 report**.
Robinhood and Chainlink now explicitly document the `oraclePaused()` workflow, and
Chainlink states that the token feed already includes `uiMultiplier()`. Live calls at
Robinhood mainnet block `8,452,869` confirmed that all 25 currently documented stock
and ETF token contracts expose `oraclePaused()`; they also shared one runtime code
hash. The current wrapper is therefore aligned with the documented interface, and it
is correct not to multiply the Chainlink answer again.

| Severity      | Count | Character                                                      |
| ------------- | ----: | -------------------------------------------------------------- |
| Critical      |     0 | None confirmed                                                 |
| High          |     0 | None confirmed                                                 |
| Medium        |     3 | Exit liveness and deployment integrity                         |
| Low           |     7 | Governance/configuration foot-guns and assurance gaps          |
| Informational |     4 | Monitoring, recovery metadata, and test-policy inconsistencies |

## Scope and method

- Baseline: `b317aa71f5933a11d409aabc76e170de77bb404b`, synchronized with
  `origin/main` before review.
- Scope: `contracts/`, production and recovery deployment scripts, manifest
  finalization, governance, oracle integration, Foundry tests/invariants, JavaScript
  operator tooling, and GitHub Actions.
- Review team: one primary Codex reviewer plus three independent agents covering
  core accounting, deployment/oracle operations, and test/CI assurance.
- Deduplication: the July 10 remediation and July 11 review were re-read first. Items
  below are net-new, newly reproduced, or materially reclassified by current primary
  sources.
- Research: official Robinhood Chain, Chainlink, Pyth, ERC/EIP, and ethers
  documentation plus read-only calls to Robinhood mainnet and testnet.
- Limitation: this is a defensive repository review, not a substitute for an
  independent professional audit and deployment rehearsal before material value is
  placed at risk.

## Medium findings

### M-01 — Closed-session staleness predictably blocks ordinary shield withdrawals

**Affected:** `contracts/oracles/ChainlinkOracleFeed.sol:142-146,435-453`,
`contracts/SplitRiskPool.sol:609-630,1274-1292,2039-2094,2189-2210,2352-2366`,
`script/DeployYieldShieldProduction.s.sol:122,599-603`

Chainlink documents Robinhood tokenized-equity feeds as 24/5 and says they have no
heartbeat during off-hours. The production adapter defaults to a maximum age of
86,400 seconds and also hard-caps all global and per-token ages at 86,400 seconds.
An ordinary weekend is longer than that bound.

The market-session gate correctly blocks new risk openings, but it does not solve
exit liveness. `shieldedWithdraw`, `partialWithdrawShielded`, and `claimRewards` all
call `_calculateAndAccumulateFees`; while transfer integrity is healthy, that function
requires a live shielded-token price and reverts `ShieldedFeePriceUnavailable` when
the Chainlink answer ages out. Even a same-asset principal exit therefore becomes
unavailable during the latter part of a weekend or extended holiday. The separate
transfer-integrity emergency branch bypasses fee pricing, but it is not a normal
closed-market liveness mechanism.

A one-off regression probe reproduced the issue: after opening a shield position,
clearing the market session, and advancing `1 days + 1`, a same-asset
`shieldedWithdraw` reverted with `ShieldedFeePriceUnavailable`. The probe was removed
after reproduction so this review remains document-only.

**Impact:** predictable temporary withdrawal and reward-claim denial during normal
market closures, with longer outages during holidays or feed incidents. This does not
misprice or lose funds, but it violates the expectation that closing new risk does not
disable same-asset exits.

**Recommendation:** separate freshness policy by operation. Keep strict live pricing
for openings and cross-asset collateral decisions, but define a market-closed path for
same-asset principal exit and fee settlement, such as a last-trusted-close checkpoint,
deferred fee settlement, or a conservative fee reserve. Add weekend, holiday, and
corporate-pause boundary tests.

Primary source: [Chainlink Robinhood tokenized-equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood).

### M-02 — The active deployment manifest can be promoted before chain finality

**Affected:** `Makefile:29-36`,
`scripts-js/finalizeDeploymentManifest.js:677-777,1088-1125`

`deploy-and-generate-abis` invokes the finalizer immediately after the broadcast
command returns. The finalizer verifies that every transaction has a currently
successful receipt, then installs the active manifest and generates downstream ABIs.
It does not wait for a confirmation count, verify a `safe` or `finalized` block, record
the receipt block hash as a validation checkpoint, or cross-check a second RPC.

Robinhood Chain documents soft confirmation, posting to Ethereum, and Ethereum
finality as distinct stages. It specifically recommends waiting for posting or full
Ethereum finality before treating high-value or irreversible actions as settled.

**Impact:** a pre-posting reorganization or faulty/compromised single RPC can cause a
noncanonical deployment generation to be written as active and propagated through
generated addresses/ABIs.

**Recommendation:** add an explicit per-chain promotion policy. For Robinhood
production, wait until each critical transaction is posted to L1 or reaches the chosen
finality stage, then re-read receipt block hashes, deployed code, codehashes, and live
wiring. Record the validation block/hash and use an independent RPC for critical
cross-checks.

Primary sources: [Robinhood transaction finality](https://docs.robinhood.com/chain/transaction-finality/),
[ethers provider receipt and confirmation APIs](https://docs.ethers.org/v6/single-page/).

### M-03 — Governance-root contracts are outside the independent codehash pins

**Affected:** `scripts-js/parseArgs.js:27-40`,
`script/DeployYieldShieldProduction.s.sol:464-470,1208-1235,1512-1522`,
`scripts-js/finalizeDeploymentManifest.js:370-483,970-995`

Strict production preflight requires reviewed runtime hashes for the factory
implementation, pool implementation, and selected Pyth/Chainlink oracle. Solidity
finalization checks several other components against runtime compiled in the current
build, but its governance validation only requires that `YSGovernor` has code, checks
its `timelock()`, and validates timelock roles. The JavaScript finalizer additionally
checks the governor's `token()` and `timelock()` topology, but its reviewed-pin list
again contains only the factory, pool, and selected oracle and silently skips any
missing expected value. Neither `YSToken` nor `YSGovernor` is independently
runtime-attested.

**Precondition:** unintended or compromised source/artifacts on the deployment host,
or direct finalizer use outside the guarded helper.

**Impact:** a modified token/governor pair can retain the expected getters and role
wiring, become the timelock's sole proposer/executor/canceller, and still satisfy the
existing reviewed pins. This weakens the supply-chain defense precisely at the
governance root.

**Recommendation:** require independently reviewed commitments for every core
component in strict mode, especially `YSToken` and `YSGovernor`. For constructor
immutables, pin the rehearsed deployed runtime or reconstruct immutable-patched
runtime. Persist all commitments in candidate metadata and make absence a promotion
failure.

## Low findings

### L-01 — The checked-in Robinhood testnet manifest represents pre-hardening bytecode

**Affected:** `deployments/46630.json`, `ROBINHOOD_MOCK_FEED_OPERATOR.md:7-10,92-101`,
`scripts-js/robinhood-mock-feed-operator.cjs:18,95-109,494`,
`scripts-js/generateTsAbis.js:577-585,645-657`

The active-looking `deployments/46630.json` file is a legacy one-line address map. It
has no schema, generation ID, status, codehash/address evidence, fixture metadata, or
`USMarketSessionGate`. At testnet block `89,805,871`, its listed
`RobinhoodStockOracleFeed` answered `innerFeed()` but reverted with empty data for
`marketSessionGate()`, `supportsProtectionOpeningEligibility(address)`, and
`isProtectionOpeningAllowed(address)`. Its Chainlink feed reported a zero sequencer
feed and `sequencerUptimeFeedRequired == false`.

The documented command

```text
npm run robinhood:mock-feeds -- health --manifest deployments/46630.json --rpc-url https://rpc.testnet.chain.robinhood.com
```

exits with `Manifest is missing fixtureMetadata.robinhoodStandardMockFeeds`.

**Impact:** testnet stock pools do not rehearse the current market-session control,
the documented feed-health workflow is unusable, and ABI/address generation can bind
new interfaces to old bytecode.

**Recommendation:** redeploy current `main` as a new chain-46630 generation, promote a
schema-v2 manifest, explicitly archive/mark the legacy generation inactive, regenerate
downstream ABIs, and reject public manifests that lack current schema/inventory and
selector/codehash smoke checks.

### L-02 — Backing recapitalization depends on an unused shielded-token price

**Affected:** `contracts/SplitRiskPool.sol:636-637,879-881,924-947,1867-1883`

`depositBackingAsset` rejects a shielded-token challenge and `_validateDeposit`
always computes total pool USD value. `_getTotalPoolValueUsd` calls
`_getShieldedValue(poolState.shieldedTokenBalance)`, and `_getShieldedValue(0)` still
evaluates `_getShieldedPrice()` before multiplying by zero.

**Impact:** protectors cannot seed an otherwise empty pool or add safety-improving
backing while an unused shielded feed is stale, challenged, or unavailable.

**Recommendation:** skip shielded challenge/price reads when there are no shielded
balances or liabilities. Preserve conservative dual-leg checks whenever any shielded
liability exists.

### L-03 — Governance can erase an active protector's accrued commission

**Affected:** `contracts/SplitRiskPool.sol:1619-1659,1694-1715,2976-3015`

The NFT owner may voluntarily forfeit an unpayable commission, and governance may
forfeit it to unblock retirement. The governance branch, however, is not restricted to
an expired epoch, paused/inactive pool, denied recipient, or retirement state.
`_forfeitCommission` removes the amount from reserved commission accounting without
paying the protector; it becomes unaccounted surplus that can later be swept to the
protocol recipient once all liabilities are gone.

**Impact:** timelocked governance has an undocumented confiscation power over earned
active-position compensation.

**Recommendation:** preserve voluntary owner forfeiture, but restrict governance
forfeiture to a verifiable unpayable/retirement condition or force-settle the value to
the current beneficiary.

### L-04 — A transfer-blocked creator cannot recover the pool-creation bond

**Affected:** `contracts/SplitRiskPoolFactory.sol:1134-1141,1192-1209,1541-1566`

Creator closure pays the bond only to the immutable creator. If an issuer-blacklistable
bond token rejects that recipient, the atomic close reverts and the active slot remains
occupied. Governance can free the slot only through `deactivatePool`, which forfeits
the bond to the protocol recipient.

**Impact:** a creator can be forced to choose between an indefinitely active empty
pool and confiscation of the creation bond.

**Recommendation:** separate deactivation from payout by recording a later claim, or
let the authenticated creator rotate the bond recipient before closure.

### L-05 — Chainlink recovery can promote an unsupported chain

**Affected:** `script/DeployYieldShieldProduction.s.sol:322-367,597`,
`scripts-js/finalizeDeploymentManifest.js:912-920`

The normal Chainlink-native deploy path accepts only Robinhood chain IDs 4663/46630.
The public Chainlink recovery finalizer has no matching chain check, and JavaScript
promotion rejects only relaxed/demo deployments outside 46630. A strict Chainlink
inventory can therefore be labelled active on an otherwise unsupported chain.

**Recommendation:** enforce `4663 || 46630` in both recovery and promotion unless
Chainlink-native support is deliberately generalized and tested per chain.

### L-06 — The fork-test job can be green without running and never forks Robinhood

**Affected:** `.github/workflows/ci.yml:86-131`, `test/OracleFork.t.sol:16-48,198-215`,
`test/SplitRiskPoolFork.t.sol:7-15`

The job runs only on pushes, requires both Ethereum mainnet and Sepolia secrets, and
skips every fork test successfully if either secret is absent. Existing fork fixtures
cover only those two networks. No fork validates Robinhood token selectors, price-feed
addresses, corporate pauses, sequencer behavior, or current deployment selectors.
The Sepolia Pyth case also catches every error as likely staleness, making address or
migration failures indistinguishable from the expected stale condition.

**Recommendation:** split network availability, require the production-chain suite as
a release gate, add Robinhood mainnet/testnet selector and feed smoke tests, and allow
only exact expected Pyth stale errors.

### L-07 — The coverage job is unscoped and non-enforcing

**Affected:** `.github/workflows/ci.yml:163-191`,
`scripts-js/__tests__/coverage-policy.test.cjs:11-27`

CI produces a coverage summary with no threshold or baseline. Its aggregate mixes
production contracts, mocks, deployment scripts, and test helpers; the policy test
only protects the gas-benchmark exclusion. A targeted reproduction reported 4.52%
aggregate coverage and still exited successfully.

**Recommendation:** emit LCOV, filter to production `contracts/` while excluding
mocks/examples, and enforce aggregate plus per-critical-contract line/branch floors.

## Informational inconsistencies

### I-01 — `isPriceStale` can report fresh when normalization always reverts

`ChainlinkOracleFeed` registration validates a positive round, while `getPrice`
additionally rejects unsupported decimals and prices that normalize to zero.
`isPriceStale` does not mirror those checks. A malformed or behavior-changing feed can
therefore look fresh to monitoring while every real price read fails closed.

**Affected:** `contracts/oracles/ChainlinkOracleFeed.sol:175-202,468-473,528-546`

### I-02 — Invariant path floors are satisfied by deterministic seeding

`_seedReachableHandlerPaths` increments success metrics before random dispatch, while
`afterInvariant` requires only one success. The strict suite is healthy today, but the
floor cannot detect a future regression where randomized interleavings never reach a
core path.

**Affected:** `test/SplitRiskPoolInvariant.t.sol:741-763,1089-1112`

### I-03 — The exact Robinhood deployment-size inventory is not a CI gate

`size-check:robinhood-deployment` is enforced by deployment preflight, but CI runs only
the generic report-only size job. This remains fail-safe at deployment; adding the
exact 96 KiB/192 KiB target inventory to CI would move discovery earlier.

**Affected:** `package.json:37`, `scripts-js/parseArgs.js:615-622`,
`.github/workflows/ci.yml:133-161`

### I-04 — Same-generation recovery can restore stale fixture-health metadata

`sameGeneration` compares only deployment ID, configuration digest, chain ID, and
address entries. When a matching history file exists, the finalizer substitutes the
old history object after completing fresh live validation. The demonstrated mutable
field is the mock-feed fixture expiry, which the operator updates only in the active
manifest; recovery can therefore reactivate an obsolete `expiresAt` value. Live
wiring and codehashes are still revalidated before substitution, so this review did
not establish stale live-code promotion.

**Affected:** `scripts-js/finalizeDeploymentManifest.js:1036-1047,1103-1110`,
`scripts-js/robinhood-mock-feed-operator.cjs:383-392,530`

**Recommendation:** store mutable fixture-health state separately from immutable
deployment history, or merge freshly validated mutable state instead of replacing the
new manifest wholesale.

## External deployment blocker — Robinhood sequencer uptime feed

The code now handles the earlier risk safely: Robinhood mainnet deployment fails
closed unless a code-bearing sequencer feed and public provenance are supplied, and
the missing-feed exception is restricted to testnet. However, the official Chainlink
sequencer registry still does not list Robinhood, while Robinhood's oracle guide says
that Chainlink provides an uptime feed without publishing a canonical proxy address.

This is not counted as a contract vulnerability because current mainnet deployment is
blocked rather than silently unprotected. It remains a **release blocker**: do not
invent or reuse another Arbitrum chain's feed. Obtain and independently verify a
canonical 4663 address, or make a documented risk decision with a different on-chain
availability design.

Primary sources: [Chainlink supported sequencer feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds),
[Robinhood oracle integration guide](https://docs.robinhood.com/chain/oracles-and-price-feeds/).

## Corrections and reclassification of July 11 findings

### Refuted — `oraclePaused()` is not merely a mock-only assumption

Robinhood and Chainlink now explicitly document the token's dedicated
`oraclePaused()` flag and the pause/update/unpause corporate-action sequence. At
Robinhood mainnet block `8,452,869`, all 25 token/ETF addresses on Robinhood's current
canonical list successfully returned `false` from `oraclePaused()` and shared runtime
codehash `0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630`.

The wrapper should still fail closed for a future token that omits the selector, but
July 11 NN-2 is not a currently confirmed deployment brick.

### Refuted — the protocol should not apply `uiMultiplier()` again

Robinhood and Chainlink state that `latestRoundData()` returns per-token Total Return
Value: underlying share price multiplied by `uiMultiplier()`. Applying the multiplier
again would double count it. The current wrapper's decision to consume the feed answer
directly is correct. Pending multiplier fields remain useful for monitoring, but their
absence from arithmetic is not a pricing defect.

Primary sources: [Robinhood building with stock tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/),
[Chainlink Robinhood feed model](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood),
[ERC-8056](https://eips.ethereum.org/EIPS/eip-8056).

### Reclassified — openings-only session policy is intentional, but stale exits are not solved

Blocking new positions while allowing existing holders to exit at an insured value is
consistent with the protection product. Gating all exits merely because the reference
market is closed would itself trap users. The actionable issue is M-01: once the price
ages past 24 hours, fee pricing traps exits anyway.

## Previously reported items still open or operationally relevant

These are not counted again as net-new findings:

- ERC-4626 vaults whose `previewRedeem` falls more than the reviewed deviation band
  below `convertToAssets` fail closed until governance refreshes/reconfigures the
  reference. This is a deliberate circuit-breaker tradeoff but must be part of vault
  admission criteria.
- An ACL-denied expired backing owner can delay deactivation until governance changes
  the ACL configuration.
- TWAP staleness reporting still does not mirror every zero-normalization failure.
- Pyth EMA and Uniswap V3 TWAP feeds remain unavailable as direct `CompositeOracle`
  primary/backup legs because they lack the required circuit-breaker marker.
- A plain Chainlink backup can bypass the stock wrapper's corporate-action pause after
  failover because that policy is not token-level (July 11 B-1).
- Opening eligibility is snapshotted and read only from the configured primary feed,
  so putting the stock wrapper second disables its session policy (July 11 B-2).

## Verification evidence

- `forge test --offline`: 1,104 passed, 0 failed, 4 skipped across 50 suites.
- Targeted oracle/session suites: 212 tests passed, 0 failed.
- Script tests: 83 passed, 0 failed.
- Strict invariant profile: 16 passed, 0 failed; 32 runs × 64 calls; zero framework
  reverts.
- Slither 0.11.5 blocking gate: 154 contracts, 74 detectors, 186 visible findings;
  exit 0 with no High-severity gate failure.
- `npm audit --omit=dev --audit-level=high`: 0 vulnerabilities.
- Live read-only selector checks: all 25 documented Robinhood mainnet stock/ETF
  contracts plus the checked-in chain-46630 deployment.
- Working tree was clean before the report was added.

## Suggested remediation order

1. Design and test the market-closed same-asset exit/fee path (M-01).
2. Add finality-aware manifest promotion and independent RPC evidence (M-02).
3. Pin the complete governance root in strict deployment attestation (M-03).
4. Replace/archive the legacy 46630 generation and add Robinhood fork/smoke gates
   (L-01, L-06).
5. Remove unnecessary oracle coupling from backing recapitalization and constrain
   governance forfeiture (L-02, L-03).
6. Resolve the previously reported stock-policy inconsistencies across dual-feed legs.
7. Harden chain allowlists, coverage, recovery metadata, and monitoring consistency.
