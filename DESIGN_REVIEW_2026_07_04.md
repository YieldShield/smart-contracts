# YieldShield Protocol — Multi-Agent Follow-Up Review

**Date:** July 4, 2026
**Scope:** `contracts/` tree — `SplitRiskPool`, `SplitRiskPoolFactory`, oracle stack, receipt NFTs, `YSToken`/`YSGovernor`, timelock, access control, libraries.
**Method:** Four-phase multi-agent review — one orientation pass, five parallel dimension reviewers (accounting, oracle, upgrade/access, NFT/token/libraries, cross-cutting consistency), adversarial per-finding verification, and a web-research lens on 2025–2026 attack patterns. Every raw finding was independently re-read at `file:line` by a skeptical verifier prompted to *refute*; anything not confirmable in current source was dropped.
**Focus of this pass:** This review runs *after* the 31 remediation commits that landed on `main` following `DESIGN_REVIEW_2026_07_02.md`. Those commits map one-to-one onto the prior review's findings (e.g. `89ed2fe` → H-1, `0f21ea3` → H-2, `cc9ea74` → M-2, `6774d80`/`deda7c0` → M-4/M-5, `08ec278` → M-7, `92e729c` → M-8). The goal here is therefore **(a) verify the fixes are correct and complete, (b) hunt for regressions the fixes introduced, and (c) surface genuinely net-new issues** — not to re-run the prior audits.

---

## Model attribution

- **Correction added July 10, 2026:** the original Fable 5 attribution was inaccurate. The session and its inherited reviewer/verifier subagents ran on **Claude Opus 4.8**. The historical commit message also contains the inaccurate Fable 5 attribution; it is left unchanged to avoid rewriting published `main` history.
- Web research (ERC-4626 manipulation, Chainlink bounds/sequencer, Pyth confidence, Uniswap V3 TWAP, UUPS upgrades, DAO governance capture) was performed in that Claude Opus 4.8 session; sources are listed at the end.
- Every code-level finding below was re-verified against the current `main` source before inclusion. Findings that could not be confirmed in code were discarded (3 of 23 raw findings were refuted and dropped).

---

## Executive summary

The 31 remediation commits are, on the whole, **clean and correctly scoped.** The two prior Highs are genuinely closed for deployed contracts: `_authorizeUpgrade` now hard-reverts on both the pool and the factory (H-1), and the shielded-token transfer-integrity path now reverts on any discrepancy instead of latching a permanent kill-switch, with a governance-gated, round-trip-probed recovery (H-2). Line-by-line auditing of the accounting fixes (`92e729c`, `2921f44`, `08ec278`, `6f9881c`, `0f21ea3`) found **no fund-draining regression**, and the round-trip probe helper (`_requireUntaxedShieldedRoundTrip`) is well-constructed.

The net-new risk this pass surfaces is a **byproduct of the fixes themselves**, in two forms:

1. **One Medium value-transfer issue.** The M-8 fix (`92e729c`, "Sweep residual protector dust on fresh deposits") resolved a DoS by **seizing** the residual backing to the protocol fee recipient rather than socializing it — which can permanently confiscate honest, still-recoverable protector principal in realistic states. This trades a liveness bug for a (bounded) value-loss bug, contrary to the prior review's explicit recommendation to preserve value.

2. **A cluster of fix-induced regressions and stale docs.** Several fixes updated executable code but left the surrounding NatSpec/comments describing the *old* behavior (unlock-window, fee-on-transfer support, upgrade/reinitializer process), one fix made a previously non-reverting public view oracle-dependent, one made a fresh same-block NFT approval unusable, and the H-1 freeze left the storage-gap/reinitializer scaffolding as dead, self-contradicting documentation.

Additionally, one remnant of H-1 survives: **`setPoolImplementation` still hands unvalidated arbitrary code to every *future* pool** — the blast radius shrank from "all pools" to "all pools created after the change," but the unvalidated-implementation power is not fully gone.

| Severity | Count | Notes |
|----------|-------|-------|
| Medium | 1 | Net-new (M-8 fix side effect) |
| Low | 6 | 4 net-new (3 fix-regressions + 1 narrowed-H-1), 2 residual-of-known |
| Informational | 11 | 6 net-new, 5 residual-of-known |

