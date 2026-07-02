# YieldShield Protocol — Multi-Agent Design Review

**Date:** July 2, 2026
**Scope:** `contracts/` tree — `SplitRiskPool`, factory, oracle stack, NFTs, access control, upgradeability, governance.
**Method:** Four-way parallel design review (three focused reviewer agents + orchestrator), manual line-by-line reading with `file:line` verification, cross-referenced against prior reports (`AUDIT_FINDINGS_2026_05_18.md`, `SECURITY_AUDIT_REPORT*.md`, `docs_ok/`), plus external research on current vault/oracle/upgrade attack patterns.
**Focus of this pass:** *net-new design weaknesses and internal inconsistencies* — not a re-run of the existing security audits. Where a prior finding was checked, its status is noted.

---

## Model attribution

Per request, this section records exactly which model performed the work.

- **All research and review in this document was performed by Claude Fable 5** — the orchestrator and all three parallel reviewer subagents ran on `claude-fable-5`.
- **No fallback to Claude Opus 4.8 was required.** Every subagent completed successfully on the first attempt; there was no capacity, timeout, or capability event that forced a downgrade.
- Web research (ERC-4626 manipulation, Chainlink bounds/liveness, UUPS upgrade practices) was performed by Claude Fable 5 via web search; sources are listed at the end.
- Every code-level finding below was independently re-verified by the orchestrator (Claude Fable 5) against the current `main` source before inclusion. Findings that could not be confirmed in code were dropped.

> If this document is regenerated and any portion is produced by a different model, that portion should be labelled inline (e.g. `[Opus 4.8]`). As of this run, nothing is so labelled because nothing required it.

---

## Executive summary

The codebase is mature and defends its **correctness** boundary well: across the deposit/withdraw/fee paths the core balance identity holds, protector share math is donation-resistant (internal accounting, not `balanceOf`-based), and no path was found that serves a *wrong* oracle price through the protected getters — the oracle stack consistently fails **closed**. The previously reported oracle fixes (H-1/H-2/H-3, M-6…M-10) and access-control fixes (H-7 approve-during-lock, H-8 admin enumeration, M-3, M-14) are present and correct in the current source.

The net-new risk this pass surfaces is the **mirror image of the old audits**. The old audits worried about wrong prices and stolen value; the dominant issue now is **liveness and governance blast-radius**:

1. **Upgrade power is unconstrained on-chain.** Both `SplitRiskPool._authorizeUpgrade` and `SplitRiskPoolFactory._authorizeUpgrade` are empty `onlyGovernance` bodies, and `_validatePoolImplementation` checks only "is UUPS-shaped." A single timelocked proposal can repoint every pool at arbitrary code and reach all user funds. This is the largest admin power in the protocol and it is not reflected in the "decentralized / no single point of failure" framing.

2. **Several independent safety mechanisms each convert a routine operational event into a multi-hour, sometimes owner-gated, full pricing outage** — Chainlink aggregator rotation, the 75 bps live-deviation gate, the 16-hour challenge window, and the ERC-4626 5% share-price band. Worse, the two escape hatches that exist (`registerVault` overwrite, instant parameter setters) *bypass the very timelocks the design relies on elsewhere.*

3. **Two sticky/one-way state flags can permanently disable a product line** (`shieldedTokenTransferIntegrityBroken` bricks all cross-asset protection with no reset; a sub-minimum protector residual can permanently block re-bootstrapping a pool).

4. **A cluster of stale invariant docstrings now contradict the code** — the exact "claimed invariants" a future maintainer would trust when making a fix.

| Severity | Count |
|----------|-------|
| High | 2 |
| Medium | 11 |
| Low | 12 |
| Informational | 9 |

No critical (immediately fund-draining, unprivileged) finding was identified in this pass.

---

## High severity

### H-1 — Pool & factory upgrades are unvalidated on-chain; governance can repoint every pool at arbitrary code and reach all funds

