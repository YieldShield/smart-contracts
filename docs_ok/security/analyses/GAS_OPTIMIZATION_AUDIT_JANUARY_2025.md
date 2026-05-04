# Gas Optimization Audit - YieldShield Protocol

**Date:** January 7, 2025  
**Auditor:** Claude AI  
**Scope:** All smart contracts in `packages/foundry/contracts/`  
**Focus:** Gas efficiency improvements and optimization opportunities

---

## Executive Summary

This audit identifies gas optimization opportunities in the YieldShield protocol smart contracts. The findings are categorized by severity of gas impact and implementation complexity. Several optimizations have already been implemented (GAS-1, GAS-2 from previous audit), and this document identifies additional opportunities.

### Summary of Findings

| Category | Count | Estimated Gas Savings |
|----------|-------|----------------------|
| High Impact | 3 | 5,000 - 20,000 gas per tx |
| Medium Impact | 5 | 1,000 - 5,000 gas per tx |
| Low Impact | 6 | 100 - 1,000 gas per tx |
| Already Fixed | 2 | (GAS-1, GAS-2) |

---

## High Impact Findings

### GAS-H1: Duplicate `_normalizeDecimals` Function Across Oracle Contracts

**Severity:** High Impact  
**Location:** Multiple oracle contracts  
**Estimated Savings:** ~200-500 gas per deployment, better maintainability

**Description:**
The `_normalizeDecimals` helper function is duplicated across 4 oracle contracts:
- `MetaOracleAdapter.sol` (lines 393-402)
- `ChainlinkOracleFeed.sol` (lines 257-265)
- `ERC4626OracleFeed.sol` (lines 286-296)
- `UniswapV3TWAPFeed.sol`

**Current Implementation (repeated in each file):**
```solidity
function _normalizeDecimals(uint256 price, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
    if (fromDecimals == toDecimals) {
        return price;
    } else if (fromDecimals < toDecimals) {
        return price * (10 ** (toDecimals - fromDecimals));
    } else {
        return price / (10 ** (fromDecimals - toDecimals));
    }
}
```

**Recommendation:**
Create a shared library `DecimalNormalizationLib.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title DecimalNormalizationLib
/// @notice Library for normalizing decimal precision across price feeds
library DecimalNormalizationLib {
    /// @notice Normalize price from one decimal precision to another
    /// @param price Original price
    /// @param fromDecimals Original decimal precision
    /// @param toDecimals Target decimal precision
    /// @return Price normalized to target decimals
    function normalize(uint256 price, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return price;
        if (fromDecimals < toDecimals) {
            return price * (10 ** (toDecimals - fromDecimals));
        }
        return price / (10 ** (fromDecimals - toDecimals));
    }
}
```

---

### GAS-H2: Loop Optimization in `getAllPoolsInfo()` and Token Whitelist

**Severity:** High Impact  
**Location:** `SplitRiskPoolFactory.sol:240`, `TokenWhitelistLib.sol:47`  
**Estimated Savings:** ~60 gas per iteration

**Description:**
Loops use post-increment (`i++`) and bounds checking on each iteration. Using unchecked blocks with pre-increment saves gas.

**Current Implementation:**
```solidity
// SplitRiskPoolFactory.sol:240
for (uint256 i = 0; i < poolCount; i++) {
    allPoolsInfo[i] = _poolInfo[pools[i]];
}
```

**Recommendation:**
```solidity
for (uint256 i = 0; i < poolCount;) {
    allPoolsInfo[i] = _poolInfo[pools[i]];
    unchecked { ++i; }
}
```

**Files Affected:**
- `SplitRiskPoolFactory.sol` - `getAllPoolsInfo()`
- `TokenWhitelistLib.sol` - `removeToken()`
- `MockTokenFaucet.sol` - Multiple functions (lower priority, test/mock contract)
- `AccessControlExample.sol` - `setAllowed()` (lower priority, example contract)

---

