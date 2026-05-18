# Smart Contract Audit Findings - May 18, 2026

## Executive Summary

Multi-agent security audit across the entire `contracts/` tree (~8,500 LOC) plus deployment scripts and CI. Four parallel reviews covered the oracle stack, core pool, NFT/governance/access-control, and cross-cutting concerns (static analysis, libraries, upgrade safety, dependencies). The audit builds upon prior reports in `SECURITY_AUDIT_REPORT.md`, `SECURITY_AUDIT_REPORT_V2.md`, `AUDIT_FINDINGS_2026_01_22.md`, `AUDIT_REPORT.md`, and the `docs_ok/security/` folder.

**Overall Assessment**: Mature, well-tested codebase with strong recent hardening of the oracle paths. No critical findings. Several high-severity issues stem from defense-in-depth gaps — silent degradation paths, missing canonical Chainlink mitigations, and economic intent of the NFT transfer lock being bypassable via approvals.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 8 |
| Medium | 16 |
| Low | 17 |
| Informational | 16 |

**Tools / Method**: Manual line-by-line review (4 parallel reviewers), Slither (74 results triaged), `forge build` clean, cross-reference against prior audits.

**Verified fixes**: All three recent oracle fix commits (bfed455, 6cfa714, 0c2f256) are correct and complete. Prior-report findings H-1, H-2, M-1, M-3, M-4 (Jan 22) and Jan 8/15 issues verified fixed.

---

## High Severity Findings

### H-1: Chainlink `minAnswer` / `maxAnswer` bounds not checked (Venus-style attack)

**Location**: `contracts/oracles/ChainlinkOracleFeed.sol:181-191` (`_getPrice`)

**Description**: `_getPrice` validates `answer > 0`, `answeredInRound >= roundId`, and staleness, but never compares `answer` against the aggregator's `minAnswer`/`maxAnswer` parameters. When a Chainlink feed's underlying price falls outside its configured `[minAnswer, maxAnswer]` band — exactly what happened to Venus during the LUNA depeg — `latestRoundData()` keeps returning the floor/ceiling value instead of the true price. The protocol accepts this stuck value as valid.

**Attack scenario**: A backing asset's price collapses below the aggregator's hard-coded floor (e.g., $0.10 for some feeds). The feed pins to the floor. An attacker deposits backing at the still-elevated "oracle" price and immediately withdraws shielded assets at their true higher values.

**Recommendation**: At `setTokenFeed`, query and cache `feed.aggregator().minAnswer()` and `.maxAnswer()`. In `_getPrice`, revert if `answer <= minAnswer || answer >= maxAnswer`. Document the special case where a feed proxy doesn't expose its underlying aggregator (some L2 wrappers).

---

### H-2: Non-protected oracle getters serve disputed feed during pending dual-feed challenge

**Location**: `contracts/oracles/CompositeOracle.sol:690-708` (`_getPrice`), `:748-750` (`getValue`), `:752-793` (`getValueWithFallback`), `:800-813` (`getEquivalentAmount`)

**Description**: When a `challengeForToken` is open (primary vs. backup deviation exceeds threshold), only `getPriceWithCircuitBreaker` / `getPriceWithStrictCircuitBreaker` revert with `OracleChallengePending`. The unprotected entrypoints continue returning the primary feed's price because `isBackupActive` stays false during the 16-hour challenge window. Any consumer path that calls `getValue` / `getEquivalentAmount` (capacity checks, fee USD valuation, view helpers, NFT metadata, future integrations) transacts on a price the protocol itself has formally disputed.

**Attack scenario**: Attacker manipulates primary feed or notices it diverged from backup. Anyone challenges. For 16h the dispute is recognized, but any non-strict consumer keeps executing against the disputed primary. Even if every current pool path uses the strict getter, this is an implicit, undocumented invariant that future changes will easily break.

**Recommendation**: Either (a) make `_getPrice` itself respect the challenge gate and expose explicit `*Unsafe` getters for the rare legitimate callers, or (b) add an inline invariant test asserting no production path calls non-strict getters on a dual-feed token whose `isTokenChallengeable()` is true.

---

### H-3: `getValueWithFallback` silently re-promotes a disabled primary when backup glitches

**Location**: `contracts/oracles/CompositeOracle.sol:752-793`

**Description**: `getValueWithFallback` does no check on `challengeStartTime` / `isTokenChallengeable` / `_hasUnresolvedDualFeedDeviation`. After a challenge has been finalized and `isBackupActive` flipped, `inactiveFeed` becomes the known-bad primary. The second branch (lines 779-789) quietly falls back to it the moment the backup hiccups (Pyth conf widening, Chainlink heartbeat lapse, sequencer hiccup). Only when **both** feeds fail does it return `(0, false)`; a single transient backup error promotes the disputed primary back into use with no on-chain signal.

**Attack scenario**: Primary was disabled because it was manipulable. Attacker waits for the backup to briefly fail. `getValueWithFallback` silently serves the manipulable primary again, even though governance had already moved off it.

**Recommendation**: When `isBackupActive == true`, never silently fall back to `primaryFeed` — surface `(0, false)` so callers fail closed. Alternatively, skip the inactive feed whenever `_hasUnresolvedDualFeedDeviation == true`.

