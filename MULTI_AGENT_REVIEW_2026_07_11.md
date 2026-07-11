# YieldShield Smart-Contract Multi-Agent Review — July 11, 2026

**Scope:** `contracts/` tree — `SplitRiskPool`, `SplitRiskPoolFactory`, the oracle stack (`CompositeOracle`, Chainlink/Pyth/PythEMA/ERC4626/UniswapV3-TWAP feeds, `SequencerUptimeGuard`), the **new tokenized-equity subsystem** (`RobinhoodStockOracleFeed`, `USMarketSessionGate`, `IProtectionOpeningEligibility`), receipt NFTs, `YSToken`/`YSGovernor`/`YSTimelockController`, access control, and libraries.

**Method:** Four-phase multi-agent workflow — one orientation pass over the ~54 commits since the round-2 follow-up, five parallel dimension reviewers (round-2 fix-verification, the new stock-oracle/session subsystem, oracle stack, governance/accounting, cross-cutting consistency), adversarial per-finding verification (each finding independently re-read at `file:line` by a skeptic prompted to *refute*, cross-checked against **all ten** prior audit/review docs), and a delta web-research lens focused on what is genuinely new (Robinhood Chain / Arbitrum Orbit, ERC-8056 stock tokens, 2026 ERC-4626 / Pyth updates). 33 raw findings → 32 verified → the set below after deduplication.

**Position in the review chain:** This is the pass *after* `MULTI_AGENT_REVIEW_2026_07_10.md` and its `REMEDIATION_PLAN_2026_07_10.md`. The remediation commits that plan produced (e.g. `457e56d` bound governance liveness, `ff5e2a1` gate stock openings, `263d351` gate ERC4626 strict on sequencer, `949cd6f` enforce pool-impl codehash, `7e5b434` settle expired backing) are all present on `main`. This review therefore **(a) verifies that remediation wave actually landed and is correct, (b) reviews the net-new tokenized-equity code it introduced, and (c) surfaces net-new weaknesses** — it is not a re-run of the prior audits.

---

## Model attribution

- This run — orchestration, all five reviewer subagents, all adversarial verifiers, and the web-research agent — executed on **Claude Fable 5** (`claude-fable-5`), the active session model. Every subagent inherited that model; there was no fallback.
- **Correction of record:** the `DESIGN_REVIEW_2026_07_04.md` "Fable 5" attribution was inaccurate — that earlier round actually ran on Claude Opus 4.8 (already annotated in that file). The intermediate `MULTI_AGENT_REVIEW_2026_07_06.md` and `_07_10.md` passes state their own attribution. This July-11 pass is genuinely Fable 5.
- Every code-level finding below was re-verified against current `main` at the cited `file:line` before inclusion; one raw finding was refuted and dropped.

---

## Executive summary

**The July-10 remediation wave is real and correct.** Independent re-verification confirmed the round-2 findings are fixed in current source: expired-backing deactivation DoS (M-1) now has a force-settle path; expired-backing egress is pause-gated (M-2); `deactivateDustPool` no longer seizes live-protector principal and returns the bond (M-3); governance liveness knobs — quorum numerator, timelock delay, pending-transfer cancellation — are bounded (M-4); ERC4626 strict support is sequencer-gated (L-1); mixed fee-accrual feed pairs are rejected at config time (L-3); the withdrawal-availability view no longer overstates (L-4); future-dated sequencer rounds report "down" in both the price path and the view (L-5); TWAP tick math is full-precision (L-6); stale-quote-oracle rotation is possible (L-7); and the pool-implementation codehash / dead-code / Pyth-narrowing informational items (I-1…I-8) are resolved. No prior High or Medium was found reopened.

**The net-new risk this pass surfaces lives almost entirely in the new tokenized-equity subsystem**, and the most important items are **deployment-reality gaps on Robinhood Chain itself** that pure source review cannot see:

