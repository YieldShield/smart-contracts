# Leveraged Pools Design Document

## Overview

This document outlines the design for "Leveraged Pools" - a new pool type that accepts NFT receipts from existing SplitRiskPool positions as collateral. This enables users to create leveraged positions by using their existing pool positions as collateral for new positions.

## Motivation

Currently, users who deposit into a SplitRiskPool receive an NFT receipt representing their position. These NFTs are transferable but otherwise idle. By allowing these NFTs to be used as collateral in other pools, we enable:

1. **Capital Efficiency**: Users can put their existing positions to work
2. **Leverage**: Users can gain exposure to multiple pools with the same underlying capital
3. **Composability**: Creates building blocks for more complex DeFi strategies

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Wallet                                  │
│  ┌──────────────┐                      ┌──────────────┐             │
│  │ Underwriter  │                      │   Borrowed   │             │
│  │ NFT (Pool A) │ ──── Deposit ────▶   │   Tokens     │             │
│  └──────────────┘                      └──────────────┘             │
└─────────────────────────────────────────────────────────────────────┘
           │                                      ▲
           │                                      │
           ▼                                      │
┌─────────────────────────────────────────────────────────────────────┐
│                      LeveragedPool                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ NFT Vault                                                     │   │
│  │  - Holds deposited NFTs as collateral                        │   │
│  │  - Tracks NFT valuations via oracle                          │   │
│  │  - Manages liquidations                                       │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Lending Pool                                                  │   │
│  │  - Lenders deposit tokens to earn yield                      │   │
│  │  - Borrowers borrow against NFT collateral                   │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
           │
           │ Queries value
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      NFT Valuation Oracle                            │
│  - Queries source pool for position data                            │
│  - Gets token price from price oracle                               │
│  - Calculates: amount × price + accrued yield - locked amount       │
└─────────────────────────────────────────────────────────────────────┘
           │
           │ Queries
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Source Pool (SplitRiskPool)                     │
│  - Original pool where NFT was minted                               │
│  - Provides position data (amount, locked, available, yield)        │
└─────────────────────────────────────────────────────────────────────┘
```

### New Contracts

#### 1. LeveragedPool.sol

The main pool contract that accepts NFT collateral and enables borrowing.

```solidity
// Core functionality
contract LeveragedPool {
    // NFT Collateral Management
    function depositNFTCollateral(address sourcePool, uint256 tokenId) external;
    function withdrawNFTCollateral(uint256 collateralId) external;
    
    // Borrowing
    function borrow(uint256 collateralId, uint256 amount) external;
    function repay(uint256 collateralId, uint256 amount) external;
    
    // Lending (liquidity provision)
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    
    // Liquidation
    function liquidate(uint256 collateralId) external;
    
    // View functions
    function getCollateralValue(uint256 collateralId) external view returns (uint256);
    function getHealthFactor(uint256 collateralId) external view returns (uint256);
    function getBorrowCapacity(uint256 collateralId) external view returns (uint256);
}
```

#### 2. NFTValuationOracle.sol

Oracle contract that calculates the USD value of NFT positions.

```solidity
contract NFTValuationOracle {
    // Get the current USD value of an NFT position
    function getNFTValue(
        address sourcePool,
        uint256 tokenId,
        bool isUnderwriter
    ) external view returns (uint256 valueUsd);
    
    // Get detailed breakdown
    function getNFTValueBreakdown(
        address sourcePool,
        uint256 tokenId,
        bool isUnderwriter
    ) external view returns (
        uint256 principalValue,
        uint256 accruedYield,
        uint256 lockedValue,
        uint256 netValue
    );
}
```

#### 3. LeveragedPoolFactory.sol

Factory for deploying new leveraged pools with proper configuration.

```solidity
contract LeveragedPoolFactory {
    function createLeveragedPool(
        address borrowToken,           // Token that can be borrowed
        address priceOracle,           // Price oracle for valuations
        uint256 collateralRatio,       // Required collateral ratio (e.g., 150%)
        uint256 liquidationThreshold,  // When liquidation can occur (e.g., 120%)
        uint256 liquidationBonus       // Bonus for liquidators (e.g., 5%)
    ) external returns (address pool);
}
```

## NFT Valuation

### Underwriter NFT Valuation

```
Value = (positionAmount × tokenPrice) 
      + accruedCommissions 
      - (lockedAmount × tokenPrice)  // If in unlock period
```

Components:
- `positionAmount`: From `getUnderwriterDepositInfo(tokenId).amount`
- `tokenPrice`: From price oracle
- `accruedCommissions`: From `getClaimableCommission(tokenId)`
- `lockedAmount`: From `getLockedAmount(tokenId)`

### Insured NFT Valuation

```
Value = (positionAmount × tokenPrice) 
      + accruedYield
      - pendingFees
