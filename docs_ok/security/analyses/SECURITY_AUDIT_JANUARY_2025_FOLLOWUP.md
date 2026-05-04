# YieldShield Protocol Security Audit - January 2025 Follow-Up

**Audit Date:** January 7, 2026  
**Auditor:** AI Security Review  
**Scope:** Smart Contract Security Analysis (Follow-up)  
**Contracts Reviewed:** SplitRiskPool, SplitRiskPoolFactory, InsuredReceiptNFT, UnderwriterReceiptNFT, Oracle Contracts, Libraries

---

## Executive Summary

This follow-up security audit examines the YieldShield protocol smart contracts after the initial comprehensive audit. The codebase demonstrates strong security practices with circuit breakers, oracle manipulation protection, and proper access controls. This review identifies additional edge cases and potential improvements not covered in the previous audit.

**Overall Risk Assessment:** LOW-MEDIUM

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 4 |
| LOW | 6 |
| INFORMATIONAL | 5 |

---

## HIGH Severity Findings

### HIGH-1: Underwriter Commission Loss During Zero Balance Transition

**File:** `SplitRiskPool.sol`  
**Lines:** 308-312

**Description:**
When `totalUnderwriterTokens` becomes zero (all underwriters withdraw), the `rewardPerShareAccumulated` update is skipped. If new underwriters deposit before accumulated commissions are claimed, these commissions become permanently stranded.

```solidity
// Update rewards-per-share accumulator (MasterChef pattern)
if (totalUnderwriterTokens > 0) {
    rewardPerShareAccumulated += (commissionAmount * REWARD_PRECISION) / totalUnderwriterTokens;
}
accumulatedCommissions += commissionAmount;
```

**Impact:** Commissions accumulated when no underwriters exist cannot be distributed to future underwriters.

**Recommendation:**
Option 1: Redirect commissions accumulated during zero-underwriter periods to protocol fee.
Option 2: Track "stranded commissions" separately and distribute to first new underwriter.

```solidity
if (totalUnderwriterTokens > 0) {
    rewardPerShareAccumulated += (commissionAmount * REWARD_PRECISION) / totalUnderwriterTokens;
} else {
    // Redirect to protocol fee when no underwriters exist
    accumulatedProtocolFee += commissionAmount;
    commissionAmount = 0;
}
```

---

## MEDIUM Severity Findings

### MED-1: Underwriter NFT Transfer Allows Unlock Timer Reset Bypass

**File:** `UnderwriterReceiptNFT.sol`, `SplitRiskPool.sol`

**Description:**
An underwriter who has started the unlock process can transfer their NFT to another address after the transfer lock period expires. The new owner inherits the existing `unlockRequestTime` but can choose to cancel and restart the unlock process at any time. While this seems intentional, it could be used to game the system.

**Scenario:**
1. Alice starts unlock process at T=0 (unlock time = T+28 days)
2. At T=27 days, Alice transfers NFT to Bob (her alt account)
3. Bob cancels the unlock (no penalty) and immediately re-starts
4. Bob now has a fresh 28-day timer from T=27 days

**Impact:** The unlock duration can be effectively extended by ping-ponging NFTs between addresses.

**Recommendation:** Consider adding a cooldown after unlock cancellation before a new unlock can be started, OR reset unlock time on transfer.

---

### MED-2: Missing Validation for Same-Underlying ERC4626 Vaults

**File:** `SplitRiskPoolFactory.sol`  
**Lines:** 125-222

**Description:**
The factory validates that insured and underwriter tokens are different addresses, but doesn't verify they don't share the same underlying asset. Two different ERC4626 vaults wrapping the same underlying token would create problematic pool dynamics.

```solidity
if (_underwriteTokenInfo.token == _insuredTokenInfo.token) revert ErrorsLib.InvalidAssetAddress();
// Missing: check if both are ERC4626 vaults with same underlying
```

**Impact:** A pool with two vaults sharing the same underlying would have 1:1 price correlation, defeating the purpose of the insurance model.

**Recommendation:**
```solidity
// After existing validation
if (IERC4626(_insuredToken).asset() == IERC4626(_underwriteToken).asset()) {
    revert ErrorsLib.SameUnderlyingAsset();
}
```

---

### MED-3: Cross-Asset Withdrawal Timing Inconsistency

**File:** `SplitRiskPool.sol`  
**Lines:** 588-594

**Description:**
The `minimumPoolTime` check only applies when withdrawing underwriter tokens, not when withdrawing the original insured tokens. This creates an inconsistency where:
- Withdrawing as underwriter tokens: requires waiting `minimumPoolTime`
- Withdrawing as insured tokens: no time restriction

