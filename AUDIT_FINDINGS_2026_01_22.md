# Smart Contract Audit Findings - January 22, 2026

## Executive Summary

This audit was conducted using automated static analysis (Slither), extended fuzz testing, invariant testing, and coverage analysis. The audit builds upon 3 prior audits completed in January 2026.

**Overall Assessment**: The codebase is mature with comprehensive testing. Several edge cases were discovered that warrant investigation.

| Severity | Count |
|----------|-------|
| High | 2 |
| Medium | 4 |
| Low | 3 |
| Informational | 5 |

---

## High Severity Findings

### H-1: Collateralization Edge Case - Available Withdrawal Off-by-One

**Location**: `SplitRiskPool.getAvailableForWithdrawal()`

**Description**: When pool utilization exceeds 100%, the function returns 1 instead of 0. This could theoretically allow tiny withdrawals when the pool should be fully locked.

**Reproduction**:
```
[Sequence] (shrunk to 3 calls)
1. depositUnderwriter(740, 24425)
2. depositInsured(12942, 12086)
3. withdrawUnderwriter(2450, 15209, ...)

Result: Available = 1 when should be 0
```

**Impact**: Minor fund leakage possible under extreme utilization scenarios.

**Recommendation**: Add explicit check `if (utilization >= BASIS_POINT_SCALE) return 0;`

---

### H-2: Accounting Invariant Violation - totalValueAtDeposit Mismatch

**Location**: `SplitRiskPool` - reward claim flow

**Description**: After reward claims, `totalValueAtDeposit` (100,000,000,000) does not match the sum of individual position `valueAtDeposit` values (108,400,000,000).

**Test**: `test_claimRewards_DoesNotChangeTotalValueAtDeposit`

**Impact**: Accounting drift could affect utilization calculations and collateralization checks over time.

**Recommendation**: Audit the reward claim flow to ensure `totalValueAtDeposit` is properly maintained.

---

## Medium Severity Findings

### M-1: Arithmetic Overflow in Fee Reserve Protection

**Location**: `SplitRiskPool` - partial withdrawal with reserved fees

**Tests Affected**:
- `testPartialWithdrawalRespectsReservedFees`
- `testWithdrawalSucceedsWhenFeesPaid`

**Description**: Arithmetic underflow/overflow (0x11) occurs during fee calculations in partial withdrawal scenarios.

**Impact**: Could cause transaction reverts in edge cases involving fee reserves.

**Recommendation**: Add bounds checking or use SafeMath patterns for fee calculations.

---

### M-2: USD Utilization Calculation Discrepancy

**Location**: `SplitRiskPool.getUtilizationRatioUsd()`

**Tests Affected**:
- `test_getUtilizationRatioUsd_PriceDivergence` - Expected 6111, got 5555
- `test_tokenBasedVsUsdBased_Comparison` - Expected 7500, got 6250

**Description**: USD-based utilization calculations diverge from expected values when token prices differ significantly.

**Impact**: Could affect collateralization enforcement when price divergence is significant.

**Recommendation**: Review USD utilization formula for precision loss in price divergence scenarios.

---

### M-3: USD Withdrawal Check Not Blocking as Expected

**Location**: `SplitRiskPool.underwriterWithdraw()`

**Test**: `test_underwriterWithdraw_BlockedByUsdCheck`

**Description**: Expected revert for USD-based withdrawal check not occurring.

**Impact**: Withdrawals may succeed when they should be blocked by USD utilization limits.

---

### M-4: Divide-Before-Multiply Pattern (Slither)

**Location**: Multiple functions in `SplitRiskPool.sol`

**Functions Affected**:
- `getUtilizationRatio()` (lines 211-215)
- `_tryGetUtilizationRatioUsd()` (lines 267-282)
- `getAvailableForWithdrawal()` (lines 316-363)
- `_calculateAndAccumulateFees()` (lines 472-575)

**Description**: Division is performed before multiplication, which can cause precision loss.

**Example**:
```solidity
requiredCollateral = (totalInsuredTokens * COLLATERAL_RATIO) / ConstantsLib.BASIS_POINT_SCALE;
result = (requiredCollateral * ConstantsLib.BASIS_POINT_SCALE) / totalUnderwriterTokens;
```

