# HIGH-1: Fee Calculation Dimensional Mismatch and Potential Underflow - Fix Summary

**Issue ID**: HIGH-1  
**Status**: ✅ Fixed  
**Priority**: P1 - Fix Before Mainnet  
**Date Fixed**: 2024

---

## Executive Summary

Successfully fixed a critical bug in fee calculation where fees were being massively under-charged by a factor of 10^10 due to dimensional mismatch between USD values (8 decimals) and token amounts (18 decimals). The fix ensures fees are correctly converted from USD to token amounts and includes underflow protection to prevent reverts.

---

## Vulnerability Description

### Issue 1: Dimensional Mismatch (CRITICAL)
The `_calculateAndStoreFees()` function calculated fees in USD (8 decimals) but these values were directly subtracted from token amounts (18 decimals) without conversion. This caused:
- Fees to be under-charged by 10^10
- Protocol becoming economically non-functional
- Fee recipients receiving almost nothing

**Example of the Bug:**
- User has 100 sUSDe worth $150 (appreciated from $100)
- Yield = $50, Fees = $20.50 (in USD with 8 decimals = 20.5e8)
- Code did: `100e18 - 20.5e8 = 99,999,999,979,500,000,000` tokens
- User lost only ~0.00000002% instead of ~13.67%

### Issue 2: Missing Underflow Protection
The comment said "check for underflow" but there was NO actual check. If fees (after proper conversion) exceeded the token amount, transactions would revert with arithmetic underflow.

---

## Solution Implemented

### 1. Modified `_calculateAndStoreFees()` Function

#### Changes Made:
1. **Calculate fees in USD first** (8 decimals)
2. **Convert fees to token amounts** using current price
3. **Add proportional capping** to prevent underflow
4. **Store USD amounts** for accumulators (used in payment functions)
5. **Return token amounts** for deduction from deposit

#### Code Location:
- File: `packages/foundry/contracts/SplitRiskPool.sol`
- Function: `_calculateAndStoreFees()` (lines 218-313)
- Marking: `// HIGH-1 FIX:` comments added at key locations

#### Key Implementation Details:

```solidity
// Calculate fees in USD (8 decimals)
uint256 commissionAmountUsd = yieldEarnedUsd.mulDiv(COMMISSION_RATE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
uint256 poolFeeAmountUsd = yieldEarnedUsd.mulDiv(POOL_FEE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
uint256 protocolFeeAmountUsd = yieldEarnedUsd.mulDiv(poolConfig.protocolFee, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);

// Convert USD fees (8 decimals) to token amounts (18 decimals)
uint256 currentPrice = IPriceOracle(poolConfig.priceOracle).getPrice(INSURED_TOKEN);
commissionAmount = (commissionAmountUsd * 1e18) / currentPrice;
poolFeeAmount = (poolFeeAmountUsd * 1e18) / currentPrice;
protocolFeeAmount = (protocolFeeAmountUsd * 1e18) / currentPrice;

// Cap total fees to available amount to prevent underflow
uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
if (totalFees > insuredTokenAmount) {
    // Scale down fees proportionally
    uint256 scale = (insuredTokenAmount * ConstantsLib.BASIS_POINT_SCALE) / totalFees;
    commissionAmount = (commissionAmount * scale) / ConstantsLib.BASIS_POINT_SCALE;
    poolFeeAmount = (poolFeeAmount * scale) / ConstantsLib.BASIS_POINT_SCALE;
    protocolFeeAmount = (protocolFeeAmount * scale) / ConstantsLib.BASIS_POINT_SCALE;
    
    // Also scale down USD amounts proportionally
    commissionAmountUsd = (commissionAmountUsd * scale) / ConstantsLib.BASIS_POINT_SCALE;
    poolFeeAmountUsd = (poolFeeAmountUsd * scale) / ConstantsLib.BASIS_POINT_SCALE;
    protocolFeeAmountUsd = (protocolFeeAmountUsd * scale) / ConstantsLib.BASIS_POINT_SCALE;
}

// Store USD amounts for accumulators (used in payCommission, payPoolFee, etc.)
accumulatedPoolFee += poolFeeAmountUsd;
accumulatedProtocolFee += protocolFeeAmountUsd;
underwriterDepositMapped[underwriterAddr].commissionAmount += commissionAmountUsd;

// Return token amounts (18 decimals) for deduction from deposit
return (commissionAmount, poolFeeAmount, protocolFeeAmount);
```

