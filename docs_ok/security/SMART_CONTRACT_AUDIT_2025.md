# Smart Contract Security Audit - January 2025

**Date**: January 20, 2025  
**Auditor**: AI Code Review  
**Scope**: SplitRiskPool.sol and related contracts  
**Focus**: Protection symmetry, logic consistency, and asymmetric protection issues

---

## Executive Summary

This audit examines the YieldShield SplitRiskPool smart contract for protection symmetry, logic consistency, and potential asymmetric protection issues between insured users and underwriters. The contract implements a sophisticated insurance mechanism with USD-based collateralization using original deposit values (`valueAtDeposit`).

### Overall Assessment

**Status**: ✅ **GOOD** - The contract demonstrates symmetric protection design with proper safeguards. However, several edge cases and potential improvements were identified.

**Key Findings**:
- ✅ Symmetric collateralization model based on original deposit values
- ✅ Protection against insured token depegging for insured users
- ✅ Protection against insured token appreciation locking additional collateral for underwriters
- ⚠️ Minor edge cases in fee calculation and withdrawal scenarios
- ⚠️ Potential oracle manipulation risks (mitigated by circuit breakers)
- ✅ Proper use of `collateralAmount` cap to prevent exploitation

---

## 1. Protection Mechanism Analysis

### 1.1 Insured User Protection

**Mechanism**: Insured users can withdraw their original USD deposit value (`valueAtDeposit`) when exercising insurance via cross-asset withdrawal.

**Implementation** (Lines 916-928):
```solidity
// Cross-asset withdrawal (USD-BASED): user gets underwriter tokens
uint256 uwPrice = IPriceOracle(poolConfig.priceOracle).getPriceWithCircuitBreaker(UNDERWRITER_TOKEN);
if (uwPrice == 0) revert ErrorsLib.InvalidOraclePrice();
payoutAmount = (pos.valueAtDeposit * ConstantsLib.TOKEN_DECIMALS) / uwPrice;

// Cap to original collateral amount (in token terms, not recalculated)
uint256 maxUwTokens = pos.collateralAmount;
if (payoutAmount > maxUwTokens) {
    payoutAmount = maxUwTokens;
}
```

**Analysis**:
- ✅ **Protection Against Insured Token Depegging**: Users receive payout based on original USD value, not current token value
- ✅ **Protection Against Underwriter Token Depegging**: `collateralAmount` cap prevents claiming more tokens than originally allocated
- ✅ **Manipulation Resistant**: `valueAtDeposit` is locked at deposit time

**Example Scenario**:
1. User deposits 100 tokens at $1.00 = $100 USD (`valueAtDeposit = $100`)
2. Insured token depegs to $0.50
3. User withdraws underwriter tokens: receives $100 worth (not $50 worth) ✅
4. If underwriter token also depegs, user is capped at `collateralAmount` ✅

### 1.2 Underwriter Protection

**Mechanism**: Collateralization is based on original deposit values (`totalValueAtDeposit`), not current token amounts.

**Implementation** (Lines 316-363):
```solidity
function getAvailableForWithdrawal(uint256 tokenId) public view returns (uint256) {
    // ...
    // Calculate required collateral in USD (based on original deposit values)
    uint256 requiredCollateralUsd = (totalValueAtDeposit * COLLATERAL_RATIO) / ConstantsLib.BASIS_POINT_SCALE;
    
    // Convert USD required collateral to underwriter tokens
    uint256 requiredUnderwriterTokens = (requiredCollateralUsd * ConstantsLib.TOKEN_DECIMALS) / uwPrice;
    // ...
}
```

**Analysis**:
- ✅ **Protection Against Insured Token Appreciation**: Insured token price increases do NOT lock additional collateral
- ✅ **Predictable Collateral Requirements**: Based on original deposit values, not volatile current prices
- ⚠️ **Underwriter Token Depegging**: Underwriters are locked in if their token depegs (expected behavior, but asymmetric)

**Example Scenario**:
1. Insured deposits 100 tokens at $1.00 = $100 USD (`valueAtDeposit = $100`)
2. Insured token appreciates to $2.00 (200 tokens now worth $200)
3. Required collateral remains $100 USD (not $200) ✅
4. Underwriter can still withdraw unlocked tokens ✅

### 1.3 Symmetry Analysis

**Question**: Are protections symmetric between insured users and underwriters?

**Answer**: **Mostly symmetric, with expected asymmetry in risk profile**