**Impact**: Minor precision loss in calculations. Acceptable given the scale of values used.

**Recommendation**: Consider reordering operations where precision is critical.

---

## Low Severity Findings

### L-1: Test Bug - Deposit Below Minimum Fuzz Test

**Location**: `test/SplitRiskPoolFuzz.t.sol:216`

**Description**: Test uses `bound(amount, 0, minDepositAmount)` but contract allows deposits of exactly `minDepositAmount`. Test should use `bound(amount, 0, minDepositAmount - 1)`.

**Contract Logic**: `if (depositAmount < poolConfig.minDepositAmount) revert` (strictly less than)

**Recommendation**: Fix test to use correct bounds.

---

### L-2: Migration Revert Not Triggered

**Location**: `SplitRiskPoolCommission.sol`

**Test**: `testMigrationRevertsWithNonZeroDebt`

**Description**: Expected revert for migration with non-zero debt not occurring.

**Impact**: Migration flow may have changed or test expectations are outdated.

---

### L-3: UniswapV3 TWAP Division by Zero

**Location**: `UniswapV3TWAPFeed.sol`

**Test**: `test_priceFromTick_MatchesTickMath_NegativeTick`

**Description**: Division by zero when processing negative ticks.

**Impact**: Oracle feed may fail for certain tick values.

---

## Informational Findings

### I-1: Unused Import

**Location**: `contracts/oracles/PythOracle.sol:7`

```solidity
import { PythConfig } from "./PythConfig.sol"; // unused
```

**Recommendation**: Remove unused import.

---

### I-2: Storage Gaps Flagged as "Unused"

**Location**: `SplitRiskPool.sol:1495`, `SplitRiskPoolFactory.sol:472`

**Description**: Slither flags `__gap` arrays as unused. This is expected behavior for upgradeable contracts.

**Status**: False positive - no action needed.

---

### I-3: Sends ETH to Arbitrary User (Expected)

**Locations**:
- `PythOracle.updatePriceFeeds()` - Sends to Pyth contract
- `Governor._executeOperations()` - OpenZeppelin governance
- `TimelockController._execute()` - OpenZeppelin timelock

**Status**: Expected behavior for Pyth oracle fees and governance execution.

---

### I-4: State Variable Shadowing

**Location**: `lib/openzeppelin-contracts/contracts/governance/Governor.sol:48`

**Description**: `Governor._name` shadows `EIP712._name`

**Status**: OpenZeppelin library issue, not actionable.

---

### I-5: Immutable Optimization Opportunity

**Location**: `contracts/oracles/UniswapV3TWAPFeed.sol:59`

```solidity
quoteToken // should be immutable
```

**Recommendation**: Add `immutable` keyword for gas optimization.

---

## Storage Layout Verification

Storage layout verified for upgrade safety:

| Contract | Slots 0-49 | Slots 50+ |
|----------|------------|-----------|
| SplitRiskPool | `_governanceTimelock` + 49-slot gap | State variables + 50-slot gap |
| SplitRiskPoolFactory | `_governanceTimelock` + 49-slot gap | State variables + 50-slot gap |

**Assessment**: Proper storage gaps maintained for UUPS upgrade safety.

---

## Test Results Summary

### Standard Test Run
- **Fuzz Tests**: 16/17 passed (1 test bug)
- **Invariant Tests**: 13/13 passed

### Coverage Run (--ir-minimum)
- **Total**: 351/361 passed
- **Failed**: 10 tests (exposed by optimizer changes)

---

## Recommendations

### Immediate Actions
1. Investigate H-1 (collateralization edge case) and H-2 (accounting drift)
2. Review M-1 arithmetic overflow in fee calculations
3. Fix L-1 test bug

### Short-term Actions
1. Review USD utilization calculations (M-2, M-3)
2. Add explicit bounds checks where divide-before-multiply occurs (M-4)

### Long-term Actions
1. Consider formal verification for critical accounting invariants
2. Add more edge case tests for >100% utilization scenarios

---

## Tools Used

- **Slither** v0.10.x - Static analysis
- **Foundry** - Fuzz testing, invariant testing, coverage
- **Manual Review** - Storage layout verification

---

## Audit Conducted By

Claude Code (Anthropic) - Automated security analysis
Date: January 22, 2026