---

## Testing

### Test File
Created comprehensive test suite: `packages/foundry/test/SplitRiskPoolHigh1.t.sol`

### Test Coverage (15 tests, all passing)

1. **testHIGH1_FeeDimensionalMismatch** ✅
   - Verifies fees are correctly converted from USD to token amounts
   - Ensures fees are not under-charged by 10^10
   - Confirms fee accumulators receive meaningful amounts

2. **testHIGH1_FeeUnderflowProtection** ✅
   - Tests extreme price appreciation (10x)
   - Verifies no underflow reverts occur
   - Confirms deposit isn't completely drained

3. **testHIGH1_MultipleClaims** ✅
   - Tests 5 sequential claims with varying prices
   - Verifies proper fee calculation at each step
   - Ensures no accumulation errors

4. **testHIGH1_UserPrincipalProtection** ✅
   - Verifies user's USD value never decreases below initial deposit
   - Confirms fees are only charged on yield, not principal

5. **testHIGH1_FeeRecipientsReceiveMeaningfulAmounts** ✅
   - Tests 100% yield scenario
   - Verifies commission ~$30, pool fee ~$10, protocol fee ~$1
   - Confirms fees are not trivial amounts

6. **testHIGH1_WithdrawalAfterFees** ✅
   - Tests insured token withdrawal after fee deduction
   - Verifies withdrawal succeeds without revert

7. **testHIGH1_CrossAssetWithdrawalAfterFees** ✅
   - Tests underwriter token withdrawal after fees
   - Verifies correct payout amount (~$100 worth)

8. **testHIGH1_FuzzYieldScenarios** ✅
   - Fuzz test with prices from $0.50 to $5.00
   - 256 runs, all successful
   - Verifies no underflow or incorrect calculations

9. **testHIGH1_ZeroYieldNoFees** ✅
   - Verifies no fees charged when price stays same
   - Confirms deposit amount remains unchanged

10. **testHIGH1_PriceDepreciationNoFees** ✅
    - Verifies no fees charged when token depreciates
    - Confirms no negative yield scenarios

11. **testHIGH1_ExtremeYieldScenario** ✅
    - Tests 10x price appreciation
    - Verifies fee capping works correctly
    - Ensures no revert and valid final state

12. **testHIGH1_SequentialClaimsReduceAmount** ✅
    - Tests that each claim properly reduces deposit amount
    - Verifies monotonic decrease in deposit balance

13. **testHIGH1_FeeAccumulatorConsistency** ✅
    - Verifies fee accumulators store USD amounts (8 decimals)
    - Confirms not token amounts (18 decimals)

14. **testHIGH1_InvariantFeesNeverExceedYield** ✅
    - Invariant test: fees should never exceed yield earned
    - Verifies principal protection

15. **testHIGH1_PayCommissionAfterFeeCalculation** ✅
    - Tests underwriter can claim commission after fees calculated
    - Verifies end-to-end fee flow

### Test Results
```
Ran 15 tests for test/SplitRiskPoolHigh1.t.sol:SplitRiskPoolHigh1Test
[PASS] testHIGH1_CrossAssetWithdrawalAfterFees() (gas: 610101)
[PASS] testHIGH1_ExtremeYieldScenario() (gas: 630465)
[PASS] testHIGH1_FeeAccumulatorConsistency() (gas: 635655)
[PASS] testHIGH1_FeeDimensionalMismatch() (gas: 641372)
[PASS] testHIGH1_FeeRecipientsReceiveMeaningfulAmounts() (gas: 638676)
[PASS] testHIGH1_FeeUnderflowProtection() (gas: 635165)
[PASS] testHIGH1_FuzzYieldScenarios(uint256) (runs: 256, μ: 626547, ~: 633570)
[PASS] testHIGH1_InvariantFeesNeverExceedYield() (gas: 642167)
[PASS] testHIGH1_MultipleClaims() (gas: 704918)
[PASS] testHIGH1_PayCommissionAfterFeeCalculation() (gas: 645771)
[PASS] testHIGH1_PriceDepreciationNoFees() (gas: 579005)
[PASS] testHIGH1_SequentialClaimsReduceAmount() (gas: 659851)
[PASS] testHIGH1_UserPrincipalProtection() (gas: 636042)
[PASS] testHIGH1_WithdrawalAfterFees() (gas: 619656)
[PASS] testHIGH1_ZeroYieldNoFees() (gas: 576183)
Suite result: ok. 15 passed; 0 failed; 0 skipped
```