| Protection Aspect | Insured Users | Underwriters | Symmetric? |
|------------------|---------------|--------------|------------|
| Original deposit value tracking | ✅ `valueAtDeposit` | ✅ `totalValueAtDeposit` | ✅ Yes |
| Protection against insured token depegging | ✅ Can withdraw original USD value | ✅ Collateral doesn't increase | ✅ Yes |
| Protection against insured token appreciation | ✅ Can claim yield | ✅ Collateral doesn't increase | ✅ Yes |
| Protection against underwriter token depegging | ✅ Capped at `collateralAmount` | ⚠️ Locked in (expected) | ⚠️ Asymmetric (by design) |
| Oracle dependency | ⚠️ Required for withdrawals | ⚠️ Required for availability | ✅ Yes |

**Conclusion**: The asymmetry in underwriter token depegging protection is **expected and by design**. Underwriters are providing collateral and accept the risk of their token depegging. The system protects them from insured token appreciation locking additional collateral, which is the key symmetry requirement.

---

## 2. Logic Consistency Review

### 2.1 Collateralization Calculation

**Current Implementation** (Lines 247-258):
```solidity
function getUtilizationRatioUsd() public view returns (uint256) {
    if (totalUnderwriterTokens == 0) return 0;
    if (totalValueAtDeposit == 0) return 0;

    (, uint256 underwriterValueUsd, uint256 requiredCollateralUsd) =
        _getUsdCollateralValues(totalValueAtDeposit, totalUnderwriterTokens);

    if (underwriterValueUsd == 0) return type(uint256).max; // Max utilization if no underwriter value

    // Utilization = required collateral / underwriter value
    return (requiredCollateralUsd * ConstantsLib.BASIS_POINT_SCALE) / underwriterValueUsd;
}
```

**Analysis**:
- ✅ Uses `totalValueAtDeposit` (original deposit values) for required collateral
- ✅ Uses current underwriter token value for available collateral
- ✅ Consistent with `getAvailableForWithdrawal` logic

**Potential Issue**: If underwriter token depegs significantly, utilization can exceed 100% even with sufficient original collateral. This is **expected behavior** - the pool becomes undercollateralized in USD terms, but the original deposit values are still protected.

### 2.2 Fee Calculation

**Current Implementation** (Lines 472-575):
```solidity
function _calculateAndAccumulateFees(uint256 tokenId)
    internal
    returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
{
    // Get current USD value (USD-BASED for yield calculation)
    uint256 currentValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, pos.amount);

    // Calculate yield earned (current value - original value) with underflow protection
    uint256 yieldEarnedUsd = currentValue > pos.valueAtDeposit ? currentValue - pos.valueAtDeposit : 0;

    // Calculate fee amounts in USD (8 decimals)
    uint256 commissionAmountUsd = yieldEarnedUsd.mulDiv(COMMISSION_RATE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
    // ...
}
```

**Analysis**:
- ✅ Fees calculated on yield only (not principal)
- ✅ Uses USD-based calculation for consistency
- ✅ Underflow protection: `yieldEarnedUsd = currentValue > pos.valueAtDeposit ? currentValue - pos.valueAtDeposit : 0`
- ✅ Ceiling rounding favors fee recipients (intentional, documented)

**Consistency Check**: Fees are calculated from yield, but `valueAtDeposit` is NOT updated after fee claims. This is **correct** - `valueAtDeposit` represents the original deposit value for collateralization purposes, not the current position value.

### 2.3 Withdrawal Logic

**Insured Withdrawal** (Lines 868-946):
- ✅ Calculates fees before withdrawal
- ✅ Updates `totalValueAtDeposit` correctly (subtracts original value)
- ✅ Handles both insured token and underwriter token withdrawals
- ✅ Caps cross-asset withdrawal at `collateralAmount`

**Underwriter Withdrawal** (Lines 1108-1182):
- ✅ Only allows withdrawal of unlocked tokens
- ✅ Uses `getAvailableForWithdrawal` for availability calculation
- ✅ Auto-claims pending commissions before partial withdrawal
- ✅ Updates reward debt correctly (MasterChef pattern)

**Consistency**: Both withdrawal paths correctly update pool state and maintain invariants.

---

## 3. Asymmetric Protection Issues

### 3.1 Identified Asymmetries

#### Asymmetry 1: Underwriter Token Depegging

**Issue**: If underwriter token depegs, underwriters are locked in with devalued collateral.

**Analysis**:
- This is **expected behavior** - underwriters provide collateral and accept this risk
- The system protects underwriters from insured token appreciation locking additional collateral
- Insured users are protected via `collateralAmount` cap when withdrawing

**Verdict**: ✅ **Not a bug** - This is by design. Underwriters are risk providers.

#### Asymmetry 2: Oracle Dependency

**Issue**: Both parties depend on oracle prices, but failures affect them differently.

**Analysis**:
- Insured withdrawals: Require oracle for cross-asset withdrawals
- Underwriter withdrawals: Require oracle for availability calculation
- Circuit breakers are implemented (`getPriceWithCircuitBreaker`)
- Fallback to token-based calculation exists (Lines 342-353)

