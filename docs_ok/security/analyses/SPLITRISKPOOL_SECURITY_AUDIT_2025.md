# SplitRiskPool Security Audit Report

**Audit Date**: January 2025  
**Contract Version**: Post rewards-per-share implementation  
**Auditor**: AI Security Audit  
**Contract**: `packages/foundry/contracts/SplitRiskPool.sol`

---

## Executive Summary

This audit examines the `SplitRiskPool.sol` contract after the implementation of the rewards-per-share (MasterChef) pattern for commission distribution. While previous critical vulnerabilities have been addressed, several medium and low severity issues remain that should be considered before mainnet deployment.

### Risk Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | - |
| High | 0 | All Fixed |
| Medium | 5 | Open |
| Low | 8 | Open |
| Informational | 3 | Open |

---

## HIGH Severity Issues

### HIGH-1: `claimRewards` Griefing Attack

**Status**: ✅ Fixed (Rate Limiting Implemented)  
**Location**: `SplitRiskPool.sol:736-746`  
**Impact**: Financial loss for insured users  
**Likelihood**: Medium

#### Description

The `claimRewards` function can be called by **anyone** for **any** insured position. While the position baseline is correctly updated (preventing double-fee extraction), this allows griefing attacks that force premature fee extraction.

#### Attack Scenario

1. Attacker monitors mempool for insured deposits in high-yield pools
2. Attacker repeatedly calls `claimRewards(victimTokenId)` every block
3. Each call extracts fees from the victim's position at current oracle prices
4. Victim loses control over timing of fee extraction
5. Position shrinks prematurely, reducing future yield potential

#### Fix Implemented

Added rate limiting with a 24-hour cooldown per tokenId:

```solidity
function claimRewards(uint256 tokenId) external nonReentrant {
    // Rate limiting: minimum 24 hours between calls per tokenId
    uint256 lastClaim = lastClaimRewardsTime[tokenId];
    if (lastClaim != 0 && block.timestamp < lastClaim + 1 days) {
        revert ErrorsLib.ClaimRewardsCooldownNotMet(lastClaim + 1 days);
    }
    lastClaimRewardsTime[tokenId] = block.timestamp;
    // ... rest of function
}
```

This prevents griefing while preserving the open-callable design that allows underwriters to trigger periodic fee accumulation.

---

## MEDIUM Severity Issues

### MED-1: Migration Function Logic Flaw

**Status**: 🟡 Open  
**Location**: `SplitRiskPool.sol:454-462`  
**Impact**: Confusion in migration tracking  
**Likelihood**: Low

#### Description

The migration function uses `rewardDebt[tokenId] != 0` to check if already migrated:

```solidity
function migrateExistingPosition(uint256 tokenId) external onlyGovernance {
    // ...
    if (rewardDebt[tokenId] != 0) revert ErrorsLib.InvalidTokenId(); // Already migrated
    rewardDebt[tokenId] = 0; // Sets debt to 0
}
```

**Problems:**
1. New positions in pools with `rewardPerShareAccumulated == 0` will have `rewardDebt[tokenId] == 0`
2. These new positions are indistinguishable from "migrated" positions
3. Migration sets debt to 0, but it's already 0 for new positions in empty pools
4. No event is emitted for tracking migrations

#### Recommendation

Use a separate mapping to track migrated positions:

```solidity
mapping(uint256 => bool) public isMigrated;

function migrateExistingPosition(uint256 tokenId) external onlyGovernance {
    if (isMigrated[tokenId]) revert ErrorsLib.AlreadyMigrated();
    // ...
    isMigrated[tokenId] = true;
    emit PositionMigrated(tokenId);
}
```

---

### MED-2: Protocol Fee Validation Missing in updatePoolConfig

**Status**: 🟡 Open  
**Location**: `SplitRiskPool.sol:919-960`  
**Impact**: Governance could set excessive fees  
**Likelihood**: Low (requires governance compromise)

#### Description

`updatePoolConfig` validates the oracle but not the protocol fee:

```solidity
function updatePoolConfig(
    // ...
    uint256 newProtocolFee,
    address newProtocolFeeRecipient,
    // ...
) external onlyGovernance {
    // No validation for newProtocolFee
    poolConfig.protocolFee = newProtocolFee;
```