1. **Robinhood Chain has no published Chainlink L2 sequencer-uptime feed, yet the guard hard-codes its chain IDs as "sequencer required."** On the exact chain this feature targets, every Chainlink-backed stock price read either bricks (`SequencerUptimeFeedRequired(4663)`) or requires governance to *disable* the sole sequencer-downtime protection on a single-sequencer chain. There is no configuration in which the guard both works and protects. (**NN-1, High / deployment-gating.**)

2. **The pause guard depends on an `oraclePaused()` function that is not part of ERC-8056** (the Robinhood "Scaled UI Amount" stock-token standard). If the real deployed tokens omit it, the wrapper fails *closed on every path* — a full per-token brick — and this is masked in tests because the mock adds `oraclePaused()`. (**NN-2, High/Med — verify against real token bytecode before mainnet.**)

3. **The wrapper ignores the ERC-8056 `uiMultiplier()`/`effectiveAt` corporate-action mechanism**, relying solely on a pause flag the documented standard does not require Robinhood to set; a split/dividend rebase can go unguarded. (**NN-3, Med.**)

4. **The market-session gate covers only position *openings*, not exits/liquidations or backing-side deposits.** Exits price off a frozen, still-in-heartbeat closed-market Chainlink print, enabling gap arbitrage across an overnight/weekend/halt close. (**NN-4 + finding on backing-side coverage, Low/Med — an explicit design decision that should be documented, not implicit.**)

Alongside those, a set of **stock-oracle design gaps** (a dual-feed failover can bypass the corporate-action pause; opening-eligibility is bound only to the primary feed; the capability probe fails *open* on an empty-data revert), **one regression still open across three rounds** (the ERC-4626 downward-haircut DoS), a **completeness gap** in the expired-backing settlement (still ACL-gated), and several documentation/event-naming inconsistencies.

**No net-new Critical or High-severity *fund-draining* code defect was found.** Every net-new oracle path fails closed (reverts) rather than mis-pricing. The High-rated items are **liveness/deployment-gating**, not theft.

| Severity | Count | Notes |
|----------|-------|-------|
| High | 1 | NN-1 (deployment-gating: no sequencer feed on target chain) |
| Medium | 3 | NN-2, NN-3, NN-4 (all Robinhood-deployment / stock-oracle) |
| Low | 5 | 4 net-new stock-oracle/settlement gaps + 1 still-open regression (ERC-4626 haircut) |
| Informational | 6 | net-new consistency / fail-open-hardening / naming |

---

## Part A — Verification of the July-10 remediation wave

Confirmed fixed in current source (spot-checked at `file:line`, no regression introduced by the fix except where noted in Part B):

| Round-2 finding | Fix commit | Verified at |
|---|---|---|
| M-1 expired-backing deactivation DoS | `7e5b434`, `0cd7562` | `SplitRiskPool.sol:1769` force-settle path *(residual: see B-6)* |
| M-2 pause doesn't gate backing egress | `0cd7562` | `SplitRiskPool.sol:1751` |
| M-3 dust deactivation seizes principal/bond | `d318995` | `SplitRiskPool.sol:2966` returns bond, no seizure |
| M-4 unbounded governance liveness knobs | `457e56d` | `YSGovernor.sol:119` bounds + cancellable transfer |
| L-1 ERC4626 strict ignores sequencer | `263d351` | `ERC4626OracleFeed.sol:420` |
| L-3 fee-accrual basis switch on failover | `065fbae` | `CompositeOracle.sol:1162` rejects mixed pairs |
| L-4 withdrawal view overstates | — | `SplitRiskPool.sol:808` reconciled |
| L-5 future-dated sequencer reported "up" | `91bd571` | `SequencerUptimeGuard.sol:124/147` both paths |
| L-6 TWAP precision loss | `6951dd7` | `UniswapV3TWAPFeed.sol:549` full-precision |
| L-7 stale-quote rotation revert | `9105776` | `UniswapV3TWAPFeed.sol:302` |
| I-1/I-2 pool-impl codehash unenforced | `949cd6f`, `1bb1a48`, `86540c7` | `SplitRiskPoolFactory.sol:880` enforced at creation |
| I-3 composite removal delists | `35a54ab` | `SplitRiskPoolFactory.sol:1848` feed-only |
| I-5/I-6/I-7/I-8 Pyth narrowing, stale signal, probe reuse, dead helper | `0a20691`, `d6ea114`, `7e940cf`, `d3a59a9` | resolved |
| Storage-layout canonicalization | `b229a95` | `SplitRiskPool.sol:3316` no slot shifted |
| Proposal reachability after burns | `57bd257` | `YSToken.sol:62` `MIN_GOVERNANCE_SUPPLY` = max proposal threshold |