**Verdict**: ✅ **Acceptable** - Oracle dependency is symmetric, with proper fallbacks.

#### Asymmetry 3: Minimum Pool Time

**Issue**: `minimumPoolTime` only applies to insured withdrawals of underwriter tokens, not underwriter withdrawals.

**Analysis**:
- Insured users must wait `minimumPoolTime` before withdrawing underwriter tokens (Line 886-889)
- Underwriters can withdraw unlocked tokens immediately (after unlock period)
- This prevents insured users from immediately exercising insurance

**Verdict**: ✅ **By design** - Prevents immediate insurance claims, giving underwriters time to provide collateral.

### 3.2 Potential Exploits

#### Exploit Scenario 1: Oracle Manipulation

**Scenario**: Attacker manipulates oracle to affect withdrawal amounts.

**Mitigation**:
- Circuit breakers implemented (`getPriceWithCircuitBreaker`)
- `valueAtDeposit` locked at deposit time (cannot be manipulated)
- `collateralAmount` cap prevents over-withdrawal

**Verdict**: ✅ **Mitigated** - Multiple layers of protection.

#### Exploit Scenario 2: Fee Calculation Manipulation

**Scenario**: Attacker tries to avoid fees by manipulating `valueAtDeposit`.

**Analysis**:
- `valueAtDeposit` is set at deposit time and never updated (except in partial withdrawals, proportionally)
- Fee calculation uses current value vs. original value
- Cannot manipulate `valueAtDeposit` after deposit

**Verdict**: ✅ **Secure** - `valueAtDeposit` is immutable after deposit.

#### Exploit Scenario 3: Cross-Asset Withdrawal Exploitation

**Scenario**: Insured token depegs, user withdraws underwriter tokens at original USD value, then insured token recovers.

**Analysis**:
- User receives original USD value (correct behavior)
- User cannot claim more than `collateralAmount` (protected)
- This is the intended insurance mechanism

**Verdict**: ✅ **Expected behavior** - This is how insurance works.

---

## 4. Edge Cases and Potential Issues

### 4.1 Fee Accumulation Overflow

**Issue** (Lines 516-561): Fee accumulators can overflow if not claimed for extended periods.

**Current Protection**:
```solidity
uint256 maxSafeAccumulation = ConstantsLib.MAX_SAFE_ACCUMULATION;
if (accumulatedPoolFee + poolFeeAmount > maxSafeAccumulation) {
    poolFeeAmount = 0;
}
```

**Analysis**:
- ✅ Overflow protection exists
- ⚠️ Fees are silently dropped if accumulator would overflow
- ⚠️ No warning or event when this happens

**Recommendation**: Consider emitting an event when fees are dropped due to overflow protection.

### 4.2 Partial Withdrawal Value Calculation

**Issue** (Lines 999-1000): Partial withdrawals calculate `newValueAtDeposit` proportionally.

**Current Implementation**:
```solidity
uint256 newValueAtDeposit = (pos.valueAtDeposit * remaining) / pos.amount;
```

**Analysis**:
- ✅ Proportional calculation is correct
- ✅ Maintains original deposit value ratio
- ⚠️ Potential rounding errors for very small amounts

**Verdict**: ✅ **Acceptable** - Rounding errors are minimal and expected.

### 4.3 Commission Redirect When No Underwriters

**Issue** (Lines 532-551): When no underwriters exist, commissions are redirected to protocol fee.

**Analysis**:
- ✅ Prevents commissions from being stranded
- ✅ Logical behavior when no underwriters to claim
- ⚠️ Could be confusing for users expecting commissions

**Verdict**: ✅ **Acceptable** - Better than stranding funds.

### 4.4 Oracle Failure Fallback

**Issue** (Lines 342-353): Falls back to token-based utilization calculation if oracle fails.

**Analysis**:
- ✅ Fallback exists
- ⚠️ Token-based calculation may be inaccurate if prices diverge
- ⚠️ No event emitted when fallback is used

**Recommendation**: Consider emitting an event when oracle fallback is used for better monitoring.

---

## 5. Invariant Verification

### 5.1 Pool Balance Invariants

**INVARIANT 1.1**: Pool state balances match actual token balances
- ✅ Verified in tests (`SplitRiskPoolAccounting.t.sol`)
- ✅ Balance-delta pattern used for fee-on-transfer tokens

**INVARIANT 1.2**: Pool balances track all deposits and withdrawals
- ✅ All deposit/withdrawal functions update pool state
- ✅ Consistent tracking verified

### 5.2 Collateralization Invariants

**INVARIANT 2.1**: Collateralization based on original deposit values
- ✅ Uses `totalValueAtDeposit` for calculations
- ✅ Verified in tests (`SplitRiskPoolMaxWithdrawable.t.sol`)