**Location:** `SplitRiskPool.sol:2849` and `SplitRiskPoolFactory.sol:1848` (both `_authorizeUpgrade(address) internal override onlyGovernance {}` — empty); `SplitRiskPoolFactory.sol:1734-1741` (`_validatePoolImplementation` checks only `code.length != 0` and that `proxiableUUID()` returns the ERC-1967 slot); `SplitRiskPoolFactory.sol:185-189` (`setPoolImplementation`).

**Description.** Neither upgrade authorizer validates the new implementation's storage-layout hash, codehash, or a version. `_validatePoolImplementation` confirms only that the target is UUPS-shaped. Because all pools share the factory-set implementation, one timelocked governance action can replace logic for **every pool simultaneously** with a contract that reads the same storage slots (`totalProtectorTokens`, `poolState`, NFT addresses) and transfers out principal — or with a shifted layout that silently corrupts accounting. The repo's CI storage-layout check (`scripts-js/check-storage-layout.sh`) protects the *repository*, but nothing enforces layout compatibility **on-chain at upgrade time**.

**Impact.** This is the protocol's single largest power. Blast radius is the entire protocol, not one pool. The only mitigations are the timelock delay and quorum — process controls, not on-chain constraints on *what* an upgrade may do. Industry precedent for this exact class (upgrade-mechanism abuse) includes the Radiant Capital (~$50M) and IoTeX bridge (~$4.4M) incidents.

**Recommendation.** In pool `_authorizeUpgrade`, at minimum re-assert `proxiableUUID()` and require the new implementation's storage-layout hash to match a governance-approved allowlist or a monotonically increasing version registry; apply the same to the factory. Independently, user-facing docs should state plainly that governance can upgrade pool logic and thereby reach user funds, so the decentralization framing is not overstated. See also I-3.

---

### H-2 — `shieldedTokenTransferIntegrityBroken` is a permanent, unresettable kill-switch for the entire protection product, while deposits and fees keep flowing

**Location:** `SplitRiskPool.sol:979-984` (set on any out-transfer shortfall), `:1844-1846` (set on deposit shortfall), `:1922-1924` (hard-blocks all cross-asset withdrawals), `:3079` (storage). No code path anywhere clears the flag.

**Description.** A single observation of `received < nominal` on *any* shielded-token transfer permanently sets a flag that blocks **all** cross-asset withdrawals — i.e., the whole downside-protection feature shielded users pay commissions for. Two compounding gaps:

- **No reset, even by governance.** A transient event (a token that briefly enables a transfer tax, a one-off issuer action, or a token that taxes only certain recipient addresses that one withdrawer happens to route through) bricks protection for every current and future shield position forever.
- **New shield deposits stay open** (`depositShieldedAsset` *sets* the flag at `:1844` but does not revert), and same-asset exits still charge full yield fees (`:1951-1953`) while protectors keep earning commissions — so the protocol keeps selling and charging for a product it can no longer pay out on.

**Impact.** One transient token event permanently disables the insured leg while the fee machinery continues. Verified: the flag is set at lines 981/1845 and read at 1922, with no clearing path in the file.

**Recommendation.** (a) Add a governance-timelocked reset that re-validates the token via the existing round-trip probe before clearing; (b) revert (or require explicit opt-in on) `depositShieldedAsset` while the flag is set; (c) consider waiving further commission accrual while the insured leg is suspended.

*(This is rated High rather than a liveness Medium because it silently continues charging users for a suspended product and has no recovery path at all.)*

---

## Medium severity

### M-1 — Factory upgrade shares the same unvalidated power over factory-owned oracles and the whole registry
`SplitRiskPoolFactory.sol:1848`. The factory owns CompositeOracle/PythOracle/ERC4626OracleFeed and holds creation bonds; its empty `_authorizeUpgrade` can re-route oracle admin, mis-account bonds, or change `defaultProtocolFeeRecipient`/`compositeOracle` for all future pools. One indirection from principal, but still total control. **Fix:** validate the factory implementation on upgrade; surface the power in governance docs.