---

### H-4: ERC4626 share-rate cap silently truncates upper-bound deviation on non-strict path

**Location**: `contracts/oracles/ERC4626OracleFeed.sol:308-340` (`_boundedAssetsPerShare`)

**Description**: When `failClosedOnUpperDeviation == false` (the `getPrice` path called by `CompositeOracle._getPrice`), an `assetsPerShare` above `maxAssetsPerShare` is silently clamped (line 339) rather than reverting. Two consequences:

1. As the vault accrues yield, the rate drifts above `referenceAssetsPerShare * (1 + maxDeviationBps)`. The oracle keeps returning the capped (under-)price until governance calls `refreshVaultSharePriceReference`. Vault depositors are systematically under-valued.
2. A real attacker-driven spike (e.g., direct underlying donation inflating `convertToAssets`) is indistinguishable from organic yield in the cap; downstream callers using `getValue` (see H-2) never learn the rate is clamped.

**Attack scenario**: Attacker donates a large amount of underlying to the vault, doubling `convertToAssets`. Strict path reverts → DoS. Non-strict path silently under-prices the share; users with these shares as backing collateral now appear under-collateralized and become liquidatable.

**Recommendation**: Either always fail closed (remove the `failClosedOnUpperDeviation` parameter), or emit an event whenever the upper cap clamps and expose a getter so callers can detect they're receiving a clamped value.

---

### H-5: `requiresStrictProtectedBackingPrice()` silently degrades to non-strict on factory call failure

**Location**: `contracts/SplitRiskPool.sol:423-438`, `:444-465`

**Description**: Every price-sensitive read calls `requiresStrictProtectedBackingPrice()`, which performs a runtime staticcall to the factory:

```solidity
(bool success, bytes memory data) = factory.staticcall(
    abi.encodeCall(ISplitRiskPoolFactory.tokenRequiresStrictProtectedPrice, (BACKING_TOKEN))
);
if (!success || data.length < 32) {
    return false;   // silently disables strict mode
}
```

If a factory upgrade regression causes this call to revert, run out of gas, remove the function, or change its signature, the entire pool population silently downgrades to the compatibility (non-strict) circuit breaker — with no event emitted.

**Attack scenario**: Backing token T was registered with `tokenRequiresStrictProtectedPrice=true` because its non-strict path can be manipulated when one dual-feed leg is degraded. A future factory storage-layout change causes the lookup to revert. Pools that use T as backing silently fall through to the non-strict path. Attacker triggers an oracle deviation that the strict path would have caught, then exits at the inflated price.

**Recommendation**: Pin the strict-pricing flag at pool init (snapshot from factory at deploy time). If dynamic policy is essential, fail closed: when the staticcall fails, revert price-sensitive operations rather than returning `false`. Emit an event when `success == false`.

---

### H-6: Fee accumulator caps trip *after* position is debited → unreachable shielded tokens

**Location**: `contracts/SplitRiskPool.sol:956-987` (`_calculateAndAccumulateFeesAtPrice`), `:1626-1647` (`claimRewards`)

**Description**: Fee amounts are deducted from the position (`newAmount = pos.amount - totalFees`) and the position is updated **before** each fee bucket is bounded by `MAX_SAFE_ACCUMULATION`. If a bucket overflows its cap, the corresponding amount is zeroed but the position has already lost it. The aggregate `totalFees` returned to `claimRewards` is the zeroed sum, so `totalShieldedTokens -= totalFees` decrements by less than what was actually removed from the position.

Result: shielded tokens equal to `(original - zeroed) fees` have no owner — not in any accumulator, not in any position, but `poolState.shieldedTokenBalance` is unchanged so they sit as unreachable dust. The invariant `totalShieldedTokens == sum(position.amount)` drifts. The cross-asset path is guarded with `RewardAccumulationIncomplete`; same-asset paths (`claimRewards`, `partialWithdrawShielded`) are not.

**Attack scenario**: Live exploit risk is low (only reached at extreme accumulation, ~2^128). However, the asymmetry means operators monitoring the invariant will see it broken, and `getUtilizationRatio()` returns inflated utilization.

**Recommendation**: Check each accumulator cap *before* committing `newAmount = pos.amount - totalFees`. If a bucket cannot fit, either revert (consistent with `RewardAccumulationIncomplete`) or do not deduct that fee. Recompute `totalFees` strictly before `updatePosition`.

---

### H-7: NFT `approve` permitted during transfer-lock window — pre-approved sweep on expiry

**Location**: `contracts/ShieldReceiptNFT.sol:126-139`, `contracts/ProtectorReceiptNFT.sol:99-115`; current behavior encoded by `test/NFTTransferLock.t.sol:172-187`

**Description**: The lock check exists in `_update` only, not in `_approve` / `approve` / `setApprovalForAll`. A freshly minted shield/protector NFT can be approved to an attacker contract immediately, while still locked. The instant the lock expires (1d shield / 28d protector), the attacker contract `transferFrom`s the position with no further action from the original holder. This enables black-market wrappers and on-chain "options" that escrow beneficial ownership before the lock expires, defeating the lock's economic intent.