```solidity
// Check minimum pool time only if withdrawing underwriter assets
if (preferredAsset == UNDERWRITER_TOKEN) {
    uint256 timeElapsed = block.timestamp - uint256(pos.depositTime);
    if (timeElapsed < poolConfig.minimumPoolTime) {
        revert ErrorsLib.InsufficientPoolTimeWithDetails(poolConfig.minimumPoolTime, timeElapsed);
    }
}
```

**Impact:** Insured users can deposit and immediately withdraw their tokens (minus fees), potentially gaming fee accumulation.

**Recommendation:** Consider applying minimum pool time to all insured withdrawals, or document this as intentional behavior.

---

### MED-4: Access Control Interface Not Validated

**File:** `SplitRiskPool.sol`  
**Lines:** 1073-1077

**Description:**
The `setAccessControl` function accepts any address without validating it implements `IPoolAccessControl`. A malicious or incorrect address would cause all deposit/withdraw operations to fail.

```solidity
function setAccessControl(address newAccessControl) external {
    if (msg.sender != POOL_CREATOR) revert ErrorsLib.InvalidPoolCreator();
    emit EventsLib.AccessControlUpdated(accessControl, newAccessControl);
    accessControl = newAccessControl;
    // Missing: validation that newAccessControl implements IPoolAccessControl
}
```

**Impact:** Pool creator could accidentally brick the pool by setting an invalid access control address.

**Recommendation:**
```solidity
function setAccessControl(address newAccessControl) external {
    if (msg.sender != POOL_CREATOR) revert ErrorsLib.InvalidPoolCreator();
    
    // Validate interface if non-zero
    if (newAccessControl != address(0)) {
        try IPoolAccessControl(newAccessControl).canDepositInsured(address(this)) returns (bool) {
            // Valid interface
        } catch {
            revert ErrorsLib.InvalidAccessControlAddress();
        }
    }
    
    emit EventsLib.AccessControlUpdated(accessControl, newAccessControl);
    accessControl = newAccessControl;
}
```

---

## LOW Severity Findings

### LOW-1: No Upper Bound on Oracle Max Price Age

**File:** `PythOracle.sol`, `ChainlinkOracleFeed.sol`

**Description:**
The `setMaxPriceAge` function has no upper bound validation. An extremely high value (e.g., 365 days) would effectively disable staleness checks.

**Recommendation:** Add upper bound validation (e.g., 1 hour max).

```solidity
uint256 public constant MAX_PRICE_AGE_LIMIT = 3600; // 1 hour

function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
    require(_maxPriceAge <= MAX_PRICE_AGE_LIMIT, "Price age too high");
    // ... existing code
}
```

---

### LOW-2: ChainlinkOracleFeed Constructor Missing Zero Check

**File:** `ChainlinkOracleFeed.sol`  
**Line:** 79

**Description:**
The constructor accepts `_maxPriceAge` without validating it's non-zero. A zero value would cause all price reads to revert.

```solidity
constructor(uint256 _maxPriceAge) Ownable(msg.sender) {
    maxPriceAge = _maxPriceAge; // No zero check
}
```

**Recommendation:**
```solidity
constructor(uint256 _maxPriceAge) Ownable(msg.sender) {
    require(_maxPriceAge > 0, "Invalid max price age");
    maxPriceAge = _maxPriceAge;
}
```

---

### LOW-3: Factory Pool Array Cannot Be Cleaned

**File:** `SplitRiskPoolFactory.sol`

**Description:**
The `pools` array can only grow, never shrink. While MAX_POOLS (1000) provides an upper bound, there's no mechanism to remove defunct or abandoned pools.

**Impact:** Over time, `getAllPools()` will return increasingly stale data, and gas costs for iteration increase.

**Recommendation:** Consider adding a governance function to mark pools as inactive or implementing an enumerable mapping pattern.

---

### LOW-4: Partial Withdrawal Precision Loss in Commission Tracking

**File:** `SplitRiskPool.sol`  
**Lines:** 817-824

**Description:**
During partial underwriter withdrawals, `rewardDebt` and `commissionsClaimed` are proportionally adjusted using integer division. Over many partial withdrawals, rounding errors accumulate.

```solidity
rewardDebt[tokenId] = (rewardDebt[tokenId] * newAmount) / pos.amount;
if (commissionsClaimed[tokenId] > 0) {
    commissionsClaimed[tokenId] = (commissionsClaimed[tokenId] * newAmount) / pos.amount;
}
```