**Nothing found in this pass is independently fund-draining under the current trust model** (governance = timelock, oracles fail closed). The Medium is the only value-loss item, and it requires a specific drained-pool state plus a fresh deposit to trigger.

---

## Medium severity

### N-1 (Medium, net-new) — M-8 dust-sweep fix confiscates honest protectors' residual backing to the protocol fee recipient

**Where:** `contracts/SplitRiskPool.sol:1558-1563` (`_expireProtectorShareEpochIfDrained`), reachable from `depositBackingAsset`.

**What the fix did.** Commit `92e729c` resolved M-8 (a sub-minimum residual permanently blocking new backing deposits) by adding a "sweep" branch. When only below-minimum backing dust remains with live shares (`totalValueAtDeposit == 0 && 0 < totalProtectorTokens < backingMinDepositAmount`), a fresh depositor's call sets `totalProtectorTokens = 0` and **transfers the entire residual `currentProtectorTokens` out to `poolConfig.protocolFeeRecipient`.** The old-epoch shareholders whose principal this represents are moved into the expired epoch in the same call.

**Why it's a problem.** After the sweep, `_getActiveProtectorPositionShares` returns 0 for those positions (epoch mismatch, `:366-367`), so:
- `protectorWithdraw`'s dust-exit path is closed — it requires `totalProtectorTokens != 0`, which is now 0 (`:2208`);
- `startUnlockProcess` reverts `InsufficientTokenBalance` (`:2191-2192`);
- only leftover *commission* remains claimable via `settleExpiredProtectorPosition` — **there is no principal-recovery path for an expired epoch.**

The sweep condition checks only aggregate pool state; it never checks per-holder recoverability. Realistic states exist where at least one holder still had a non-zero `positionAmount` (e.g. a majority-share holder, or two roughly-equal holders whose residual/share ratio rounds non-zero) and could have recovered principal via normal `protectorWithdraw` *before* a fresh deposit front-runs it. In those states, honest, recoverable principal is transferred to `protocolFeeRecipient` with **no consent, no per-holder event** (only an aggregate `ProtectorResidualBackingSwept`), and **no recovery**.

The seizable amount is bounded by `backingMinDepositAmount`, but `updatePoolConfig` (`:2588-2600`) only enforces `min < max <= MAX_SAFE_ACCUMULATION`, so governance can raise the ceiling well above dust.

**Honest nuance (why Medium, not High).** In many residual states every holder's proportional claim already rounds to 0 — that is precisely the condition under which dust-exit becomes available — so the residual was often unrecoverable even before the sweep. The confiscation only bites the subset of drained states where a holder's claim was still non-zero. It is governance/deposit-triggered rather than attacker-triggered, and bounded in size. Still, the prior review's M-8 explicitly recommended **socializing the residual into the incoming deposit's share math** (value-preserving — the formula already exists at `depositBackingAsset:1807-1809`) or letting governance clear the state; confiscation to the fee recipient was not the intended remedy.

**Suggested fix.** Replace the transfer-to-`protocolFeeRecipient` with either (a) socializing `currentProtectorTokens` into the incoming depositor's share basis, or (b) leaving the residual in-pool and clearing only the *accounting* flag that blocked deposits, so the original holders retain a claim. If a sweep-out is genuinely required, gate it behind `onlyGovernance` and emit a per-holder-attributable event.

---

## Low severity

### N-2 (Low, net-new) — Transfer-integrity recovery probe can be satisfied by a conditional-tax token that still taxes users

**Where:** `contracts/SplitRiskPool.sol:2890` (`resetShieldedTokenTransferIntegrity`), helper `:988-1008`.

`resetShieldedTokenTransferIntegrity` clears the H-2 suspension after `_requireUntaxedShieldedRoundTrip(probeAmount)` round-trips `probeAmount` from the pool to a freshly-deployed `TransferIntegrityProbe` and back. **Both legs have the pool as an endpoint**, so the probe proves only that the token round-trips untaxed *for the pool's own transfer of `probeAmount`* — not for arbitrary user withdrawals. A fee-on-transfer token that exempts the pool address (a common whitelist pattern), or taxes only above a threshold (and `probeAmount` is governance-chosen and can be tiny), passes the probe while ordinary user exits are still taxed. The zero-balance branch (`:2896-2905`) clears the flag with *no* probe at all.

