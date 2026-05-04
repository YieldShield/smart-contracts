# CRITICAL-2 Fix Summary: Collateral Unlocking and Insufficient Collateral Protection

## Overview
This document summarizes the fixes implemented for **CRITICAL-2**, a critical vulnerability in the `SplitRiskPool` contract related to collateral unlocking and insufficient collateral protection during cross-asset withdrawals.

## Vulnerability Description

### Issue 1: Incorrect Collateral Unlocking
When insured users withdrew underwriter tokens (cross-asset withdrawal), the collateral unlocking calculation used the **payout amount** instead of the **original collateralized amount**. This caused:
- **Permanent locking** of collateral when the insured token depegged (user gets less than collateral, remainder stays locked)
- **Incorrect unlocking** calculations that didn't match the originally locked amount

### Issue 2: Missing Collateral Cap
The withdrawal calculation computed payouts based on current oracle prices without capping them to the available collateral. When the collateral token (underwriter token) depegged, the code attempted to pay out more tokens than were actually collateralized, potentially causing:
- **Insolvency** if the pool didn't have enough tokens
- **Theft** from other underwriters' deposits if the pool had tokens from other deposits

## Changes Made

### 1. Contract Changes (`SplitRiskPool.sol`)

#### A. Added `collateralizedAmount` field to `InsuredDeposit` struct (Line 74)
```solidity
struct InsuredDeposit {
    uint256 amount;
    uint64 poolTime;
    address underwriterAddress;
    bool isWithdrawn;
    uint256 valueOfDeposit;
    uint256 collateralizedAmount; // NEW: Store the exact amount locked at deposit
}
```

#### B. Updated `depositInsuredAsset()` to store collateralized amount (Line 429)
```solidity
insuredDepositMapped[msg.sender].push(
    InsuredDeposit({
        amount: received,
        poolTime: uint64(block.timestamp),
        underwriterAddress: underwriterAddress,
        isWithdrawn: false,
        valueOfDeposit: valueOfDeposit,
        collateralizedAmount: collateralizedAmount // STORE the locked amount
    })
);
```

#### C. Fixed `insuredWithdraw()` for cross-asset withdrawals (Lines 512-531)
**Cap withdrawal to collateralized amount:**
```solidity
uint256 equivalentUnderwriterAmount = (depositValueUsd * 1e18) / underwriterPrice;

// CRITICAL-2 FIX: Cap to available collateral
uint256 collateralizedAmount = insuredDepositMapped[msg.sender][withdrawIndex].collateralizedAmount;
if (equivalentUnderwriterAmount > collateralizedAmount) {
    equivalentUnderwriterAmount = collateralizedAmount;
}
```

**Always unlock full collateral:**
```solidity
// CRITICAL-2 FIX: Always unlock the full collateral amount, not the payout amount
address uw = insuredDepositMapped[msg.sender][withdrawIndex].underwriterAddress;
uint256 locked = underwriterDepositMapped[uw].lockedAmount;
if (locked >= collateralizedAmount) {
    underwriterDepositMapped[uw].lockedAmount = locked - collateralizedAmount;
} else {
    underwriterDepositMapped[uw].lockedAmount = 0;
}
```

#### D. Updated insured token withdrawals to unlock collateral (Lines 495-506)
```solidity
if (preferredAsset == INSURED_TOKEN) {
    // ... existing withdrawal logic ...
    
    // CRITICAL-2 FIX: Unlock collateral for insured token withdrawal
    address uw = insuredDepositMapped[msg.sender][withdrawIndex].underwriterAddress;
    uint256 collateralizedAmount = insuredDepositMapped[msg.sender][withdrawIndex].collateralizedAmount;
    uint256 locked = underwriterDepositMapped[uw].lockedAmount;
    if (locked >= collateralizedAmount) {
        underwriterDepositMapped[uw].lockedAmount = locked - collateralizedAmount;
    } else {
        underwriterDepositMapped[uw].lockedAmount = 0;
    }
}
```

### 2. Interface Changes (`ISplitRiskPool.sol`)

Updated `getInsuredDepositInfo()` to return the new field (Line 78-81):
```solidity
function getInsuredDepositInfo(address insuredAddress, uint256 depositIndex)
    external
    view
    returns (
        uint256 amount,
        uint64 poolTime,
        address underwriterAddress,
        bool isWithdrawn,
        uint256 valueOfDeposit,
        uint256 collateralizedAmount  // NEW return value
    );
```