```

Components:
- `positionAmount`: From `getInsuredDepositInfo(tokenId).amount`
- `tokenPrice`: From price oracle
- `accruedYield`: Calculated from yield earned since deposit
- `pendingFees`: Commission + pool fee + protocol fee on yield

### Valuation Considerations

1. **Stale Price Protection**: Use circuit breakers if price deviates significantly
2. **Source Pool Health**: Discount value if source pool is undercollateralized
3. **Unlock Status**: Further discount if unlock process has been initiated
4. **Haircut**: Apply a safety haircut (e.g., 10%) to account for liquidation slippage

## Risk Management

### 1. Cascading Risk Mitigation

**Problem**: If Pool A fails, NFTs from Pool A lose value, causing Pool B to fail.

**Mitigations**:
- **Leverage Depth Limit**: NFTs from LeveragedPools cannot be used as collateral (max depth = 1)
- **Source Pool Health Check**: Reject NFTs from pools with utilization > 90%
- **Concentration Limits**: Max 20% of total collateral from any single source pool
- **Insurance Fund**: Portion of fees go to insurance fund for bad debt

### 2. Liquidation Mechanism

```solidity
struct LiquidationParams {
    uint256 liquidationThreshold;  // e.g., 120% - when liquidation can start
    uint256 liquidationBonus;      // e.g., 5% - incentive for liquidators
    uint256 maxLiquidationAmount;  // Max % of position liquidatable at once
}
```

**Liquidation Process**:
1. Anyone can call `liquidate()` when health factor < 1
2. Liquidator repays portion of debt
3. Liquidator receives NFT collateral + bonus
4. If NFT is worth more than debt + bonus, remainder goes to original owner

### 3. Bad Debt Handling

If NFT value drops below debt (underwater position):
1. Protocol insurance fund covers shortfall
2. If insurance fund insufficient, socialize loss among lenders
3. Pause new borrows until resolved

### 4. Transfer Lock Handling

**Problem**: Source pool NFTs have transfer locks.

**Solution**:
- LeveragedPool must receive actual NFT ownership (not just approval)
- Original owner cannot withdraw from source pool while NFT is collateral
- Original owner can still claim yields/commissions (routed through LeveragedPool)

## Economic Parameters

### Suggested Default Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Collateral Ratio | 200% | Higher than normal pools due to NFT complexity |
| Liquidation Threshold | 150% | Buffer before liquidation |
| Liquidation Bonus | 5% | Incentive for liquidators |
| Max Borrow Utilization | 80% | Maintain liquidity for withdrawals |
| Source Pool Max Utilization | 90% | Don't accept NFTs from stressed pools |
| Concentration Limit | 20% | Max exposure to single source pool |
| Leverage Depth | 1 | NFTs from leveraged pools not accepted |
| Valuation Haircut | 10% | Safety buffer on NFT valuations |

### Interest Rate Model

Use a utilization-based interest rate model (similar to Aave/Compound):

```
If utilization < 80%:
    rate = baseRate + utilization × slope1
    
If utilization >= 80%:
    rate = baseRate + 0.8 × slope1 + (utilization - 0.8) × slope2