**Impact:** Small amounts of commission may be lost or over-claimed after many partial withdrawals.

**Recommendation:** Document this behavior or use higher precision arithmetic.

---

### LOW-5: Missing Event for Pool Configuration Read Operations

**File:** `SplitRiskPool.sol`

**Description:**
Several view functions that return sensitive configuration data don't emit events when called. While view functions typically don't emit events, tracking oracle queries could aid monitoring.

**Recommendation:** Consider adding off-chain monitoring for oracle price queries.

---

### LOW-6: MetaOracleAdapter Cooldown Can Block Emergency Actions

**File:** `MetaOracleAdapter.sol`

**Description:**
The 1-hour cooldown period applies universally, including after `forceResetToPrimary`. In an emergency, if admin force-resets and then realizes the primary is still problematic, they must wait 1 hour before the system can switch again.

**Recommendation:** Consider allowing owner to bypass cooldown for emergency actions.

---

## INFORMATIONAL Findings

### INFO-1: Magic Numbers in Commission Calculation

**File:** `SplitRiskPool.sol`

Several magic numbers could be extracted to named constants:
- `1 days` (claim cooldown)
- `REWARD_PRECISION = 1e18`

**Recommendation:** Add to ConstantsLib for consistency.

---

### INFO-2: Function Ordering Inconsistency

**File:** `SplitRiskPool.sol`

The contract mixes view functions, state-changing functions, and modifiers without clear grouping. Consider organizing by:
1. State variables
2. Events
3. Modifiers
4. Constructor/Initialize
5. External state-changing functions
6. External view functions
7. Internal functions

---

### INFO-3: NFT Transfer Lock Period Asymmetry

**Files:** `InsuredReceiptNFT.sol`, `UnderwriterReceiptNFT.sol`

The default transfer lock periods differ significantly:
- InsuredReceiptNFT: 1 day
- UnderwriterReceiptNFT: 28 days

This is likely intentional but should be documented explaining the rationale.

---

### INFO-4: Pool State Recovery Documentation

**File:** `SplitRiskPool.sol`

If the tracked balances (`poolState.insuredTokenBalance`, etc.) ever diverge from actual token balances (due to direct transfers or contract upgrades), there's no recovery mechanism.

**Recommendation:** Document that direct token transfers to the pool will be lost and consider adding a governance-controlled sync function for emergency recovery.

---

### INFO-5: Test Coverage Recommendations

Areas that would benefit from additional test coverage:
1. Commission distribution with exactly 1 wei of accumulated commissions
2. Multiple partial withdrawals in sequence (precision loss accumulation)
3. Oracle switchover during active insured withdrawal transaction
4. Pool behavior when all positions are withdrawn (zero state)
5. ERC4626 vault share inflation attack scenarios with various MIN_VAULT_SUPPLY values

---

## Gas Optimization Opportunities

### GAS-1: Redundant Balance Check

**File:** `SplitRiskPool.sol`  
**Lines:** 333-339, 360-366

Both `payPoolFee` and `payProtocolFee` perform two balance checks that could be consolidated:

```solidity
if (poolState.insuredTokenBalance < poolFeeAmount) {
    revert ErrorsLib.InsufficientTokenBalance();
}
uint256 actualBalance = IERC20(INSURED_TOKEN).balanceOf(address(this));
if (actualBalance < poolFeeAmount) {
    revert ErrorsLib.InsufficientTokenBalance();
}
```

The second check (actual token balance) is sufficient if the accounting is correct.

### GAS-2: Storage Read Optimization

**File:** `SplitRiskPool.sol`

In `claimCommission`, `totalUnderwriterTokens` is read multiple times. Consider caching in memory.

---

## Conclusion

The YieldShield protocol demonstrates mature security practices with comprehensive oracle manipulation protection, proper access controls, and defensive coding patterns. The findings in this audit are primarily edge cases and optimization opportunities rather than critical vulnerabilities.

Key strengths:
- Circuit breaker protection on all oracle operations
- MasterChef-pattern commission distribution prevents late-joiner exploitation
- Proper reentrancy guards and pausability
- Storage gaps for upgrade safety

Priority remediation order:
1. HIGH-1: Commission loss during zero-underwriter transition
2. MED-4: Access control validation
3. MED-2: Same-underlying vault validation
4. Remaining items as time permits

---

*This audit is provided for informational purposes and does not constitute a guarantee of security. Smart contract security is an ongoing process requiring continuous monitoring and improvement.*