Governance could set `protocolFee` to 10000 (100%), extracting all yield from users.

#### Recommendation

Add bounds validation:

```solidity
if (newProtocolFee > ConstantsLib.MAX_PROTOCOL_FEE) {
    revert ErrorsLib.InvalidProtocolFee();
}
```

---

### MED-3: Fee Accumulator Overflow Silently Zeros Fees

**Status**: 🟡 Open  
**Location**: `SplitRiskPool.sol:294-314`  
**Impact**: Lost fees without notification  
**Likelihood**: Very Low (requires huge accumulation)

#### Description

When fee accumulators approach `type(uint128).max`, fees are silently zeroed:

```solidity
if (accumulatedCommissions + commissionAmount > maxSafeAccumulation) {
    commissionAmount = 0;  // Silently zeroed!
}
```

No event is emitted to alert governance that fees are being dropped.

#### Recommendation

Emit an event when fees are dropped:

```solidity
if (accumulatedCommissions + commissionAmount > maxSafeAccumulation) {
    emit CommissionOverflowPrevented(tokenId, commissionAmount);
    commissionAmount = 0;
}
```

---

### MED-4: Missing Storage Gap for Upgradeable Contract

**Status**: 🟡 Open  
**Location**: `SplitRiskPool.sol`  
**Impact**: Storage collision risk on upgrade  
**Likelihood**: Medium (on future upgrades)

#### Description

The contract inherits from `ProtocolAccessControlUpgradeable` and `UUPSUpgradeable` but doesn't include a `__gap` storage variable. If base contracts add storage variables in future versions, storage layout could collide.

#### Recommendation

Add a storage gap at the end of the contract:

```solidity
// Reserve storage slots for future upgrades
uint256[50] private __gap;
```

---

### MED-5: Access Control Contract Centralization Risk

**Status**: 🟡 Open  
**Location**: `SplitRiskPool.sol:481, 520, 572, 767, 992-996`  
**Impact**: Pool creator has significant control  
**Likelihood**: Design decision

#### Description

The pool creator can set any `accessControl` contract via `setAccessControl`:

```solidity
function setAccessControl(address newAccessControl) external {
    if (msg.sender != POOL_CREATOR) revert ErrorsLib.InvalidPoolCreator();
    accessControl = newAccessControl;
}
```

A malicious access control contract could:
- Block all deposits/withdrawals
- Allow only specific addresses
- Change permissions without timelock

#### Recommendation

Document this trust assumption clearly. Consider adding:
- Timelock for access control changes
- Maximum restrictions (e.g., cannot block withdrawals for > 7 days)
- Event emission for access control changes (already implemented ✅)

---

## LOW Severity Issues

### LOW-1: Unlock Duration Missing Bounds Validation

**Location**: `SplitRiskPool.sol:945`

`newUnlockDuration` can be set to 0 (instant unlocks) or extremely high values (locks forever):

```solidity
poolConfig.unlockDuration = newUnlockDuration;  // No validation
```

**Recommendation**: Add min/max bounds (e.g., 1 day to 365 days).

---

### LOW-2: startUnlockProcess Silent Return

**Location**: `SplitRiskPool.sol:703`

```solidity
if (poolState.insuredTokenBalance + poolState.totalUnderwriteTokenBalance == 0) return;
```

Silently returns when pool is empty. User may think unlock started.

**Recommendation**: Revert with descriptive error or emit event.

---

### LOW-3: Protocol Fee Recipient Can Be Set to Zero

**Location**: `SplitRiskPool.sol:947`

`newProtocolFeeRecipient` isn't validated in `updatePoolConfig`, could be set to `address(0)`.

**Recommendation**: Add `require(newProtocolFeeRecipient != address(0))`.

---

### LOW-4: Misleading Error Reuse

**Location**: `SplitRiskPool.sol:728`

```solidity
if (pos.unlockRequestTime == 0) {
    revert ErrorsLib.UnlockProcessAlreadyStarted(); // Means "no unlock to cancel"
}
```

Error name doesn't match usage.

**Recommendation**: Create `NoUnlockToCancel` error.

---

### LOW-5: Precision Loss in Partial Withdrawal Collateral Calculation

**Location**: `SplitRiskPool.sol:678`