### M-2 — Routine Chainlink aggregator rotation bricks all pricing until the owner manually refreshes bounds
`ChainlinkOracleFeed.sol:205-233, 243-248, 461-471`. `_cacheFeedBounds` writes `tokenFeedBoundsAggregator[token] = underlying` **unconditionally** (verified at `:207`), *before* the min/max try-blocks, so the "no cached aggregator → skip" branch of `_requireFreshFeedBounds` is dead. When a Chainlink proxy rotates its aggregator (routine, a few times/year per feed), every `getPrice` reverts `FeedBoundsStale` until the **owner** calls `refreshFeedBounds`. This cascades: primary reverting ⇒ CompositeOracle treats it as max-deviation ⇒ every protected getter reverts and a 16-hour challenge can be opened. **Fix:** make `refreshFeedBounds` permissionless (it consumes only on-chain feed data), or read `minAnswer/maxAnswer` live in `_getPrice` and drop the cache/pin. Note current Chainlink guidance also warns these bounds are deprecated on many feeds — reading them live and treating absence gracefully is preferable to a hard pin.

### M-3 — Dual-feed state machine has multi-hour fail-closed windows with no permissionless recovery in either direction
`CompositeOracle.sol:59-62, 616-659, 703-752, 787-815`. (a) When the primary breaks, the healthy backup cannot serve until `challengeForToken` + 16h `finalizeChallenge` — the backup provides *zero* availability benefit for the first 16 hours of any outage. (b) With `isBackupActive` and a live primary/backup deviation, all protected getters revert **and** `revertToPrimary` reverts even when the primary is demonstrably healthy — recovery requires owner `scheduleForceResetToPrimary` + 2h. (c) The default `deviationThresholdBps = 75` is calibrated for stable/stable pairs, yet the interface contemplates NAV-primary + market-backup (`ICompositeOracle.sol:72-73`), where >0.75% divergence is routine during volatility — so the gate will hard-revert with no attacker present. **Fix:** allow permissionless revert-to-primary when the *backup* is the failed leg; make the deviation threshold per-token.

### M-4 — `registerVault` re-registration instantly bypasses the reference-refresh and removal timelocks
`ERC4626OracleFeed.sol:192-228` vs `232-287, 305-343`. `registerVault` doesn't check whether a vault is already registered; it overwrites `VaultConfig` wholesale, re-anchoring `referenceAssetsPerShare` to the *current* rate with no delay and no band check, and resets `maxSharePriceDeviationBps` to default. This makes the entire `scheduleVaultSharePriceReferenceRefresh` → 1-day → band-checked pipeline advisory: an owner key can re-anchor the manipulation guard to any live (possibly donation-inflated) rate in one tx. **Fix:** revert if already registered (force the timelocked path), or route re-registration through the scheduled delay.

### M-5 — ERC-4626 share-price band turns donations into a cheap pricing DoS with no in-band recovery
`ERC4626OracleFeed.sol:537-555, 604-617, 238-241`. A donation of `> maxSharePriceDeviationBps` (default 5%) of `totalAssets` pushes `assetsPerShare` out of band, after which *every* getter reverts — and `scheduleVaultSharePriceReferenceRefresh` also reverts (requires the new reference within band of the old), so the timelocked recovery is unusable and the only escape is the timelock-bypassing `registerVault` overwrite (M-4), which bakes in the attacker's inflated rate. With `MIN_VAULT_VALUE_USD = 1_000e8`, DoSing a small vault costs ~$50 of sacrificed underlying. External research corroborates that internal-balance / capped-oracle designs (e.g. Aave CAPO, virtual-share offsets) are the standard mitigation. **Fix:** let the scheduled refresh be created for out-of-band rates (the 1-day delay + execute-time re-check is the safety), or add a stepwise "walk the reference" recovery.