### GAS-H3: Cache `poolConfig.priceOracle` in `_calculateAndAccumulateFees()`

**Severity:** High Impact  
**Location:** `SplitRiskPool.sol:244-346`  
**Estimated Savings:** ~2,100 gas (1 SLOAD = 2,100 gas saved)

**Description:**
The function `_calculateAndAccumulateFees()` reads `poolConfig.priceOracle` 3 times:
- Line 254: `getValue()`
- Line 267: `getPrice()`
- Line 340: `getValue()`

**Current Implementation:**
```solidity
uint256 currentValue = IPriceOracle(poolConfig.priceOracle).getValue(INSURED_TOKEN, pos.amount);
// ...
uint256 currentPrice = IPriceOracle(poolConfig.priceOracle).getPrice(INSURED_TOKEN);
// ...
uint256 newValue = IPriceOracle(poolConfig.priceOracle).getValue(INSURED_TOKEN, newAmount);
```

**Recommendation:**
```solidity
function _calculateAndAccumulateFees(uint256 tokenId)
    internal
    returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
{
    // GAS: Cache oracle address
    address priceOracle = poolConfig.priceOracle;
    
    // Use cached address
    uint256 currentValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, pos.amount);
    // ...
    uint256 currentPrice = IPriceOracle(priceOracle).getPrice(INSURED_TOKEN);
    // ...
    uint256 newValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, newAmount);
}
```

---

## Medium Impact Findings

### GAS-M1: Cache `getClaimableCommission()` Storage Reads

**Severity:** Medium Impact  
**Location:** `SplitRiskPool.sol:450-461`  
**Estimated Savings:** ~2,100 gas

**Description:**
Unlike `claimCommission()` which already caches `totalUnderwriterTokens` (GAS-2 fix), the view function `getClaimableCommission()` does not cache this value.

**Current Implementation:**
```solidity
function getClaimableCommission(uint256 tokenId) public view returns (uint256) {
    if (totalUnderwriterTokens == 0) return 0;  // First read
    // ...
}
```

**Recommendation:**
Although this is a view function (no gas cost for external calls), it's called internally in `getUnderwriterDepositInfo()`, so caching helps:

```solidity
function getClaimableCommission(uint256 tokenId) public view returns (uint256) {
    uint256 totalUnderwriterTokens_ = totalUnderwriterTokens;  // Cache
    if (totalUnderwriterTokens_ == 0) return 0;
    // ...
}
```

---

### GAS-M2: Double Balance Check in `claimCommission()`

**Severity:** Medium Impact  
**Location:** `SplitRiskPool.sol:424-435`  
**Estimated Savings:** ~2,100 gas (1 SLOAD)

**Description:**
The function performs two balance checks that are largely redundant:

```solidity
if (poolState.insuredTokenBalance < claimable) {
    revert ErrorsLib.InsufficientTokenBalance();
}
uint256 actualBalance = IERC20(INSURED_TOKEN).balanceOf(address(this));
if (actualBalance < claimable) {
    revert ErrorsLib.InsufficientTokenBalance();
}
```

**Recommendation:**
Since the actual balance check is the authoritative source of truth (protects against accounting discrepancies), the `poolState.insuredTokenBalance` check is redundant:

```solidity
// Only check actual balance (source of truth)
uint256 actualBalance = IERC20(INSURED_TOKEN).balanceOf(address(this));
if (actualBalance < claimable) {
    revert ErrorsLib.InsufficientTokenBalance();
}
```

**Note:** Keep both if accounting integrity verification is desired, but consider if the dual check adds sufficient value.

---

### GAS-M3: Optimize `insuredWithdraw()` Oracle Calls

**Severity:** Medium Impact  
**Location:** `SplitRiskPool.sol:593-662`  
**Estimated Savings:** ~2,100 gas when preferredAsset == UNDERWRITER_TOKEN

**Description:**
When `preferredAsset == UNDERWRITER_TOKEN`, the function calls `getPriceWithCircuitBreaker()` but could reuse cached price from `_calculateAndAccumulateFees()`.

