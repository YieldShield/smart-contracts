# YieldShield Smart Contract Security Audit Overview

## Executive Summary

YieldShield is a decentralized balance protection protocol that enables users to insure yield-bearing assets by pairing them with underwriter collateral. The protocol uses a pool-based model where insured deposits are matched with underwriter deposits at a configurable collateral ratio. The system tracks yield earned on insured assets and distributes it among underwriters (as commission), pool creators, and the protocol, while ensuring insured users can withdraw their principal at the original USD value.

## System Architecture

### Core Contracts

1. **SplitRiskPool** - Main pool contract managing deposits, withdrawals, and yield distribution
2. **SplitRiskPoolFactory** - Factory contract for creating and managing pools
3. **Tranche** - ERC20 receipt tokens representing claims on pool assets
4. **YSGovernor** - Governance contract for protocol parameter management
5. **YSToken** - Governance token with voting capabilities

### Supporting Infrastructure

- **Price Oracle** (IPriceOracle) - Provides USD valuations for tokens
- **Access Control** (IPoolAccessControl) - Optional per-pool access restrictions
- **Protocol Access Control** - Base contract for governance and pausability

## Core Concepts

### Pool Structure

Each pool consists of:
- **Insured Token**: The yield-bearing asset being insured (e.g., aUSDC, stETH)
- **Underwriter Token**: The collateral asset backing the insurance (e.g., USDC, ETH)
- **Collateral Ratio**: The ratio of underwriter tokens required per unit of insured tokens (e.g., 150% = 1.5x)
- **Commission Rate**: Percentage of yield paid to underwriters (in basis points)
- **Pool Fee**: Percentage of yield paid to pool creator (in basis points)
- **Protocol Fee**: Percentage of yield paid to protocol (in basis points)

### Receipt Tokens

The protocol issues two types of receipt tokens:
- **INSURED_RECEIPT_TOKEN**: Represents insured deposits (1:1 with deposited amount)
- **UNDERWRITER_RECEIPT_TOKEN**: Represents underwriter deposits (1:1 with deposited amount)

These tokens are ERC20 tokens with permit functionality, allowing users to transfer their positions.

## Critical Invariants

### 1. Pool Balance Invariants

**INVARIANT 1.1**: Pool state balances must always match actual token balances
```solidity
poolState.insuredTokenBalance == IERC20(INSURED_TOKEN).balanceOf(address(this))
poolState.totalUnderwriteTokenBalance == IERC20(UNDERWRITER_TOKEN).balanceOf(address(this))
```

**INVARIANT 1.2**: Pool balances must track all deposits and withdrawals
- When insured deposits: `poolState.insuredTokenBalance += received`
- When underwriter deposits: `poolState.totalUnderwriteTokenBalance += received`
- When insured withdraws: `poolState.insuredTokenBalance -= amountWithdrawn`
- When underwriter withdraws: `poolState.totalUnderwriteTokenBalance -= amountWithdrawn`

### 2. Collateralization Invariants

**INVARIANT 2.1**: Underwriter tokens must be locked when insured deposits are made
- Collateralization is based on original deposit values (`valueAtDeposit`), not current token amounts
- For each insured deposit, `collateralizedAmount = valueAtDeposit * COLLATERAL_RATIO / BASIS_POINT_SCALE`
- The sum of all `valueAtDeposit` values is tracked as `totalValueAtDeposit`
- Required collateral = `totalValueAtDeposit * COLLATERAL_RATIO / BASIS_POINT_SCALE` (in USD)
- The matched underwriter's `lockedAmount` must be increased by at least `collateralizedAmount`
- `underwriterDepositMapped[underwriter].amount - lockedAmount >= collateralizedAmount` must hold before new insured deposits

**INVARIANT 2.2**: Locked amounts cannot exceed total underwriter deposits
- `underwriterDepositMapped[address].lockedAmount <= underwriterDepositMapped[address].amount` (always)

**INVARIANT 2.3**: Unlocked underwriter tokens available for withdrawal
- `availableUnlockedAmount = amount - lockedAmount`
- Withdrawals can only use `availableUnlockedAmount`
- Available amount is calculated based on original deposit values (`totalValueAtDeposit`), ensuring insured token appreciation doesn't lock additional collateral

