# YieldShield Smart Contract Security Follow-Up

**Date:** February 19, 2026  
**Auditor:** Codex (AI-assisted manual review)  
**Scope:** `/packages/foundry/contracts` first-party contracts, interfaces, libraries, and tests  
**Context Clarifications Provided by Team:**
1. `claimRewards` is intentionally permissionless.
2. Non-18-decimal tokens are expected to be supported.
3. Pool-creator unilateral ACL control is an intended trust model.

---

## Executive Summary

This follow-up review focused on protocol-level safety, oracle routing correctness, and accounting assumptions after incorporating the trust-model clarifications above.

Key result: two materially important technical risks remain open, and one fee-model issue has now been remediated in code/tests:

1. **Circuit-breaker bypass through `CompositeOracle` routing** (HIGH, open)
2. **Pool accounting assumes 18-decimal pool assets while protocol intends broader decimal support** (HIGH, open)
3. **Repeated fee charging against unchanged baseline in permissionless `claimRewards` flow** (MEDIUM, fixed on February 19, 2026)

---

## Severity Summary

| Severity | Count |
|----------|-------|
| HIGH (Open) | 2 |
| MEDIUM (Open) | 0 |
| MEDIUM (Fixed) | 1 |
| LOW | 0 |
| INFO | 2 |

---

## Findings

### HIGH-1: Circuit Breaker Not Enforced When Pool Uses `CompositeOracle`

**Status:** Open  
**Affected Files:**
- `contracts/SplitRiskPool.sol`
- `contracts/oracles/CompositeOracle.sol`
- `contracts/oracles/PythOracle.sol`

**Relevant Code Paths:**
- `SplitRiskPool.shieldedWithdraw()` calls `getPriceWithCircuitBreaker(BACKING_TOKEN)` for cross-asset payouts.
- `CompositeOracle.getPriceWithCircuitBreaker()` currently delegates to `_getPrice()` (standard spot path).
- `_getPrice()` uses `IOracleFeed.getPrice(token)`, not feed-specific circuit-breaker methods.

**Risk**

The pool expects circuit-breaker-protected pricing during critical payout paths, but for feed types like `PythOracle`, it effectively receives normal spot pricing when routed via `CompositeOracle`. This can weaken oracle manipulation resistance exactly where the pool expects strongest protection.

**Potential Solutions**

Option A (recommended): add an optional circuit-breaker feed interface and use it when available.

```solidity
interface ICircuitBreakerFeed is IOracleFeed {
    function getPriceWithCircuitBreaker(address token) external view returns (uint256);
}
```

Then in `CompositeOracle`:
- Try `ICircuitBreakerFeed(activeFeed).getPriceWithCircuitBreaker(token)` via `try/catch`
- Fallback to `IOracleFeed(activeFeed).getPrice(token)` if unavailable

Option B: enforce a policy that any feed used for payout-critical assets must be a feed type with integrated circuit breaker semantics inside `getPrice()`.

Option C: dual-path API in `CompositeOracle`, where pool uses a dedicated hardened function for critical valuations (e.g., payout and liquidation-critical checks).

**Suggested Validation**
- Add tests proving that when active feed is `PythOracle`, `CompositeOracle.getPriceWithCircuitBreaker()` actually enforces deviation threshold behavior.

---

### HIGH-2: Decimal-Handling Model Conflicts With Intended Non-18 Token Support

**Status:** Open  
**Affected Files:**
- `contracts/SplitRiskPool.sol`
- `contracts/libraries/ConstantsLib.sol`

**Relevant Patterns**
- Core arithmetic uses `ConstantsLib.TOKEN_DECIMALS` (`1e18`) for conversions and collateral math.
- No explicit token-decimal normalization layer in pool accounting despite non-18 support requirement.

**Risk**

If a pool asset does not use 18 decimals, collateral and fee conversions can become dimensionally incorrect, leading to valuation drift, over/under-withdrawal allowances, or incorrect utilization and capacity checks.

**Potential Solutions**