**Attack scenario**:
1. Pool incident occurs; shielded user A wants to liquidate-out before discovery.
2. A cannot transfer yet but calls `approve(blackMarketContract, tokenId)` immediately after deposit.
3. A signs off-chain a sale to B for USDC.
4. Lock expires; B calls `blackMarketContract.execute`, which `transferFrom`s the NFT from A to B and pays A USDC.
5. Effective lock duration = 0.

**Recommendation**: Gate `approve` / `setApprovalForAll` with the same lock check, OR reset/lengthen the lock when an approval is granted, OR document explicitly that the lock guarantees only "no on-chain transfer until T," not "no transfer of beneficial ownership." Invert `test/NFTTransferLock.t.sol:172-187` once fixed.

---

### H-8: `_validateGovernanceTimelock` doesn't enumerate other `DEFAULT_ADMIN_ROLE` holders

**Location**: `contracts/base/ProtocolAccessControlUpgradeable.sol:96-120`, `:129-140`

**Description**: When proposing a new timelock, the validator checks: candidate admins itself, current owner isn't admin, current timelock isn't admin. It does not enumerate other `DEFAULT_ADMIN_ROLE` holders. A timelock candidate with attacker EOA pre-granted as admin in constructor args passes all checks. The `expectedCodehash` pin only constrains bytecode, not role state — a stock `TimelockController` bytecode with arbitrary role members has the same codehash.

**Attack scenario**:
1. Malicious proposal creates a `TimelockController` with `[attackerEOA]` in the admin set, calls `setGovernanceTimelock(newTimelock)` on every protocol contract.
2. After the 2-day delay, the candidate calls `acceptGovernanceTimelock`. All checks pass.
3. Attacker (holding admin on the new timelock) schedules + executes arbitrary upgrades, can `updateDelay` to zero. Full protocol takeover.

Governance must approve the malicious proposal first (mitigated by social review and quorum), but the on-chain validator gives a false sense that role hygiene is enforced. Combined with M-2 below (single Safe holds 100% of bootstrap voting power), this is a realistic takeover path during the bootstrap window.

**Recommendation**: Require `IAccessControlEnumerable.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1` on the candidate (with the only member being the candidate itself). Also constrain `PROPOSER_ROLE` / `EXECUTOR_ROLE` / `CANCELLER_ROLE` member counts. Consider pinning a known timelock implementation codehash at `initialize()` rather than only on subsequent rotations.

---

## Medium Severity Findings

### M-1: `MAX_PRICE_AGE_LIMIT = 3600s` incompatible with long-heartbeat RWA feeds

**Location**: `contracts/oracles/ChainlinkOracleFeed.sol:86`, `PythOracle.sol:103`, `PythEMAOracleFeed.sol:59`

`MAX_PRICE_AGE_LIMIT` is a `public constant` hard-capped at 1 hour. Many Chainlink feeds use 24h heartbeats (LBTC, sDAI, USDY); Pyth RWA feeds in `PythConfig.sol` (USTB, DEJAAA, USYC, RLP) publish at lower cadence than crypto pairs. Any quiet window > 1h spuriously reverts `StalePrice`, cascading to a DoS for every pool touching that token. Not owner-settable; requires redeploy to fix.

**Recommendation**: Raise to 86400 and add per-token override `maxPriceAgePerToken[token]`.

---

### M-2: Bootstrap holder controls 100% of governance unilaterally during bootstrap period

**Location**: `script/DeployYieldShieldProduction.s.sol:78-83, 209-258`; `contracts/YSToken.sol:21-25`; `contracts/YSGovernor.sol:27-41`

`YSToken` mints 1,000,000 YS to the bootstrap holder and self-delegates. `proposalThreshold = 1,000` (0.1%), `MIN_QUORUM_VOTES = 10,000` (1%). A single 2-of-N Safe meets quorum by itself and can unilaterally propose + pass any governance action (upgrades, oracle changes, transfer-lock changes, NFT/factory ownership transfer, malicious timelock installation per H-8) until tokens are distributed. The deploy script enforces only Safe shape (`≥2 owners, threshold ≥2`), not distribution schedule.

**Recommendation**: Document this risk in user-facing docs. Consider: (a) higher absolute `MIN_QUORUM_VOTES` once token is distributed, (b) "warmup" period disabling `_authorizeUpgrade` / oracle changes for N days post-deploy, (c) per-asset emergency-shutdown right held by users.

---

### M-3: `setTransferLockPeriod(0)` permanently disables the lock; no minimum bound

**Location**: `contracts/ShieldReceiptNFT.sol:119-123`, `contracts/ProtectorReceiptNFT.sol:93-97`; pool wrappers `SplitRiskPool.sol:2003-2014`

`MAX_TRANSFER_LOCK` is enforced but no minimum. Governance can lower the lock to zero. Combined with H-7, this provides two failure modes: lock cranked to max (DoS on exits) or zero (defeats protection).

**Recommendation**: Enforce `newPeriod >= MIN_TRANSFER_LOCK` (e.g., 1 hour). Optionally restrict per-call change magnitude.

---

### M-4: Cross-asset withdrawal decrements `totalShieldCollateralAmount` by deposit-time cap, not actual payout

**Location**: `contracts/SplitRiskPool.sol:1442-1451`