**INVARIANT 2.4**: Total valueAtDeposit consistency
- `totalValueAtDeposit == sum of all pos.valueAtDeposit where !pos.isWithdrawn`
- Maintained by deposit/withdraw operations:
  - `depositInsuredAsset`: `totalValueAtDeposit += valueAtDeposit`
  - `insuredWithdraw`: `totalValueAtDeposit -= pos.valueAtDeposit`
  - `partialWithdrawInsured`: `totalValueAtDeposit -= pos.valueAtDeposit`, then `totalValueAtDeposit += (pos.valueAtDeposit * remaining / pos.amount)`
  - `claimRewards`: Does NOT change `totalValueAtDeposit` (original deposit value remains unchanged)

### 3. Receipt Token Invariants

**INVARIANT 3.1**: Receipt tokens are minted 1:1 with deposits
- Insured deposit of `X` tokens → mint `X` INSURED_RECEIPT_TOKEN
- Underwriter deposit of `Y` tokens → mint `Y` UNDERWRITER_RECEIPT_TOKEN

**INVARIANT 3.2**: Receipt tokens are burned 1:1 with withdrawals
- Withdrawal of `X` insured tokens → burn `X` INSURED_RECEIPT_TOKEN
- Withdrawal of `Y` underwriter tokens → burn `Y` UNDERWRITER_RECEIPT_TOKEN

**INVARIANT 3.3**: Receipt token balance must match deposit amount for withdrawals
- `ITranche(INSURED_RECEIPT_TOKEN).balanceOf(user) >= insuredTokenOfWithdrawer` (checked before withdrawal)
- `ITranche(UNDERWRITER_RECEIPT_TOKEN).balanceOf(user) >= totalTokensToWithdraw` (checked before withdrawal)

### 4. Fee Accumulation Invariants

**INVARIANT 4.1**: Fees are calculated from yield, not principal
- `yieldEarned = currentValue - valueOfDeposit` (only if positive)
- Fees are calculated as: `yieldEarned * feeRate / BASIS_POINT_SCALE`
- Fees are deducted from insured token balance, not added to it

**INVARIANT 4.2**: Fee accumulators must match actual fee calculations
- `accumulatedPoolFee` tracks pool fees from all deposits
- `accumulatedProtocolFee` tracks protocol fees from all deposits
- `underwriterDepositMapped[address].commissionAmount` tracks individual underwriter commissions

**INVARIANT 4.3**: Fees reduce insured token amount
- After fee calculation: `insuredDepositMapped[address][index].amount -= (commissionAmount + poolFeeAmount + protocolFeeAmount)`
- Fees are paid from the insured token balance in the pool

### 5. Withdrawal Value Invariants

**INVARIANT 5.1**: Insured withdrawals at original USD value (CRITICAL)
- When withdrawing underwriter tokens, the insured user receives: `(valueOfDeposit * 1e18) / underwriterPrice`
- `valueOfDeposit` is stored at deposit time and represents the USD value (8 decimals)
- This ensures insured users get their principal back in USD terms, regardless of insured token price changes

**INVARIANT 5.2**: Insured withdrawals in insured tokens deduct fees
- When withdrawing insured tokens: `payoutAmount = insuredTokenAmount - commissionAmount - poolFeeAmount - protocolFeeAmount`
- The user receives the remaining insured tokens after fees

**INVARIANT 5.3**: Withdrawal unlocks matched underwriter tokens
- When insured withdraws, matched underwriter's `lockedAmount` is reduced
- `lockedAmount = max(0, lockedAmount - insuredTokenOfWithdrawer)`

### 6. Deposit Tracking Invariants

**INVARIANT 6.1**: Each insured deposit is tracked independently
- `insuredDepositMapped[address]` is an array, allowing multiple deposits per user
- Each deposit has: `amount`, `poolTime`, `underwriterAddress`, `isWithdrawn`, `valueOfDeposit`

**INVARIANT 6.2**: Deposits cannot be double-withdrawn
- `isWithdrawn` flag prevents multiple withdrawals of the same deposit
- Once `isWithdrawn = true`, the deposit cannot be withdrawn again

**INVARIANT 6.3**: Pool time tracking for minimum lock period
- `poolTime` is set to `block.timestamp` at deposit
- Minimum pool time must elapse before withdrawing underwriter tokens: `block.timestamp - poolTime >= minimumPoolTime`