**One round-2 item is *not* closed (regression, still open):** the ERC-4626 downward-haircut DoS — see **B-5**.

---

## Part B — Net-new findings

### High

#### NN-1 (High — deployment-gating) — Robinhood Chain has no Chainlink sequencer-uptime feed, but the guard hard-codes its chain IDs as "sequencer required"

**Where:** `contracts/oracles/SequencerUptimeGuard.sol:171-173` (`_isKnownL2RequiringSequencer` returns true for `4663`/`46630`), `:61` (constructor sets `sequencerUptimeFeedRequired = true`), `:105` (only-disable escape), `:78` (setter rejects codeless addresses); `contracts/oracles/ChainlinkOracleFeed.sol:441` (`_checkSequencerUptime()` on every priced read); `RobinhoodStockOracleFeed.sol:94` (delegates into that inner feed).

Robinhood Chain is an Arbitrum Orbit L2 (mainnet chainId **4663**, testnet **46630**, public mainnet live July 1 2026, single first-come sequencer). As of this review it is **not** in Chainlink's L2 Sequencer Uptime Feed registry — there is no feed address to configure. Because the guard hard-codes 4663/46630 as sequencer-required, the constructor sets the flag true, and every Chainlink read reverts `SequencerUptimeFeedRequired(4663)` since `setSequencerUptimeFeed` rejects a codeless address. The **only** way to unbrick is `setSequencerUptimeFeedRequired(false)`, which removes the sole sequencer-downtime protection on a chain that has a single sequencer. Net: the guard is either bricking or inert on the exact chain this feature targets.

**Action:** treat as a hard deployment gate. Either confirm Chainlink ships a 4663 feed before mainnet, or make the "no feed available" case an explicit, documented, monitored risk acceptance (off-chain sequencer monitoring) rather than a silent `setSequencerUptimeFeedRequired(false)`. *(Contingent on the external fact that no 4663 feed exists at deploy time — re-check at deployment.)*

### Medium

#### NN-2 (Medium; High if confirmed) — the pause guard depends on `oraclePaused()`, which is not part of ERC-8056; a real token omitting it bricks the feed, and the mock hides this

**Where:** `contracts/oracles/RobinhoodStockOracleFeed.sol:81-87` (`_requireNotPaused` — `catch { revert StockTokenPauseProbeFailed }`), also `:102`, `:129`, `:148`; masked by `contracts/mocks/MockRobinhoodStockToken.sol:10,40` which *adds* `oraclePaused`.

Robinhood stock tokens are ERC-8056 ("Scaled UI Amount"): corporate actions are applied via `uiMultiplier()`/`effectiveAt`/`UIMultiplierUpdated`, **not** an oracle-pause flag. `oraclePaused()` is not in the standard or the Robinhood Chain token docs. The wrapper fails *closed* if the probe reverts — correct fail-closed discipline, but it means a real token that does not implement `oraclePaused()` makes `getPrice`/`getPriceUnsafe`/`isPriceStale` revert on **every** call, bricking pricing, deposits, exits, and liquidations for that token. The test suite cannot catch this because the mock implements the function. **Verify the real deployed token bytecode exposes `oraclePaused()` before mainnet;** if it does not, the corporate-action guard must be rebuilt on the ERC-8056 fields.

#### NN-3 (Medium) — the wrapper ignores the ERC-8056 `uiMultiplier()`/`effectiveAt` rebase mechanism

**Where:** `contracts/oracles/RobinhoodStockOracleFeed.sol` (no `uiMultiplier` read anywhere; the only `uiMultiplier` references in `contracts/` are in the mock, `MockRobinhoodStockToken.sol:7,18-34`).

