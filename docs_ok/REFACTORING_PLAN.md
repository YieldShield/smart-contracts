# YieldShield Smart Contract Refactoring Plan

**Created:** January 19, 2026  
**Status:** In Progress  
**Priority Order:** REFACTOR-2 > REFACTOR-5 > REFACTOR-4 > REFACTOR-6

---

## Completed Refactors

| ID | Name | Date Completed |
|----|------|---------------|
| REFACTOR-1 | Oracle Validation Library | January 19, 2026 |
| REFACTOR-6 | Constants Consolidation | January 19, 2026 |

---

## Table of Contents

1. [REFACTOR-1: Oracle Validation Library](#refactor-1-oracle-validation-library)
2. [REFACTOR-2: Fee Calculation Decomposition](#refactor-2-fee-calculation-decomposition)
3. [REFACTOR-3: Interface Segregation (Deferred)](#refactor-3-interface-segregation-deferred)
4. [REFACTOR-4: Batch Operations](#refactor-4-batch-operations)
5. [REFACTOR-5: View Function Variants](#refactor-5-view-function-variants)
6. [REFACTOR-6: Constants Consolidation](#refactor-6-constants-consolidation)

---

## REFACTOR-1: Oracle Validation Library ✅ COMPLETED

### Priority: Medium
### Effort: 2-3 hours
### Risk: Low
### Status: **COMPLETED** (January 19, 2026)

### Problem Statement

Each oracle contract (`PythOracle`, `ChainlinkOracleFeed`, `ERC4626OracleFeed`, `CompositeOracle`) implements its own validation logic for:
- Zero price checks
- Staleness validation
- Decimal normalization

This leads to:
- Code duplication across 4+ contracts
- Inconsistent error messages
- Maintenance burden when updating validation logic

### Current State

```solidity
// PythOracle.sol
if (price <= 0) revert InvalidPrice(token, 0);

// ChainlinkOracleFeed.sol  
if (answer <= 0) revert InvalidPrice(token, answer);
if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice(token, updatedAt, maxPriceAge);

// ERC4626OracleFeed.sol
if (totalSupply < MIN_VAULT_SUPPLY) revert InsufficientVaultLiquidity(vault, totalSupply, MIN_VAULT_SUPPLY);
```

### Proposed Solution

Create `contracts/libraries/OracleValidationLib.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title OracleValidationLib
/// @notice Shared validation logic for oracle contracts
/// @dev Centralizes price and staleness validation to reduce code duplication
library OracleValidationLib {
    // ============ Errors ============
    
    /// @notice Thrown when price is zero or negative
    error InvalidPrice(address token, int256 price);
    
    /// @notice Thrown when price data is stale
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge, uint256 currentTime);
    
    /// @notice Thrown when price deviation exceeds threshold
    error PriceDeviationExceeded(
        address token, 
        uint256 price1, 
        uint256 price2, 
        uint256 deviationBps, 
        uint256 maxDeviationBps
    );

    // ============ Validation Functions ============

    /// @notice Validate that a price is positive
    /// @param price The price to validate (int256 for Chainlink compatibility)
    /// @param token The token address (for error reporting)
    function validatePositivePrice(int256 price, address token) internal pure {
        if (price <= 0) revert InvalidPrice(token, price);
    }

    /// @notice Validate that a price is non-zero (uint256 variant)
    /// @param price The price to validate
    /// @param token The token address (for error reporting)
    function validateNonZeroPrice(uint256 price, address token) internal pure {
        if (price == 0) revert InvalidPrice(token, 0);
    }

    /// @notice Validate price staleness
    /// @param updatedAt Timestamp of last price update
    /// @param maxAge Maximum allowed age in seconds
    /// @param token The token address (for error reporting)
    function validateStaleness(uint256 updatedAt, uint256 maxAge, address token) internal view {
        uint256 age = block.timestamp - updatedAt;
        if (age > maxAge) {
            revert StalePrice(token, updatedAt, maxAge, block.timestamp);
        }
    }

    /// @notice Calculate deviation between two prices in basis points
    /// @param price1 First price
    /// @param price2 Second price  
    /// @return deviationBps Deviation in basis points (0-10000+)
    function calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        if (price1 == 0 || price2 == 0) return type(uint256).max;
        
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 minPrice = price1 < price2 ? price1 : price2;
        
        return (diff * 10000) / minPrice;
    }

    /// @notice Validate that price deviation is within threshold
    /// @param price1 First price
    /// @param price2 Second price
    /// @param maxDeviationBps Maximum allowed deviation in basis points
    /// @param token The token address (for error reporting)
    function validateDeviation(
        uint256 price1, 
        uint256 price2, 
        uint256 maxDeviationBps,
        address token
    ) internal pure {
        uint256 deviation = calculateDeviation(price1, price2);
        if (deviation > maxDeviationBps) {
            revert PriceDeviationExceeded(token, price1, price2, deviation, maxDeviationBps);
        }
    }
}
```

### Migration Steps

1. **Create library** (new file, no breaking changes)
2. **Update PythOracle.sol** - Replace inline validation with library calls
3. **Update ChainlinkOracleFeed.sol** - Replace inline validation
4. **Update MetaOracleAdapter.sol** - Replace `_calculateDeviation` with library
5. **Update tests** - Change expected error selectors to library errors
6. **Deploy** - Library is embedded at compile time, no separate deployment needed

### Files Affected

| File | Changes |
|------|---------|
| `libraries/OracleValidationLib.sol` | New file |
| `oracles/PythOracle.sol` | Import library, replace validation |
| `oracles/ChainlinkOracleFeed.sol` | Import library, replace validation |
| `oracles/MetaOracleAdapter.sol` | Import library, replace `_calculateDeviation` |
| `test/PythOracle.t.sol` | Update error selectors |
| `test/ChainlinkOracleFeed.t.sol` | Update error selectors |

### Backward Compatibility

- ⚠️ **Breaking:** Error selectors will change
- External integrations checking for specific errors need updates
- Consider keeping old errors as aliases during transition period

### Implementation Notes (Completed January 19, 2026)

**Files Created:**
- `contracts/libraries/OracleValidationLib.sol` - New shared library with:
  - `validatePositivePrice(int256 price, address token)` - For Chainlink int256 prices
  - `validateNonZeroPrice(uint256 price, address token)` - For uint256 prices
  - `validateStaleness(uint256 updatedAt, uint256 maxAge, address token)`
  - `calculateDeviation(uint256 price1, uint256 price2)` - Returns deviation in basis points
  - `validateDeviation(uint256 price1, uint256 price2, uint256 maxDeviationBps, address token)`
  - `checkDeviation(uint256 price1, uint256 price2, uint256 maxDeviationBps)` - Non-reverting variant

**Files Updated:**
- `oracles/PythOracle.sol` - Uses library's `calculateDeviation`
- `oracles/ChainlinkOracleFeed.sol` - Uses `validatePositivePrice`, `validateStaleness`
- `oracles/MetaOracleAdapter.sol` - Uses library's `calculateDeviation`
- `oracles/CompositeOracle.sol` - Uses `validateNonZeroPrice` for division checks

**Tests:** All 96 oracle tests pass (PythOracle: 22, ChainlinkL2Sequencer: 18, CompositeOracle: 14, MetaOracleAdapter: 42)

---

## REFACTOR-2: Fee Calculation Decomposition

### Priority: High
### Effort: 4-6 hours
### Risk: Medium (touches core accounting)

### Problem Statement

`_calculateAndAccumulateFees()` in `SplitRiskPool.sol` is 100+ lines handling:
1. Position validation
2. Yield calculation
3. Fee calculation (3 types)
4. USD to token conversion
5. Fee capping logic
6. Overflow protection
7. Commission redirection (when no underwriters)
8. Rewards-per-share updates
9. Position state updates

This makes the function:
- Difficult to audit
- Hard to test individual components
- Prone to bugs when modifying any part

### Current State

```solidity
function _calculateAndAccumulateFees(uint256 tokenId)
    internal
    returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
{
    // 100+ lines of mixed concerns
}
```

### Proposed Solution

Split into focused helper functions:

```solidity
// ============ Fee Calculation Structs ============

/// @dev Intermediate fee calculation results in USD (8 decimals)
struct FeeAmountsUsd {
    uint256 commissionUsd;
    uint256 poolFeeUsd;
    uint256 protocolFeeUsd;
}

/// @dev Final fee amounts in tokens (18 decimals)
struct FeeAmountsTokens {
    uint256 commission;
    uint256 poolFee;
    uint256 protocolFee;
}

// ============ Internal Fee Helpers ============

/// @dev Calculate yield earned since deposit
/// @param currentValue Current USD value of position
/// @param valueAtDeposit USD value at deposit time
/// @return yieldUsd Yield earned in USD (8 decimals), 0 if negative
function _calculateYieldEarned(
    uint256 currentValue, 
    uint256 valueAtDeposit
) internal pure returns (uint256 yieldUsd) {
    return currentValue > valueAtDeposit ? currentValue - valueAtDeposit : 0;
}

/// @dev Calculate fee amounts in USD from yield
/// @param yieldEarnedUsd The yield to calculate fees on
/// @return fees Fee amounts in USD (8 decimals)
function _calculateFeeAmountsUsd(
    uint256 yieldEarnedUsd
) internal view returns (FeeAmountsUsd memory fees) {
    fees.commissionUsd = yieldEarnedUsd.mulDiv(
        COMMISSION_RATE, 
        ConstantsLib.BASIS_POINT_SCALE, 
        Math.Rounding.Ceil
    );
    fees.poolFeeUsd = yieldEarnedUsd.mulDiv(
        POOL_FEE, 
        ConstantsLib.BASIS_POINT_SCALE, 
        Math.Rounding.Ceil
    );
    fees.protocolFeeUsd = yieldEarnedUsd.mulDiv(
        poolConfig.protocolFee, 
        ConstantsLib.BASIS_POINT_SCALE, 
        Math.Rounding.Ceil
    );
}

/// @dev Convert USD fee amounts to token amounts
/// @param feesUsd Fee amounts in USD (8 decimals)
/// @param tokenPrice Current token price in USD (8 decimals)
/// @return feesTokens Fee amounts in tokens (18 decimals)
function _convertFeesToTokens(
    FeeAmountsUsd memory feesUsd,
    uint256 tokenPrice
) internal pure returns (FeeAmountsTokens memory feesTokens) {
    if (tokenPrice == 0) revert ErrorsLib.InvalidOraclePrice();
    
    feesTokens.commission = (feesUsd.commissionUsd * ConstantsLib.TOKEN_DECIMALS) / tokenPrice;
    feesTokens.poolFee = (feesUsd.poolFeeUsd * ConstantsLib.TOKEN_DECIMALS) / tokenPrice;
    feesTokens.protocolFee = (feesUsd.protocolFeeUsd * ConstantsLib.TOKEN_DECIMALS) / tokenPrice;
}

/// @dev Cap fees to available position amount, scaling proportionally if needed
/// @param fees Fee amounts to potentially cap
/// @param maxAmount Maximum total fees allowed
/// @return cappedFees Fees after capping (may be scaled down)
function _capFeesToAmount(
    FeeAmountsTokens memory fees,
    uint256 maxAmount
) internal pure returns (FeeAmountsTokens memory cappedFees) {
    uint256 totalFees = fees.commission + fees.poolFee + fees.protocolFee;
    
    if (totalFees <= maxAmount) {
        return fees;
    }
    
    // Scale down proportionally
    uint256 scale = (maxAmount * ConstantsLib.BASIS_POINT_SCALE) / totalFees;
    cappedFees.commission = (fees.commission * scale) / ConstantsLib.BASIS_POINT_SCALE;
    cappedFees.poolFee = (fees.poolFee * scale) / ConstantsLib.BASIS_POINT_SCALE;
    cappedFees.protocolFee = (fees.protocolFee * scale) / ConstantsLib.BASIS_POINT_SCALE;
}

/// @dev Accumulate fees to storage with overflow protection
/// @param fees Fee amounts to accumulate
/// @return actualFees Actual fees accumulated (may be 0 if overflow would occur)
function _accumulateFees(
    FeeAmountsTokens memory fees
) internal returns (FeeAmountsTokens memory actualFees) {
    uint256 maxSafe = ConstantsLib.MAX_SAFE_ACCUMULATION;
    
    // Pool fee
    if (accumulatedPoolFee + fees.poolFee <= maxSafe) {
        accumulatedPoolFee += fees.poolFee;
        actualFees.poolFee = fees.poolFee;
    }
    
    // Protocol fee
    if (accumulatedProtocolFee + fees.protocolFee <= maxSafe) {
        accumulatedProtocolFee += fees.protocolFee;
        actualFees.protocolFee = fees.protocolFee;
    }
    
    // Commission (with redirection logic if no underwriters)
    actualFees.commission = _accumulateCommission(fees.commission);
}

/// @dev Accumulate commission with underwriter check and redirection
/// @param commissionAmount Commission to accumulate
/// @return actualCommission Actual commission accumulated
function _accumulateCommission(uint256 commissionAmount) internal returns (uint256 actualCommission) {
    uint256 maxSafe = ConstantsLib.MAX_SAFE_ACCUMULATION;
    
    if (totalUnderwriterTokens == 0) {
        // Redirect to protocol fee
        uint256 redirected = _safeAddToProtocolFee(commissionAmount);
        return 0; // Commission is 0 since redirected
    }
    
    if (accumulatedCommissions + commissionAmount > maxSafe) {
        return 0;
    }
    
    // Update rewards-per-share (MasterChef pattern)
    rewardPerShareAccumulated += (commissionAmount * ConstantsLib.REWARD_PRECISION) / totalUnderwriterTokens;
    accumulatedCommissions += commissionAmount;
    totalCommissionsEverAccumulated += commissionAmount;
    
    return commissionAmount;
}

/// @dev Safely add amount to protocol fee with overflow protection
function _safeAddToProtocolFee(uint256 amount) internal returns (uint256 added) {
    uint256 maxSafe = ConstantsLib.MAX_SAFE_ACCUMULATION;
    
    if (accumulatedProtocolFee + amount > maxSafe) {
        if (accumulatedProtocolFee < maxSafe) {
            added = maxSafe - accumulatedProtocolFee;
        }
    } else {
        added = amount;
    }
    
    accumulatedProtocolFee += added;
    return added;
}
```

### Refactored Main Function

```solidity
/// @dev Calculate and accumulate fees for an insured position
function _calculateAndAccumulateFees(uint256 tokenId)
    internal
    returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
{
    // 1. Load and validate position
    IInsuredReceiptNFT.InsuredPosition memory pos = IInsuredReceiptNFT(insuredReceiptNFT).getPosition(tokenId);
    if (pos.amount == 0) revert ErrorsLib.InsufficientTokenBalance();
    if (pos.isWithdrawn) revert ErrorsLib.PositionAlreadyWithdrawn();

    address priceOracle = poolConfig.priceOracle;

    // 2. Calculate yield
    uint256 currentValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, pos.amount);
    uint256 yieldEarnedUsd = _calculateYieldEarned(currentValue, pos.valueAtDeposit);

    // 3. Calculate fees in USD
    FeeAmountsUsd memory feesUsd = _calculateFeeAmountsUsd(yieldEarnedUsd);

    // 4. Convert to tokens
    uint256 currentPrice = IPriceOracle(priceOracle).getPrice(INSURED_TOKEN);
    FeeAmountsTokens memory feesTokens = _convertFeesToTokens(feesUsd, currentPrice);

    // 5. Cap to position amount
    feesTokens = _capFeesToAmount(feesTokens, pos.amount);

    // 6. Accumulate with overflow protection
    FeeAmountsTokens memory actualFees = _accumulateFees(feesTokens);

    // 7. Update position
    uint256 totalFees = actualFees.commission + actualFees.poolFee + actualFees.protocolFee;
    uint256 newAmount = pos.amount - totalFees;
    uint256 newValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, newAmount);
    
    IInsuredReceiptNFT(insuredReceiptNFT).updatePosition(
        tokenId, newAmount, newValue, pos.collateralAmount, uint64(block.timestamp)
    );

    return (actualFees.commission, actualFees.poolFee, actualFees.protocolFee);
}
```

### Migration Steps

1. **Add structs** to SplitRiskPool.sol (non-breaking)
2. **Add helper functions** as internal (non-breaking)
3. **Write unit tests** for each helper function
4. **Refactor main function** to use helpers
5. **Run full test suite** to verify behavior unchanged
6. **Gas comparison** - measure before/after gas usage

### Testing Strategy

```solidity
// New test file: test/SplitRiskPoolFeeHelpers.t.sol

function test_calculateYieldEarned_PositiveYield() public {
    uint256 yield = pool._calculateYieldEarned(110e8, 100e8);
    assertEq(yield, 10e8);
}

function test_calculateYieldEarned_NoYield() public {
    uint256 yield = pool._calculateYieldEarned(100e8, 100e8);
    assertEq(yield, 0);
}

function test_calculateYieldEarned_NegativeYield_ReturnsZero() public {
    uint256 yield = pool._calculateYieldEarned(90e8, 100e8);
    assertEq(yield, 0);
}

function test_capFeesToAmount_NoCapNeeded() public {
    FeeAmountsTokens memory fees = FeeAmountsTokens(10e18, 5e18, 2e18);
    FeeAmountsTokens memory capped = pool._capFeesToAmount(fees, 100e18);
    assertEq(capped.commission, 10e18);
}

function test_capFeesToAmount_ScalesProportionally() public {
    FeeAmountsTokens memory fees = FeeAmountsTokens(60e18, 30e18, 10e18); // Total: 100
    FeeAmountsTokens memory capped = pool._capFeesToAmount(fees, 50e18); // Cap to 50%
    assertEq(capped.commission + capped.poolFee + capped.protocolFee, 50e18);
}
```

### Backward Compatibility

- ✅ **Fully backward compatible** - Internal refactoring only
- External interface unchanged
- Event emissions unchanged
- Return values unchanged

---

## REFACTOR-3: Interface Segregation (Deferred)

### Priority: Low
### Effort: 8-12 hours
### Risk: High (affects all oracle consumers)

### Recommendation: Defer

Interface segregation would require:
- Creating 3+ new interfaces
- Updating all oracle implementations
- Updating all consumers (SplitRiskPool, etc.)
- Extensive testing

**Current interfaces work well.** The cost/benefit ratio is unfavorable. Revisit if:
- New oracle types are added that don't need circuit breakers
- Gas optimization becomes critical (smaller interface = less bytecode)

---

## REFACTOR-4: Batch Operations

### Priority: Low
### Effort: 1-2 hours
### Risk: Low

### Problem Statement

Admin operations like token whitelisting require individual transactions:

```solidity
factory.addToken(tokenA, "TokenA", "TKA", oracleFeedA, 10000);
factory.addToken(tokenB, "TokenB", "TKB", oracleFeedB, 10000);
factory.addToken(tokenC, "TokenC", "TKC", oracleFeedC, 15000);
// 3 transactions = 3x base gas cost
```

### Proposed Solution

Add batch variants to `SplitRiskPoolFactory.sol` and `CompositeOracle.sol`:

```solidity
// SplitRiskPoolFactory.sol

struct TokenConfig {
    address token;
    string name;
    string symbol;
    address oracleFeed;
    uint256 minCollateralRatioBp;
}

/// @notice Batch add multiple tokens (governance only)
/// @param configs Array of token configurations
function addTokenBatch(TokenConfig[] calldata configs) external onlyGovernance {
    for (uint256 i = 0; i < configs.length;) {
        _addToken(
            configs[i].token,
            configs[i].name,
            configs[i].symbol,
            configs[i].oracleFeed,
            configs[i].minCollateralRatioBp
        );
        unchecked { ++i; }
    }
}

/// @notice Internal token addition logic (extracted for reuse)
function _addToken(
    address token,
    string memory name,
    string memory symbol,
    address oracleFeed,
    uint256 minCollateralRatioBp
) internal {
    if (oracleFeed == address(0)) revert ErrorsLib.InvalidAssetAddress();
    TokenWhitelistLib.addToken(whitelistedTokens, isWhitelisted, token);

    tokenInfo[token] = TokenWhitelistLib.TokenInfo({
        name: name,
        symbol: symbol,
        token: token,
        oracleFeed: oracleFeed,
        minCollateralRatioBp: minCollateralRatioBp
    });

    if (compositeOracle != address(0)) {
        ICompositeOracle(compositeOracle).setTokenOracleFeed(token, oracleFeed);
    }

    emit EventsLib.TokenWhitelisted(token, symbol, minCollateralRatioBp);
}
```

```solidity
// CompositeOracle.sol

/// @notice Batch set oracle feeds for multiple tokens
/// @param tokens Array of token addresses
/// @param feeds Array of oracle feed addresses
function setTokenOracleFeedBatch(
    address[] calldata tokens,
    address[] calldata feeds
) external onlyAuthorized {
    if (tokens.length != feeds.length) revert("Length mismatch");
    
    for (uint256 i = 0; i < tokens.length;) {
        _setTokenOracleFeed(tokens[i], feeds[i]);
        unchecked { ++i; }
    }
}

/// @notice Internal helper for single token feed setup
function _setTokenOracleFeed(address token, address oracleFeed) internal {
    if (token == address(0)) revert InvalidTokenAddress(token);
    if (oracleFeed == address(0)) revert InvalidOracleFeed(oracleFeed);

    _tokenOracleFeed[token] = oracleFeed;
    _isTokenSupported[token] = true;

    try IOracleFeed(oracleFeed).description() returns (string memory desc) {
        _tokenOracleType[token] = _detectOracleType(desc);
    } catch {
        _tokenOracleType[token] = "unknown";
    }

    emit TokenOracleFeedSet(token, oracleFeed);
}
```

### Gas Savings

| Operation | Individual | Batch (5 tokens) | Savings |
|-----------|-----------|------------------|---------|
| Token whitelisting | 5 × 50k = 250k | ~150k | ~40% |
| Oracle feed setup | 5 × 45k = 225k | ~130k | ~42% |

### Backward Compatibility

- ✅ **Fully backward compatible** - Adds new functions only
- Existing single-token functions unchanged

---

## REFACTOR-5: View Function Variants

### Priority: Medium
### Effort: 1-2 hours
### Risk: Low

### Problem Statement

`ERC4626OracleFeed.isPriceStale()` emits an event, preventing composition with other view functions:

```solidity
// This fails because isPriceStale is not view
function getValidatedPrice(address vault) external view returns (uint256) {
    (bool stale,) = feed.isPriceStale(vault); // ❌ Can't call non-view from view
    require(!stale, "Stale price");
    return feed.getPrice(vault);
}
```

### Proposed Solution

```solidity
// ERC4626OracleFeed.sol

/// @notice Check staleness without emitting events (view function)
/// @param vault The vault address
/// @return isStale True if the underlying price is stale
/// @return publishTime The timestamp of the price (0 if not available)
function isPriceStaleView(address vault) external view returns (bool isStale, uint64 publishTime) {
    address underlying = vaultToUnderlying[vault];
    if (underlying == address(0)) {
        revert VaultNotRegistered(vault);
    }
    return _checkUnderlyingStaleness(underlying);
}

/// @notice Check staleness and emit monitoring event
/// @param vault The vault address
/// @return isStale True if the underlying price is stale
/// @return publishTime The timestamp of the price
function isPriceStale(address vault) external returns (bool isStale, uint64 publishTime) {
    (isStale, publishTime) = this.isPriceStaleView(vault);
    address underlying = vaultToUnderlying[vault];
    emit StalePriceDetected(vault, underlying, isStale);
}
```

### Backward Compatibility

- ✅ **Fully backward compatible**
- Existing `isPriceStale()` behavior unchanged
- New `isPriceStaleView()` adds view-compatible option

---

## REFACTOR-6: Constants Consolidation ✅ COMPLETED

### Priority: Low  
### Effort: 1 hour
### Risk: Very Low
### Status: **COMPLETED** (January 19, 2026)

### Problem Statement

Some constants are duplicated or could be derived:

```solidity
// ConstantsLib.sol
uint256 public constant BASIS_POINT_SCALE = 1e4;
uint256 public constant MAX_BASIS_POINTS = 10000;  // Same as BASIS_POINT_SCALE
uint256 public constant MIN_BASIS_POINTS = 10000;  // Confusing name

// Multiple contracts define their own
uint8 private constant DECIMALS = 8;  // In CompositeOracle, ERC4626OracleFeed, etc.
```

### Proposed Solution

```solidity
// ConstantsLib.sol - Add oracle-related constants

/// @notice Standard decimals for USD prices
uint8 public constant USD_DECIMALS = 8;

/// @notice Standard decimals for token amounts
uint8 public constant TOKEN_DECIMALS_UINT8 = 18;

// Remove duplicate MAX_BASIS_POINTS (use BASIS_POINT_SCALE)
// Rename MIN_BASIS_POINTS to MIN_COLLATERAL_RATIO_BP for clarity
```

### Impact

- Removes 1-2 redundant constants
- Centralizes oracle decimals
- Improves readability

### Implementation Notes (Completed January 19, 2026)

**ConstantsLib.sol changes:**
- Removed `MAX_BASIS_POINTS` (unused, duplicate of `BASIS_POINT_SCALE`)
- Removed `MIN_BASIS_POINTS` (unused, confusing name)
- Added `USD_DECIMALS = 8` (uint8 for oracle price decimals)
- Added `TOKEN_DECIMALS_UINT8 = 18` (uint8 for ERC20.decimals() compatibility)

**Updated contracts:**
- `oracles/CompositeOracle.sol` - Removed local `DECIMALS`, uses `ConstantsLib.USD_DECIMALS`
- `oracles/ERC4626OracleFeed.sol` - Removed local `DECIMALS`, uses `ConstantsLib.USD_DECIMALS`

**Tests:** All 148 oracle tests pass (including 25 ERC4626OracleFeed tests)

---

## Implementation Order

### Phase 1: Quick Wins (1-2 days)
1. ✅ **REFACTOR-4:** Add batch operations
2. ✅ **REFACTOR-5:** Add view function variants
3. ✅ **REFACTOR-6:** Consolidate constants

### Phase 2: Medium Effort (3-5 days)
4. **REFACTOR-2:** Fee calculation decomposition
   - Highest value - improves auditability of core accounting
   - Requires careful testing

### Phase 3: Lower Priority (1-2 days)
5. **REFACTOR-1:** Oracle validation library
   - Deferred until next oracle addition or audit

### Phase 4: Deferred
6. **REFACTOR-3:** Interface segregation
   - Only if compelling need arises

---

## Risk Assessment

| Refactor | Risk Level | Mitigation |
|----------|------------|------------|
| REFACTOR-1 | Low | Library is stateless, changes are mechanical |
| REFACTOR-2 | Medium | Extensive unit tests for each helper, integration tests |
| REFACTOR-3 | High | Deferred - low value vs effort |
| REFACTOR-4 | Low | New functions only, no changes to existing |
| REFACTOR-5 | Low | New function, existing unchanged |
| REFACTOR-6 | Very Low | Compile-time constants only |

---

## Testing Requirements

### For Each Refactor

1. **Unit tests** for new/modified functions
2. **Integration tests** verifying end-to-end behavior unchanged
3. **Gas comparison** before/after
4. **Fuzz tests** for edge cases (where applicable)

### Regression Test Suite

Run full test suite after each refactor:
```bash
forge test --no-match-test "Fork" -vvv
```

---

## Conclusion

The recommended approach is:
1. Start with low-risk, high-value refactors (Phase 1)
2. Tackle fee calculation decomposition when time permits (Phase 2)
3. Defer interface changes unless compelling need arises

Total estimated effort: **8-16 hours** for Phases 1-2