### 7. Unlock Process Invariants

**INVARIANT 7.1**: Unlock process must be started before withdrawal
- `lockedUntil = 1` means unlock process not started
- `lockedUntil = 0` means fully unlocked
- `lockedUntil > 1` means unlock process started, tokens unlock at that timestamp

**INVARIANT 7.2**: Unlock duration must pass before tokens are available
- `lockedUntil <= block.timestamp` must be true for withdrawal
- Unlock duration is configurable (default 28 days)

**INVARIANT 7.3**: Unlock process can only be started once
- If `lockedUntil != 0 && lockedUntil != 1`, unlock process already started

### 8. TVL and Deposit Limit Invariants

**INVARIANT 8.1**: Total Value Locked cannot exceed maximum
- `_getTotalPoolValue() + depositAmount <= maxTotalValueLocked`
- `_getTotalPoolValue() = poolState.insuredTokenBalance + poolState.totalUnderwriteTokenBalance`

**INVARIANT 8.2**: Individual deposits must be within bounds
- `minDepositAmount < depositAmount <= maxDepositAmount`

### 9. Access Control Invariants

**INVARIANT 9.1**: Optional per-pool access control
- If `accessControl != address(0)`, access control checks are enforced
- If `accessControl == address(0)`, no restrictions (default)

**INVARIANT 9.2**: Pool creator can set access control
- Only `POOL_CREATOR` can call `setAccessControl()`

### 10. Governance Invariants

**INVARIANT 10.1**: Only governance timelock can update pool config
- `updatePoolConfig()` requires `onlyGovernance` modifier
- Only governance can upgrade implementation (`_authorizeUpgrade`)

**INVARIANT 10.2**: Protocol parameters have maximum bounds
- `COMMISSION_RATE <= MAX_COMMISSION_RATE` (5000 = 50%)
- `POOL_FEE <= MAX_POOL_FEE` (2000 = 20%)
- `COLLATERAL_RATIO <= MAX_COLLATERAL_RATIO` (50000 = 500%)

## Key Operations and Flows

### 1. Pool Creation Flow

1. Factory validates tokens are whitelisted
2. Factory validates pool parameters (commission rate, pool fee, collateral ratio)
3. Factory deploys new SplitRiskPool via UUPS proxy
4. Pool initializes with:
   - Token addresses (insured and underwriter)
   - Fee rates (commission, pool fee, protocol fee)
   - Collateral ratio
   - Price oracle address
   - Creates two Tranche receipt tokens
5. Pool info stored in factory

**Access Control**: Anyone can create pools (if tokens are whitelisted)

### 2. Underwriter Deposit Flow

1. User calls `depositUnderwriteAsset(asset, depositAmount, minReceiptAmount)`
2. Validations:
   - `depositAmount > minDepositAmount`
   - `depositAmount <= maxDepositAmount`
   - `asset == UNDERWRITER_TOKEN`
   - `_getTotalPoolValue() + depositAmount <= maxTotalValueLocked`
   - Optional access control check
3. Transfer tokens from user (handles fee-on-transfer tokens)
4. Update `poolState.totalUnderwriteTokenBalance += received`
5. Update `underwriterDepositMapped[msg.sender].amount += received`
6. Track underwriter address if new
7. Mint receipt tokens: `ITranche(UNDERWRITER_RECEIPT_TOKEN).mint(msg.sender, received)`
8. Emit event

**Key Behavior**: Underwriter tokens are immediately available for matching with insured deposits (but will be locked when matched)

### 3. Insured Deposit Flow

1. User calls `depositInsuredAsset(asset, depositAmount, underwriterAddress, minReceiptAmount)`
2. Validations:
   - `depositAmount > minDepositAmount`
   - `depositAmount <= maxDepositAmount`
   - `asset == INSURED_TOKEN`
   - `underwriterAddress != address(0)`
   - Underwriter has sufficient unlocked tokens
   - `_getTotalPoolValue() + depositAmount <= maxTotalValueLocked`
   - Optional access control check
3. Transfer tokens from user
4. Calculate collateral requirement:
   - `equivalentAmount = getEquivalentAmount(INSURED_TOKEN, received, UNDERWRITER_TOKEN)`
   - `collateralizedAmount = equivalentAmount * COLLATERAL_RATIO / BASIS_POINT_SCALE`
