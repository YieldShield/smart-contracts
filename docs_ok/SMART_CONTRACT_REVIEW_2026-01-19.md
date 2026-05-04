# YieldShield Smart Contract Review

**Review Date:** January 19, 2026  
**Reviewer:** AI Code Review  
**Scope:** SplitRiskPool, SplitRiskPoolFactory, NFT contracts, Oracle system

---

## Executive Summary

This review identifies potential bugs, security concerns, and refactoring opportunities in the YieldShield smart contracts. The codebase shows evidence of prior security audits (see `SECURITY_AUDIT_REPORT.md`) with comprehensive fixes implemented. This document focuses on new findings and optimization opportunities.

---

## 🔴 Potential Bugs / Security Concerns

### BUG-1: Division by Zero in PythOracle.getEquivalentAmount()

**Severity:** Medium  
**Location:** `contracts/oracles/PythOracle.sol:185`

```solidity
function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB)
    external
    view
    override
    returns (uint256)
{
    uint256 priceA = this.getPrice(tokenA);
    uint256 priceB = this.getPrice(tokenB);

    // ⚠️ No zero check for priceB before division
    return (amountA * priceA) / priceB;
}
```

**Issue:** While `getPrice()` reverts for invalid prices, if a token is not supported or the oracle returns 0, the function may behave unexpectedly. The `getEquivalentAmountWithCircuitBreaker()` function has this protection but the regular function doesn't.

**Recommendation:**
```solidity
if (priceB == 0) revert InvalidPrice(tokenB, priceB);
return (amountA * priceA) / priceB;
```

---

### BUG-2: Double Decimal Normalization in MetaOracleAdapter.getValue()

**Severity:** Low  
**Location:** `contracts/oracles/MetaOracleAdapter.sol:164-169`

```solidity
function getValue(address token, uint256 amount) external view override returns (uint256) {
    uint256 price = this.getPrice(token);  // Already returns raw feed price
    uint8 feedDecimals = _isBackupActive ? _backupFeed.decimals() : _primaryFeed.decimals();
    uint256 adjustedPrice = price.normalize(feedDecimals, 8);  // Normalizing again
    return (amount * adjustedPrice) / 1e18;
}
```

**Issue:** `getPrice()` returns the raw feed price which is then normalized. However, if the underlying feeds already normalize their output to 8 decimals (as stated in the natspec), this double normalization could cause incorrect values.

**Recommendation:** Verify that underlying feeds return consistent decimal formats and remove redundant normalization if feeds already return 8 decimals.

---

### BUG-3: Inconsistent External Self-Calls Create Gas Overhead

**Severity:** Gas/Informational  
**Location:** `contracts/oracles/CompositeOracle.sol:151, 168, 169, 188`

```solidity
function getValue(address token, uint256 amount) external view override returns (uint256) {
    uint256 price = this.getPrice(token);  // External call to self (~2600+ gas overhead)
    return (amount * price) / 1e18;
}
```

**Issue:** Using `this.getPrice()` creates an external CALL instead of an internal JUMP, adding ~2600 gas per call. This pattern is repeated in multiple functions.

**Recommendation:** Extract the core price logic to an internal function:
```solidity
function _getPriceInternal(address token) internal view returns (uint256) {
    address oracleFeed = _tokenOracleFeed[token];
    if (oracleFeed == address(0)) revert TokenNotSupported(token);
    uint256 price = IOracleFeed(oracleFeed).getPrice(token);
    uint8 feedDecimals = IOracleFeed(oracleFeed).decimals();
    return price.normalize(feedDecimals, DECIMALS);
}

function getPrice(address token) external view override returns (uint256) {
    return _getPriceInternal(token);
}

function getValue(address token, uint256 amount) external view override returns (uint256) {
    uint256 price = _getPriceInternal(token);  // Internal call saves gas
    return (amount * price) / 1e18;
}
```

---

### BUG-4: Missing Zero Price Check in _calculateAndAccumulateFees

**Severity:** Low (already noted in audit, fix incomplete)  
**Location:** `contracts/SplitRiskPool.sol:466-470`

The check was added at line 467, but the function continues to use `currentPrice` for calculations even if it's theoretically possible for an oracle to return 0 after the check passes (e.g., between the getValue and getPrice calls in high latency scenarios).

**Current Code:**
```solidity
uint256 currentPrice = IPriceOracle(priceOracle).getPrice(INSURED_TOKEN);
if (currentPrice == 0) revert ErrorsLib.InvalidOraclePrice();
commissionAmount = (commissionAmountUsd * ConstantsLib.TOKEN_DECIMALS) / currentPrice;
```

**Assessment:** The fix is sufficient for normal operation. The oracle contract itself prevents zero returns.