### 3. Test Files Updated

Updated all existing test files to handle the new return value:
- `test/SplitRiskPool.t.sol` - 12 occurrences updated
- `test/Oracle.t.sol` - 2 occurrences updated

### 4. New Comprehensive Test Suite

Created `test/SplitRiskPoolCritical2.t.sol` with 10 comprehensive tests:

1. **testCollateralUnlockingWhenInsuredTokenDepegs** - Verifies full collateral unlocking when insured token loses value
2. **testMultipleWithdrawalsWithInsuredTokenDepeg** - Tests multiple deposits/withdrawals with depeg
3. **testCollateralCapWhenUnderwriterTokenDepegs** - Verifies withdrawal is capped at collateral when underwriter token depegs
4. **testCollateralCapPreventsStealingFromOtherUnderwriters** - Ensures one user can't drain more than their collateral
5. **testCollateralCapWithExtremeDePeg** - Tests cap with 90% depeg scenario
6. **testInvariantWithdrawalNeverExceedsCollateral** - Invariant test across various price scenarios
7. **testInvariantLockedAmountNeverExceedsDeposit** - Ensures locked amount never exceeds total deposit
8. **testCollateralizedAmountStoredCorrectly** - Verifies correct storage at deposit time
9. **testInsuredTokenWithdrawalUnlocksCollateral** - Tests collateral unlocking for insured token withdrawals
10. **testFuzzCollateralCapWorksAcrossScenarios** - Fuzz test with various amounts and prices

## Test Results

All 10 CRITICAL-2 tests pass successfully:
```
Ran 10 tests for test/SplitRiskPoolCritical2.t.sol:SplitRiskPoolCritical2Test
[PASS] testCollateralCapPreventsStealingFromOtherUnderwriters() (gas: 985389)
[PASS] testCollateralCapWhenUnderwriterTokenDepegs() (gas: 564049)
[PASS] testCollateralCapWithExtremeDePeg() (gas: 554295)
[PASS] testCollateralUnlockingWhenInsuredTokenDepegs() (gas: 560868)
[PASS] testCollateralizedAmountStoredCorrectly() (gas: 549680)
[PASS] testFuzzCollateralCapWorksAcrossScenarios(uint256,uint256) (runs: 256, μ: 563096, ~: 563167)
[PASS] testInsuredTokenWithdrawalUnlocksCollateral() (gas: 472328)
[PASS] testInvariantLockedAmountNeverExceedsDeposit() (gas: 1007235)
[PASS] testInvariantWithdrawalNeverExceedsCollateral() (gas: 1269736)
[PASS] testMultipleWithdrawalsWithInsuredTokenDepeg() (gas: 697866)
Suite result: ok. 10 passed; 0 failed; 0 skipped
```

## Acceptance Criteria Status

All acceptance criteria from the security audit have been met:

- ✅ `InsuredDeposit` struct includes `collateralizedAmount`
- ✅ Deposit flow stores collateralized amount
- ✅ Cross-asset withdrawal is capped at collateralized amount
- ✅ Withdrawal always unlocks full collateralized amount (not payout amount)
- ✅ Test with insured token depeg passes
- ✅ Test with collateral token depeg passes
- ✅ Invariant test: `lockedAmount <= amount` always holds
- ✅ Invariant test: `withdrawalAmount <= collateralizedAmount` always holds

## Security Impact

### Before Fix:
- ❌ Collateral could be permanently locked when insured token depegged
- ❌ Users could withdraw more than collateralized amount when underwriter token depegged
- ❌ Potential insolvency or theft from other underwriters

### After Fix:
- ✅ Collateral is always fully unlocked on withdrawal
- ✅ Withdrawals are capped at the collateralized amount
- ✅ Pool remains solvent and protected from excessive payouts
- ✅ Underwriters' funds are protected from being drained by other users

## Deployment Notes

1. This is a **breaking change** to the `InsuredDeposit` struct storage layout
2. Existing pools will need to be migrated or redeployed
3. The `getInsuredDepositInfo()` interface change requires frontend updates
4. All integrations calling `getInsuredDepositInfo()` must be updated to handle the new return value

## Files Modified