**Current Flow:**
1. `_calculateAndAccumulateFees()` calls oracle (line 618-619)
2. If cross-asset withdrawal, calls oracle again (line 635)

**Recommendation:**
Consider restructuring to pass price data from fee calculation if the same oracle/token is used, or accept the extra call as necessary for circuit breaker protection.

---

### GAS-M4: Storage Struct Packing Optimization

**Severity:** Medium Impact  
**Location:** `SplitRiskPool.sol:32-47`  
**Estimated Savings:** Potential future savings

**Description:**
The current `PoolConfig` and `PoolState` structs are reasonably organized, but `PoolConfig` could be further optimized:

**Current PoolConfig (8 storage slots):**
```solidity
struct PoolConfig {
    uint256 minDepositAmount;      // slot 0
    uint256 maxDepositAmount;      // slot 1
    uint256 maxTotalValueLocked;   // slot 2
    uint256 minimumPoolTime;       // slot 3
    uint256 unlockDuration;        // slot 4
    uint256 protocolFee;           // slot 5
    address protocolFeeRecipient;  // slot 6
    address priceOracle;           // slot 7
}
```

**Potential Optimization:**
If protocol fee can be safely limited to `uint96` (max ~79 billion with 18 decimals):

```solidity
struct PoolConfig {
    uint256 minDepositAmount;      // slot 0
    uint256 maxDepositAmount;      // slot 1
    uint256 maxTotalValueLocked;   // slot 2
    uint256 minimumPoolTime;       // slot 3
    uint256 unlockDuration;        // slot 4
    address protocolFeeRecipient;  // slot 5 (20 bytes)
    uint96 protocolFee;            // slot 5 (12 bytes) - packed!
    address priceOracle;           // slot 6
}
```

**Savings:** 1 storage slot (~2,100 gas on first write)

**Note:** This is a breaking change for existing deployments and requires careful consideration of upgrade implications.

---

### GAS-M5: Batch NFT Position Updates

**Severity:** Medium Impact  
**Location:** `InsuredReceiptNFT.sol:77-89`  
**Estimated Savings:** ~100-200 gas per update

**Description:**
The `updatePosition()` function performs 4 separate storage writes:

```solidity
function updatePosition(...) external onlyPool {
    if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
    positions[tokenId].amount = newAmount;              // SSTORE 1
    positions[tokenId].valueAtDeposit = newValue;       // SSTORE 2
    positions[tokenId].collateralAmount = newCollateralAmount; // SSTORE 3
    positions[tokenId].lastFeeClaimTime = newLastFeeClaimTime; // SSTORE 4
}
```

**Recommendation:**
Use a storage pointer to reduce lookups:

```solidity
function updatePosition(...) external onlyPool {
    if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
    InsuredPosition storage pos = positions[tokenId];
    pos.amount = newAmount;
    pos.valueAtDeposit = newValue;
    pos.collateralAmount = newCollateralAmount;
    pos.lastFeeClaimTime = newLastFeeClaimTime;
}
```

---

## Low Impact Findings

### GAS-L1: Use `immutable` for Constant-Like Constructor Values

**Severity:** Low Impact  
**Location:** `MetaOracleAdapter.sol`  
**Estimated Savings:** Minor per read

**Description:**
Variables like `_primaryFeed`, `_backupFeed`, `_deviationThreshold`, `_challengeDuration` are already `immutable` - good practice. Verify other contracts follow same pattern.

**Status:** ✅ Already optimized

---

### GAS-L2: String Concatenation in Factory

**Severity:** Low Impact  
**Location:** `SplitRiskPoolFactory.sol:168-171`  
**Estimated Savings:** ~100-200 gas

**Description:**
Multiple `string.concat()` calls could be combined:

```solidity
string memory insuredReceiptSymbol = string.concat("i", insuredTokenInfo.symbol);
string memory insuredReceiptName = insuredReceiptSymbol;
```