---

### BUG-5: ERC4626OracleFeed.isPriceStale() State Mutability

**Severity:** Informational  
**Location:** `contracts/oracles/ERC4626OracleFeed.sol:181`

```solidity
function isPriceStale(address vault) external returns (bool isStale, uint64 publishTime) {
```

**Issue:** This function emits an event but could be marked `view` if the event emission is moved to a separate function. This limits composability with other view functions.

**Recommendation:** Create separate view and non-view variants:
```solidity
function isPriceStaleView(address vault) external view returns (bool isStale, uint64 publishTime) {
    // ... logic without event
}

function isPriceStale(address vault) external returns (bool isStale, uint64 publishTime) {
    (isStale, publishTime) = isPriceStaleView(vault);
    emit StalePriceDetected(vault, underlying, isStale);
}
```

---

### BUG-6: Potential Front-Running in claimRewards()

**Severity:** Low  
**Location:** `contracts/SplitRiskPool.sol:1022-1042`

```solidity
function claimRewards(uint256 tokenId) external nonReentrant {
    // Anyone can call this - intended behavior, but could be exploited
    // to force fee accumulation right before an insured user tries to withdraw
}
```

**Issue:** While rate-limited to 24 hours, an attacker could time `claimRewards()` calls to manipulate fee calculations for insured users preparing to withdraw.

**Recommendation:** This is by design and the rate limiting mitigates abuse. Consider documenting this behavior more explicitly.

---

## 🟡 Medium Priority Refactoring Opportunities

### REFACTOR-1: Extract Oracle Validation Logic to Library

**Location:** Multiple oracle contracts

**Current State:** Each oracle contract implements its own validation logic for prices, staleness, and decimals.

**Recommendation:** Create `OracleValidationLib.sol`:
```solidity
library OracleValidationLib {
    error InvalidPrice(address token, uint256 price);
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge);
    
    function validatePrice(uint256 price, address token) internal pure {
        if (price == 0) revert InvalidPrice(token, price);
    }
    
    function validateStaleness(uint256 updatedAt, uint256 maxAge, address token) internal view {
        if (block.timestamp - updatedAt > maxAge) {
            revert StalePrice(token, updatedAt, maxAge);
        }
    }
}
```

---

### REFACTOR-2: Consolidate Fee Calculation Logic

**Location:** `contracts/SplitRiskPool.sol:439-542`

**Issue:** The `_calculateAndAccumulateFees()` function is 100+ lines with complex nested logic. This makes it difficult to audit and maintain.

**Recommendation:** Split into smaller functions:
```solidity
function _calculateFeeAmountsUsd(
    uint256 yieldEarnedUsd
) internal view returns (uint256 commissionUsd, uint256 poolFeeUsd, uint256 protocolFeeUsd) {
    commissionUsd = yieldEarnedUsd.mulDiv(COMMISSION_RATE, BASIS_POINT_SCALE, Math.Rounding.Ceil);
    poolFeeUsd = yieldEarnedUsd.mulDiv(POOL_FEE, BASIS_POINT_SCALE, Math.Rounding.Ceil);
    protocolFeeUsd = yieldEarnedUsd.mulDiv(poolConfig.protocolFee, BASIS_POINT_SCALE, Math.Rounding.Ceil);
}

function _convertUsdToTokens(
    uint256 amountUsd,
    uint256 currentPrice
) internal pure returns (uint256) {
    return (amountUsd * TOKEN_DECIMALS) / currentPrice;
}

function _accumulateFees(
    uint256 commissionAmount,
    uint256 poolFeeAmount,
    uint256 protocolFeeAmount
) internal {
    // Fee accumulation logic
}
```

---

### REFACTOR-3: Use Custom Errors Consistently in Libraries

**Location:** `contracts/libraries/SlippageLib.sol`

**Current Code:**
```solidity
library SlippageLib {
    function enforceMinReceived(uint256 received, uint256 minExpected) internal pure {
        if (received < minExpected) {
            revert ErrorsLib.SlippageTooHigh();
        }
    }
}
```

**Recommendation:** This is already well-implemented. No changes needed.

---

### REFACTOR-4: Consider Interface Segregation for Oracle Feeds

**Location:** `contracts/interfaces/IOracleFeed.sol`, `contracts/interfaces/IPriceOracle.sol`

**Issue:** Some oracle implementations don't need all interface functions (e.g., circuit breaker functions).

**Recommendation:** Split interfaces:
```solidity
interface IOracleBasic {
    function getPrice(address token) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IOracleWithCircuitBreaker is IOracleBasic {
    function getPriceWithCircuitBreaker(address token) external view returns (uint256);
}

interface IOracleWithStaleness is IOracleBasic {
    function isPriceStale(address token) external view returns (bool, uint64);
}
```