The documented corporate-action path for these tokens is the multiplier (splits/dividends rebase effective shares = raw × `uiMultiplier`/1e18), applied at `effectiveAt`. The production wrapper never reads it and cannot detect a pending or just-applied multiplier; it relies entirely on `oraclePaused()` being asserted during the transition (which — per NN-2 — the standard does not require). Across a rebase, correct valuation then depends entirely on whether the Chainlink feed's basis is per-raw-token or per-underlying-share; a mismatch is a persistent, unguarded mispricing, and the split-moment is unguarded regardless. **Gate on `effectiveAt` proximity via the ERC-8056 fields rather than a possibly-vestigial pause flag.**

#### NN-4 (Medium/Low — explicit design decision needed) — the market-session gate covers only openings, not exits/liquidations or backing-side deposits

**Where:** sole gate call site `SplitRiskPool.sol:1972` inside `depositShieldedAsset` (via `_requireProtectionOpeningAllowed`, `:566`). `depositBackingAsset` (`:1867`), `shieldedWithdraw`/cross-asset withdraw/liquidation paths have **no** market-hours gate.

`USMarketSessionGate` itself is well-built (fail-closed UTC calendar, pause-only guardian). But it gates only the shielded *opening* path. Two consequences:
- **Exits/liquidations during a close** price off a frozen, still-in-heartbeat closed-market Chainlink print. If `oraclePaused()` is false over an overnight/weekend/holiday/halt window, a holder can open at Friday's close and redeem before Monday's open at the same stale print, or race a halt — gap arbitrage against the pool. (This is adjacent to `MULTI_AGENT_REVIEW_2026_07_10.md` M-01, the still-fresh 24/5 off-hours adverse-selection case, but concerns the *exit* leg, which M-01 does not.)
- **Backing-side deposits are ungated:** nothing forces the gated equity to be the `SHIELDED_TOKEN`. A pool with the stock as `BACKING_TOKEN` lets protectors open equity-collateral exposure while the market is closed. (Impact is more limited than the shield side — backing shares are token-based and store no `valueAtDeposit`, so it is capacity/collateral distortion, not a locked-price arb.)

Fail-closing exits during a halt would trap users mid-halt, so this is a genuine tradeoff — but it should be an **explicit documented risk decision**, and the opening-vs-exit asymmetry should be stated, not implicit.

### Low

#### B-1 (Low, net-new) — a dual-feed failover to a non-wrapper backup bypasses the corporate-action pause guard

**Where:** `CompositeOracle.sol:1050-1060` (and `:1072`, `:1097`, `:1016`, `:1252`) select `activeFeed = isBackupActive ? backupFeed : primaryFeed` and read it directly; the pause guard lives only inside the wrapper (`RobinhoodStockOracleFeed.sol:81-137`); `setTokenOracleFeedDual` (`CompositeOracle.sol:333-371`) does not require the backup to carry the pause guard.

If governance configures a stock token as dual with primary = `RobinhoodStockOracleFeed` and backup = a bare `ChainlinkOracleFeed`, then after a challenge fails over (`isBackupActive = true`, `:755`) all safe reads route to the unguarded backup. Openings still gate correctly (the eligibility path reads only the primary), but **exits, fee accrual, and settlement price through the unguarded backup during a split/rebase window.** Because the wrapper reverts while paused, `getValueWithFallback` can leak the backup price even before formal failover. Governance foot-gun (the natural config wraps both legs or uses the wrapper as a single feed) — hence Low — but validation should either require the backup to also implement the pause guard or route eligibility/pause through the active feed.

#### B-2 (Low, net-new) — protection-opening eligibility is bound only to the primary feed and is not re-evaluated after failover

**Where:** `CompositeOracle.sol:489-497` (`isProtectionOpeningAllowed` always staticcalls `config.primaryFeed`), `:1529-1538` (`protectionOpeningEligibilityRequired[token]` snapshotted from the primary only), `:755` (failover leaves feeds unchanged).