### M-6 — Challenge-gate parameters and feed mappings change with instant effect, inconsistent with the timelock discipline used everywhere else
`CompositeOracle.sol:219-237, 250-359`; `ChainlinkOracleFeed.sol:175-199`; `UniswapV3TWAPFeed.sol:249-254`. Feed *removal*, emergency overrides, quote-oracle failover, and reference refreshes are all timelocked — but `setDeviationThreshold` (can disable or insta-trip the dispute gate), `setChallengeDuration` (can retroactively stretch a pending challenge's fail-closed window, since finalize reads the live value), `setTokenOracleFeed*` (swaps a token's price source instantly, and is `onlyAuthorized` — a wider surface than the owner-only removals it sits beside), and `setTWAPPeriod` (30min→5min instantly, cheapening manipulation) all take effect in one transaction. **Fix:** apply the same schedule/execute pattern to these, or document why replacement is exempt.

### M-7 — Perpetual pre-armed unlock gives protectors a standing free-exit option (adverse selection)
`SplitRiskPool.sol:2153-2166, 2290-2292, 2352-2359`. `startUnlockProcess` sets `unlockRequestTime = now + unlockDuration`, and the withdraw gate only checks `!= 0 && <= now`; an elapsed unlock never expires. The code itself re-arms the notice after *partial* withdrawals (`:2359`), showing the intent is an ongoing notice — but a protector who arms the unlock at deposit is permanently "unlocked" after `unlockDuration` while still earning commissions. Every rational protector arms at deposit and exits the unreserved buffer the moment a drawdown becomes visible, socializing future losses onto only the protectors who didn't. **Fix:** make an elapsed unlock valid only for a bounded window `[t, t + N days]`, then require re-request — matching the partial-withdrawal re-arm.

### M-8 — Sub-minimum protector residual with live shares permanently blocks new backing deposits (engineerable pool DoS)
`SplitRiskPool.sol:1506-1513` (`_expireProtectorShareEpochIfDrained` reverts `ResidualProtectorBackingPending`, called from `depositBackingAsset:1773`); `sweepInactiveProtectorBackingDustFromFactory:2786-2788` (requires `totalProtectorShares == 0`). When `totalValueAtDeposit == 0`, `0 < totalProtectorTokens < backingMinDepositAmount`, and shares are non-zero, every `depositBackingAsset` reverts; the residual holder is the only party who can clear it (via a full withdraw gated on a 28-day unlock), and the factory dust-sweep refuses while shares exist. An attacker can deliberately leave a few-wei residual on an abandoned NFT and permanently deposit-block the pool for the cost of one fee round; the only remedy is governance lowering `backingMinDepositAmount` (undocumented as a recovery procedure). **Fix:** socialize the residual into the incoming deposit's share math (the existing formula at `:1777-1779` already handles this), or let governance clear the state without repricing the minimum.

### M-9 — `deactivateProtectorOnlyPool` forfeits the creator's bond even with no wrongdoing
`SplitRiskPoolFactory.sol:1107-1125` (calls `_forfeitCreationBond` → `defaultProtocolFeeRecipient`). A pool that only ever held protector backing (never launched a shielded position) can, after a 7-day delay, have its creator's bond **forfeited** rather than returned — even though this is an anti-griefing slot reclaim, not a penalty for abuse (`closePool` returns the bond; this path seizes it). **Fix:** use `_returnCreationBond` for the honest protector-only path, reserving forfeiture for the dust/griefing deactivations; at minimum document that this bond is forfeitable.

### M-10 — Deposit fee baseline and fee-accrual price use different price bases; phantom "yield" taxed at deposit
`SplitRiskPool.sol:1857, 1877` (`feeValueBaselineUsd = valueAtDeposit` from the *protected market* price) vs `:553-569, 1261` (`getPriceForFeeAccrual`, an ERC-4626-NAV price). If NAV sits above the protected market price at deposit (a normal in-band divergence), the first accrual sees `currentValue > baseline` with zero elapsed yield and charges commission/pool/protocol fees on the basis difference — up to ~80% of the divergence at parameter maxima (`ConstantsLib.sol:18-24`). The reverse divergence forgives real yield. Systematic, not random. **Fix:** initialize the fee baseline with the *same* price source used for accrual, keeping `valueAtDeposit` on the protected price for capacity/payout.