```solidity
payoutAmount = Math.mulDiv(pos.valueAtDeposit, backingTokenScale, uwPrice);
uint256 maxBackingTokens = pos.collateralAmount;   // fixed at deposit time
if (payoutAmount > maxBackingTokens) payoutAmount = maxBackingTokens;
...
totalShieldCollateralAmount -= pos.collateralAmount;   // full cap
totalProtectorTokens         -= payoutAmount;          // actual paid
```

When backing token price rises post-deposit, `payoutAmount < pos.collateralAmount`. The "phantom" difference frees up future protector withdrawals beyond the original collateralization promise.

**Recommendation**: Decrement `totalShieldCollateralAmount` by `min(pos.collateralAmount, payoutAmount)`, or scale `pos.collateralAmount` down proportionally when the cap is not hit.

---

### M-5: `tokenRequiresStrictProtectedPrice` can be flipped mid-flight, retroactively changing pool pricing

**Location**: `contracts/SplitRiskPoolFactory.sol:723-732`, `SplitRiskPool.sol:423-445`

Pools read the flag fresh on every priced call. Flipping it instantly re-routes pricing on in-flight positions with no per-pool override, no grace period, no version pin. A mempool tx executed pre-flip vs post-flip behaves differently. Combined with H-5.

**Recommendation**: Pin at pool init. If runtime updates desired, add per-pool migration gated by pool-level governance with explicit event emission.

---

### M-6: Pyth EMA and spot share one `maxConfidenceBps`; EMA conf widens during shocks

**Location**: `contracts/oracles/PythOracle.sol:320-329`, `PythEMAOracleFeed.sol:169-178`

Pyth EMA conf is systematically wider than spot during volatility windows — exactly when the protocol most needs EMA fallback. The single 200 bps threshold causes `PythEMAOracleFeed.getPrice` to revert `PriceConfidenceTooWide` precisely during the shocks it's designed to dampen.

**Recommendation**: Separate thresholds `maxSpotConfidenceBps` and `maxEmaConfidenceBps`, EMA loosened (5-10%). Or skip conf check on EMA entirely and rely on spot/EMA deviation as the manipulation signal.

---

### M-7: `ERC4626OracleFeed._checkUnderlyingStaleness` accepts future-dated publish times up to 24h

**Location**: `contracts/oracles/ERC4626OracleFeed.sol:377-410`

The decoder accepts `time64 > 0 && time64 <= block.timestamp + 86400`. A future-dated publishTime up to 24h ahead bypasses the staleness gate. The `(bool, uint256)` fallback is also dead code — both encodings share the same 64-byte ABI layout, so the first `abi.decode` always succeeds.

**Recommendation**: Drop the dual-decoder, use the `IPriceOracle` interface explicitly. Clamp accepted publishTime to `block.timestamp + sequencerSkewTolerance` (e.g., 30s).

---

### M-8: `forceResetToPrimary` / `emergencyCancelChallenge` are owner-only with no timelock

**Location**: `contracts/oracles/CompositeOracle.sol:623-636`, `:641-652`

Single-key abort of the entire challenge mechanism. If the owner key is compromised — or simply slow — an attacker who corrupted the primary feed can force-revert the system back to it.

**Recommendation**: Short timelock (1-2h) on both functions so users can withdraw before override takes effect. At minimum, separate "emergency multisig" role distinct from the feed-setter owner.

---

### M-9: `CompositeOracle.isPriceStale` fallback reports "fresh" when feed lacks staleness helper

**Location**: `contracts/oracles/CompositeOracle.sol:664-683`

When the active feed doesn't implement `isPriceStale(address)`, the fallback returns `(false, uint64(block.timestamp))` — i.e., always-fresh. Consumed by `ERC4626OracleFeed._checkUnderlyingStaleness`; any new feed without `isPriceStale` silently has no staleness gate.

**Recommendation**: Fail closed — return `(true, 0)` when feed lacks the helper. Require all production feeds to implement it.

---

### M-10: `PythOracle._convertPrice` silently truncates to zero for `expo < -8`

**Location**: `contracts/oracles/PythOracle.sol:300-318`, `PythEMAOracleFeed.sol:152-167`

Integer division in the divide branch can yield zero with no revert for small-priced assets. Zero propagates into composition without `validateNonZeroPrice` catching it on the numerator path.

**Recommendation**: After divide branch, `if (result == 0) revert InvalidPrice(token, 0);`. Reject Pyth feeds with `expo < -18` at registration.

---

### M-11: `PythOracle.updatePriceFeeds` is permissionless → free MEV sandwich

**Location**: `contracts/oracles/PythOracle.sol:130-143`

Any address can choose which Hermes message (within the ~2-3s buffer) to post on-chain. Attacker pre-calls with the lowest-valid price ahead of a victim deposit/withdraw. Documented as an accepted property of pull oracles, but worth re-emphasizing that the protected path (`getPriceWithCircuitBreaker`) MUST be used by consumers to catch the worst manipulation via EMA deviation.

**Recommendation**: Document this invariant in consumer code. Optionally restrict callers or charge a premium.

---

### M-12: External `_safeMint` precedes per-tokenId state initialization