**Strong mitigations keep this Low:** `depositShieldedAsset` reverts on any `received != depositAmount` (`:1877-1879`), so no new taxed positions can form; `_markShieldedTransferIntegrityIfReduced` (`:981-986`) re-arms the flag when a same-asset exit under-delivers, so the system self-heals — a user eats at most one under-delivered exit. Everything is `onlyGovernance` (timelock). Consider documenting that the probe is a pool-side sanity check, not a general untaxed-transfer proof.

### N-3 (Low, net-new — regression from the M-7 fix) — `protectorWithdraw` NatSpec contradicts the new bounded unlock window

**Where:** `contracts/SplitRiskPool.sol:2281` (docstring) vs `:2333` + `:2215-2218` (gate).

The M-7 fix (`08ec278`) changed the withdraw gate to `_isProtectorUnlockActive`, which now also requires `block.timestamp <= unlockRequestTime + PROTECTOR_UNLOCK_WINDOW` (7 days, `ConstantsLib.sol:37`). The docstring still says the only requirement is "unlock process to be completed (`unlockRequestTime <= block.timestamp`)", and `@custom:error InsufficientUnlockedTokens` omits the window-expiry case. A protector who lets the window lapse must re-arm and wait the full `unlockDuration` (up to 365 days) again — the opposite of what the docs promise. Comment-only; update the NatSpec.

### N-4 (Low, net-new — regression from the L-10 fix) — Same-block NFT re-approval cannot authorize a transfer

**Where:** `contracts/ShieldReceiptNFT.sol:172/181/208`; identical in `contracts/ProtectorReceiptNFT.sol:158/167/194`.

The L-10 fix (`fff71bc`) added a per-token `_tokenMovementTimestamp` and gates operator authorization on `approvalTimestamp > _tokenMovementTimestamp[tokenId]` — a **strict** `>` on second-granularity `uint64` timestamps. If a recipient receives a token and re-grants `setApprovalForAll` in the **same block**, `approvalTimestamp == _tokenMovementTimestamp`, so `T > T` is false and the fresh, legitimate approval is denied until the next second. The fix's own test works around this with `vm.warp(block.timestamp + 1)` before re-approving, confirming the behavior. This breaks atomic receive-and-approve-and-transfer flows (marketplaces, routers). It fails closed (no security impact), but is a usability regression. Consider `>=` against the movement timestamp, or tracking approval *block number* alongside timestamp.

### N-5 (Low, net-new — narrowed remnant of H-1/M-1) — `setPoolImplementation` still hands unvalidated arbitrary code to every future pool

**Where:** `contracts/SplitRiskPoolFactory.sol:185-189`, `_validatePoolImplementation:1732-1739`.

The H-1 freeze made *existing* proxies immutable, but new pools are freshly-deployed `ERC1967Proxy` instances pointing at `splitRiskPoolImplementation` (`PoolCreationLib.sol:69`). `setPoolImplementation` still validates only "is UUPS-shaped" (`code.length != 0` and `proxiableUUID()`), with no storage-layout hash or version-registry pin. A malicious (timelocked) `setPoolImplementation` therefore still hands arbitrary code to **every pool created after the change**. The blast radius shrank from "all pools" to "all future pools," but the unvalidated-implementation power is not gone. Add a storage-layout allowlist or a monotonic version registry to `setPoolImplementation`.

### K-1 (Low, residual of L-6) — `getClaimableCommission` view still omits the `accumulatedCommissions` clamp

**Where:** `contracts/SplitRiskPool.sol:1746-1756`.

The L-6 fix (`2921f44`) mirrored the *expired-epoch reserve* clamp into the view but **not** the `if (claimable > accumulatedCommissions) claimable = accumulatedCommissions` clamp that both state paths apply (`:1577`, `:1629`). For a current-epoch position whose MasterChef-computed `claimable` exceeds the actual `accumulatedCommissions` pot (divergence from per-share rounding dust and orphaned-commission redirects at `:1165-1171`/`:1201-1209`), the view **overstates** what `claimCommission` will pay. Bounded, view-only, affects UIs/integrators. The prior L-6 fix directive was "mirror the clamps (plural)"; only one of two was mirrored.