### M-11 — Withdrawal ACL vs deposit ACL asymmetry lets a creator shape one-sided pools
`SplitRiskPool.sol:1753, 1831` (deposit gate uses any non-zero `accessControl`) vs `:2933-2937, 2971-2975` (withdrawal gate only bites when the ACL admin is the governance timelock). A creator can set an ACL permitting only themselves, take a position, then flip the ACL to deny *deposits* for everyone else while the counterparty side can't be freely entered — a market-integrity/griefing lever, though not a fund-theft path (withdrawals stay open). The ACL is presented as a neutral "Morpho-style gate." **Fix:** emit an event / expose a view flagging whether the active ACL is creator- vs governance-controlled, so UIs can warn users.

---

## Low severity

### L-1 — `getUtilizationRatio` compares native units of two different tokens
`SplitRiskPool.sol:350-356` (public via `ISplitRiskPool.sol:74`). `(totalShieldedTokens * COLLATERAL_RATIO) / totalProtectorTokens` divides shielded native units by backing native units with no decimal normalization (supported decimals span 6–32) and no price — an 18/6-decimal pool inflates the result by 1e12. Verified: the "M-4 FIX" comment addresses precision ordering but not the unit mismatch. Not used in on-chain decisions, but it's public API and any integrator/keeper reading it gets a meaningless number. **Fix:** normalize by token scales, or remove it in favor of `getUtilizationRatioUsd`.

### L-2 — `getValueWithFallback` never actually falls back to the backup feed
`CompositeOracle.sol:1190-1251` vs `ICompositeOracle.sol:172-179`. The docstring promises "tries active feed, then backup if available… useful for `_checkCapacity` when primary is stale," but whenever the primary's `getPrice` fails, the deviation probe already flags a dispute and the function returns `(0,false)` early — the inactive-feed branch is effectively unreachable. Consumers expecting graceful degradation instead get a hard zero. **Fix:** either re-document as "returns (0,false) whenever the active feed is unavailable," or exempt this getter from treating pure primary-unavailability as a dispute when a healthy CB-capable backup exists.