**Location**: `contracts/SplitRiskPool.sol:1270-1278` (`depositBackingAsset`), `:1344-1347` (`depositShieldedAsset`)

`mint` is called before `protectorShares[tokenId]`, `protectorShareEpochs[tokenId]`, `rewardDebt[tokenId]`, `feeValueBaselineUsd[tokenId]` are set. `onERC721Received` observes inconsistent state. `nonReentrant` blocks re-entry into the same pool, but not cross-pool view reads, off-chain indexers, or future hook additions. Currently no direct fund loss, but a future code change that moves any mutation after the mint would expose a real reentrancy.

**Recommendation**: Initialize per-tokenId mappings before calling `mint`. The NFT can be modified to accept metadata in a single call, or mappings keyed by `nextTokenId` (read pre-mint) can be set first.

---

### M-13: Same-asset shielded withdrawal silently skips fees during oracle pending challenge

**Location**: `contracts/SplitRiskPool.sol:911-923`, `:1626-1647`

`_tryCalculateAndAccumulateFees` returns `(0,0,0)` when the protected shielded price is unavailable or token has a pending challenge. In `shieldedWithdraw` (same-asset path, line 1399-1401), this lets the user exit during oracle outage without paying fees on accrued yield. A user can intentionally trigger a challenge (anyone can call `challengeForToken` if deviation exceeds threshold) to skip fees on a desired exit window.

**Recommendation**: Revert same-asset withdrawals during pending challenge (symmetric to cross-asset, accepting the liveness hit) OR fall back to `pos.valueAtDeposit / pos.amount` as a price floor when protected price is unavailable.

---

### M-14: Pool fees stuck if SHIELDED_TOKEN blacklists `POOL_CREATOR`

**Location**: `contracts/SplitRiskPool.sol:1039-1071`

`POOL_CREATOR` is immutable. If the underlying token (e.g., USDC) blacklists the creator address for unrelated regulatory action, accumulated pool fees become permanently unreachable. Protocol fees have a recipient governance can rotate; pool creator does not.

**Recommendation**: Add `setPoolFeeRecipient` callable by pool creator (optionally with timelock). Alternatively, allow governance to override stuck recipients.

---

### M-15: Governor `proposalThreshold` checkable from votes 1 second old → flash-loan-propose

**Location**: `lib/openzeppelin-contracts/contracts/governance/Governor.sol:288-296`, `contracts/YSGovernor.sol:36`, `contracts/YSToken.sol:41-43`

OZ Governor checks `getVotes(proposer, clock() - 1)` at propose time. If YS ever becomes flash-loanable (Aave/Morpho listing, AMM with flash callbacks), an attacker can flash-borrow 1,000+ YS, delegate, propose in the next block, return the loan. Voting itself is snapshot-protected, but proposal-spam and snapshot-timing-of-attacker-choice remain.

**Recommendation**: Raise propose threshold to ~1% of supply (10K YS), or restrict proposing to delegates of users who held YS for a minimum duration.

---

### M-16: `ProtectorReceiptNFT.getPosition` swallows pool revert → stale amount served

**Location**: `contracts/ProtectorReceiptNFT.sol:67-78`

`try ... catch { }` around `getProtectorPositionAmount`. On pool revert (pause, upgrade, selfdestruct), returns the stored `position.amount` instead of socialized-down current amount. Integrators reading this field have no signal they're seeing stale data.

**Recommendation**: Re-throw with a distinct error, document the field's semantics, or remove the stored `amount` now that loss-socialization is share-based.

---

## Low Severity Findings

### L-1: `UniswapV3TWAPFeed.setMinimumAverageLiquidity(0)` silently disables the liquidity floor

**Location**: `contracts/oracles/UniswapV3TWAPFeed.sol:181-185`, `:347-360`

Setting zero makes `_validateAverageLiquidity` accept any pool, including near-zero-liquidity pools that are trivially manipulable. Owner-only, but no event severity / monitoring signal.

**Recommendation**: Forbid zero in the setter; require explicit `emergencyDisableLiquidityFloor()` with unmistakable name and event.

---

### L-2: `ChainlinkOracleFeed.setSequencerUptimeFeed` accepts `startedAt == 0`

**Location**: `contracts/oracles/ChainlinkOracleFeed.sol:138-158`

Spoofed feed with `startedAt = 0` accepted at registration → permanent `SequencerDown` revert on every L2 price read.

**Recommendation**: Require `startedAt > 0 && startedAt <= block.timestamp` at registration.

---

### L-3: `PythOracle.getPrice` (unprotected) is the publicly exposed default; consumers may forget protected variant

**Location**: `contracts/oracles/PythOracle.sol:224-256`

`getPrice` / `getValue` / `getEquivalentAmount` skip the spot/EMA deviation check. Protected variant is opt-in. Structural footgun that has caused real losses elsewhere (Inverse Finance, Cream).

**Recommendation**: Make protected the default and rename unprotected to `getPriceUnsafe` / `getValueUnsafe`.

---

### L-4: `CompositeOracle.removeTokenOracleFeed` not gated on active pool usage

**Location**: `contracts/oracles/CompositeOracle.sol:312-338`

No timelock, no reference counting. Users mid-flow are bricked instantly.

**Recommendation**: 24h timelock on removal, or factory-side check that no live pool depends on the token.