**Note:** This is during pool creation (infrequent), so impact is low.

---

### GAS-L3: Redundant Token Support Check in ChainlinkOracleFeed

**Severity:** Low Impact  
**Location:** `ChainlinkOracleFeed.sol:183-188`  
**Estimated Savings:** ~200 gas

**Description:**
`getTokenFeedDecimals()` checks `isTokenSupported[token]` before reading the feed. The feed mapping could be checked directly:

```solidity
function getTokenFeedDecimals(address token) external view returns (uint8) {
    AggregatorV3Interface feed = tokenFeeds[token];
    if (address(feed) == address(0)) revert TokenNotSupported(token);
    return feed.decimals();
}
```

---

### GAS-L4: Event Parameter Indexing

**Severity:** Low Impact  
**Location:** Various contracts  
**Estimated Savings:** ~75 gas per non-indexed to indexed conversion (for filtering)

**Description:**
Some events could benefit from additional `indexed` parameters for efficient filtering. Review events in `EventsLib.sol` for commonly filtered parameters.

---

### GAS-L5: Constants in ConstantsLib

**Severity:** Low Impact  
**Location:** `ConstantsLib.sol`  
**Estimated Savings:** Already optimized

**Description:**
All constants are properly declared as `constant`, which inlines them at compile time.

**Status:** ✅ Already optimized

---

### GAS-L6: Calldata vs Memory for External Function Parameters

**Severity:** Low Impact  
**Location:** `SplitRiskPool.sol:108-120` (initialize function)  
**Note:** This is already optimal

**Description:**
The `initialize` function uses `memory` for `TokenInfo` structs, which is correct since they're passed via proxy initialization. External functions receiving arrays could potentially use `calldata` but none are applicable here.

**Status:** ✅ Already optimized

---

## Already Implemented Optimizations

### GAS-1: Redundant Balance Check (FIXED)
**Location:** `SplitRiskPool.sol:352-360, 376-384`  
Removed redundant `poolState.insuredTokenBalance` checks in `payPoolFee()` and `payProtocolFee()`.

### GAS-2: Storage Read Caching (FIXED)
**Location:** `SplitRiskPool.sol:409-410`  
Cached `totalUnderwriterTokens` in `claimCommission()`.

---

## Deployment and Testing Recommendations

### Gas Profiling
1. Use Foundry's gas reporting: `forge test --gas-report`
2. Profile specific functions with `forge snapshot`
3. Compare before/after optimization with `forge snapshot --diff`

### Testing Commands
```bash
# Generate gas report
forge test --gas-report

# Create snapshot for comparison
forge snapshot

# Compare against baseline
forge snapshot --diff .gas-snapshot
```

### Priority Implementation Order

1. **High Priority (Implement First)**
   - GAS-H2: Loop optimization (low risk, high frequency)
   - GAS-H3: Cache oracle address (low risk, high frequency)

2. **Medium Priority**
   - GAS-H1: Create DecimalNormalizationLib (code cleanup + minor gas savings)
   - GAS-M1: Cache in view function (very low risk)
   - GAS-M5: Storage pointer in NFT update (low risk)

3. **Low Priority / Future Consideration**
   - GAS-M2: Evaluate double balance check necessity
   - GAS-M4: Struct packing (breaking change, upgrade consideration)

---

## Conclusion

The YieldShield protocol is reasonably gas-optimized, with previous audit findings (GAS-1, GAS-2) already implemented. The most impactful remaining optimizations are:

1. **Loop optimizations** (GAS-H2) - Simple, safe, immediate benefit
2. **Oracle address caching** (GAS-H3) - ~2,100 gas savings per fee calculation
3. **Code deduplication** (GAS-H1) - Better maintainability and slight deployment savings

Total estimated savings for high-priority items: **4,000-6,000 gas per complex transaction** (e.g., insured withdrawal with fees).

---

*This audit focuses on gas optimization opportunities and does not replace comprehensive security audits.*