### K-2 (Low, residual of L-3) — `getSequencerStatus` reports "up + grace passed" for `startedAt == 0`

**Where:** `contracts/oracles/SequencerUptimeGuard.sol:121-125`; duplicate in `ChainlinkOracleFeed.sol:548-557`.

The L-3 alignment (`f3ae466`) added `_isSequencerUnavailableForStaleness` (correctly treats `startedAt == 0` as unavailable, `:560-580`) but did **not** align the monitoring view `getSequencerStatus`. With `startedAt == 0` the view computes `timeSinceUp = block.timestamp - 0` (huge) → `gracePeriodPassed = true` and `isUp = true`, while the price path reverts `SequencerDown` (`:142`). A dashboard reading the view sees green while every price read reverts. View-only; `startedAt == 0` is rejected at registration so it only arises from a later malformed round. Add the `startedAt == 0` guard to the view.

---

## Informational

Net-new consistency/dead-code items introduced or exposed by the fixes:

- **N-6 (net-new) — Stale factory upgrade docs after the H-1 freeze.** `SplitRiskPoolFactory.sol:129-131` and `:159-161` still instruct future maintainers to "append new storage below this marker and initialize newly-added config through a reinitializer called with `upgradeToAndCall`," but `_authorizeUpgrade` now reverts `UpgradeDisabled()` (`:1846-1848`), making that path permanently unreachable. `SECURITY.md:88-89` documents the *real* process (fresh deployment). Same dead scaffolding on the pool: the `__gap` and storage-layout-"valid on upgrade" comments (`SplitRiskPool.sol:3117-3124`) now document a capability that no longer exists. Remove or annotate the upgrade/reinitializer NatSpec and the storage-gap rationale to reflect immutability.
- **N-7 (net-new) — Dead error `ResidualProtectorBackingPending`.** `92e729c` removed the only `revert` site; the selector remains defined at `ErrorsLib.sol:117`, thrown nowhere. Remove it.
- **N-8 (net-new) — Shielded-deposit comment claims fee-on-transfer support the code now rejects.** `SplitRiskPool.sol:1875` comment says "balance-delta for fee-on-transfer tokens," but the H-2 fix made `:1877` revert on any `received != depositAmount`. The comment is a stale copy of the backing-path semantics (`:1792`); fix-on-transfer shielded tokens are intentionally unsupported now. Correct the comment.
- **N-9 (net-new) — `getUtilizationRatio()` became oracle-dependent.** The L-1 fix (`99ddff4`) aliased it to `getUtilizationRatioUsd()`, which reads the protected backing oracle and **reverts** during staleness/outage/pending-challenge (`:462-473`). The pre-fix implementation was pure token arithmetic that never reverted. Integrators/keepers relying on a non-reverting view now get reverts during oracle outages. Document the behavior change (or expose a non-reverting variant).
- **N-10 (net-new) — `PythOracle.supportsStrictProtectedPrice` ignores the sequencer-feed requirement.** Returns `isTokenSupported[token]` unconditionally (`PythOracle.sol:453`), unlike `ChainlinkOracleFeed` which returns `false` when the sequencer feed is required-but-unset (`:400-406`). On an L2 with `sequencerUptimeFeedRequired && sequencerUptimeFeed == address(0)`, Pyth advertises strict support while every strict read reverts — and `PoolOracleValidationLib` trusts this marker at pool creation (`:188-190`). Marker-only (price path fails closed); align the marker with the actual gate.
- **N-11 (net-new) — `UniswapV3TWAPFeed.getPrice` does not gate on the quote oracle's `isPriceStale`.** `getPrice` (`:422`) trusts the quote oracle's `getPrice` to fail closed, while the feed's own `isPriceStale` (`:481-484`) *does* consult the quote oracle's staleness. If a lenient quote oracle's `getPrice` returns a stale-but-nonzero value, `getPrice` serves a stale-quote-derived TWAP price that `isPriceStale` would flag. Exposure is limited to direct integrators (in-protocol quote oracles revert on stale `getPrice`, and TWAP feeds cannot be registered inside `CompositeOracle` — see below).

Residual-of-known items still open (not addressed by the 31 fixes):