---

### L-5: `_calculateFeedDeviation` reverts when either feed fails, blocking `getCurrentDeviation` external view

**Location**: `contracts/oracles/CompositeOracle.sol:396-419`

Off-chain monitoring loses visibility when most needed.

**Recommendation**: Return `type(uint256).max` on partial failure so dashboards can distinguish "deviation huge" from "RPC error."

---

### L-6: `UniswapV3TWAPFeed` quote-token oracle is mutable in one call with no bound

**Location**: `contracts/oracles/UniswapV3TWAPFeed.sol:189-194`

Single-call total compromise of every TWAP-priced asset. No "new oracle must be within X% of current" sanity check.

**Recommendation**: Require post-change price within X% of pre-change. Emit both old and new prices in the event.

---

### L-7: `UniswapV3TWAPFeed.getPrice` precision loss → zero price for micro-USD tokens

**Location**: `contracts/oracles/UniswapV3TWAPFeed.sol:219-226`

Stacked divisions can round the final 8-decimal price to zero for assets like `$1e-9`. Composing pools then treat the asset as worthless.

**Recommendation**: `if (result == 0) revert InvalidPrice(...)` after final normalize. Reject whitelists whose token decimals × price range normalize to zero.

---

### L-8: `YSToken.burn` boundary uses `<` instead of `<=` against `MIN_GOVERNANCE_SUPPLY`

**Location**: `contracts/YSToken.sol:58-66`

Allows burning to exactly `MIN_GOVERNANCE_SUPPLY = 10,000e18 = MIN_QUORUM_VOTES`. At supply == quorum, any non-voter can hold proposals indefinitely. `test_ProductionBootstrap_BurnCannotReduceBelowQuorumVotingPower` uses `MIN - 1` and leaves the boundary untested.

**Recommendation**: Change to `<=`. Update the test.

---

### L-9: Safe validation in `_validateProductionBootstrapHolder` is shape-only

**Location**: `script/DeployYieldShieldProduction.s.sol:209-258`

Decodes `VERSION` / `nonce` / `domainSeparator` but only checks they're nonempty. A malicious wrapper with matching selectors passes.

**Recommendation**: Pin known Safe master-copy codehash per target chain. Or verify via `IERC1271.isValidSignature` round-trip.

---

### L-10: `setPool` on receipt NFTs is one-shot; partial deployment is irrecoverable

**Location**: `contracts/libraries/PoolCreationLib.sol:48-73`

Deployment order: deploy NFT → init pool → `setPool` → `transferOwnership`. If anything in init/`setPool` fails after NFT deploy, the factory permanently retains `setTransferLockPeriod` rights on a dead NFT.

**Recommendation**: Make deployment + setPool + transferOwnership atomic in the NFT constructor, or add a factory-only rescue path before any deposit.

---

### L-11: `MIN_PUBLIC_GOVERNANCE_DELAY = 1 day` allows short emergency-replacement delays on L2s

**Location**: `contracts/base/ProtocolAccessControlUpgradeable.sol:37`

Production deploys with 2 days, but a future proposal could swap to a 1-day timelock. Combined with H-8, 1 day is short for community response.

**Recommendation**: Raise to 2 days; align with `DEFAULT_PRODUCTION_TIMELOCK_DELAY`.

---

### L-12: `ShieldReceiptNFT.updatePosition` accepts caller-supplied `lastFeeClaimTime` with no upper bound

**Location**: `contracts/ShieldReceiptNFT.sol:103-116`

`onlyPool` so currently safe (pool passes `block.timestamp`). Defense-in-depth: future code that passes attacker-influenced value could disable fee accrual indefinitely.

**Recommendation**: `if (newLastFeeClaimTime > block.timestamp) revert`.

---

### L-13: `partialWithdrawShielded` rounding drifts value-per-token down across many partials

**Location**: `contracts/SplitRiskPool.sol:1512-1520`

`newValueAtDeposit` and `newCollateralAmount` round down. `totalValueAtDeposit` invariant holds globally, but per-position `valueAtDeposit/amount` drifts down across many partials → tiny haircut on eventual cross-asset payout.

**Recommendation**: Round these recalculations with `Math.Rounding.Ceil`. Verify against the global invariant.

---

### L-14: `claimRewards` cooldown is keyed by NFT, not owner — NFT buyer inherits 24h block

**Location**: `contracts/SplitRiskPool.sol:1629-1634`

Complicates secondary-market transactions; buyer can't crystallize state for ~24h.

**Recommendation**: Reset cooldown on NFT transfer (NFT `_update` calls into pool), or document carryover clearly.

---

### L-15: `setAccessControl` validation calls ACL with `address(0)` — malicious ACL passes

**Location**: `contracts/SplitRiskPool.sol:2118-2139`

`_validateAccessControlHook` only checks `address(0)` returns a decodable bool. ACL returning `true` for zero and reverting for nonzero passes validation, bricks pool. Mitigated by governance-only `accessControlCanGateWithdrawals`, but gives false sense of safety.

**Recommendation**: Validate with `msg.sender` and a known-test nonzero address; require at least one nonzero path to return without reverting.

---