1. `packages/foundry/contracts/SplitRiskPool.sol` - Core contract fixes
2. `packages/foundry/contracts/interfaces/ISplitRiskPool.sol` - Interface update
3. `packages/foundry/test/SplitRiskPool.t.sol` - Updated existing tests
4. `packages/foundry/test/Oracle.t.sol` - Updated existing tests
5. `packages/foundry/test/SplitRiskPoolCritical2.t.sol` - New comprehensive test suite

## Conclusion

CRITICAL-2 has been successfully fixed with comprehensive test coverage. The fixes ensure that:
1. Collateral is always correctly unlocked regardless of price changes
2. Withdrawals are capped at the collateralized amount to prevent insolvency
3. The system maintains its invariants under all price scenarios
4. All edge cases are covered by the test suite

The implementation follows the exact fix strategy outlined in the security audit and passes all acceptance criteria.

## Future Work: Partial Withdrawal Support

### Current Limitation

The current implementation **only supports full withdrawals** of insured deposits. When a user withdraws, the entire deposit is removed and all collateral is unlocked. The function documentation states:
> "If the user wants to withdraw a smaller amount than the insured token, they need to deposit the remaining amount again."

### Desired Behavior

To improve user experience, the protocol should support **proportional collateral unlocking** for partial withdrawals, maintaining the 1:1.5 collateral ratio for remaining insured assets.

#### Scenario 1: Partial Withdrawal (50%)
1. User deposits 100 sUSDe for insurance
2. Collateral is set to 150% → 150 USDC are locked
3. User withdraws 50 sUSDe (50% of deposit)
4. **Expected behavior**: Protocol should unlock 75 USDC (50% of 150 USDC)
5. **Remaining**: 50 sUSDe still insured with 75 USDC collateral (maintains 1:1.5 ratio)

#### Scenario 2: Full Withdrawal (100%)
1. User deposits 100 sUSDe for insurance
2. Collateral is set to 150% → 150 USDC are locked
3. User withdraws 100 sUSDe (100% of deposit)
4. **Expected behavior**: Protocol should unlock all 150 USDC
5. **Current implementation**: ✅ This already works correctly

### Implementation Requirements

To support partial withdrawals, the following changes would be needed:

1. **Add withdrawal amount parameter** to `insuredWithdraw()`:
   ```solidity
   function insuredWithdraw(
       uint256 withdrawIndex,
       address preferredAsset,
       uint256 withdrawAmount,  // NEW: amount to withdraw
       uint256 minAmountOut
   )
   ```

2. **Calculate proportional collateral to unlock**:
   ```solidity
   uint256 depositAmount = insuredDepositMapped[msg.sender][withdrawIndex].amount;
   uint256 totalCollateral = insuredDepositMapped[msg.sender][withdrawIndex].collateralizedAmount;
   uint256 collateralToUnlock = (totalCollateral * withdrawAmount) / depositAmount;
   ```

3. **Update stored values proportionally**:
   - Reduce `amount` by `withdrawAmount` (plus fees)
   - Reduce `collateralizedAmount` by `collateralToUnlock`
   - Update `valueOfDeposit` proportionally
   - Only set `isWithdrawn = true` if `amount` reaches 0

4. **Burn proportional receipt tokens**:
   ```solidity
   ITranche(INSURED_RECEIPT_TOKEN).burn(msg.sender, withdrawAmount);
   ```

5. **Unlock proportional collateral**:
   ```solidity
   address uw = insuredDepositMapped[msg.sender][withdrawIndex].underwriterAddress;
   uint256 locked = underwriterDepositMapped[uw].lockedAmount;
   if (locked >= collateralToUnlock) {
       underwriterDepositMapped[uw].lockedAmount = locked - collateralToUnlock;
   } else {
       underwriterDepositMapped[uw].lockedAmount = 0;
   }
   ```

### Benefits

- **Better UX**: Users can adjust their insurance coverage without full withdrawal/re-deposit
- **Gas efficiency**: Single transaction instead of withdraw + re-deposit
- **Maintains ratios**: Remaining insured assets stay properly collateralized at 1:1.5

### Considerations

- This is a **feature enhancement**, not a security fix
- Requires comprehensive testing for edge cases (fees, rounding, etc.)
- May need to handle `valueOfDeposit` recalculation for remaining amount
- Should maintain backward compatibility or clearly document breaking changes