- **K-3 (residual of I-2) — `_tryCalculateAndAccumulateFees` is dead code.** Defined at `SplitRiskPool.sol:1279`, called nowhere; still carries a maintenance footprint (was even edited by the H-2 fix). Remove it.
- **K-4 (residual of L-3) — Pyth `isPriceStale` omits the confidence-width and spot/EMA-deviation gates** that `getPrice` enforces (`PythOracle.sol:747-759` vs `:675`/`:796`). Same class as L-3, confidence/deviation dimension. Signal-only; consumers still fail closed.
- **K-5 (residual of L-2) — `getValueWithFallback` docstring promises a backup fallback that is unreachable.** Whenever the active feed's `getPrice` fails, the dual-feed dispute gate returns `(0,false)` before the inactive-feed branch can serve (`CompositeOracle.sol:1219-1264`). Fails closed (safe); the docstring overpromises graceful degradation.
- **K-6 (residual of I-6) — `_tryGetNormalizedDisputeFeedPrice` is a pure alias** (`CompositeOracle.sol:580`) whose docstring claims a dispute-only anchoring guarantee it does not add over `_tryGetNormalizedFeedPrice`. Misleading to maintainers editing the challenge gate.

---

## Web research: 2025–2026 attack patterns vs current code

Verified against current source; all items are **defended** unless noted. Full source list at the end.

1. **ERC-4626 inflation / donation** (e.g. sDOLA Llamalend, Mar 2026): **defended, fail-closed.** `ERC4626OracleFeed` uses `min(convertToAssets, previewRedeem)`, a reference-deviation band (5% default), and min-share/min-USD floors; an out-of-band rate **reverts** rather than mis-prices. M-4 timelock-bypass fixed (`registerVault` reverts re-registration); M-5 recovery restored (`deda7c0`). Residual: cheap donation-DoS of a small vault (= M-5), 1-day timelock recovery — unchanged.
2. **Chainlink `minAnswer`/`maxAnswer`, L2 sequencer** (Venus-style; recurring 2025 sequencer findings): **defended.** Bounds check + cached bounds, sequencer gate + grace period, future-`startedAt` and `startedAt == 0` fail closed, `isPriceStale` mirrors the price path. M-2 rotation liveness gap **partially** closed — `refreshFeedBounds` is now permissionless (`cc9ea74`), but a transient `FeedBoundsStale` window persists until someone refreshes.
3. **Pyth pull-oracle confidence/staleness:** **defended** (confidence width, EMA/spot deviation, exponent handling, future-timestamp rejection all present). Residuals: shared conf threshold (M-6), permissionless `updatePriceFeeds` MEV (M-11), and K-4 above.
4. **Uniswap V3 TWAP / JIT liquidity:** **defended by exclusion.** The TWAP feed intentionally does not expose `supportsCircuitBreaker`/`getPriceUnsafe` (`:41-42`), and `CompositeOracle` refuses to register any feed lacking that marker — so **TWAP cannot enter the protected pricing path at all** (unchanged L-9). The concentrated-liquidity manipulation surface is not reachable in production valuation.
5. **UUPS upgrade / uninitialized-proxy (2025 $10M+ campaign) / storage collision:** **defended via a hard design pivot.** `_authorizeUpgrade` reverts on pool and factory (deployed contracts permanently immutable); both constructors call `_disableInitializers()`; NFTs are non-upgradeable ERC721. **Design consequence worth stating plainly to users/governance:** no deployed pool or the factory can ever be patched on-chain — a future contract-level bug can only be mitigated by governance knobs, not code replacement. Remnant: N-5 (`setPoolImplementation`).
6. **Governance / timelock capture (GreenField $31M, UPCX $70M, 2025):** **defended for the single-block flash-vote.** `YSToken` is `ERC20Votes` (snapshot voting) and is **not** `ERC20FlashMint`, so it isn't flash-mintable; admin-critical actions are timelocked. Standing concerns unchanged: bootstrap-holder unilateral control (May-18 M-2), single-admin timelock-candidate hygiene (May-18 H-8).

---

## Status of the two prior Highs (re-verified)

