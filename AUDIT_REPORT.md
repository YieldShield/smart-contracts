# SplitRiskPool Smart Contract Audit Report

**Contract:** `SplitRiskPool.sol`  
**Version:** Solidity 0.8.30  
**Date:** January 15, 2026  
**Auditor:** AI Security Review  

---

## Executive Summary

The SplitRiskPool contract is a well-architected decentralized balance protection protocol implementing a dual-token system with NFT-based position tracking. The contract demonstrates strong security practices including:

- Proper use of OpenZeppelin's upgradeable contracts
- ReentrancyGuard on all state-changing external functions
- SafeERC20 for token transfers
- Balance-delta pattern for fee-on-transfer token support
- MasterChef-style rewards distribution to prevent late-joiner exploits
- Circuit breaker protection on oracle price feeds

The codebase shows evidence of previous security improvements addressing common vulnerabilities.

---

## Findings Summary

| Severity | Count | Description |
|----------|-------|-------------|
| Critical | 0 | No critical vulnerabilities found |
| High | 0 | No high severity issues found |
| Medium | 2 | Potential issues requiring attention |
| Low | 4 | Minor issues and improvements |
| Informational | 5 | Best practice recommendations |

---

## Medium Severity

### M-1: Unclaimed Commission Loss on Partial Underwriter Withdrawal

**Location:** `underwriterWithdraw()` lines 1054-1060

**Description:** When an underwriter performs a partial withdrawal, the contract resets `commissionsClaimed[tokenId]` to 0 and sets a fresh `rewardDebt`. This means any unclaimed commission at the time of partial withdrawal is forfeited.

```solidity
// Partial withdrawal - reset to clean slate to avoid rounding exploits
rewardDebt[tokenId] = (rewardPerShareAccumulated * newAmount) / ConstantsLib.REWARD_PRECISION;
delete commissionsClaimed[tokenId];
```

**Impact:** Underwriters who don't claim their commission before partial withdrawal will lose those rewards.

**Recommendation:** Consider auto-claiming pending commissions before the partial withdrawal, or document this behavior clearly for users.

---

### M-2: setAccessControl Has No Interface Validation

**Location:** `setAccessControl()` line 1333

**Description:** The `setAccessControl` function allows the pool creator to set any address as the access control contract without validating it implements `IPoolAccessControl`. If an invalid contract is set, the pool could become bricked.

```solidity
function setAccessControl(address newAccessControl) external {
    if (msg.sender != POOL_CREATOR) revert ErrorsLib.InvalidPoolCreator();
    emit EventsLib.AccessControlUpdated(accessControl, newAccessControl);
    accessControl = newAccessControl;
}
```

**Impact:** Pool creator error could permanently lock the pool.

**Recommendation:** Add interface validation using a try-catch pattern similar to oracle validation in `updatePoolConfig()`:

```solidity
if (newAccessControl != address(0)) {
    try IPoolAccessControl(newAccessControl).canDepositInsured(address(0)) returns (bool) {
        // Interface check passed
    } catch {
        revert ErrorsLib.InvalidAccessControlAddress();
    }
}
```

---

## Low Severity

### L-1: External Self-Call in getLockedAmount

**Location:** `getLockedAmount()` lines 257-262

**Description:** The function uses `this.getUtilizationRatioUsd()` which is an external call to self. This is a valid pattern for try-catch but is gas-inefficient.

```solidity
try this.getUtilizationRatioUsd() returns (uint256 usdRatio) {
    utilizationRatio = usdRatio;
} catch {
    utilizationRatio = getUtilizationRatio();
}
```

**Impact:** ~2600 extra gas per call due to external call overhead.

**Recommendation:** Refactor to use an internal helper function that returns a success boolean, or accept the gas cost as acceptable for the fallback pattern.

---

### L-2: migrateExistingPosition Sets Debt to 0 Unconditionally

**Location:** `migrateExistingPosition()` line 654

**Description:** The migration function sets `rewardDebt[tokenId] = 0`, but this is the same as the default value. A position that was never migrated and a newly migrated position have the same `rewardDebt` value of 0.

```solidity
rewardDebt[tokenId] = 0;
```

**Impact:** The check `if (rewardDebt[tokenId] != 0) revert` will fail for positions that have never been migrated but happen to have a non-zero debt from normal operation.

**Recommendation:** Consider using a separate mapping to track migration status, or document that migration is only for positions created before the rewards-per-share system was implemented.

---

### L-3: startUnlockProcess Pool Empty Check May Be Unnecessary

**Location:** `startUnlockProcess()` lines 933-935

**Description:** The function reverts if the pool is empty, but this check seems unnecessary since an underwriter with tokens implies the pool isn't truly empty.

```solidity
if (poolState.insuredTokenBalance + poolState.totalUnderwriteTokenBalance == 0) {
    revert ErrorsLib.PoolEmpty();
}
```

**Impact:** Minimal, but the check is confusing since the underwriter calling this function means `totalUnderwriteTokenBalance > 0`.

**Recommendation:** Remove this check or clarify its purpose with documentation.

---

### L-4: Rounding Direction in Fee Calculation