If the gated stock feed is ever configured as the **backup** with a plain feed as primary, `protectionOpeningEligibilityRequired` is computed as `false` and the market calendar is silently not enforced for new stock openings (`SplitRiskPool.sol:576-577` returns early). This is a deployment/configuration invariant — *the gated stock feed must be the primary* — that is currently unenforced and undocumented. The primary-gated case fails closed correctly.

#### B-3 (Low, net-new) — expired-backing settlement is still gated by the withdrawal ACL, so a denied owner's reserve can block pool deactivation

**Where:** `SplitRiskPool.sol:1780` (`settleExpiredProtectorBacking` and `claimExpiredProtectorBacking` both call `_requireProtectorWithdrawalAllowed(positionOwner)`; the governance branch bypasses the pause check at `:1774-1776` but **not** the ACL); `:3200-3204` (ACL revert); deactivation sweeps require `totalBackingTokenBalance == totalProtectorTokens` (`:2953`, `:2990`).

The M-1 force-settle path resolves the common lost-key case, but if a withdrawal-gating ACL denies the reserve's owner, *no* keeper or governance call can clear the reserve, so the residual keeps the pool non-empty and blocks deactivation. **Recoverable** — governance can `setAccessControl(address(0))` (`:3088-3114`) then settle — so it is a completeness gap, not a hard lock, and refusing egress to a compliance-denied owner is arguably intended. Consider either netting `protectorEpochBackingRemainingReserve` out of the deactivation checks, or a governance-only ACL-bypass on the settle path specifically.

#### B-4 (Low, net-new) — a stock-token issuer controls `oraclePaused()` and can freeze all pool pricing, exits, and fee accrual

**Where:** `RobinhoodStockOracleFeed.sol:81-95,128-137`; downstream `SplitRiskPool.sol:526-527` (`_getShieldedPrice`, no fallback), `shieldedWithdraw` → `_calculateAndAccumulateFees` reverts `ShieldedFeePriceUnavailable`.

`oraclePaused()` is set by the external stock-token issuer (non-governance). While paused, every shielded price read reverts, freezing not just openings but exits and fee accrual — with **no governance override at the immutable wrapper level** (only a slow, timelocked `poolConfig.priceOracle` replacement). A prolonged or erroneous issuer pause is an indefinite user-exit freeze. Deliberate fail-closed design; worth documenting as a third-party liveness dependency and a candidate for a governance-controlled maximum-pause escape hatch.

#### B-5 (Low, **regression still open across 3 rounds**) — ERC-4626 downward-haircut DoS: the fix decoupled the reference (accounting NAV) from the floored value (`previewRedeem`)

**Where:** `contracts/oracles/ERC4626OracleFeed.sol:538-547` (reference = `convertToAssets` via `_accountingAssetsPerShare`, floor checked against `previewRedeem` via `_redeemableAssetsPerShare`), `:602-619` (one-sided lower-bound revert), `:59` (`DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS = 500`). Prior: round-2 L-2 / `MULTI_AGENT_REVIEW_2026_07_06.md` M-1.

The round-2 fix (`8f3a46c` + `c9b35bd`) moved the deviation band's reference onto the fee-free accounting NAV (`convertToAssets`) while the one-sided floor is checked against the fee/haircut-bearing `previewRedeem`. The two rates are now structurally decoupled: **any vault whose `previewRedeem` sits >5% below `convertToAssets`** (withdrawal fee, withdrawal-queue mode, thin liquidity) reverts `SharePriceDeviationTooHigh` on *every* read, DoSing every pool that prices that leg. A vault with a permanent >5% withdrawal fee is registerable but unpriceable from the first read. Before the fix both the reference and the priced rate used `min(convertToAssets, previewRedeem)`, so haircuts were self-consistent — the fix *sharpened* L-2 into a structural DoS rather than closing it. DoS/liveness only (no fund loss), and registration is owner-gated, but dynamic haircut/queue-mode is not owner-controlled. **Recommended:** check the floor against the same basis used for the reference (or clamp both to the conservative min), so a downward haircut degrades gracefully instead of reverting.