5. Verify underwriter has enough unlocked tokens:
   - `underwriterDepositMapped[underwriterAddress].amount - lockedAmount >= collateralizedAmount`
6. Lock underwriter tokens: `_lockUnderwriterTokens(collateralizedAmount, underwriterAddress)`
7. Update `poolState.insuredTokenBalance += received`
8. Calculate USD value: `valueOfDeposit = getValue(INSURED_TOKEN, received)`
9. Store deposit:
   ```solidity
   insuredDepositMapped[msg.sender].push(InsuredDeposit({
       amount: received,
       poolTime: block.timestamp,
       underwriterAddress: underwriterAddress,
       isWithdrawn: false,
       valueOfDeposit: valueOfDeposit
   }))
   ```
10. Mint receipt tokens: `ITranche(INSURED_RECEIPT_TOKEN).mint(msg.sender, received)`
11. Emit event

**Key Behavior**: 
- Each deposit is matched to a specific underwriter
- USD value is captured at deposit time (critical for withdrawal behavior)
- Underwriter tokens are locked as collateral

### 4. Insured Withdrawal Flow

**CRITICAL BEHAVIOR**: When withdrawing underwriter tokens, insured users receive tokens based on the **original USD value** of their deposit, not the current value.

#### Withdrawal in Insured Tokens

1. User calls `insuredWithdraw(withdrawIndex, INSURED_TOKEN, minAmountOut)`
2. Validations:
   - Valid deposit index
   - Sufficient receipt token balance
   - Deposit not already withdrawn
   - Optional access control check
3. Calculate fees: `_calculateAndStoreFees(index, msg.sender)`
   - `currentValue = getValue(INSURED_TOKEN, insuredTokenAmount)`
   - `yieldEarned = currentValue > valueOfDeposit ? currentValue - valueOfDeposit : 0`
   - Calculate commission, pool fee, protocol fee from yield
   - Update fee accumulators
   - Update `poolTime` to current timestamp
4. Burn receipt tokens: `ITranche(INSURED_RECEIPT_TOKEN).burn(msg.sender, insuredTokenOfWithdrawer)`
5. Mark as withdrawn: `insuredDepositMapped[msg.sender][withdrawIndex].isWithdrawn = true`
6. Calculate payout:
   - `payoutAmount = insuredTokenOfWithdrawer - commissionAmount - poolFeeAmount - protocolFeeAmount`
   - `insuredDepositMapped[msg.sender][withdrawIndex].amount = 0`
7. Update pool balance: `poolState.insuredTokenBalance -= payoutAmount`
8. Unlock matched underwriter tokens (proportional to fees paid)
9. Transfer insured tokens to user
10. Emit event

#### Withdrawal in Underwriter Tokens (CRITICAL)

1. User calls `insuredWithdraw(withdrawIndex, UNDERWRITER_TOKEN, minAmountOut)`
2. Validations:
   - Valid deposit index
   - Sufficient receipt token balance
   - Deposit not already withdrawn
   - `block.timestamp - poolTime >= minimumPoolTime` (minimum lock period)
   - Optional access control check
3. Calculate fees: `_calculateAndStoreFees(index, msg.sender)`
4. Burn receipt tokens
5. Mark as withdrawn
6. **CRITICAL CALCULATION**:
   ```solidity
   // Get original USD value stored at deposit time
   uint256 depositValueUsd = insuredDepositMapped[msg.sender][withdrawIndex].valueOfDeposit;
   
   // Get current underwriter token price (8 decimals)
   uint256 underwriterPrice = IPriceOracle(poolConfig.priceOracle).getPrice(UNDERWRITER_TOKEN);
   
   // Calculate underwriter tokens: (depositValueUsd * 1e18) / underwriterPrice
   uint256 equivalentUnderwriterAmount = (depositValueUsd * 1e18) / underwriterPrice;
   ```
7. Update deposit: `insuredDepositMapped[msg.sender][withdrawIndex].amount -= (commissionAmount + poolFeeAmount + protocolFeeAmount)`
8. Update pool balance: `poolState.totalUnderwriteTokenBalance -= equivalentUnderwriterAmount`
9. Unlock matched underwriter tokens
10. Transfer underwriter tokens to user
11. Emit event