### L-16: Slither `setCompositeOracle` loop-DoS over `whitelistedTokens`

**Location**: `contracts/SplitRiskPoolFactory.sol:945-984`

Governance-only, but no cap on `whitelistedTokens.length`. After many whitelistings, oracle migration could exceed block gas.

**Recommendation**: Cap `whitelistedTokens.length` or paginate `setCompositeOracle`.

---

### L-17: Missing zero-checks on `SplitRiskPool.initialize(initialOwner)`, `setManagedPythOracle`, `setManagedERC4626OracleFeed`

**Location**: `contracts/SplitRiskPool.sol:180,203`; `contracts/SplitRiskPoolFactory.sol:257,267`

Effectively mitigated by `_disableInitializers` and downstream `_requireOwnedByFactory(newOracle)` reverting for `address(0)`, but a direct zero-check produces a clearer revert and matches the style of other zero-checks at 182-187.

**Recommendation**: Add explicit `if (initialOwner == address(0)) revert ZeroAddress();` etc.

---

## Informational Findings

### I-1: `MockTokenFaucet.sol` sits at top level of `contracts/`, not in `contracts/mocks/`
Excluded by `slither.config.json:2` and `aderyn.toml:7`, but the file path is not obviously a mock. Move to `contracts/mocks/` and update exclude paths to prevent accidental production deployment.

### I-2: No storage-layout regression test in CI
Highest-leverage missing check given UUPS upgradeability. Snapshot `forge inspect SplitRiskPool storageLayout` and `forge inspect SplitRiskPoolFactory storageLayout` into the repo; fail CI on diff. Would catch `__gap` accounting mistakes (factory currently reserves ~59 slots, deviating from the common 50-slot convention — U-3 in the cross-cutting review).

### I-3: CI runs Slither / Aderyn with `continue-on-error: true`
Findings are artifact-only, never block PRs. The true-positive lows (L-17 and others) are invisible to PR reviewers. Convert to baseline-diff that fails on new high/medium findings.

### I-4: TickMath / FullMath vendored without upstream version pin
Add Uniswap v3-core commit hash so static analyzers can compare against known-good baseline.

### I-5: `_supportsCircuitBreaker` treats a fresh token (zero price) as "no CB"
Edge case; zero-price assets shouldn't trade. `contracts/oracles/CompositeOracle.sol:930-952`.

### I-6: `_detectOracleType` substring matching is fragile
Already noted in V2 audit. Recommend storing oracle type explicitly at registration; deprecate the auto-detect path. `contracts/oracles/CompositeOracle.sol:957-1005`.

### I-7: `PythEMAOracleFeed` exposes no `getPriceWithCircuitBreaker` by design
Document explicitly that no pool may route through an EMA-only feed as backing collateral with `strictCircuitBreakerRequired = true` (would brick the pool).

### I-8: `protectorWithdraw` shares ceiling rounds against the user
Acceptable (favors pool), document.

