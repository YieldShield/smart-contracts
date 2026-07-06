# Multi-Agent Security & Consistency Review — 2026-07-06

**Method:** Three parallel review agents (core pool + libraries; oracle stack; governance/ACL/NFTs/deployment) plus one external-research agent (recent exploit patterns, dependency advisories, 2025–26 best practices). All agents read the eight prior audit/review documents first and were instructed to report only new issues or residuals of recent fixes. Every finding below was independently re-verified against `main` source before inclusion.

**Baseline:** `b82f5c4` (Normalize transfer probe storage snapshot). Primary target surface: the ~19 fix commits landed after the 2026-07-04 follow-up review, as the least-reviewed code.

**Summary:** No Critical or High issues found. The round-2 fixes reviewed are correctly implemented. One Medium (a one-sided circuit breaker introduced by a recent fix), five Lows, and a set of consistency/informational items remain.

---

## M-1 (Medium) — ERC4626 `previewRedeem` leg bypasses the share-rate deviation band downward

**Location:** `contracts/oracles/ERC4626OracleFeed.sol` — `_getPriceFromConfig` (~L526–532), `_redeemableAssetsPerShare` (~L563–565). Behavior pinned by `test/ERC4626OracleFeed.t.sol:200-212`.

Commit `8f3a46c` ("Check ERC4626 bands against accounting NAV") split the conservative rate: the deviation band (`maxSharePriceDeviationBps`, default 5 %, cap 20 %) is now applied only to `convertToAssets`; `previewRedeem` is taken raw and `min()`-ed in afterwards:

```solidity
uint256 boundedAccountingAssetsPerShare =
    _boundedAssetsPerShare(vault, accountingAssetsPerShare, config, clampUpwardToReference);
uint256 redeemableAssetsPerShare = _redeemableAssetsPerShare(vault, config.shareUnit);
uint256 assetsPerShare = redeemableAssetsPerShare < boundedAccountingAssetsPerShare
    ? redeemableAssetsPerShare
    : boundedAccountingAssetsPerShare;
```

Previously a `previewRedeem` collapse reverted with `SharePriceDeviationTooHigh` (fail-closed). Now any vault state where `previewRedeem` drops — withdrawal-queue mode, exit-fee escalation, liquidity-dependent haircuts, states third parties can often force by draining idle vault liquidity — flows into the **protected** `getPrice` unbounded. The new regression test itself asserts a 50 % haircut yields a 50 % price. The circuit breaker is therefore one-sided: `convertToAssets` manipulation is capped at ±band, downward `previewRedeem` moves are uncapped.

**Impact:** solvency is not directly broken (cross-asset payouts key off `valueAtDeposit`), but during a forced-haircut window: (a) new shield depositors permanently lock in an undervalued `valueAtDeposit`; (b) less collateral is reserved per deposit; (c) fee-accrual baselines distort downward, inflating later "yield" fees.

**Recommendation:** apply the band floor to the redeemable leg as well — revert (or clamp) when `redeemableAssetsPerShare < reference − deviation`, keeping the in-band `min()` for ordinary redemption fees. If deep-haircut vaults must remain priceable, make that an explicit per-vault opt-in rather than the silent default. This intersects directly with the Venus wUSDM (Feb 2025) and sDOLA/Llamalend incident class, where the oracle reading a manipulable vault rate was the attack vector.

---

## L-1 (Low) — Feed-only composite removal silently erases `tokenRequiresStrictProtectedPrice`

**Location:** `contracts/SplitRiskPoolFactory.sol` — `_removeCompositeOracleFeedOnly` (~L1848–1857).
*Found independently by two agents.*

Commit `35a54ab` made `removeCompositeOracleTokenFeed` non-delisting (the token stays whitelisted, `tokenInfo` preserved for re-registration), but kept the `delete tokenRequiresStrictProtectedPrice[token];` copied from the full-delisting path:

```solidity
info.primaryOracleFeed = address(0);
info.backupOracleFeed = address(0);
delete tokenRequiresStrictProtectedPrice[token];   // leftover from the delisting alias
emit CompositeOracleTokenFeedRemoved(token);
```