**Key Behavior**: 
- User receives underwriter tokens based on **original USD value**, not current insured token value
- This protects insured users from insured token depegging
- Fees are still deducted from the insured token amount tracking

### 5. Underwriter Withdrawal Flow

1. User calls `underwriterWithdraw(totalTokensToWithdraw, preferredAsset, minAmountOut)`
2. Validations:
   - `totalTokensToWithdraw > 0`
   - Sufficient receipt token balance
   - `preferredAsset == UNDERWRITER_TOKEN` (insured token withdrawal not implemented)
   - Optional access control check
3. Check unlock status:
   - If `lockedUntil != 1 && lockedUntil != 0 && lockedUntil <= block.timestamp`: unlock tokens
   - `availableUnlockedAmount = amount - lockedAmount`
4. Verify sufficient unlocked tokens:
   - `totalTokensToWithdraw <= availableUnlockedAmount`
5. Update deposit: `underwriterDepositMapped[msg.sender].amount -= totalTokensToWithdraw`
6. Update pool balance: `poolState.totalUnderwriteTokenBalance -= totalTokensToWithdraw`
7. Burn receipt tokens: `ITranche(UNDERWRITER_RECEIPT_TOKEN).burn(msg.sender, totalTokensToWithdraw)`
8. Transfer tokens to user
9. Emit event

**Key Behavior**: 
- Only unlocked tokens can be withdrawn
- Unlock process must be started and completed before withdrawal

### 6. Unlock Process Flow

1. Underwriter calls `startUnlockProcess()`
2. Validations:
   - Pool has deposits (early return if empty)
   - Underwriter has deposits
   - Unlock process not already started (`lockedUntil == 0 || lockedUntil == 1`)
3. Set unlock timestamp: `lockedUntil = block.timestamp + unlockDuration`
4. Emit event

**Key Behavior**: 
- Unlock process is one-way (cannot be cancelled)
- Tokens unlock after `unlockDuration` (default 28 days)
- During unlock period, tokens remain locked and cannot be withdrawn

### 7. Fee Claiming Flow

#### Claim Rewards (for Insured)

1. Anyone can call `claimRewards(index, insuredAddress)`
2. Calculate fees: `_calculateAndStoreFees(index, insuredAddress)`
3. Reduce insured deposit amount: `insuredDepositMapped[insuredAddress][index].amount -= (commissionAmount + poolFeeAmount + protocolFeeAmount)`
4. Unlock matched underwriter tokens (proportional to fees)
5. Emit event

**Key Behavior**: 
- Fees are deducted from insured deposit amount
- This reduces the principal tracking, effectively "claiming" the yield
- Can be called multiple times as yield accumulates

#### Pay Commission (for Underwriter)

1. Underwriter calls `payCommission()`
2. Get commission amount: `underwriterDepositMapped[msg.sender].commissionAmount`
3. If zero, return early
4. Update pool balance: `poolState.insuredTokenBalance -= commissionAmount`
5. Reset commission: `underwriterDepositMapped[msg.sender].commissionAmount = 0`
6. Transfer insured tokens to underwriter
7. Emit event

**Key Behavior**: 
- Commission is paid in insured tokens (the yield-bearing asset)
- Commission accumulator is reset after payment

#### Pay Pool Fee (for Pool Creator)

1. Pool creator calls `payPoolFee()`
2. Get accumulated fee: `accumulatedPoolFee`
3. If zero, return early
4. Update pool balance: `poolState.insuredTokenBalance -= poolFeeAmount`
5. Reset accumulator: `accumulatedPoolFee = 0`
6. Transfer insured tokens to pool creator
7. Emit event

#### Pay Protocol Fee (for Protocol)

1. Anyone can call `payProtocolFee()`
2. Get accumulated fee: `accumulatedProtocolFee`
3. If zero, return early
4. Update pool balance: `poolState.insuredTokenBalance -= protocolFeeAmount`
5. Reset accumulator: `accumulatedProtocolFee = 0`
6. Transfer insured tokens to protocol fee recipient
7. Emit event

## Fee Calculation Details

### Fee Calculation Logic

Fees are calculated in `_calculateAndStoreFees()`:

```solidity
// Get current USD value of insured tokens
uint256 currentValue = IPriceOracle(poolConfig.priceOracle).getValue(INSURED_TOKEN, insuredTokenAmount);

// Calculate yield earned (only positive)
uint256 yieldEarned = currentValue > valueOfDeposit ? currentValue - valueOfDeposit : 0;

// Calculate fees as percentage of yield
commissionAmount = yieldEarned.mulDiv(COMMISSION_RATE, BASIS_POINT_SCALE, Math.Rounding.Ceil);
poolFeeAmount = yieldEarned.mulDiv(POOL_FEE, BASIS_POINT_SCALE, Math.Rounding.Ceil);
protocolFeeAmount = yieldEarned.mulDiv(poolConfig.protocolFee, BASIS_POINT_SCALE, Math.Rounding.Ceil);
```

**Key Points**:
- Fees are only calculated on yield, not principal
- If `currentValue <= valueOfDeposit`, no fees are charged (no yield earned)
- Fees use ceiling rounding (favoring fee recipients)
- Fees are stored in accumulators and deducted from insured deposit amount

### Fee Distribution

1. **Commission**: Stored per underwriter in `underwriterDepositMapped[address].commissionAmount`
2. **Pool Fee**: Stored globally in `accumulatedPoolFee`
3. **Protocol Fee**: Stored globally in `accumulatedProtocolFee`

All fees are paid from the insured token balance in the pool.

## Price Oracle Integration

### Oracle Interface

The protocol uses `IPriceOracle` interface with three key functions:
- `getPrice(token)`: Returns USD price with 8 decimals
- `getValue(token, amount)`: Returns USD value of amount (8 decimals)
- `getEquivalentAmount(tokenA, amountA, tokenB)`: Returns equivalent amount of tokenB

### Oracle Usage

1. **Deposit Time**: `getValue(INSURED_TOKEN, received)` to store `valueOfDeposit`
2. **Withdrawal Time**: 
   - `getValue(INSURED_TOKEN, insuredTokenAmount)` to calculate current value
   - `getPrice(UNDERWRITER_TOKEN)` to convert USD value to underwriter tokens
3. **Collateral Calculation**: `getEquivalentAmount(INSURED_TOKEN, received, UNDERWRITER_TOKEN)` to calculate collateral requirement

**Critical Dependency**: Oracle price accuracy and staleness checks are essential for protocol security.

## Access Control Model

### Protocol-Level Access Control

- **Owner**: Can pause/unpause, set governance timelock
- **Governance Timelock**: Can update pool config, upgrade implementation
- **Pool Creator**: Can set pool-level access control

### Pool-Level Access Control (Optional)

If `accessControl != address(0)`, the pool checks:
- `canDepositUnderwriter(address)`: For underwriter deposits
- `canDepositInsured(address)`: For insured deposits
- `canWithdrawUnderwriter(address)`: For underwriter withdrawals
- `canWithdrawInsured(address)`: For insured withdrawals

### Pausability

- Pool can be paused by owner or governance
- When paused, deposits and withdrawals are blocked
- Fee claiming is not blocked by pause

## Upgradeability

### UUPS Proxy Pattern

- Pools are deployed as UUPS (Universal Upgradeable Proxy Standard) proxies
- Implementation can be upgraded by governance
- `_authorizeUpgrade()` requires `onlyGovernance` modifier

### Factory Implementation

- Factory implementation can be upgraded by governance
- New pools use the current implementation address

## Edge Cases and Important Behaviors

### 1. Fee-on-Transfer Tokens

The protocol handles fee-on-transfer tokens by using balance-delta approach:
```solidity
uint256 beforeBal = IERC20(asset).balanceOf(address(this));
SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), depositAmount);
uint256 afterBal = IERC20(asset).balanceOf(address(this));
received = afterBal - beforeBal;
```

**Impact**: Only the actual received amount is used for all calculations.

### 2. Multiple Deposits per User

- Insured users can make multiple deposits (tracked as array)
- Each deposit is independent with its own `valueOfDeposit`, `poolTime`, and `underwriterAddress`
- Withdrawals must specify the deposit index

### 3. Underwriter Token Matching

- Insured deposits specify which underwriter to match with
- If underwriter has insufficient unlocked tokens, deposit fails
- Multiple insured deposits can match to the same underwriter
- Locked amounts accumulate per underwriter

### 4. Yield Calculation