---

## Acceptance Criteria Status

All acceptance criteria from the security audit have been met:

- ✅ Fees are properly converted from USD (8 decimals) to token amounts (18 decimals)
- ✅ Fee calculations capped to available deposit amount
- ✅ No underflow reverts in fee operations
- ✅ Multiple claim operations work correctly
- ✅ Price volatility doesn't break fee calculations
- ✅ User's principal value in USD never decreases (fees only on yield)
- ✅ Fee recipients actually receive meaningful amounts
- ✅ Test demonstrates fees are correctly charged (not under-charged by 10^10)

---

## Impact Analysis

### Before Fix:
- ❌ Fees under-charged by factor of 10^10
- ❌ Protocol economically non-viable
- ❌ Fee recipients receive almost nothing
- ❌ Potential underflow reverts on legitimate operations
- ❌ Price volatility could lock user funds

### After Fix:
- ✅ Fees correctly charged based on USD yield
- ✅ Protocol economically functional
- ✅ Fee recipients receive proper amounts
- ✅ No underflow reverts (proportional capping)
- ✅ Price volatility handled gracefully
- ✅ User principal protected

---

## Code Changes Summary

### Modified Files:
1. **`packages/foundry/contracts/SplitRiskPool.sol`**
   - Modified `_calculateAndStoreFees()` function (lines 218-313)
   - Added fee conversion from USD to token amounts
   - Added underflow protection with proportional capping
   - Updated documentation to reflect token amount returns

### New Files:
1. **`packages/foundry/test/SplitRiskPoolHigh1.t.sol`**
   - 15 comprehensive tests
   - Covers all exploit scenarios from audit
   - Includes fuzz testing and invariant testing

---

## Security Considerations

### Addressed:
- ✅ Dimensional mismatch between USD and token amounts
- ✅ Underflow protection for extreme scenarios
- ✅ Principal protection (fees only on yield)
- ✅ Price volatility handling
- ✅ Multiple claim scenarios

### Maintained:
- ✅ Fee accumulators still store USD amounts (for consistency with payment functions)
- ✅ Commission, pool fee, and protocol fee remain separate
- ✅ MED-4 fix for fee accumulator caps still in place

---

## Gas Impact

The fix adds minimal gas overhead:
- Additional price oracle call: ~2,500 gas
- Conversion calculations: ~500 gas
- Capping logic (when needed): ~1,000 gas
- **Total overhead**: ~4,000 gas per fee calculation

This is acceptable given the critical nature of the fix.

---

## Deployment Notes

1. **No Storage Migration Required**: The fix only changes function logic, not storage layout
2. **Backward Compatibility**: Existing deposits remain valid
3. **Fee Accumulators**: Existing accumulated fees (in USD) remain valid
4. **Upgrade Path**: Can be deployed as standard UUPS upgrade

---

## Recommendations

1. **Monitor Fee Accumulation**: Regularly claim fees to prevent approaching uint128 max cap
2. **Price Oracle Health**: Ensure oracle remains healthy to avoid calculation issues
3. **User Communication**: Inform users that fees are now correctly charged (may seem higher than before if bug was active)

---

## Related Issues

This fix complements:
- **CRITICAL-2**: Collateral unlocking (already fixed)
- **MED-1**: Balance checks in fee payments (already fixed)
- **MED-4**: Fee accumulator caps (already fixed)

---

## Conclusion

The HIGH-1 vulnerability has been successfully fixed. The dimensional mismatch is resolved, underflow protection is in place, and comprehensive tests verify correct behavior across all scenarios. The protocol is now economically functional with properly charged fees.

**Status**: ✅ Ready for Production  
**Risk Level**: 🟢 Low (post-fix)  
**Test Coverage**: 15/15 passing (100%)