Under the old (delisting) semantics the delete was safe; now a later `setCompositeOracleTokenFeed` restores pricing in one call and validates against the now-false flag. Consequences: every pool created between feed re-registration and a separate `setTokenRequiresStrictProtectedPrice(token, true)` call permanently pins `strict = false` (pools snapshot the flag at initialize); a `refreshStrictProtectedBackingPriceFlag()` call on an existing pool would downgrade it; no `TokenStrictProtectedPriceRequirementUpdated` event is emitted, so monitoring keyed on strict-flag changes misses the downgrade; and the CompositeOracle-side `setStrictCircuitBreakerRequired` flag is not synced, so factory and oracle policy diverge. The project previously rated silent strict-pricing downgrades High (H-5) and mid-flight flips Medium (M-5), so this residual matters even though both operations are timelocked.

**Test gap:** `testFactoryCanRemoveCompositeOracleFeedWhenAuthorized` (`test/SplitRiskPoolFactory.t.sol:899-928`) asserts `tokenInfo` survives but never asserts the strict flag across the remove/re-add cycle.

**Recommendation:** preserve the flag across feed-only removal (strict validation re-runs at re-registration, so there is no stale-config hazard), or if clearing is intended, emit `TokenStrictProtectedPriceRequirementUpdated(token, previous, false)` and sync the composite oracle. Add the missing test assertion either way.

---

## L-2 (Low) — `ERC4626OracleFeed.isPriceStale` not aligned with its protected path

**Location:** `contracts/oracles/ERC4626OracleFeed.sol` — `isPriceStale` (~L468–478).

Commit `8c97e0b` aligned `PythOracle.isPriceStale` with the full protected path (`try this.getPrice(token)`), and the composite's M-9 fix fails closed when the helper is absent — both on the principle that the stale signal must not report "fresh" while `getPrice` reverts. The ERC4626 feed still checks only the sequencer gate and underlying-oracle staleness:

```solidity
(isStale, publishTime) = _checkUnderlyingStaleness(config.underlying);
```

A vault in band breach (`SharePriceDeviationTooHigh`), below `minimumSupply`, or below `MIN_VAULT_VALUE_USD` reports `(false, publishTime)` while every getter reverts, and `CompositeOracle.isPriceStale` forwards that "fresh" answer to consumers (monitoring, `UniswapV3TWAPFeed._quoteTokenPriceStaleness`, nested staleness chains). Same gap class fixed twice elsewhere (Pyth `8c97e0b`, Chainlink `f3ae466`).

**Recommendation:** mirror the Pyth pattern — after the underlying staleness check, `try this.getPrice(vault)` and report stale on revert (mind staticcall-safety, as the composite probes this helper via `staticcall`).

---

## L-3 (Low) — `deactivateDustPool` cannot clear the griefing state it documents, and forfeits the bond

**Location:** `contracts/SplitRiskPoolFactory.sol` — `deactivateDustPool` (~L1134–1153); `contracts/SplitRiskPool.sol` — `sweepInactiveProtectorBackingDustFromFactory` (~L2950–2984).

The NatSpec describes an "escape hatch for pool-cap griefing" where "protector backing is at or below its configured minimum", but the sweep requires `totalProtectorShares == 0` and `totalBackingTokenBalance == totalProtectorTokens`. Tracing state transitions: a live sub-minimum protector (the actual griefing case) has shares ≠ 0 → revert; once dust is epoch-reserved by `_expireProtectorShareEpochIfDrained`, the balance invariant fails → revert. The only reachable sweepable state is the ≤1-share-worth ceil-clamp leftover from a protector partial exit — a few wei. So the function is effectively `deactivatePool` plus a wei-level sweep, yet unlike `deactivateProtectorOnlyPool` (which handles the real griefing case after 7 days and returns the bond) it calls `_forfeitCreationBond`. An operator following the doc comment would reach for the wrong tool and burn an honest creator's bond, or find the call reverts.

**Recommendation:** remove the function, or rewrite the NatSpec to describe the only state it can clear and align bond handling with the other deactivation paths. If kept, add a test constructing the ceil-clamp leftover state (only revert paths are tested today).

---

## L-4 (Low) — `pyth-sdk-solidity` pinned to a deprecated, unsupported repository

**Location:** `.gitmodules`, `lib/pyth-sdk-solidity` @ v2.2.0.

The submodule tracks `github.com/pyth-network/pyth-sdk-solidity`, which Pyth declared outdated/unsupported with removal announced for August 2025; the maintained distribution is the npm package `@pythnetwork/pyth-sdk-solidity` (4.x line). The `IPyth`/`PythStructs` surface used here is stable, so this is a supply-chain/maintenance risk rather than a live API break — but fresh `--recurse-submodules` clones and CI break if the repo is removed, and no security fixes flow to v2.2.0.