```solidity
uint256 newCollateralAmount = (pos.collateralAmount * remaining) / pos.amount;
```

Rounding down could cause slight under-collateralization over many partial withdrawals.

**Recommendation**: Use `Math.Rounding.Ceil` or accept as minor accounting variance.

---

### LOW-6: Fallback Without Explicit Receive

**Location**: `SplitRiskPool.sol:999-1001`

Has `fallback()` that reverts but no `receive()` function. Both paths revert, which is correct, but explicit `receive()` is clearer.

**Recommendation**: Add explicit `receive() external payable { revert ErrorsLib.EtherTransferNotAllowed(); }`.

---

### LOW-7: No Event for Migration

**Location**: `SplitRiskPool.sol:454-462`

`migrateExistingPosition` doesn't emit an event.

**Recommendation**: Add `emit PositionMigrated(tokenId)`.

---

### LOW-8: Total Fees Can Equal Position Amount

**Location**: `SplitRiskPool.sol:275-288`

After fee scaling, `totalFees` could equal `pos.amount`, resulting in `newAmount = 0`. User loses entire deposit to fees.

**Recommendation**: Ensure minimum remaining amount or add fee cap (e.g., max 95% of position).

---

## INFORMATIONAL Issues

### INFO-1: Unused Parameters

**Location**: `SplitRiskPool.sol:472, 514`

`minReceiptAmount` parameter is unused in both deposit functions:

```solidity
function depositUnderwriteAsset(address asset, uint256 depositAmount, uint256 /* minReceiptAmount */ )
```

**Recommendation**: Remove or implement slippage protection.

---

### INFO-2: getUserTokenBalances Returns NFT Counts, Not Amounts

**Location**: `SplitRiskPool.sol:835-844`

Function name suggests token balances but returns NFT counts:

```solidity
function getUserTokenBalances(address user)
    external view returns (uint256 insuredBalance, uint256 underwriterBalance)
{
    insuredBalance = IInsuredReceiptNFT(insuredReceiptNFT).balanceOf(user);
    underwriterBalance = IUnderwriterReceiptNFT(underwriterReceiptNFT).balanceOf(user);
}
```

**Recommendation**: Rename to `getUserNFTCounts` or implement actual balance aggregation.

---

### INFO-3: Cross-Asset Withdrawal Time Check Asymmetry

**Location**: `SplitRiskPool.sol:579-585`

`minimumPoolTime` only applies to underwriter token withdrawals, not insured token withdrawals. This is documented in code but may surprise users.

**Recommendation**: Document this behavior clearly in NatSpec.

---

## Positive Security Features

The contract implements several security best practices:

1. ✅ **ReentrancyGuard**: All state-changing functions use `nonReentrant`
2. ✅ **Pausable**: Emergency pause functionality via `whenNotPaused`
3. ✅ **SafeERC20**: Safe token transfers throughout
4. ✅ **Fee-on-Transfer Support**: Balance-delta pattern in deposits
5. ✅ **Circuit Breaker**: Oracle manipulation protection on cross-asset withdrawals
6. ✅ **Slippage Protection**: `minAmountOut` parameters on withdrawals
7. ✅ **Access Control**: Governance-only functions properly gated
8. ✅ **Rewards-Per-Share**: MasterChef pattern prevents late-joiner commission exploit
9. ✅ **Collateral Capping**: Cross-asset withdrawals capped to prevent over-extraction

---

## Recommendations Summary

| Priority | Recommendation | Effort |
|----------|---------------|--------|
| P1 | Add ownership check to `claimRewards` | 1 hour |
| P2 | Add protocol fee bounds validation | 30 min |
| P2 | Add unlock duration bounds | 30 min |
| P2 | Add storage gap for upgrades | 30 min |
| P3 | Emit events for fee overflow prevention | 1 hour |
| P3 | Fix migration tracking logic | 2 hours |
| P3 | Create dedicated error for unlock cancellation | 30 min |

---

## Conclusion

The `SplitRiskPool` contract has improved significantly with the rewards-per-share implementation. The main actionable item is **HIGH-1** (claimRewards griefing), which should be addressed before mainnet. The medium and low severity issues represent defense-in-depth improvements that would further harden the contract.

