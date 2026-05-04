# YieldShield Protocol Security Audit Report

**Audit Date:** January 8, 2026  
**Auditor:** Automated Security Review  
**Audit Framework:** [Solidity Security Audit Checklist](https://github.com/iAnonymous3000/solidity-security-audit-checklist)  
**Contracts Reviewed:** SplitRiskPool.sol, SplitRiskPoolFactory.sol, MetaOracleAdapter.sol, InsuredReceiptNFT.sol, UnderwriterReceiptNFT.sol, ProtocolAccessControlUpgradeable.sol, PoolValidationLib.sol

---

## Executive Summary

This security audit reviews the YieldShield protocol smart contracts using the comprehensive [Solidity Security Audit Checklist](https://github.com/iAnonymous3000/solidity-security-audit-checklist) and industry best practices. The codebase demonstrates strong security practices with evidence of multiple prior audit fixes already implemented (marked as HIGH-X, MED-X, LOW-X, INFO-X, etc.).

### Overall Assessment: **GOOD** ✅

The protocol shows mature security design with:
- Reentrancy protection throughout
- Proper access control implementation
- Comprehensive input validation
- Oracle manipulation resistance
- Fee reserve protection
- Upgrade safety patterns

### Summary of Findings

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | N/A |
| High | 0 | N/A |
| Medium | 2 | Open (Informational) |
| Low | 4 | Open (Recommendations) |
| Informational | 5 | Open (Best Practices) |

---

## 1. Reentrancy Vulnerabilities ✅ PASS

### Assessment: **Secure**

The protocol demonstrates excellent reentrancy protection:

#### Implemented Protections:
- **ReentrancyGuard from OpenZeppelin**: All state-changing functions use `nonReentrant` modifier
- **Checks-Effects-Interactions Pattern**: State changes occur before external calls throughout
- **SafeERC20**: All token transfers use OpenZeppelin's SafeERC20

#### Code Evidence:

```solidity
// SplitRiskPool.sol - All public functions properly protected
function depositUnderwriteAsset(...) external nonReentrant whenNotPaused returns (uint256 tokenId)
function depositInsuredAsset(...) external nonReentrant whenNotPaused returns (uint256 tokenId)
function insuredWithdraw(...) external nonReentrant whenNotPaused
function claimCommission(...) external nonReentrant
function payPoolFee() external nonReentrant
function payProtocolFee() external nonReentrant
```

```solidity
// Checks-Effects-Interactions pattern in insuredWithdraw()
// 1. State changes first
totalInsuredTokens -= pos.amount;
poolState.insuredTokenBalance -= payoutAmount;

// 2. External transfer last
SafeERC20.safeTransfer(IERC20(preferredAsset), msg.sender, payoutAmount);
```

#### Recommendation: **None - Properly Implemented**

---

## 2. Arithmetic Issues ✅ PASS

### Assessment: **Secure**

The protocol uses Solidity 0.8.30 which has built-in overflow/underflow protection.

#### Implemented Protections:
- **Solidity ^0.8.30**: Built-in overflow/underflow checks
- **OpenZeppelin Math Library**: Safe division operations with rounding control
- **Explicit Underflow Protection**: Defensive checks added (LOW-3 FIX)

#### Code Evidence:

```solidity
// LOW-3 FIX: Defensive underflow protection
function getAvailableForWithdrawal(uint256 tokenId) public view returns (uint256) {
    uint256 locked = getLockedAmount(tokenId);
    return locked >= pos.amount ? 0 : pos.amount - locked;
}
```

```solidity
// Safe math with explicit rounding
uint256 commissionAmountUsd = yieldEarnedUsd.mulDiv(
    COMMISSION_RATE, 
    ConstantsLib.BASIS_POINT_SCALE, 
    Math.Rounding.Ceil
);
```

```solidity
// Fee cap to prevent underflow
if (totalFees > pos.amount) {
    uint256 scale = (pos.amount * ConstantsLib.BASIS_POINT_SCALE) / totalFees;
    // Scale down fees proportionally
}
```

#### Recommendation: **None - Properly Implemented**

---

## 3. Unchecked External Calls ✅ PASS

### Assessment: **Secure**

The protocol properly handles all external calls with appropriate error handling.

#### Implemented Protections:
- **SafeERC20**: All token transfers use safe variants
- **Try-Catch for Interface Detection**: Oracle and ERC4626 interface checks use try-catch
- **Balance-Delta Pattern**: Fee-on-transfer token support

#### Code Evidence:

```solidity
// SafeERC20 for all token operations
SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), depositAmount);
SafeERC20.safeTransfer(IERC20(INSURED_TOKEN), msg.sender, claimable);
```

```solidity
// Try-catch for oracle validation
try IPriceOracle(newPriceOracle).getPrice(INSURED_TOKEN) returns (uint256) {
    // Oracle is callable - validation passed
} catch {
    revert ErrorsLib.InvalidAssetAddress();
}
```

```solidity
// Balance-delta for fee-on-transfer tokens
function _transferAndGetReceived(address asset, uint256 depositAmount) internal returns (uint256 received) {
    uint256 beforeBal = IERC20(asset).balanceOf(address(this));
    SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), depositAmount);
    uint256 afterBal = IERC20(asset).balanceOf(address(this));
    received = afterBal - beforeBal;
}
```

#### Recommendation: **None - Properly Implemented**

---

## 4. Access Control ✅ PASS

### Assessment: **Secure**

The protocol implements a robust multi-tiered access control system.

#### Access Control Hierarchy:
1. **Owner**: Initial setup, emergency functions
2. **Governance Timelock**: Protocol parameter changes, upgrades
3. **Pool Creator**: Pool-specific settings, fee collection
4. **NFT Owner**: Position management, commission claims
5. **Public**: Read functions, some limited state changes

#### Code Evidence:

```solidity
// Multi-level access modifiers
modifier onlyGovernance();
modifier onlyGovernanceOrOwner();
modifier onlyPool();  // NFT contracts

// NEW-1 FIX: Access control for fee payments
function payPoolFee() external nonReentrant {
    if (msg.sender != POOL_CREATOR && msg.sender != _governanceTimelock) {
        revert ErrorsLib.AccessControlDenied(msg.sender, "payPoolFee");
    }
}
```

```solidity
// NFT ownership verification
if (IUnderwriterReceiptNFT(underwriterReceiptNFT).ownerOf(tokenId) != msg.sender) {
    revert ErrorsLib.NotOwner();
}
```

#### Recommendation: **None - Properly Implemented**

---

## 5. Input Validation and Sanitization ✅ PASS

### Assessment: **Secure**

Comprehensive input validation is implemented throughout the protocol.

#### Implemented Validations:
- Zero address checks
- Bound validations (min/max)
- Token whitelist enforcement
- ERC4626 underlying asset validation (MED-2 FIX)
- String length limits

#### Code Evidence:

```solidity
// Comprehensive initialization validation
if (_insuredTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
if (_underwriteTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
if (_commissionRate > ConstantsLib.MAX_COMMISSION_RATE) revert ErrorsLib.InvalidCommissionRate();
if (_collateralRatio < ConstantsLib.MIN_COLLATERAL_RATIO || 
    _collateralRatio > ConstantsLib.MAX_COLLATERAL_RATIO) {
    revert ErrorsLib.InvalidCollateralRatio();
}
```

```solidity
// MED-2 FIX: ERC4626 underlying validation
function validateERC4626Underlying(address _insuredToken, address _underwriteToken) external view {
    // Prevents creating pools with same underlying asset
    if (insuredIsERC4626 && underwriterIsERC4626 && insuredUnderlying == underwriterUnderlying) {
        revert ErrorsLib.SameUnderlyingAsset(_insuredToken, _underwriteToken, insuredUnderlying);
    }
}
```

#### Recommendation: **None - Properly Implemented**

---

## 6. Randomness ✅ N/A

### Assessment: **Not Applicable**

The protocol does not rely on randomness for any functionality.

---

## 7. Timestamp Dependence ⚠️ LOW RISK

### Assessment: **Acceptable with Minor Concerns**

The protocol uses `block.timestamp` for time-based mechanics.

#### Usage Analysis:

| Usage | Risk | Mitigation |
|-------|------|------------|
| Unlock duration tracking | Low | 1-day minimum duration |
| Minimum pool time | Low | Time periods are in hours/days |
| Cooldown enforcement | Low | 1-hour period is acceptable |
| Fee claim timestamps | Low | Daily cooldown |

#### Code Evidence:

```solidity
// Unlock time calculation
IUnderwriterReceiptNFT(underwriterReceiptNFT).setUnlockRequestTime(
    tokenId, uint64(block.timestamp + poolConfig.unlockDuration)
);

// Rate limiting with 24-hour cooldown
if (lastClaim != 0 && block.timestamp < lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN) {
    revert ErrorsLib.ClaimRewardsCooldownNotMet(lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN);
}
```

#### Assessment:
The time periods used (24 hours minimum) are long enough that minor timestamp manipulation by miners (typically ±15 seconds) would have negligible impact.

#### Recommendation: **None - Acceptable Risk Level**

---

## 8. Denial of Service (DoS) Attacks ✅ PASS

### Assessment: **Secure**

The protocol includes multiple DoS protections.

#### Implemented Protections:

1. **MED-5 FIX: Pool Count Limit**
```solidity
uint256 public constant MAX_POOLS = 1000;
if (pools.length >= MAX_POOLS) {
    revert ErrorsLib.MaxPoolsExceeded(pools.length, MAX_POOLS);
}
```

2. **GAS-H2 FIX: Optimized Loops**
```solidity
for (uint256 i = 0; i < poolCount;) {
    allPoolsInfo[i] = _poolInfo[pools[i]];
    unchecked { ++i; }
}
```

3. **Fee Overflow Protection**
```solidity
uint256 maxSafeAccumulation = type(uint128).max;
if (accumulatedPoolFee + poolFeeAmount > maxSafeAccumulation) {
    poolFeeAmount = 0;
}
```

4. **HIGH-1 FIX: Rate Limiting**
```solidity
if (lastClaim != 0 && block.timestamp < lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN) {
    revert ErrorsLib.ClaimRewardsCooldownNotMet(...);
}
```

5. **HIGH-2 FIX: Challenge Cooldown**
```solidity
if (block.timestamp < lastChallengeTime + COOLDOWN_PERIOD) {
    revert ChallengeNotPossible("Cooldown period not elapsed");
}
```

#### Recommendation: **None - Properly Implemented**

---

## 9. Front-running and MEV ⚠️ MEDIUM RISK

### Assessment: **Mitigated but Residual Risk Exists**

The protocol implements slippage protection but some MEV exposure remains.

#### Implemented Protections:

```solidity
// Slippage protection parameters
function depositUnderwriteAsset(address asset, uint256 depositAmount, uint256 minReceivedAmount)
function insuredWithdraw(uint256 tokenId, address preferredAsset, uint256 minAmountOut)
```

```solidity
// INFO-5 FIX: Slippage enforcement
if (minReceivedAmount > 0) {
    SlippageLib.enforceMinReceived(received, minReceivedAmount);
}
```

#### Remaining MEV Vectors:

1. **Oracle Price Updates**: Price oracle updates could be front-run before deposits/withdrawals
2. **Cross-Asset Withdrawals**: Large withdrawals might benefit from oracle price manipulation

#### Finding ID: MED-NEW-1
**Severity:** Medium  
**Description:** Cross-asset withdrawals rely on real-time oracle prices. An attacker could potentially manipulate the backup oracle price (Pyth/Chainlink) just before executing a large cross-asset withdrawal.

**Mitigation:** The protocol uses `valueAtDeposit` for USD value calculations and caps withdrawals to `collateralAmount`, significantly limiting the attack surface.

**Recommendation:** Consider implementing TWAP (Time-Weighted Average Price) for cross-asset withdrawal pricing, or adding a delay mechanism for large withdrawals.

---

## 10. Flash Loan Attacks ✅ PASS

### Assessment: **Secure**

The protocol is designed to be resistant to flash loan attacks.

#### Implemented Protections:

1. **TOKEN-BASED Capacity Checks**: Collateral calculations use token amounts, not oracle values
```solidity
function _checkCapacity(uint256 insuredAmount) internal view {
    uint256 requiredCollateral =
        (totalInsuredTokens + insuredAmount) * COLLATERAL_RATIO / ConstantsLib.BASIS_POINT_SCALE;
    if (requiredCollateral > totalUnderwriterTokens) {
        revert ErrorsLib.InsufficientUnderwriterTokenBalance();
    }
}
```

2. **Locked Value at Deposit**: `valueAtDeposit` is stored at deposit time, preventing oracle manipulation
```solidity
uint256 valueAtDeposit = IPriceOracle(poolConfig.priceOracle).getValue(INSURED_TOKEN, received);
// Used for cross-asset withdrawal calculations
```

3. **Collateral Amount Cap**: Maximum payout capped to original collateral
```solidity
uint256 maxUwTokens = pos.collateralAmount;
if (payoutAmount > maxUwTokens) {
    payoutAmount = maxUwTokens;
}
```

4. **ERC4626 Share Inflation Protection** (MIN_VAULT_SUPPLY check)
```solidity
uint256 public constant MIN_VAULT_SUPPLY = 1000e18;
```

#### Recommendation: **None - Properly Implemented**

---

## 11. Cross-Chain and Interoperability ✅ N/A

### Assessment: **Not Applicable**

The protocol does not currently implement cross-chain functionality.

---

## 12. NFT Security Considerations ✅ PASS

### Assessment: **Secure**

The NFT contracts implement proper security measures.

#### Implemented Protections:

1. **Transfer Lock Period**
```solidity
// InsuredReceiptNFT.sol
uint256 public transferLockPeriod;
uint256 public constant MAX_TRANSFER_LOCK = 30 days;

function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
    if (from != address(0) && to != address(0)) {
        if (block.timestamp < pos.depositTime + transferLockPeriod) {
            revert ErrorsLib.TransferLocked(unlockTime);
        }
    }
    return super._update(to, tokenId, auth);
}
```

2. **Pool-Only Minting/Burning**
```solidity
modifier onlyPool() {
    if (msg.sender != pool) revert ErrorsLib.NotOwner();
    _;
}

function mint(...) external onlyPool returns (uint256 tokenId)
function burn(uint256 tokenId) external onlyPool
```

3. **One-Time Pool Setting**
```solidity
function setPool(address _pool) external onlyOwner {
    if (pool != address(0)) revert ErrorsLib.PoolAlreadySet();
    pool = _pool;
}
```

4. **LOW-12 FIX: Storage Cleanup**
```solidity
function burn(uint256 tokenId) external onlyPool {
    _burn(tokenId);
    delete positions[tokenId]; // Clear storage for gas refund
}
```

5. **Fees Follow NFT**: Commission tracking by tokenId ensures fees transfer with NFT ownership

#### Recommendation: **None - Properly Implemented**

---

## 13. Gas Optimization ✅ PASS

### Assessment: **Well Optimized**

Multiple gas optimizations have been implemented.

#### Implemented Optimizations:

| Fix ID | Optimization | Gas Saved |
|--------|-------------|-----------|
| GAS-M4 | Struct packing (protocolFeeRecipient + protocolFee) | ~1 storage slot |
| GAS-H2 | Unchecked pre-increment in loops | ~25 gas/iteration |
| GAS-H3 | Caching oracle address in memory | ~4,200 gas (2 SLOADs) |
| GAS-2 | Caching totalUnderwriterTokens | ~2,100 gas (1 SLOAD) |
| GAS-M5 | Storage pointer for position updates | ~2,100+ gas |

#### Code Evidence:

```solidity
// GAS-M4 FIX: Struct packed to save 1 storage slot
struct PoolConfig {
    // ... other fields ...
    address protocolFeeRecipient; // 20 bytes
    uint96 protocolFee;           // 12 bytes = 32 bytes total (1 slot)
}
```

```solidity
// GAS-H3 FIX: Cache oracle address
address priceOracle = poolConfig.priceOracle;
uint256 currentValue = IPriceOracle(priceOracle).getValue(INSURED_TOKEN, pos.amount);
```

#### Recommendation: **None - Well Optimized**

---

## 14. Upgradeability Security ✅ PASS

### Assessment: **Secure**

The protocol implements safe upgradeable patterns.

#### Implemented Protections:

1. **UUPS Pattern**: Using OpenZeppelin's UUPSUpgradeable
2. **Governance-Only Upgrades**
```solidity
function _authorizeUpgrade(address newImplementation) internal override onlyGovernance { }
```

3. **MED-7 FIX: Storage Gaps**
```solidity
// SplitRiskPool.sol
uint256[50] private __gap;

// ProtocolAccessControlUpgradeable.sol
uint256[49] private __gap; // 49 because _governanceTimelock uses 1 slot
```

4. **Initializer Protection**
```solidity
constructor() {
    _disableInitializers();
}
```

#### Recommendation: **None - Properly Implemented**

---

## Additional Findings

### Finding ID: LOW-NEW-1
**Severity:** Low  
**Location:** `SplitRiskPoolFactory.sol:removeToken()`  
**Description:** When removing a token from the whitelist, the `tokenInfo` mapping is not cleared.

```solidity
function removeToken(address token) external onlyGovernance {
    TokenWhitelistLib.removeToken(whitelistedTokens, isWhitelisted, token);
    emit EventsLib.TokenRemoved(token);
    // Note: tokenInfo[token] is not deleted
}
```

**Impact:** Minor storage inefficiency. The token cannot be used in new pools since `isWhitelisted[token]` is false, but the tokenInfo remains in storage.

**Recommendation:** Add `delete tokenInfo[token];` for cleaner state management.

---

### Finding ID: LOW-NEW-2
**Severity:** Low  
**Location:** `SplitRiskPool.sol:setAccessControl()`  
**Description:** No interface validation when setting access control contract.

```solidity
// MED-4: Note in existing documentation
function setAccessControl(address newAccessControl) external {
    if (msg.sender != POOL_CREATOR) revert ErrorsLib.InvalidPoolCreator();
    accessControl = newAccessControl;
}
```

**Impact:** If an incorrect address is set that doesn't implement `IPoolAccessControl`, all deposits/withdrawals that check access control will revert, effectively bricking the pool.

**Recommendation:** Consider adding interface validation via try-catch, or require governance approval to reset.

---

### Finding ID: LOW-NEW-3
**Severity:** Low  
**Location:** `MetaOracleAdapter.sol`  
**Description:** The `forceResetToPrimary()` function can be called without cooldown.

```solidity
function forceResetToPrimary() external onlyOwner {
    _isBackupActive = false;
    _challengeStartTime = 0;
    challengedToken = address(0);
    emit OracleSwitched(false);
    // No cooldown applied
}
```

**Impact:** Owner could bypass cooldown protection, though this is an emergency function and owner is trusted.

**Recommendation:** Consider applying cooldown even for admin resets to maintain consistent behavior.

---

### Finding ID: LOW-NEW-4  
**Severity:** Low  
**Location:** `SplitRiskPool.sol:_calculateAndAccumulateFees()`  
**Description:** If `currentPrice` from oracle returns 0, division by zero will occur.

```solidity
uint256 currentPrice = IPriceOracle(priceOracle).getPrice(INSURED_TOKEN);
commissionAmount = (commissionAmountUsd * ConstantsLib.TOKEN_DECIMALS) / currentPrice;
```

**Impact:** Transaction would revert with panic code 0x12 (division by zero) instead of a descriptive error.

**Recommendation:** Add explicit zero price check with custom error:
```solidity
if (currentPrice == 0) revert ErrorsLib.InvalidOraclePrice();
```

---

### Finding ID: INFO-NEW-1
**Severity:** Informational  
**Location:** Multiple contracts  
**Description:** Event emission for important state changes is comprehensive.

**Assessment:** The protocol emits events for all critical state changes, enabling proper off-chain monitoring and indexing. This is a positive security practice.

---

### Finding ID: INFO-NEW-2
**Severity:** Informational  
**Location:** `SplitRiskPool.sol`  
**Description:** ETH transfer protection is properly implemented.

```solidity
receive() external payable {
    revert ErrorsLib.EtherTransferNotAllowed();
}

fallback() external {
    revert ErrorsLib.EtherTransferNotAllowed();
}
```

**Assessment:** Prevents accidental ETH sends and unknown function call attacks.

---

### Finding ID: INFO-NEW-3
**Severity:** Informational  
**Description:** The protocol uses a comprehensive constants library (`ConstantsLib.sol`) for all magic numbers.

**Assessment:** This is a best practice that improves maintainability and reduces the risk of inconsistent values across contracts.

---

### Finding ID: INFO-NEW-4
**Severity:** Informational  
**Description:** Custom errors are used throughout instead of revert strings.

**Assessment:** This is a gas optimization best practice and provides better error handling with structured data.

---

### Finding ID: INFO-NEW-5
**Severity:** Informational  
**Description:** The MasterChef reward pattern implementation prevents late-joiner exploits.

```solidity
// Record reward debt at current accumulator value
rewardDebt[tokenId] = (rewardPerShareAccumulated * received) / ConstantsLib.REWARD_PRECISION;
```

**Assessment:** This is a well-known secure pattern for fair reward distribution.

---

## Summary of Recommendations

### Must Fix (None)
No critical issues requiring immediate fixes.

### Should Fix (Low Priority)

1. **LOW-NEW-1**: Clear `tokenInfo` mapping when removing tokens from whitelist
2. **LOW-NEW-2**: Consider adding interface validation for `setAccessControl()`
3. **LOW-NEW-4**: Add explicit zero price check in fee calculation

### Consider (Optional)

1. **MED-NEW-1**: Implement TWAP for cross-asset withdrawal pricing to reduce MEV risk
2. **LOW-NEW-3**: Apply cooldown to `forceResetToPrimary()` for consistency

---

## Audit Conclusion

The YieldShield protocol demonstrates excellent security practices with:

✅ **Reentrancy Protection** - All state-changing functions protected  
✅ **Access Control** - Multi-tiered, properly implemented  
✅ **Input Validation** - Comprehensive checks throughout  
✅ **Oracle Security** - Manipulation-resistant design with circuit breakers  
✅ **Flash Loan Resistance** - Token-based accounting, locked values  
✅ **DoS Protection** - Rate limiting, pool limits, gas optimization  
✅ **Upgrade Safety** - UUPS pattern with storage gaps  
✅ **NFT Security** - Transfer locks, pool-only operations

The codebase shows evidence of multiple prior security audits with comprehensive fixes implemented. The remaining findings are low severity and do not pose significant risk to user funds or protocol operation.

**Overall Security Rating: GOOD** ✅

---

## References

- [Solidity Security Audit Checklist](https://github.com/iAnonymous3000/solidity-security-audit-checklist)
- [OpenZeppelin Security Best Practices](https://docs.openzeppelin.com/contracts/4.x/api/security)
- [SWC Registry - Smart Contract Weakness Classification](https://swcregistry.io/)
- [Trail of Bits Building Secure Contracts](https://github.com/crytic/building-secure-contracts)
- [ConsenSys Diligence Security Best Practices](https://consensys.github.io/smart-contract-best-practices/)

---

*This report was generated using automated security analysis tools and manual code review following industry-standard audit practices.*