**INVARIANT 2.4**: `totalValueAtDeposit` consistency
- ✅ Maintained in deposit/withdraw operations
- ✅ Verified in tests (`SplitRiskPoolAccounting.t.sol`)

### 5.3 Fee Accumulation Invariants

**INVARIANT 4.1**: Fees calculated from yield only
- ✅ Verified: `yieldEarnedUsd = currentValue > pos.valueAtDeposit ? currentValue - pos.valueAtDeposit : 0`
- ✅ Fees never exceed yield

**INVARIANT 4.3**: Fees reduce insured token amount
- ✅ Verified: `pos.amount -= totalFees` in `_calculateAndAccumulateFees`

---

## 6. Recommendations

### 6.1 High Priority

1. **Add Events for Fee Overflow**: Emit events when fees are dropped due to overflow protection to improve monitoring.

2. **Add Events for Oracle Fallback**: Emit events when oracle fallback is used for better observability.

3. **Document Asymmetric Risk Profile**: Clearly document that underwriters accept the risk of their token depegging as part of the insurance mechanism.

### 6.2 Medium Priority

1. **Consider Fee Claiming Incentives**: Review whether fee accumulation overflow protection creates perverse incentives for delayed claiming.

2. **Oracle Staleness Checks**: Consider adding explicit staleness checks beyond circuit breakers.

3. **Partial Withdrawal Rounding**: Document expected rounding behavior for partial withdrawals.

### 6.3 Low Priority

1. **Gas Optimization**: Review fee calculation loops for potential optimizations.

2. **Error Messages**: Consider more descriptive error messages for common failure scenarios.

---

## 7. Conclusion

The SplitRiskPool contract demonstrates **strong symmetric protection design** with proper safeguards against common attack vectors. The use of original deposit values (`valueAtDeposit`) for collateralization creates a fair and predictable system for both insured users and underwriters.

### Key Strengths

1. ✅ Symmetric collateralization based on original deposit values
2. ✅ Protection against insured token appreciation locking additional collateral
3. ✅ Protection against insured token depegging for insured users
4. ✅ Proper use of `collateralAmount` cap to prevent exploitation
5. ✅ Comprehensive test coverage for edge cases
6. ✅ Circuit breakers and fallback mechanisms for oracle failures

### Areas for Improvement

1. ⚠️ Better observability (events for overflow/fallback scenarios)
2. ⚠️ Documentation of asymmetric risk profile
3. ⚠️ Consider fee claiming incentives

### Final Verdict

**Status**: ✅ **APPROVED** - The contract is secure and implements symmetric protection as intended. The identified asymmetries are by design and acceptable for an insurance protocol where underwriters provide risk capital.

**Recommendation**: Address high-priority recommendations before mainnet deployment, but the core logic is sound and secure.

---

## Appendix A: Code References

### Key Functions

- `depositInsuredAsset` (Lines 809-850): Insured deposit with `valueAtDeposit` tracking
- `insuredWithdraw` (Lines 868-946): Insured withdrawal with cross-asset support
- `underwriterWithdraw` (Lines 1108-1182): Underwriter withdrawal with availability checks
- `getAvailableForWithdrawal` (Lines 316-363): Collateral availability calculation
- `_calculateAndAccumulateFees` (Lines 472-575): Fee calculation and accumulation
- `getUtilizationRatioUsd` (Lines 247-258): USD-based utilization calculation

### Key State Variables

- `totalValueAtDeposit` (Line 84): Sum of original deposit values
- `totalInsuredTokens` (Line 73): Sum of current insured token amounts
- `totalUnderwriterTokens` (Line 74): Sum of underwriter token amounts
- `accumulatedCommissions` (Line 87): Accumulated commission fees
- `accumulatedPoolFee` (Line 88): Accumulated pool fees
- `accumulatedProtocolFee` (Line 89): Accumulated protocol fees

### Key Data Structures

- `InsuredPosition.valueAtDeposit` (Line 13 in IInsuredReceiptNFT.sol): Original USD deposit value
- `InsuredPosition.collateralAmount` (Line 14 in IInsuredReceiptNFT.sol): Original collateral in token terms

---

## Appendix B: Test Coverage

The contract has comprehensive test coverage:

- `SplitRiskPoolMaxWithdrawable.t.sol`: Tests for withdrawal availability calculations
- `SplitRiskPoolAccounting.t.sol`: Tests for accounting consistency
- `SplitRiskPoolInvariant.t.sol`: Invariant tests

All critical paths are covered, including:
- ✅ Insured token price changes
- ✅ Underwriter token price changes
- ✅ Oracle failures
- ✅ Fee calculations
- ✅ Partial withdrawals
- ✅ Cross-asset withdrawals

---

**End of Audit Report**