### Informational

- **B-6 (net-new) — capability probe fails *open* on an empty-data revert.** `SplitRiskPool.sol:570-572`: if the stage-1 `protectionOpeningEligibilityRequired` staticcall reverts with empty return data, the pool treats the oracle as legacy and skips gating — the sole fail-*open* branch in a function that otherwise fails closed (`:573-588`). Safe for the current `CompositeOracle` (the selector is a public mapping getter that cannot revert), but a future oracle implementing it as a bare `require`/`assert` would silently disable the market gate. Harden to fail closed unless the selector is provably absent.
- **B-7 (net-new) — `ICompositeOracle.getOracleType` NatSpec omits the new stock type.** `interfaces/ICompositeOracle.sol:61`'s example list (`"pyth", "erc4626", "chainlink", "twap", "dual"`) omits the new `'chainlink-stock'` value that `_detectOracleType` returns for the stock wrapper (`CompositeOracle.sol:1556`), so a frontend keyed off the doc mishandles stock feeds. (Note: `'dual'` *is* a valid return — set at `CompositeOracle.sol:366` for dual feeds and returned via `getOracleType`→`_tokenOracleType`, `:500-501` — so the list is under-inclusive, not wrong; the hedged "like …" phrasing keeps this Informational.)
- **B-8 (net-new) — `RewardsClaimed` event name contradicts its payload.** `EventsLib.sol:39` — the second parameter was renamed to `feesCharged`, but the event is still `RewardsClaimed`; the emit at `SplitRiskPool.sol:2377` passes `totalFees` *deducted from* the position. An indexer displaying it as "rewards received" inverts the user-facing meaning.
- **B-9 (net-new) — `MAX_POOLS` NatSpec claims a coupling that does not exist.** `SplitRiskPoolFactory.sol:106` says the token whitelist reuses the same ceiling, but the whitelist cap is an independent literal (`TokenWhitelistLib.MAX_WHITELISTED_TOKENS = 100`). They coincide today but are uncoupled; raising `MAX_POOLS` would not track the whitelist.
- **B-10 (known, still open) — TWAP `isPriceStale` does not mirror `getPrice`'s zero-truncation reverts.** `UniswapV3TWAPFeed.sol:456-495` returns "not stale" for a micro-priced asset whose normalized price would truncate to zero and revert in `getPrice`. Bounded/fail-closed (TWAP can't register in `CompositeOracle`; the ERC4626 underlying-oracle path propagates the revert). Same class as `MULTI_AGENT_REVIEW_2026_07_06.md` L-2; predates all reviews (not net-new).
- **B-11 (known) — `PythEMAOracleFeed` and `UniswapV3TWAPFeed` still cannot be registered as `CompositeOracle` primary or backup** (no circuit-breaker marker), despite dual-feed backup framing. Carried forward from `DESIGN_REVIEW_2026_07_02.md` L-9.

---

## Delta research summary (current-code exposure)

- **Arbitrum Orbit `block.number` vs `block.timestamp`: CLEAN.** All staleness/heartbeat/TWAP logic reasons in `block.timestamp` (the sequencer clock); the only `block.number` reference is a comment in `YSToken.sol:42` documenting the deliberate ERC-6372 timestamp clock. `UniswapV3TWAPFeed` uses timestamp-based `observe(secondsAgos)`. Timing constants (`MIN_TWAP_PERIOD = 300`s, `GRACE_PERIOD_TIME = 3600`s) sit above Orbit's "unreliable in minutes" band. No change required.
- **ERC-4626 NAV-band manipulation (2026): defended, adequate in shape.** Fresh corroboration — the Lazy Summer Protocol exploit (July 6 2026, ~$6.04M) inflated share price via `totalAssets()` donation-crediting. `ERC4626OracleFeed` clamps `convertToAssets()` to a timelock-set reference ± `maxDeviationBps` with a hard cap (`:61,152,591-595,611-614`) and separates the fee-accrual path so organic growth isn't clamped. Residual is operational (keep `maxDeviationBps` tight; refresh the reference via timelock). The band is the mitigation the 2026 exploits argue for — but see B-5 for the downward-haircut side effect.
- **Pyth pull-oracle (informational):** staleness-bounded reads are consistent with best practice. Live action item is the **July 31 2026 Pyth DAO address migration** — ensure any pinned Pyth address tracks it. Moot on Robinhood Chain, where no canonical Pyth contract is documented (NN-5: Pyth legs are non-deployable there; use Chainlink-native + Uniswap-TWAP only).

