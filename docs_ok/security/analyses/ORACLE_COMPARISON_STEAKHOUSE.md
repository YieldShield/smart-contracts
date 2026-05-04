# Oracle Implementation Comparison: YieldShield vs Steakhouse MetaOracle

## Executive Summary

This document compares YieldShield's oracle implementation with Steakhouse Financial's MetaOracle approach, as detailed in their article "No Country for Old Prices: A Field Guide to DeFi Oracles" and their open-source implementation at [steakhouse-oracles](https://github.com/Steakhouse-Financial/steakhouse-oracles).

**Status Update (January 2026)**: YieldShield has now implemented a comprehensive oracle architecture inspired by Steakhouse's MetaOracle pattern. The implementation includes dual-oracle support, graceful degradation, challenge/timelock mechanisms, and multiple oracle adapters.

---

## 1. Overview of Approaches

### 1.1 YieldShield Oracle Architecture (Current)

YieldShield now provides a multi-layered oracle system:

**Core Components:**
- `PythOracle` - Primary oracle with staleness checks, EMA circuit breaker, and graceful degradation
- `MetaOracleAdapter` - Dual-oracle adapter with challenge/timelock switching mechanism
- `ERC4626OracleFeed` - NAV-based pricing for yield-bearing vaults
- `ChainlinkOracleFeed` - Chainlink price feed adapter
- `PythEMAOracleFeed` - Pyth EMA-only feed for stability-focused pricing
- `UniswapV3TWAPFeed` - TWAP pricing from Uniswap V3 pools

**Key Features:**
- **Graceful degradation**: Falls back to EMA instead of reverting during volatility
- **Dual-oracle support**: Primary (stability) + backup (market-responsive) with challenge mechanism
- **16-hour timelock**: Prevents hasty oracle switches during temporary deviations
- **Automatic recovery**: `revertToPrimary()` when market stabilizes

```solidity
// YieldShield's graceful degradation approach
function getPriceWithFallback(address token) external view returns (uint256 price, bool isReliable) {
    bytes32 feedId = _getFeedId(token);
    uint256 spotPrice = _convertPrice(pyth.getPriceNoOlderThan(feedId, maxPriceAge));
    uint256 emaPrice = _convertPrice(pyth.getEmaPriceNoOlderThan(feedId, maxPriceAge));
    
    uint256 deviation = calculateDeviation(spotPrice, emaPrice);
    if (deviation > maxPriceDeviation) {
        return (emaPrice, false); // Graceful fallback instead of revert
    }
    return (spotPrice, true);
}
```

### 1.2 Steakhouse MetaOracle

MetaOracle provides an adaptive dual-oracle system:
- **Primary Oracle**: Stability-focused (e.g., NAV/TWAP, resists short-term volatility)
- **Backup Oracle**: Market-responsive (e.g., Chainlink spot, reflects real-time prices)
- **Challenge mechanism**: Anyone can challenge when deviation exceeds threshold
- **Timelock**: 16-hour delay before switching to backup oracle

---

## 2. Detailed Comparison

### 2.1 Oracle Types Supported

| Feature | YieldShield | Steakhouse MetaOracle |
|---------|-------------|----------------------|
| Pyth Network | ✅ `PythOracle` | ❌ Not mentioned |
| Chainlink | ✅ `ChainlinkOracleFeed` | ✅ Supported |
| Chronicle | ❌ Not yet | ✅ Supported |
| TWAP/AMM | ✅ `UniswapV3TWAPFeed` | ✅ Pendle TWAP |
| NAV/Exchange Rate | ✅ `ERC4626OracleFeed` | ✅ ERC4626Feed |
| EMA-based | ✅ `PythEMAOracleFeed` | ❌ Different approach |
| Hardcoded | ✅ `MockOracle` | ✅ Supported |

### 2.2 Price Staleness Protection

| Aspect | YieldShield | Steakhouse |
|--------|-------------|------------|
| Staleness check | ✅ Configurable per-feed | Per-feed basis |
| Revert on stale | ✅ Yes | Depends on feed |
| Configurable | ✅ Owner can update | Per-feed config |

**YieldShield Implementation:**
```solidity
// All oracle feeds support staleness configuration
PythOracle: maxPriceAge (default 60s)
ChainlinkOracleFeed: maxPriceAge (configurable)
UniswapV3TWAPFeed: twapPeriod (default 30 min)
```

### 2.3 Manipulation Protection

| Mechanism | YieldShield | Steakhouse |
|-----------|-------------|------------|
| Spot vs EMA comparison | ✅ (5% default threshold) | ❌ Different approach |
| Deviation threshold | ✅ Configurable (0.75% default in MetaOracle) | ✅ 0.75% for challenge |
| Challenge timelock | ✅ 16-hour delay | ✅ 16-hour delay |
| Dual oracle switching | ✅ `MetaOracleAdapter` | ✅ Primary/Backup |
| Graceful fallback | ✅ `getPriceWithFallback()` | ❌ Different approach |
| Automatic recovery | ✅ `revertToPrimary()` | Varies |

**Key Implementation**: YieldShield now supports **both** approaches:
1. **Aggressive protection**: `getPriceWithCircuitBreaker()` reverts on manipulation
2. **Graceful degradation**: `getPriceWithFallback()` returns EMA with `isReliable=false`

### 2.4 Different Market Conditions

Steakhouse's article identifies three price feed types:
1. **Market Price**: Observed trading prices (spot, TWAP, VWAP)
2. **NAV (Net Asset Value)**: Intrinsic value from underlying holdings
3. **Hardcoded**: Fixed rates (e.g., 1 USDT = 1 USDC)

**YieldShield Support:**

| Feed Type | YieldShield Implementation |
|-----------|---------------------------|
| Market Price | `PythOracle`, `ChainlinkOracleFeed`, `UniswapV3TWAPFeed` |
| NAV | `ERC4626OracleFeed` |
| EMA (stability) | `PythEMAOracleFeed` |
| Dual-oracle | `MetaOracleAdapter` |

---

## 3. Specific Vulnerabilities Addressed

### 3.1 Short-Term Volatility

**Scenario**: USDe briefly trades at 0.65 on CEXs but remains near parity on-chain.

| Protocol | Response |
|----------|----------|
| YieldShield (old) | Circuit breaker would trigger, blocking transactions |
| YieldShield (new) | `getPriceWithFallback()` returns EMA price with `isReliable=false`; MetaOracleAdapter continues with primary (NAV) pricing |
| Steakhouse | Primary oracle (NAV) continues normal operation |

**Result**: ✅ YieldShield now **continues operating** during short-term volatility.

### 3.2 Sustained Depegs

**Scenario**: Token permanently loses peg (e.g., issuer failure).

| Protocol | Response |
|----------|----------|
| YieldShield (old) | Circuit breaker may continuously trigger, preventing withdrawals |
| YieldShield (new) | After challenge + 16h timelock, MetaOracleAdapter switches to market oracle; `revertToPrimary()` available when deviation resolves |
| Steakhouse | After 16h challenge period, switches to market oracle |

**Result**: ✅ YieldShield now handles long-term depegs gracefully.

### 3.3 Oracle Manipulation Attacks

**Scenario**: Attacker manipulates on-chain price to extract value.

| Protocol | Response |
|----------|----------|
| YieldShield | `getPriceWithCircuitBreaker()` reverts if spot deviates >5% from EMA; MetaOracleAdapter requires 16h timelock before switching |
| Steakhouse | Challenge mechanism + timelock prevents instant exploitation |

**Result**: ✅ Both provide equivalent protection.

---

## 4. YieldShield Oracle Components

### 4.1 MetaOracleAdapter

The core dual-oracle switching mechanism:

```solidity
contract MetaOracleAdapter is IPriceOracleAdapter, Ownable {
    IOracleFeed public immutable _primaryFeed;   // Stability-focused (NAV, EMA)
    IOracleFeed public immutable _backupFeed;    // Market-responsive (Pyth spot)
    
    uint256 public immutable _deviationThreshold;     // e.g., 0.75%
    uint256 public immutable _challengeDuration;      // e.g., 16 hours
    
    bool public _isBackupActive;
    uint256 public _challengeStartTime;
    address public challengedToken;
    
    function challengeForToken(address token) external {
        // Anyone can call if deviation > threshold
        uint256 primaryPrice = _primaryFeed.getPrice(token);
        uint256 backupPrice = _backupFeed.getPrice(token);
        uint256 deviation = _calculateDeviation(primaryPrice, backupPrice);
        
        require(deviation > _deviationThreshold, "Deviation below threshold");
        challengedToken = token;
        _challengeStartTime = block.timestamp;
    }
    
    function finalizeChallenge() external {
        require(block.timestamp >= _challengeStartTime + _challengeDuration);
        // Verify deviation still persists for challenged token
        uint256 currentDeviation = _calculateDeviation(...);
        if (currentDeviation <= _deviationThreshold) {
            // Auto-cancel if deviation resolved
            _challengeStartTime = 0;
            return;
        }
        _isBackupActive = true;
    }
    
    function revertToPrimary(address token) external {
        // Anyone can call when deviation returns to normal
        require(_isBackupActive, "Primary already active");
        uint256 deviation = _calculateDeviation(...);
        require(deviation <= _deviationThreshold, "Deviation still high");
        _isBackupActive = false;
    }
}
```

### 4.2 Supported Oracle Feeds

YieldShield provides various oracle adapters:

| Feed | File | Purpose |
|------|------|---------|
| `PythOracle` | `oracles/PythOracle.sol` | Pyth Network with EMA circuit breaker |
| `PythEMAOracleFeed` | `oracles/PythEMAOracleFeed.sol` | Pyth EMA-only for stability |
| `ChainlinkOracleFeed` | `oracles/ChainlinkOracleFeed.sol` | Chainlink AggregatorV3 integration |
| `ERC4626OracleFeed` | `oracles/ERC4626OracleFeed.sol` | NAV from ERC4626 vaults |
| `UniswapV3TWAPFeed` | `oracles/UniswapV3TWAPFeed.sol` | TWAP from Uniswap V3 |
| `MockOracle` | `mocks/MockOracle.sol` | Testing and hardcoded prices |

### 4.3 Deployment Approach

YieldShield deploys concrete oracle components directly and wires them together in deployment scripts. There is no standalone oracle factory in the current architecture.

---

## 5. Implementation Status

### 5.1 Completed Recommendations

| Recommendation | Status | Implementation |
|----------------|--------|----------------|
| R1: Dual-Oracle Architecture | ✅ **DONE** | `MetaOracleAdapter` with challenge/timelock |
| R2: ERC4626 NAV Oracle | ✅ **DONE** | `ERC4626OracleFeed` |
| R3: Graceful Degradation | ✅ **DONE** | `getPriceWithFallback()` in PythOracle |
| R4: Timelock-Based Switching | ✅ **DONE** | 16h challenge duration in MetaOracleAdapter |
| R5: Multiple Oracle Sources | ✅ **DONE** | Chainlink, Pyth, TWAP, NAV adapters |
| R6: Chainlink Support | ✅ **DONE** | `ChainlinkOracleFeed` |
| R7: TWAP Oracle | ✅ **DONE** | `UniswapV3TWAPFeed` |

### 5.2 Remaining Gaps

| Feature | YieldShield | Steakhouse | Priority |
|---------|-------------|------------|----------|
| Chronicle Protocol | ❌ Not implemented | ✅ Supported | Low |
| Pendle PT TWAP | ❌ Not implemented | ✅ Supported | Low |
| Multi-sig Oracle | ❌ Not implemented | ✅ MSigOracleFeed | Low |

---

## 6. Risk Analysis

### Current YieldShield Risks (Post-Implementation)

| Risk | Severity | Mitigation Status |
|------|----------|-------------------|
| Stale prices | Low | ✅ Staleness checks on all feeds |
| Flash manipulation | Low | ✅ EMA circuit breaker + timelock |
| Long-term depeg | Low | ✅ Automatic oracle switching |
| Oracle downtime | Low | ✅ Multiple oracle sources + fallback |
| Single oracle dependency | Low | ✅ Multi-oracle support |
| Blocked operations | Low | ✅ Graceful degradation |

### Comparison to Original Analysis

| Risk | Before | After |
|------|--------|-------|
| Stale prices | High → ✅ Mitigated | Low |
| Flash manipulation | High → ✅ Mitigated | Low |
| Long-term depeg | Medium → ⚠️ Partial | ✅ Low |
| Oracle downtime | Medium → ❌ Not addressed | ✅ Low |
| Single oracle dependency | Medium → ❌ Not addressed | ✅ Low |

---

## 7. Usage Examples

### 7.1 Basic Pool with Pyth Oracle

```solidity
// Deploy Pyth oracle
PythOracle pythOracle = new PythOracle(PYTH_ADDRESS, 60);
pythOracle.setTokenPriceFeed(token, ETH_USD_FEED_ID);

// Set as pool oracle
factory.setDefaultPriceOracle(address(pythOracle));
```

### 7.2 Dual-Oracle with NAV Primary

```solidity
// Create NAV-based primary + market backup
(address adapter, address navFeed) = oracleFactory.createDualOracleStackWithNAV(
    address(underlyingOracle), // For NAV calculation
    address(pythOracle)        // Market-responsive backup
);

// Register vault in NAV feed
ERC4626OracleFeed(navFeed).registerVault(vaultAddress, underlyingToken);

// Set as pool oracle
factory.setDefaultPriceOracle(adapter);
```

### 7.3 Pyth EMA/Spot Dual Oracle

```solidity
// Create Pyth-based dual oracle (EMA primary, spot backup)
(address adapter, address emaFeed) = oracleFactory.createPythDualOracle(
    PYTH_ADDRESS,
    address(existingPythOracle), // Spot prices as backup
    3600 // 1 hour max age
);

// Configure token feeds on EMA feed
PythEMAOracleFeed(emaFeed).setTokenPriceFeed(token, feedId);
```

### 7.4 Query Oracle Info from Pool

```solidity
// Check if pool uses dual-oracle
(
    address oracle,
    bool isDualOracle,
    address primaryFeed,
    address backupFeed,
    bool isBackupActive
) = pool.getOracleInfo();

if (isDualOracle && isBackupActive) {
    // Pool is using market-responsive pricing
}
```

---

## 8. Conclusion

YieldShield has successfully implemented a comprehensive oracle architecture that matches and in some cases exceeds Steakhouse's MetaOracle capabilities:

| Capability | Steakhouse | YieldShield |
|------------|------------|-------------|
| Dual-oracle switching | ✅ | ✅ |
| Challenge/timelock | ✅ | ✅ |
| NAV pricing | ✅ | ✅ |
| Graceful degradation | Varies | ✅ (EMA fallback) |
| Automatic recovery | Varies | ✅ (`revertToPrimary()`) |
| TWAP support | ✅ Pendle | ✅ Uniswap V3 |
| Chainlink | ✅ | ✅ |
| Pyth Network | ❌ | ✅ |

**Key Advantages of YieldShield Implementation:**
1. **Pyth Network support** - First-class integration with Pyth's pull oracle model
2. **Graceful degradation** - Returns EMA with reliability flag instead of reverting
3. **Automatic recovery** - Anyone can call `revertToPrimary()` when deviation resolves
4. **Pool integration** - `getOracleInfo()` for transparent oracle status

---

## References

1. Steakhouse Financial. "No Country for Old Prices: A Field Guide to DeFi Oracles." [kitchen.steakhouse.financial](https://kitchen.steakhouse.financial/p/no-country-for-old-prices-a-field)
2. Steakhouse Oracles GitHub. [github.com/Steakhouse-Financial/steakhouse-oracles](https://github.com/Steakhouse-Financial/steakhouse-oracles)
3. Pyth Network Documentation. [docs.pyth.network](https://docs.pyth.network/)
4. MetaOracle Cantina Audit. Available in steakhouse-oracles repository.

---

## Appendix: File Locations

| Component | Path |
|-----------|------|
| PythOracle | `contracts/oracles/PythOracle.sol` |
| MetaOracleAdapter | `contracts/oracles/MetaOracleAdapter.sol` |
| ERC4626OracleFeed | `contracts/oracles/ERC4626OracleFeed.sol` |
| ChainlinkOracleFeed | `contracts/oracles/ChainlinkOracleFeed.sol` |
| PythEMAOracleFeed | `contracts/oracles/PythEMAOracleFeed.sol` |
| UniswapV3TWAPFeed | `contracts/oracles/UniswapV3TWAPFeed.sol` |
| IPriceOracleAdapter | `contracts/interfaces/IPriceOracleAdapter.sol` |
| IOracleFeed | `contracts/interfaces/IOracleFeed.sol` |
| Fork Tests | `test/OracleFork.t.sol` |