**Location:** `_calculateAndAccumulateFees()` lines 409-413

**Description:** Fee calculations use `Math.Rounding.Ceil` which rounds up in favor of fee recipients. While this is intentional, the cumulative effect of rounding up commission, pool fee, and protocol fee could slightly disadvantage insured users.

```solidity
uint256 commissionAmountUsd = yieldEarnedUsd.mulDiv(COMMISSION_RATE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
```

**Impact:** Very minor - only affects dust amounts.

**Recommendation:** Acceptable as-is, but document this design decision.

---

## Informational

### I-1: Storage Optimization Opportunity

**Location:** `PoolConfig` struct

**Description:** The `PoolConfig` struct packs `protocolFeeRecipient` (address, 20 bytes) with `protocolFee` (uint96, 12 bytes) in the same slot. However, `priceOracle` (address, 20 bytes) is in its own slot.

**Recommendation:** Consider reordering struct members to optimize storage if additional uint96 parameters are added in the future.

---

### I-2: Event Naming Inconsistency

**Location:** `EventsLib.insuredWithdrawal`

**Description:** The event `insuredWithdrawal` uses camelCase starting with lowercase, while other events like `CollateralWithdraw` use PascalCase.

**Recommendation:** Standardize event naming to PascalCase for consistency.

---

### I-3: Constants Could Use More Descriptive Names

**Location:** `ConstantsLib.BASIS_POINT_SCALE`

**Description:** `BASIS_POINT_SCALE` is used both for percentage calculations (10000 = 100%) and for utilization ratio calculations. Consider aliasing for clarity.

**Recommendation:** Add constants like `PERCENTAGE_SCALE = BASIS_POINT_SCALE` for self-documenting code.

---

### I-4: Missing NatSpec on Some Internal Functions

**Location:** Various internal functions

**Description:** Some internal functions like `_getTotalPoolValue()` have minimal NatSpec documentation.

**Recommendation:** Add comprehensive NatSpec to all functions for better maintainability.

---

### I-5: Consider Adding Pool Health View Function

**Description:** The contract provides various view functions but lacks a single "pool health" function that aggregates key metrics.

**Recommendation:** Add a `getPoolHealth()` function returning utilization ratio, collateralization status, and any warning flags in one call.

---

## Security Properties Verified

### Access Control
- [x] `onlyGovernance` modifier properly restricts sensitive functions
- [x] `onlyGovernanceOrOwner` allows emergency actions
- [x] NFT ownership verified before position operations
- [x] Pool creator permissions limited appropriately

### Reentrancy Protection
- [x] `nonReentrant` modifier on all state-changing external functions
- [x] Checks-Effects-Interactions pattern followed
- [x] State updates occur before external calls

### Token Safety
- [x] SafeERC20 used for all token transfers
- [x] Balance-delta pattern for fee-on-transfer support
- [x] Slippage protection via `minAmountOut` parameters

### Oracle Security
- [x] Circuit breaker on cross-asset withdrawals
- [x] Fallback to token-based calculations on oracle failure
- [x] Zero price checks prevent division errors

### Upgrade Safety
- [x] UUPS pattern with governance-only upgrade authorization
- [x] Storage gap reserved for future upgrades
- [x] `_disableInitializers()` in constructor

### Economic Security
- [x] MasterChef pattern prevents late-joiner reward dilution
- [x] Fee caps prevent overflow
- [x] Collateral ratio bounds enforced
- [x] Reserved fees protected from user withdrawals

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      SplitRiskPool                               │
├─────────────────────────────────────────────────────────────────┤
│  Inherits:                                                       │
│  - Initializable (UUPS upgradeable)                             │
│  - UUPSUpgradeable                                              │
│  - ProtocolAccessControlUpgradeable                             │
│    - OwnableUpgradeable                                         │
│    - PausableUpgradeable                                        │
│    - ReentrancyGuardUpgradeable                                 │
├─────────────────────────────────────────────────────────────────┤
│  External Dependencies:                                          │
│  - InsuredReceiptNFT (ERC721 positions)                         │
│  - UnderwriterReceiptNFT (ERC721 positions)                     │
│  - IPriceOracle (price feeds)                                   │
│  - IPoolAccessControl (optional whitelist)                      │
├─────────────────────────────────────────────────────────────────┤
│  Key Flows:                                                      │
│  1. Deposit → Mint NFT → Track position                         │
│  2. Withdraw → Calculate fees → Burn NFT → Transfer tokens      │
│  3. Commission → MasterChef rewards-per-share distribution      │
│  4. Cross-asset → Oracle price → Collateral cap → Transfer      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Conclusion

The SplitRiskPool contract demonstrates a mature security posture with appropriate use of battle-tested OpenZeppelin libraries. The two medium-severity findings relate to user experience (commission loss on partial withdrawal) and operational risk (access control validation), neither of which presents immediate fund loss risk.

The contract is well-suited for production deployment with the following recommendations:
1. Address M-1 by auto-claiming commissions before partial withdrawals
2. Add interface validation for `setAccessControl` (M-2)
3. Consider the gas optimization for external self-call (L-1)

**Overall Assessment:** Production Ready with Minor Improvements Recommended