Option A (recommended): normalize all token amounts to internal 18-decimal "wad" units at ingress/egress.
- Store per-token decimals once at initialization.
- Convert external token amounts into internal wad amounts for all accounting.
- Convert back on token transfers.

Option B: enforce both pool assets to have identical decimals and normalize by that shared precision (less flexible, lower complexity).

Option C: store and use explicit decimal scalars per token for every cross-token and USD conversion path (more explicit but noisier code).

**Implementation Notes**
- Add immutable or config fields:
  - `shieldedTokenDecimals`
  - `backingTokenDecimals`
  - `shieldedScale`
  - `backingScale`
- Audit all usages of `1e18` assumptions in:
  - utilization
  - fee conversion
  - cross-asset payout
  - capacity checks

**Suggested Validation**
- Add test pools using 6-decimal backing and 18-decimal shielded tokens.
- Add invariant checks with mixed decimals for deposits, partial withdrawals, and cross-asset withdrawals.

---

### MEDIUM-1: Repeated Fee Charging on Unchanged Yield in Permissionless `claimRewards`

**Status:** Fixed (implemented on branch `sb/feat/rebranding`, February 19, 2026)  
**Affected Files:**
- `contracts/SplitRiskPool.sol`
- `test/SplitRiskPoolCommission.t.sol`

**Original Mechanism**
- `_calculateAndAccumulateFees()` used `currentValue - valueAtDeposit` as yield basis.
- `valueAtDeposit` is intentionally immutable.
- With permissionless `claimRewards`, repeated calls could charge fees again on already-taxed gains.

**Impact**

The issue was not unauthorized access (permissionless design is intentional), but fee-model behavior: same historical gain could be taxed multiple times across cooldown intervals.

**Implemented Solution**

Option A was implemented: per-position fee baseline with high-water-mark semantics.
- Added `feeValueBaselineUsd[tokenId]`.
- Yield now uses `currentValue - baselineValueUsd` (fallback to `valueAtDeposit` for legacy positions with zero baseline).
- After fees are deducted, baseline advances to `max(previousBaseline, postFeeValueUsd)` to avoid retaxing unchanged gains and to avoid taxing pure recovery after drawdowns.
- Baseline lifecycle is handled on deposit, full withdrawal cleanup, and partial withdrawal token split.

**Validation**
- Added regression test: `testClaimRewards_DoesNotRetaxSameYield` in `SplitRiskPoolCommission.t.sol`.
- Verified with:
  - `forge test --offline --match-contract SplitRiskPoolCommissionTest -vv`
  - `forge test --offline --match-contract SplitRiskPoolAccountingTest -vv`

**Alternative Designs (not implemented)**

Option B: keep current model and disclose compounding fee semantics explicitly in UI/docs.  
Option C: owner-authorized fee realization with keeper fallback.

---

## Informational Notes

### INFO-1: Intended Trust Assumptions Confirmed

The following were reviewed and treated as design assumptions, not vulnerabilities:
- Pool-creator unilateral ACL control
- Permissionless reward-claim trigger

These should remain explicitly disclosed in public docs and UI risk sections.

### INFO-2: Test Environment Stability

`forge test` (default mode) encountered a Foundry runtime panic in this environment related to system proxy detection.  
`forge test --offline` executed and produced broad passing coverage for reviewed suites.

---

## Recommended Next Steps (Priority Order)

1. Fix oracle circuit-breaker routing in `CompositeOracle`.
2. Introduce explicit decimal normalization strategy for mixed-decimal assets.
3. Expand tests for mixed-decimal pools and circuit-breaker-through-router behavior.
4. Add one more regression suite around baseline behavior for legacy (pre-baseline) positions and partial-withdraw split/merge scenarios.

---

## Appendix: Commands Used

```bash
forge test --offline
forge test --offline --match-contract SplitRiskPoolCommissionTest -vv
forge test --offline --match-contract SplitRiskPoolAccountingTest -vv
rg --files packages/foundry/contracts
rg -n "function " packages/foundry/contracts/**/*.sol
```