```

Suggested parameters:
- Base Rate: 2% APY
- Slope 1: 4% (rate at 80% utilization = 2% + 3.2% = 5.2%)
- Slope 2: 75% (rate at 100% utilization = 5.2% + 15% = 20.2%)

## Yield Routing

### Option A: Pass-Through (Recommended)

Yields from underlying NFT positions pass through to the NFT owner (borrower):

```solidity
function claimUnderlyingYield(uint256 collateralId) external {
    // Only the original depositor can claim
    require(msg.sender == collateralOwner[collateralId]);
    
    // Claim from source pool
    address sourcePool = collateral[collateralId].sourcePool;
    uint256 tokenId = collateral[collateralId].tokenId;
    
    // Route yield to owner
    ISplitRiskPool(sourcePool).claimRewards(tokenId);
    // Transfer claimed amount to owner
}
```

### Option B: Yield as Additional Collateral

Yields automatically add to collateral value:
- Improves health factor over time
- More complex accounting
- Owner claims yield when withdrawing collateral

## Security Considerations

### 1. Reentrancy

- Use ReentrancyGuard on all state-changing functions
- Follow checks-effects-interactions pattern
- Be careful with external calls to source pools

### 2. Oracle Manipulation

- Use TWAP or multiple oracle sources
- Circuit breakers for large price movements
- Minimum collateral age before borrowing

### 3. Flash Loan Attacks

```
Attack vector:
1. Flash loan large amount
2. Manipulate NFT valuation 
3. Borrow max against inflated collateral
4. Repay flash loan, keep borrowed funds
```

**Mitigations**:
- Time-weighted average for NFT valuations
- Minimum collateral deposit time before borrowing (e.g., 1 block)
- Max borrow per transaction limits

### 4. Governance Attacks

- Timelock on parameter changes
- Multi-sig for emergency functions
- Gradual parameter changes (max 10% per day)

## Implementation Phases

### Phase 1: Core Infrastructure (2-3 weeks)

1. **NFTValuationOracle**
   - Implement valuation logic for underwriter NFTs
   - Implement valuation logic for insured NFTs
   - Add circuit breakers and safety checks

2. **LeveragedPool (Basic)**
   - NFT deposit/withdrawal
   - Basic borrow/repay
   - Simple liquidation

### Phase 2: Risk Management (2 weeks)

1. **Advanced Liquidation**
   - Partial liquidation support
   - Dutch auction for NFTs
   - Bad debt handling

2. **Risk Parameters**
   - Source pool health checks
   - Concentration limits
   - Emergency pause functionality

### Phase 3: Optimization (1-2 weeks)

1. **Gas Optimization**
   - Batch operations
   - Storage optimization

2. **Interest Rate Model**
   - Dynamic rates based on utilization
   - Rate accumulator pattern

### Phase 4: Testing & Audit (2-4 weeks)

1. **Comprehensive Testing**
   - Unit tests for all functions
   - Integration tests with existing pools
   - Fuzz testing for edge cases
   - Invariant testing

2. **Security Audit**
   - External audit by reputable firm
   - Bug bounty program

## Open Questions

1. **Yield Routing**: Should yields from collateral NFTs be claimable by the depositor, or locked as additional collateral?

2. **Multiple NFTs**: Should users be able to deposit multiple NFTs as collateral for a single borrow position?

3. **Partial Collateral**: Should users be able to use only a portion of an NFT's value as collateral?

4. **Cross-Chain**: Should leveraged pools work across chains with bridged NFTs?

5. **NFT Standards**: Should we support any ERC721, or only our specific receipt NFTs?

## Appendix: Interface Definitions

### ILeveragedPool

```solidity
interface ILeveragedPool {
    // Events
    event CollateralDeposited(address indexed user, address sourcePool, uint256 tokenId, uint256 collateralId);
    event CollateralWithdrawn(address indexed user, uint256 collateralId);
    event Borrowed(address indexed user, uint256 collateralId, uint256 amount);
    event Repaid(address indexed user, uint256 collateralId, uint256 amount);
    event Liquidated(address indexed liquidator, uint256 collateralId, uint256 debtRepaid, uint256 collateralSeized);
    
    // Collateral management
    function depositNFTCollateral(address sourcePool, uint256 tokenId, bool isUnderwriter) external returns (uint256 collateralId);
    function withdrawNFTCollateral(uint256 collateralId) external;
    
    // Borrowing
    function borrow(uint256 collateralId, uint256 amount) external;
    function repay(uint256 collateralId, uint256 amount) external;
    function repayAll(uint256 collateralId) external;
    
    // Liquidation
    function liquidate(uint256 collateralId, uint256 debtToCover) external;
    
    // View functions
    function getCollateralValue(uint256 collateralId) external view returns (uint256);
    function getDebt(uint256 collateralId) external view returns (uint256);
    function getHealthFactor(uint256 collateralId) external view returns (uint256);
    function getBorrowCapacity(uint256 collateralId) external view returns (uint256);
    function isLiquidatable(uint256 collateralId) external view returns (bool);
}
```

### INFTValuationOracle

```solidity
interface INFTValuationOracle {
    // Get NFT value in USD (8 decimals)
    function getNFTValue(
        address sourcePool,
        uint256 tokenId,
        bool isUnderwriter
    ) external view returns (uint256 valueUsd);
    
    // Check if NFT is acceptable as collateral
    function isAcceptableCollateral(
        address sourcePool,
        uint256 tokenId,
        bool isUnderwriter
    ) external view returns (bool acceptable, string memory reason);
    
    // Get source pool health
    function getSourcePoolHealth(address sourcePool) external view returns (uint256 healthScore);
}
```

## Conclusion

Leveraged pools represent a significant expansion of the YieldShield protocol's capabilities. While complex, the design prioritizes safety through:

1. Conservative collateral ratios
2. Multiple layers of risk management
3. Clear liquidation mechanisms
4. Isolation from base protocol

The phased implementation approach allows for iterative development and thorough testing before mainnet deployment.