---

## 🟢 Low Priority / Code Quality Improvements

### QUALITY-1: Add Natspec for Return Values

**Location:** Multiple functions

Several functions are missing `@return` natspec documentation. Example:

```solidity
/// @notice Get the current utilization ratio of the pool
/// @dev Calculates utilization using TOKEN-BASED accounting
/// @return utilizationRatio Utilization ratio in basis points  // ← Add this
function getUtilizationRatio() public view returns (uint256) {
```

---

### QUALITY-2: Consider Using Assembly for Gas-Critical Paths

**Location:** `contracts/SplitRiskPool.sol` - hot paths

For extremely gas-sensitive operations like commission calculations, consider using assembly:

```solidity
// Example: Optimized multiplication with overflow check
function _mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
    assembly {
        let mm := mulmod(a, b, not(0))
        let prod0 := mul(a, b)
        let prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        
        if iszero(denominator) { revert(0, 0) }
        // ... rest of implementation
    }
}
```

**Note:** Only implement if gas savings justify the added complexity and reduced readability.

---

### QUALITY-3: Add Events for State Variable Changes in Oracles

**Location:** `contracts/oracles/PythOracle.sol`

Missing events for some state changes:

```solidity
function removeToken(address token) external onlyOwner {
    delete tokenToPriceFeedId[token];
    isTokenSupported[token] = false;
    emit TokenPriceFeedSet(token, bytes32(0));  // ✓ Has event
}
```

This is already implemented. Other oracles follow the same pattern.

---

### QUALITY-4: Consider Batch Operations for Gas Savings

**Location:** `contracts/oracles/CompositeOracle.sol`

**Recommendation:** Add batch token registration:
```solidity
function setTokenOracleFeedBatch(
    address[] calldata tokens,
    address[] calldata oracleFeeds
) external onlyAuthorized {
    require(tokens.length == oracleFeeds.length, "Length mismatch");
    for (uint256 i = 0; i < tokens.length;) {
        _setTokenOracleFeed(tokens[i], oracleFeeds[i]);
        unchecked { ++i; }
    }
}
```

---

## 🔵 Architecture Observations

### OBS-1: Well-Designed Oracle System

The dual-oracle system with `MetaOracleAdapter` providing challenge/timelock switching is well-designed for:
- Stability (NAV-based primary pricing)
- Market responsiveness (Pyth/Chainlink backup)
- Attack resistance (challenge mechanism with cooldown)

### OBS-2: Solid Commission System

The MasterChef-style rewards-per-share pattern prevents late-joiner exploits effectively.

### OBS-3: Good Upgrade Safety

- UUPS pattern properly implemented
- Storage gaps in all upgradeable contracts
- Governance-only upgrade authorization

### OBS-4: Fee Reserve Protection

The `getReservedFees()` and `getWithdrawableBalance()` functions properly protect accumulated fees from being withdrawn by users.

---

## Summary of Recommendations

| ID | Severity | Description | Effort |
|----|----------|-------------|--------|
| BUG-1 | Medium | Add zero check in PythOracle.getEquivalentAmount() | Low |
| BUG-2 | Low | Review decimal normalization in MetaOracleAdapter | Low |
| BUG-3 | Gas | Use internal calls instead of external self-calls | Medium |
| BUG-5 | Info | Split isPriceStale into view/non-view variants | Low |
| REFACTOR-1 | Medium | Extract oracle validation to library | Medium |
| REFACTOR-2 | Medium | Split fee calculation into smaller functions | Medium |
| REFACTOR-4 | Low | Interface segregation for oracle feeds | High |
| QUALITY-4 | Low | Add batch operations for oracle registration | Low |

---

## Files Reviewed

1. `SplitRiskPool.sol` - Core pool logic
2. `SplitRiskPoolFactory.sol` - Pool deployment factory
3. `InsuredReceiptNFT.sol` - Insured position NFT
4. `UnderwriterReceiptNFT.sol` - Underwriter position NFT
5. `CompositeOracle.sol` - Oracle routing
6. `PythOracle.sol` - Pyth integration
7. `ChainlinkOracleFeed.sol` - Chainlink integration
8. `ERC4626OracleFeed.sol` - NAV-based pricing
9. `MetaOracleAdapter.sol` - Dual-oracle adapter
10. `ProtocolAccessControlUpgradeable.sol` - Access control base
11. `ErrorsLib.sol` - Custom errors
12. `ConstantsLib.sol` - Protocol constants

---

*This review is complementary to the existing `SECURITY_AUDIT_REPORT.md` and focuses on identifying additional improvement opportunities.*