**Recommendation:** vendor the interfaces or migrate the dependency to the npm package (pin 4.x), diffing the `IPyth` surface during the swap.
Sources: [pyth-sdk-solidity repo notice](https://github.com/pyth-network/pyth-sdk-solidity), [npm package](https://www.npmjs.com/package/@pythnetwork/pyth-sdk-solidity).

---

## L-5 (Low, operational — extends known I-4) — Withdrawal ACL fails open across a governance-timelock rotation

**Location:** `contracts/SplitRiskPool.sol` — `_withdrawalAccessControlActive` / `_accessControlAuthorityIsGovernance` (~L3171–3201).

Withdrawal gating is active only while the ACL contract's authority equals the *current* `_governanceTimelock`. During a timelock rotation, an ACL still owned by the old timelock silently disables withdrawal restrictions until governance re-points ACL ownership; deposits fail closed by contrast. Deliberate and documented, but operator-dependent.

**Recommendation:** codify "transfer ACL ownership to the new timelock *before* `acceptGovernanceTimelock`" as a hard runbook step, and add a regression test asserting the fail-open window so it isn't later "fixed" into fund-locking fail-closed behavior.

---

## Informational

**I-1 — Dead `allowShieldedSpotFallback` plumbing.** `SplitRiskPool.sol` `_validateDeposit` (~L944) declares `bool allowShieldedSpotFallback = false;`, never mutated, making `_getShieldedSpotValue` / `_getShieldedSpotPrice` unreachable from state-changing paths while masquerading as a live knob. Remove or wire deliberately — dead pricing paths are where refactors re-enable unsafe getters by accident.

**I-2 — Event field semantics drift.** `ShieldedAssetDeposited`/`ProtectorAssetDeposited` declare `tokensIssued` but receive the NFT `tokenId` (`SplitRiskPool.sol:1941, 2027`); `RewardsClaimed` reports fees charged, not rewards received (~L2386); `setPoolFeeRecipient` re-emits `ProtocolFeeRecipientUpdated` (~L1497) so monitors can't distinguish recipient types. ABI-compatible; batch into the deferred I-16 event-schema break.

**I-3 — Chainlink strict-price marker satisfied by sentinel bounds.** `ChainlinkOracleFeed.sol` (~L400–453): aggregators shipping `minAnswer = 1, maxAnswer = int192.max` pass `supportsStrictProtectedPrice`, but the runtime bound check can never trip — strict mode is nominal for such feeds. Flag/emit when cached bounds are the known sentinels so operators don't count on depeg protection there.

**I-4 — Pyth composite product can round to zero on the unsafe path.** `PythOracle.sol:675` `Math.mulDiv(basePrice, quoteUsdPrice, 1e8)` has no zero guard, contradicting the file's own fail-closed zero-price policy. Protected path and composite normalization catch it downstream; one-line `InvalidPrice` revert closes the unsafe-getter gap.

**I-5 — `finalizeChallenge` comment overstates failover.** `CompositeOracle.sol:752-754` says the backup "becomes the feed used by protected pool valuation paths", but with a live-but-deviant primary the token stays `OraclePriceDisputed` after finalization (fail-closed, tested). Update the comment and document the governance runbook (single-feed the backup) for that state.

**I-6 — `setPoolImplementation` is a guaranteed no-op emitting a success-looking event.** `SplitRiskPoolFactory.sol:191-198` reverts for every address except the pinned implementation yet emits `PoolImplementationPinChecked`. Rename to an assertion (`assertPinnedPoolImplementation`) or drop it.

**I-7 — Non-upgradeable `ReentrancyGuard` in the upgradeable base.** `ProtocolAccessControlUpgradeable.sol:8,16` imports the plain-storage variant behind UUPS proxies. Inert today (upgrades permanently disabled, layout snapshot-gated in CI, `__gap[47]` math correct) — flagged so any future re-enabling of upgradeability accounts for the slot.

---

## Consistency

**C-1 — TWAP failover expiry boundary is inclusive** (`UniswapV3TWAPFeed.sol:344` uses `>` where every other scheduled action uses `>= expiresAt`). Cosmetic 1-second divergence in an otherwise uniform pattern.

**C-2 — Fee-accrual "capability" pairing check is a liveness probe** (`CompositeOracle.sol:1141-1175`, commit `065fbae`): support inferred from a live `getPriceForFeeAccrual` call, so a transient revert-with-data at config time blocks `setTokenOracleFeedDual` entirely. Consider a static capability marker like `supportsCircuitBreaker(address)`.

**C-3 — Stale deploy-summary instruction.** `script/DeployYieldShieldProduction.s.sol:600` tells the bootstrap holder to self-delegate, but `YSToken` self-delegates at construction (`YSToken.sol:24`). Update the log line.

**C-4 — `deployments/421614.json` omits governance + implementation contracts** (no YSToken/Timelock/Governor/implementation entries), and `DeploymentMetadata.t.sol` doesn't check completeness. Testnet-only; backfill so governance wiring is auditable from metadata.

**C-5 — Aderyn is report-only in CI.** Slither has a genuine failing gate (`slither-gate`, `--fail-high`) and the storage-layout guard gates; Aderyn runs `continue-on-error`. Acceptable; add a severity gate only if parity is wanted.

---

## External research notes (2025–26)

- **EIP-7702 (Pectra): no action required.** The codebase uses no `tx.origin == msg.sender` or `code.length == 0` gates on user-facing paths; all `code.length` checks are "must-be-contract" assertions on governance-set infra addresses, which remain safe. Keep it that way for future user-supplied-address paths.
- **Chainlink L2 sequencer feed:** `SequencerUptimeGuard._checkSequencerUptime` correctly handles the Arbitrum `startedAt == 0` quirk, rejects future `startedAt`, and fails closed on known L2 chain IDs — textbook implementation. Operationally confirm the hardcoded Robinhood chain IDs and the fixed 1 h grace period against real feed catch-up times.
- **OpenZeppelin 5.6.1:** past the TimelockController executor-role advisory (GHSA-fg47-3c2x-m2wr); recent OZ patches touched `SignatureChecker`/`ERC165Checker` ill-encoded-return handling — neither is used in this codebase. Deployment wiring should keep the executor role non-open (not `address(0)`); `YSGovernor._validateReplacementTimelock` already enforces sole-admin/proposer/executor/canceller invariants.
- **ERC4626 oracle manipulation (Venus wUSDM 2025, sDOLA/Llamalend):** the feed's defenses (min-supply and min-USD gates, `min(previewRedeem, convertToAssets)`, timelocked reference-rate clamp) are above standard — M-1 above is the one seam left open.
- **Permissionless Pyth updates + same-tx interaction:** anyone can push a price update in the transaction that triggers a value-moving call; the protected path's spot/EMA circuit breaker and confidence gates are the mitigations — keep per-token `maxPriceAge` well below the 24 h cap and treat `maxEmaConfidenceBps = 1000` as an upper bound, not a default to reach.

---

## Verified sound (regression checks on recent fix commits)

- Expired-backing reserve settlement (`7e5b434`, `0cd7562`): governance-while-paused path, keeper path, pause gating, and post-transfer `ownerOf` re-checks all correct and tested.
- Pool implementation codehash pinning (`949cd6f`): reverts on mismatch in `_createPool`; no `selfdestruct` in `SplitRiskPool`, so metamorphic bypass is unreachable.
- Governor timelock replacement (`YSGovernor.sol:183-205`): enforces the sole-`DEFAULT_ADMIN` invariant in addition to codehash and sole proposer/executor/canceller — the crafted-replacement gap probed for is closed.
- Transfer-integrity probe reuse (`7e940cf`, `b82f5c4`): pool-gated `returnToken`, both-legs balance-delta checks, pre-funded-dust handled, governance reset path sound.
- NFT operator-approval escalation fix (H-7 + L-10/N-4 follow-ups): `approvalTimestamp >= unlock && >= movement` with same-block re-approval preserved; state written before `_safeMint`.
- Protector share math: ledger-based accounting (no donation-inflation surface), ceil-clamped exits round against the withdrawer by ≤1 share, reward dust bounded by `REWARD_PRECISION = 1e36` across 6–32 decimals.
- Pyth confidence rounding (`PythEMAOracleFeed` vs `PythOracle`): checked and equivalent (`conf·10⁴ > price·maxBps` ≡ ceil-rounded comparison) — candidate finding dropped.

## Notably well done

- Both-legs balance-delta discipline on every transfer (fee-on-transfer behavior measured, never assumed).
- Epoch-based loss socialization that preserves drained-epoch protector claims instead of confiscating them, with a dedicated 25+ case regression suite.
- Uniform fail-closed oracle posture: sequencer gates on every leg, zero-price truncation reverts, dispute gates on both value-moving legs, pinned strict-price snapshots, nonce-bound emergency overrides.
- Production bootstrap asserts codehashes, UUPS slots, sole timelock role membership, and zero residual authorized callers before returning; initializer front-running is structurally impossible.