### I-9: `requireGovernanceOrBootstrapOwner` lets pre-launch owner set composite oracle to any non-zero address with no liveness check
Add a minimal liveness probe (e.g., `oracle.getPrice(knownToken)` doesn't revert).

### I-10: `commissionsClaimed[tokenId]` reset to 0 on partial protector withdrawal
Correct per-NFT accounting but off-chain analytics computing per-NFT claimable should be aware.

### I-11: Dust-redirect path drops residual when `accumulatedProtocolFee` hits cap
Acceptable given cap value (~3.4e38). Document.

### I-12: `_authorizeUpgrade` doesn't validate UUPS `proxiableUUID` or storage layout
Standard OZ pattern; governance must externally validate upgrade payload.

### I-13: `addToken` in factory accepts feed without liveness check
Misconfiguration silently passes until first deposit.

### I-14: `_isProtectorDustExitAvailable` sole-holder branch is dead code
`contracts/SplitRiskPool.sol:1589-1595`, `:1696-1699`. Remove or document as defensive.

### I-15: `pause()` is `onlyGovernance` (timelocked) — no fast-path emergency pause
2-day detection-to-pause gap is too long for real incidents. Consider a guardian role with pause-only rights.

### I-16: `EventsLib.sol` parameter-change events don't include `address indexed caller`
Hurts audit trail. Add caller to all governance-config events.

---

## Verified Fixes (Prior Reports)

| Prior Finding | Status | Notes |
|---|---|---|
| **bfed455** — emit events on Pyth conf threshold change | ✅ Verified | `PythOracle.sol:211-218`, `PythEMAOracleFeed.sol:112-119`. Consistent with sibling setters. |
| **6cfa714** — guard sequencer uptime against future `startedAt` | ✅ Verified | `ChainlinkOracleFeed.sol:288-290` and `:246-248` short-circuit `startedAt > block.timestamp`. Minor gap: registration doesn't validate `startedAt` (see L-2). |
| **0c2f256** — fail closed on future-dated Chainlink timestamps | ✅ Verified | `OracleValidationLib.validateStaleness:58-66` reverts before unsigned subtraction. Propagated to all consumers. Pyth path was already guarded. |
| **Jan 22 H-1** — off-by-one in `getAvailableForWithdrawal` | ✅ Fixed | Line 607: `if (requiredProtectorTokens >= totalProtectorTokens) return 0`. |
| **Jan 22 H-2** — `totalValueAtDeposit` drift on reward claims | ✅ Fixed | `_calculateAndAccumulateFeesAtPrice` preserves `pos.valueAtDeposit`; `claimRewards` doesn't touch it. Caveat: see L-13 on rounding. |
| **Jan 22 M-1** — fee reserve protection overflow | ✅ Fixed | Bounds check at line 1512. (But see H-6 for NEW concern around accumulator caps.) |
| **Jan 22 M-2/M-3** — USD utilization / withdrawal check | ✅ Fixed (presumed) | `getAvailableForWithdrawal` returns 0; `protectorWithdraw` enforces `InsufficientUnlockedTokens`. |
| **Jan 22 M-4** — divide-before-multiply | ✅ Fixed | Lines 245, 547, 601 reordered. |
| **Jan 22 L-2** — migration revert | N/A | `SplitRiskPoolCommission.sol` referenced no longer present; appears refactored away. |
| **Jan 8 LOW-NEW-1** — `tokenInfo` not cleared on `removeToken` | ✅ Fixed | Factory line 598: `delete tokenInfo[token]`. |
| **Jan 8 LOW-NEW-2 / Jan 15 M-2** — `setAccessControl` no validation | ⚠️ Partially fixed | `_validateAccessControl` exists but uses `address(0)` only (see L-15). |
| **Jan 8 LOW-NEW-4** — division by zero on `currentPrice == 0` | ✅ Fixed | All shielded retrievals revert `InvalidOraclePrice` on zero. |
| **Jan 15 M-1** — unclaimed commission loss on partial protector withdrawal | ✅ Fixed | `_claimCommissionTo` called BEFORE share changes (line 1732). |
| **e53d21d** — raw private key reveal helper removed | ✅ Verified | No surviving plaintext-key exporter in `scripts-js/`. All flows route through Foundry's `cast wallet`. |

---

## Governance Attack Surface Summary

**Unilateral (no timelock, no vote)**
- Bootstrap holder Safe keys: self-delegate + unilateral proposal (M-2).
- `acceptGovernanceTimelock`: only by `_pendingGovernanceTimelock` after prior proposal.
- Pool creator (before first deposit): `setAccessControl` on their pool.
- Factory: `pauseFromFactory` any pool (no timelock).

**Requires governor vote + timelock (default 2 days)**
- Whitelist add/remove, oracle administration, pool upgrades, parameter changes, governance timelock rotation, token removal, pool deactivation, protocol pause.

**Immutable post-deploy**
- Additional YS mints (supply fixed in constructor; `burn` is the only post-deploy change).
- Pool creator address per pool.
- NFT `setPool` (one-shot).
- Any `initialize` call.

**Single-point-of-failure concerns**
1. Bootstrap Safe = full protocol control until distribution (M-2).
2. Malicious-but-validly-shaped timelock candidate passes installation checks (H-8).
3. NFT approve-during-lock defeats lock economic intent (H-7).
4. Factory call failure silently downgrades pool pricing (H-5).
5. `MIN_PUBLIC_GOVERNANCE_DELAY = 1 day` short for L2 community response (L-11).

---

## Top Recommendations (Ranked by Leverage)

1. **Add Chainlink min/max-answer checks** (H-1). Canonical Venus finding, well-understood mitigation, no design changes.
2. **Make `_getPrice` / `getValueWithFallback` respect the challenge gate**, or rename non-protected getters to `*Unsafe` (H-2, H-3). Eliminates footgun for every future integration.
3. **Pin `requiresStrictProtectedBackingPrice` at pool init** instead of dynamic factory lookup (H-5, M-5). Closes both upgrade-regression downgrade and mid-flight policy flip.
4. **Cap fee buckets before deducting position** (H-6). Small refactor of `_calculateAndAccumulateFeesAtPrice`.
5. **Gate `approve` / `setApprovalForAll` with the transfer-lock check** (H-7). Preserves economic intent.
6. **Enumerate DEFAULT_ADMIN_ROLE on timelock candidates** (H-8). Reject candidates with more than one admin.
7. **Add storage-layout regression test in CI** (I-2). Highest-leverage missing check.
8. **Gate Slither/Aderyn findings as PR-blocking** via baseline diff (I-3).
9. **Raise `MAX_PRICE_AGE_LIMIT`** to 86400 + per-token override (M-1). Required for the RWA Pyth feeds already in scope.
10. **Add storage-layout / upgrade fork test** that performs `upgradeToAndCall` on a real proxy and asserts critical invariants survive.

---

## Tools Used

- Manual review (4 parallel reviewers across oracle / pool / NFT-gov / cross-cutting)
- Slither 0.10.x (74 results, triaged)
- `forge build` (clean)
- Cross-reference against prior reports: `SECURITY_AUDIT_REPORT.md`, `SECURITY_AUDIT_REPORT_V2.md`, `AUDIT_FINDINGS_2026_01_22.md`, `AUDIT_REPORT.md`, `docs_ok/security/*`
- Cross-reference against recent commits: bfed455, 6cfa714, 0c2f256, e53d21d, e310751

## Audit Conducted By

Claude Code (multi-agent), 2026-05-18.