---

## Suggested remediation order

1. **NN-1 (High)** — Resolve the Robinhood Chain sequencer-feed gap before any mainnet deployment there: confirm a 4663 Chainlink feed exists, or make "no feed" an explicit, monitored, documented risk acceptance instead of a silent disable.
2. **NN-2 (High if confirmed)** — Verify the real ERC-8056 stock token exposes `oraclePaused()`; if not, rebuild the corporate-action guard on the standard's `uiMultiplier`/`effectiveAt` fields. Add a test against a mock that does **not** implement `oraclePaused()`.
3. **NN-3, NN-4 (Med)** — Gate on `effectiveAt` proximity for rebases; make the openings-only session-gating an explicit, documented decision and decide whether exits/backing deposits need coverage.
4. **B-5 (Low, still open)** — Fix the ERC-4626 haircut DoS by checking the floor against the reference's basis (or clamping both to the conservative min).
5. **B-1, B-2, B-3 (Low)** — Enforce the "gated stock feed must be primary and both dual legs carry the pause guard" invariant in `setTokenOracleFeedDual`; add a governance path to clear an ACL-blocked expired-backing reserve for deactivation.
6. **B-4, B-6…B-9 (Info)** — Document the third-party pause liveness dependency; harden the capability probe to fail closed; correct the `getOracleType`, `RewardsClaimed`, and `MAX_POOLS` docs/naming.

---

## Sources (delta web research)

- Arbitrum — [Robinhood Chain mainnet](https://blog.arbitrum.io/robinhood-chain-mainnet/); [block numbers and time on Orbit](https://docs.arbitrum.io/build-decentralized-apps/arbitrum-vs-ethereum/block-numbers-and-time)
- Robinhood Chain docs — [chain](https://docs.robinhood.com/chain/), [stock tokens](https://docs.robinhood.com/chain/stock-tokens/), [contracts](https://docs.robinhood.com/chain/contracts/)
- Ethereum — [ERC-8056 Scaled UI Amount](https://eips.ethereum.org/EIPS/eip-8056)
- Chainlink — [L2 Sequencer Uptime Feeds registry](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- RWA.xyz — [Robinhood's tokenized stocks: the good, the bad, and the fix](https://app.rwa.xyz/blog/robinhoods-tokenized-stocks-the-good-the-bad-and-the-fix)
- Summer.fi — [Lazy Summer USDC vault exploit post-mortem (Jul 2026)](https://blog.summer.fi/lazy-summer-usdc-vault-exploit-post-mortem-what-happened-and-what-comes-next/); Euler — [Exchange-rate manipulation in ERC-4626 vaults](https://www.euler.finance/blog/exchange-rate-manipulation-in-erc4626-vaults)
- Pyth — [best practices](https://docs.pyth.network/price-feeds/core/best-practices), [pull updates](https://docs.pyth.network/price-feeds/pull-updates), [Hermes](https://docs.pyth.network/price-feeds/how-pyth-works/hermes)

---

*Generated by a Claude Fable 5 multi-agent workflow (40 subagents; 5 review dimensions; adversarial per-finding verification cross-checked against all 10 prior audit/review documents; delta web research). 33 raw findings → 32 verified → this set after deduplication. This review complements, and does not supersede, `MULTI_AGENT_REVIEW_2026_07_10.md`, `REMEDIATION_PLAN_2026_07_10.md`, `MULTI_AGENT_REVIEW_2026_07_06.md`, the `DESIGN_REVIEW_*` chain, and the `AUDIT_FINDINGS_*` / `SECURITY_AUDIT_*` documents.*