### L-3 — `isPriceStale` implementations are systematically weaker than the corresponding `getPrice`, and inconsistent across feeds
`ChainlinkOracleFeed.sol:498-514` (no `answer > 0`, no `answeredInRound`, no bounds/`FeedBoundsStale`); `PythOracle.sol:503-525` (no sequencer gate, unlike Chainlink's `isPriceStale`); `ChainlinkOracleFeed.sol:528-537` / `SequencerUptimeGuard.sol:121-125` (`startedAt == 0` reports "up" in the view but `SequencerDown` in the price path). "Stale" is consumed as an independent signal (ERC-4626 protected path, TWAP quote staleness) and should be at least as strict as the price path. **Fix:** align the staleness checks with the price-path checks.

### L-4 — TWAP liquidity floor is a single global, unit-agnostic value; default is dust
`UniswapV3TWAPFeed.sol:68, 121, 261-266, 586-617`. `minimumAverageLiquidity` is one `uint128` shared by every pool, but Uniswap `L = sqrt(x·y)` scales with token decimals and price, so one floor cannot be meaningful across pairs; `DEFAULT_MINIMUM_AVERAGE_LIQUIDITY = 1_000_000` is dust. Also, the harmonic average counts *anyone's* liquidity, so an attacker meets any floor with a JIT position for the window, and `MIN_TWAP_OBSERVATION_CARDINALITY = 2` doesn't guarantee servable history (`observe(twapPeriod)` can hit `OLD`). **Fix:** per-token floor set from an observed baseline at `setTokenPool`; require cardinality consistent with `twapPeriod`.

### L-5 — `getEquivalentAmount` double-truncates through the 8-decimal USD intermediate
`CompositeOracle.sol:1362-1371`; same pattern `PythOracle.sol:878-887`. The intermediate USD value floors to 8 decimals before re-scaling into tokenB, so low-unit-price tokens or small `amountA` suffer material relative error, and the function returns `0` tokenB (instead of reverting) when the intermediate floors to zero. Division-by-zero itself is guarded. **Fix:** compute as one fraction `mulDiv(amountA * priceA, scaleB, scaleA * priceB)` with overflow guards.

### L-6 — Expired-epoch commission claims can fall through to the current epoch's reserve
`SplitRiskPool.sol:1546-1573, 1600-1628`. The epoch-reserve clamp only applies while `tracksExpiredEpoch` is true; once an expired epoch is fully settled, a residual `claimable` takes the `else` branch and decrements `currentEpochCommissionReserve` — consuming commissions owed to *current-epoch* protectors. Reachable amounts are dust today (protected by accumulation floors), but reserve segregation isn't enforced as an invariant. `getClaimableCommission` (`:1721-1726`) applies none of the clamps, so the view can overstate a claim. **Fix:** clamp expired-epoch claims to the epoch reserve unconditionally; never touch the current-epoch reserve for an expired claim; mirror the clamps in the view.

### L-7 — Factory creation-bond floor uses the unprotected `getValue` (disputed-price path)
`SplitRiskPoolFactory.sol:1433`. The bond USD floor calls `getValue` (not a circuit-breaker getter), so during an open dual-feed challenge on the backing token the floor is evaluated against the disputed price. Impact is minor (only minimum bond sizing at creation) but it's a live consumer of the disputed path flagged by the prior H-2/H-3. **Fix:** use the strict/protected valuation, or document the floor as best-effort.

### L-8 — `protectorWithdraw` emits `ShieldActivated`; event semantics inverted vs real activation
`SplitRiskPool.sol:2380`; `EventsLib.sol:16-19, 32`. Every protector *principal* withdrawal emits `ShieldActivated(...)`, while the real shield-activation (cross-asset `shieldedWithdraw`) emits `ShieldedWithdrawal` (`:2033`). Indexers/monitoring will misclassify routine protector exits as activations and have no clean signal for the economically critical events. **Fix:** emit the already-defined `ProtectorAssetWithdrawn` from `protectorWithdraw`, and `ShieldActivated` from the cross-asset branch.

### L-9 — PythEMAOracleFeed and UniswapV3TWAPFeed cannot be registered in CompositeOracle at all, despite docs/dead code implying they can
`CompositeOracle.sol:1385-1406` requires circuit-breaker support for both primary and backup unconditionally; neither feed exposes `supportsCircuitBreaker`/`getPriceUnsafe`, so every `setTokenOracleFeed*` reverts `CircuitBreakerNotSupported` (confirmed by `test/PoolOracleValidation.t.sol:174-185`). This makes the "market-responsive backup" design in `ICompositeOracle.sol:72-73` unusable with the feeds shipped for it, and renders `_calculateFeedDeviation` and the non-CB branches dead. **Fix:** decide intent — add the CB marker to these feeds, or delete the feeds/comments.

### L-10 — NFT operator-approval timestamp is per `(owner, operator)`, never invalidated on token movement
`ShieldReceiptNFT.sol:167-199`; `ProtectorReceiptNFT.sol:153-185`. The unlock-aware approval check holds correctly (a stale approval predates a freshly-minted locked token's unlock, so it's denied), so **no security impact** — but the timestamp isn't cleared when tokens leave the wallet, leaving lingering state. Documentation-only. **Fix:** document the single-timestamp-per-operator semantics.

### L-11 — `acceptPoolGovernanceTimelockTransfers` has a dead redundant branch
`SplitRiskPoolFactory.sol:281-289`. After the `!=` revert, the following `==` check is always true. No impact; remove for clarity.

### L-12 — Fee model taxes USD market appreciation, not just yield, when accrual falls back to market price
`SplitRiskPool.sol:1296-1314, 553-569`. "Yield" is defined as USD-value increase over a high-water baseline. For NAV-exposing oracles this approximates true yield; for any market-priced shielded token, pure market beta is taxed at up to ~80% while protection stays pinned to `valueAtDeposit` — an asymmetric deal (upside heavily taxed, downside protected only to original value) not stated in the contract docs, which say "yield." **Fix:** document explicitly and/or gate high commission/pool-fee parameters to NAV-capable oracles.

---

## Informational / consistency

**I-1 — Stale invariant docstring (`totalValueAtDeposit`).** `SplitRiskPool.sol:89` claims partial withdrawal adds back `pos.valueAtDeposit * remaining / pos.amount`; the code (`:2112`) uses `remaining / amountAfterFees` with `Rounding.Ceil`. The *code* is the correct convention; the comment would mislead a fix in the wrong direction. Fix the comment.

**I-2 — Dead spot-fallback path with contradicting comment.** `_validateDeposit` hardcodes `allowShieldedSpotFallback = false` (`:914`), making the whole `_getShieldedSpotPrice`/`_getShieldedSpotValue` path (`:534-538, 577-579, 860-862`) dead, while the B7 comment (`:528-533`) documents the opposite. Delete the fallback or fix the comment. Similarly, `_tryCalculateAndAccumulateFees` (`:1272-1284`) is never called yet reasoned about in `claimCommission`'s pause rationale (`:1643-1644`); and `protectorWithdraw`'s natspec (`:2247-2248`) still promises a "USD-based undercollateralization" block that `getAvailableForWithdrawal` (`:785-821`) deliberately doesn't implement.

**I-3 — Governance-surface accuracy.** Combining H-1 + M-1, the accurate statement is: *a single timelocked proposal can replace the implementation of every pool and the factory with arbitrary code and thereby reach all user funds.* The existing governance-surface summary lists "pool upgrades" but doesn't state they are unvalidated and fund-reaching. Update user-facing docs so "no single point of failure" isn't overstated — the timelock effectively *is* that point, mitigated only by delay + quorum.

**I-4 — Epoch-expired protector NFTs become unburnable zombies.** `SplitRiskPool.sol:2156-2160, 2274-2288`. After epoch expiry, active shares are 0, so both `startUnlockProcess` and `protectorWithdraw` revert and the NFT can never be burned (only its expired-epoch commission remains, settleable by keepers). Harmless, but per-token mappings never clean up and marketplaces show a live NFT with no exit. Add a burn/close path for fully-settled expired positions.

**I-5 — `CompositeOracle.supportsCircuitBreaker(token)` ignores live feed capability** (`:1328-1330`) — returns `_isTokenSupported[token]` even after the active feed loses CB support, contradicting its docstring; downstream probes get `true` then revert (fail-closed, but the marker lies).

**I-6 — `_tryGetNormalizedDisputeFeedPrice` is a pure alias** of `_tryGetNormalizedFeedPrice` (`CompositeOracle.sol:576-582`) yet its docstring describes an anchoring guarantee the alias doesn't add. Inline it or implement the described behavior.

**I-7 — Missing strict-price / CB markers on ERC4626 and TWAP feeds** mean strict-mode tokens can never be priced by them (`CompositeOracle.sol:1450-1460`); if intended, document it in the feed headers as Chainlink does.

**I-8 — `ERC4626OracleFeed.getPriceWithStaleness` is state-mutating** (emits an event, `:458`) — unusable from view contexts, inconsistent with every other getter, and silently uses the *unsafe* underlying path without disclosing it in natspec.

**I-9 — Interface/enumeration gaps.** `IShieldReceiptNFT`/`IProtectorReceiptNFT` omit methods the concrete contracts expose (`setPool`, `pool`, `positions`, `nextTokenId`); NFTs are plain `ERC721` (no `ERC721Enumerable`) while front-ends rely on `balanceOf` alone, so token IDs can't be enumerated on-chain. NFTs use `Ownable` (not `Ownable2Step`) — safe today because ownership is transferred atomically in `PoolCreationLib`, but a future refactor separating those steps would reintroduce the one-shot-`setPool` recovery gap. Also stale: TWAP header "quote oracle MUST return 8-decimal prices" (`UniswapV3TWAPFeed.sol:46`) is obsolete (code normalizes via `oracle.decimals()`), and `ChainlinkOracleFeed` duplicates `SequencerUptimeGuard` logic with slight drift — inherit the shared guard to prevent divergence.

---

## Status of selected prior findings (re-verified this pass)

- **May-18 H-1/H-2/H-3, M-6…M-10 (oracle):** verified present/correct in current code.
- **May-18 H-7 (approve-during-lock), H-8 (admin enumeration), M-3, M-14, L-8:** verified fixed.
- **May-18 H-6/B4 (fee-bucket overflow forgiving fees):** verified fixed — all three buckets revert `RewardAccumulationIncomplete` before the position debit (`SplitRiskPool.sol:1344-1352, 1122-1124`).
- **May-18 M-4 (cross-asset releases full cap, not actual payout):** unchanged; now carries a justifying comment (`:2009-2012`) that full-cap release is intended. Internally consistent, but the consequence noted in M-4 (freed "phantom" cap enlarges the protector buffer when backing appreciates) still holds.
- **Prior I-12 (unvalidated `_authorizeUpgrade`):** **still unaddressed** for pools and factory — escalated here as H-1/M-1.

---

## Suggested remediation order

1. **H-1 / M-1** — add on-chain implementation validation (layout-hash allowlist or version registry) to pool and factory `_authorizeUpgrade`; update governance docs (I-3). Highest leverage: converts "arbitrary code over all funds" into a constrained upgrade.
2. **H-2** — governance-timelocked reset for `shieldedTokenTransferIntegrityBroken` + block/opt-in deposits while set.
3. **M-2 / M-5 / M-4** — remove the manual-refresh and timelock-bypass footguns in the oracle liveness paths (permissionless bounds refresh; recoverable ERC-4626 band; no instant `registerVault` re-anchor).
4. **M-8 / M-7** — fix the residual-blocks-deposits DoS and bound the pre-armed unlock window.
5. **M-9 / M-10 / M-6** — bond-return correctness, fee-baseline price-source consistency, and timelock parity for oracle parameter setters.
6. Low/Info — the docstring/invariant contradictions (I-1, I-2) are cheap and high-value because they mislead future fixes; batch the rest.

---

## Sources (external research, performed by Claude Fable 5)

- OpenZeppelin — [ERC-4626 Tokens in DeFi: Exchange Rate Manipulation Risks](https://www.openzeppelin.com/news/erc-4626-tokens-in-defi-exchange-rate-manipulation-risks)
- Euler Finance — [Exchange Rate Manipulation in ERC-4626 Vaults](https://www.euler.finance/blog/exchange-rate-manipulation-in-erc4626-vaults) · [Donation Attacks](https://docs.euler.finance/security/attack-vectors/donation-attacks/)
- Zellic — [Exploring ERC-4626: A Security Primer](https://www.zellic.io/blog/exploring-erc-4626/)
- Cyfrin — [Chainlink Oracle DeFi Attacks & Vulnerabilities](https://medium.com/cyfrin/chainlink-oracle-defi-attacks-93b6cb6541bf) · CodeHawks — [min/max answers never checked](https://codehawks.cyfrin.io/c/2024-05-beanstalk-the-finale/s/506)
- 7BlockLabs — [Chainlink Oracle Security Best Practices: staleness, deviation, circuit breakers](https://www.7blocklabs.com/blog/chainlink-oracle-security-best-practices-for-price-feeds-staleness-deviation-and-circuit-breakers)
- Ackee Blockchain — [Chainlink Data Feeds, Security Researcher's Perspective](https://ackee.xyz/blog/chainlink-data-feeds/) · [Resupply Hack Analysis](https://ackee.xyz/blog/resupply-hack-analysis/)
- Zealynx — [Proxy Security Checklist: 33 Critical Upgradeability Checks](https://www.zealynx.io/blogs/proxy-upgradeability-security-checklist)
- Octane — [Upgradeable Smart Contracts: Patterns, Pitfalls and CI/CD Safeguards](https://www.octane.security/post/upgradeable-smart-contracts-proxies-patterns-pitfalls-cicd-safeguards)
- CertiK — [Upgradeable Proxy Contract Security Best Practices](https://www.certik.com/resources/blog/upgradeable-proxy-contract-security-best-practices)

*Every code finding above was re-verified against `main` at review time. Line numbers reference the working tree as of the commit this document is added in.*