- Yield is calculated as difference between current USD value and original USD value
- Uses oracle prices, not actual token balances
- If insured token depegs, yield calculation reflects this (but withdrawal protects principal)

### 5. Withdrawal Protection

**CRITICAL**: When withdrawing underwriter tokens:
- User receives tokens based on **original USD value** (`valueOfDeposit`)
- This protects against insured token depegging
- Example: User deposits $100 worth of insured tokens, insured token depegs to $0.50, user still gets $100 worth of underwriter tokens

### 6. Minimum Pool Time

- Applies only when withdrawing underwriter tokens
- Prevents immediate withdrawal after deposit
- Default: 1 day

### 7. Unlock Duration

- Underwriters must wait `unlockDuration` (default 28 days) after starting unlock process
- Prevents sudden withdrawal of collateral
- Tokens remain locked during unlock period

### 8. Empty Pool Handling

- `startUnlockProcess()` returns early if pool is empty
- `_lockUnderwriterTokens()` returns early if pool is empty

### 9. Slippage Protection

- All deposit/withdrawal functions accept `minReceiptAmount` or `minAmountOut`
- Uses `SlippageLib.enforceMinReceived()` to validate
- If `minAmount = 0`, slippage check is skipped

### 10. Receipt Token Ownership

- Receipt tokens are owned by the pool contract
- Pool contract mints/burns on behalf of users
- Users can transfer receipt tokens (standard ERC20)

## Security Considerations

### 1. Oracle Manipulation

- Oracle price manipulation could affect:
  - Yield calculations (fees)
  - Collateral requirements
  - Withdrawal amounts (especially underwriter token withdrawals)
- **Mitigation**: Use trusted oracles with staleness checks

### 2. Reentrancy Protection

- All state-changing functions use `nonReentrant` modifier
- Checks-effects-interactions pattern followed
- Fee calculations happen before token transfers

### 3. Integer Overflow/Underflow

- Uses Solidity 0.8.30 (built-in overflow protection)
- Uses OpenZeppelin's `Math` library for safe math operations
- Underflow protection in yield calculation: `currentValue > valueOfDeposit ? currentValue - valueOfDeposit : 0`

### 4. Access Control

- Multiple layers: protocol-level, pool-level, function-level
- Governance actions require timelock
- Pool creator can set per-pool restrictions

### 5. Pausability

- Emergency pause mechanism
- Pauses deposits and withdrawals
- Does not pause fee claiming (allows users to claim rewards)

### 6. Upgrade Risks

- UUPS proxy pattern allows implementation upgrades
- Only governance can upgrade
- Storage layout changes could break existing pools

### 7. Collateral Ratio

- Minimum 100% (10000 basis points)
- Maximum 500% (50000 basis points)
- Higher ratio = more collateral per insured deposit

### 8. Fee Accumulation

- Fees accumulate over time
- Must be explicitly claimed/paid
- Fee accumulators can grow large if not claimed

## Testing Coverage

### Invariant Tests

- `invariant_poolBalancesTrackDeposits()`: Verifies pool balances match tracked deposits

### Unit Tests

- Deposit/withdrawal flows
- Fee calculations
- Unlock process
- Access control
- Edge cases (empty pool, multiple deposits, etc.)

## Known Limitations

1. **Yield Calculation**: Currently uses oracle prices, not actual yield-bearing token balances (commented out code suggests this was considered)
2. **Underwriter Token Withdrawal**: Only supports withdrawing underwriter tokens, not insured tokens
3. **Partial Withdrawals**: Insured deposits must be withdrawn in full (cannot partially withdraw)
4. **Oracle Dependency**: Critical dependency on oracle accuracy and availability

## Conclusion

The YieldShield protocol implements a sophisticated insurance mechanism with careful tracking of deposits, yield, and fees. The critical behavior of protecting insured users' principal value through USD-based withdrawal calculations is a key security feature. The system relies heavily on oracle accuracy and proper collateralization ratios to maintain solvency.

Key areas for security audit focus:
1. Oracle price manipulation resistance
2. Fee calculation accuracy and rounding
3. Collateralization ratio enforcement
4. Withdrawal value calculations (especially USD-based withdrawals)
5. Reentrancy protection
6. Access control enforcement
7. Upgrade safety
8. Edge case handling (empty pools, zero yields, etc.)