- **H-1 (unvalidated upgrades):** **Closed for deployed contracts** — `_authorizeUpgrade` reverts `UpgradeDisabled()` on `SplitRiskPool.sol:2916` and `SplitRiskPoolFactory.sol:1846`. Narrowed remnant survives as **N-5** (`setPoolImplementation` → future pools) and the immutability tradeoff is now a first-order design fact (**N-6** docs).
- **H-2 (permanent transfer-integrity kill-switch):** **Closed** — cross-asset deposit reverts on discrepancy (`:1877-1879`) instead of latching; governance-gated recovery via round-trip probe (`:2890`). Residual limitation is **N-2** (conditional-tax tokens).

---

## Suggested remediation order

1. **N-1 (Medium)** — Stop confiscating protector residual to the fee recipient; socialize it or retain the holders' claim. Only value-loss item in this pass.
2. **N-5 (Low)** — Pin `setPoolImplementation` to a storage-layout/version allowlist; it is the last remnant of H-1's arbitrary-code power.
3. **N-3, N-4 (Low)** — Fix the two fix-induced regressions: stale unlock-window NatSpec; same-block NFT re-approval (`>=` or block-number tracking).
4. **K-1, K-2 (Low)** — Complete the L-6 view clamp and the L-3 sequencer-view alignment (both left half-done by their fixes).
5. **Informational cleanup** — N-6…N-11 and K-3…K-6: correct the stale docs/comments (upgrade/reinitializer, fee-on-transfer, `getUtilizationRatio` behavior change), remove dead code/errors, and align the remaining `isPriceStale`/marker inconsistencies. Individually minor, but collectively they are the "claimed invariants" a future maintainer will trust.

---

## Sources (external research, performed by Claude Opus 4.8)

- OpenZeppelin — [ERC-4626 Exchange-Rate Manipulation Risks](https://www.openzeppelin.com/news/erc-4626-tokens-in-defi-exchange-rate-manipulation-risks)
- DEV — [ERC-4626 Inflation Attacks Still Aren't Solved: sDOLA Llamalend Exploit (2026)](https://dev.to/ohmygod/erc-4626-vault-inflation-attacks-still-arent-solved-lessons-from-the-sdola-llamalend-exploit-5gmm)
- Zellic — [ERC-4626 Inflation Attack on Vault](https://reports.zellic.io/publications/perennial/findings/critical-vaultsol-erc-4626-inflation-attack-on-vault)
- Chainlink — [L2 Sequencer Uptime Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- Sherlock/Malda 2025 — [Missing L2 sequencer uptime check (#71)](https://github.com/sherlock-audit/2025-07-malda-judging/issues/71); Zellic/Concrete — [Incorrect L2 sequencer uptime integration](https://reports.zellic.io/publications/concrete/findings/medium-concreteoracle-incorrect-l2-sequencer-uptime-feed-integration)
- Sherlock/Debita — [Oracle does not verify Pyth confidence interval (#548)](https://github.com/sherlock-audit/2024-10-debita-judging/issues/548); Messari — [State of Pyth Q4 2025](https://messari.io/report/state-of-pyth-q4-2025)
- Euler — [uni-v3-twap-manipulation cost-of-attack](https://github.com/euler-xyz/uni-v3-twap-manipulation); Imperial — [JIT Liquidity Attacks on Uniswap V3](https://spiral.imperial.ac.uk/server/api/core/bitstreams/381ecaee-f928-4da1-a18e-41dacaa43001/content)
- OWASP — [SC10:2026 Proxy & Upgradeability](https://scs.owasp.org/sctop10/SC10-ProxyAndUpgradeabilityVulnerabilities/); Octane — [Upgradeable Contracts: Pitfalls & CI/CD Safeguards](https://www.octane.security/post/upgradeable-smart-contracts-proxies-patterns-pitfalls-cicd-safeguards)
- SmartContractsHacking — [DAO Governance Attacks (GreenField, UPCX 2025)](https://smartcontractshacking.com/attacks/dao-governance-attacks); arXiv — [Time-Weighted Snapshot Framework for DAO Governance](https://arxiv.org/html/2505.00888v1)

---

*Generated by a Claude Opus 4.8 multi-agent workflow (30 subagents, 5 review dimensions, adversarial verification, web research). 23 raw findings → 20 verified → 18 unique after deduplication. This review complements, and does not supersede, `DESIGN_REVIEW_2026_07_02.md` and the `AUDIT_FINDINGS_*` / `SECURITY_AUDIT_REPORT*` documents.*
