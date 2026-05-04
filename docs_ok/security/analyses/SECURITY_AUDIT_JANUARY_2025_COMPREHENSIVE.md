# Comprehensive Security Audit - January 2025

**Audit Date:** January 7, 2025  
**Auditor:** AI Security Analyst  
**Scope:** Full smart contract codebase review  
**Focus:** Logic errors, edge cases, access control, economic attacks, and implementation gaps

---

## Executive Summary

This audit covers all smart contracts in the YieldShield protocol, including:
- `SplitRiskPool.sol` - Core pool logic
- `SplitRiskPoolFactory.sol` - Pool deployment factory
- `InsuredReceiptNFT.sol` / `UnderwriterReceiptNFT.sol` - Position NFTs
- `MetaOracleAdapter.sol` - Dual-oracle switching mechanism
- Supporting libraries and base contracts

Previous audits have addressed many issues. This audit focuses on identifying remaining edge cases and potential vulnerabilities.

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| MED-1 | Medium | Pool Config Update Missing Deposit Amount Validation | Open |
| MED-2 | Medium | Partial Withdrawal Resets Minimum Pool Time | Open |
| MED-3 | Medium | Fee Accumulator Race Condition | Open |
| MED-4 | Medium | Oracle Challenge Front-Running Window | Acknowledged |
| LOW-1 | Low | Pool Creator Cannot Be Changed | Open |
| LOW-2 | Low | TokenInfo Not Cleared on Whitelist Removal | Open |
| LOW-3 | Low | getAvailableForWithdrawal Precision Edge Case | Open |
| LOW-4 | Low | NFT getPosition Returns Default for Non-Existent Tokens | Open |
| LOW-5 | Low | Silent Return on Zero Commission Claim | Open |
| LOW-6 | Low | Missing Maximum Total Fee Validation | Open |
| INFO-1 | Info | Inconsistent Error Messages | Open |
| INFO-2 | Info | Missing Constants for Magic Numbers | Open |
| INFO-3 | Info | Test Coverage Gap | Open |

---

## Medium Severity Findings

### MED-1: Pool Config Update Missing Deposit Amount Validation

**Location:** `SplitRiskPool.sol:updatePoolConfig()`

**Description:**
The `updatePoolConfig` function doesn't validate that `newMinDepositAmount < newMaxDepositAmount`. This could create an impossible configuration where minimum deposit exceeds maximum deposit, effectively freezing new deposits.

**Current Code:**
```solidity
function updatePoolConfig(
    uint256 newMinDepositAmount,
    uint256 newMaxDepositAmount,
    // ...
) external onlyGovernance {
    // Missing: if (newMinDepositAmount >= newMaxDepositAmount) revert;
    poolConfig.minDepositAmount = newMinDepositAmount;
    poolConfig.maxDepositAmount = newMaxDepositAmount;
    // ...
}
```

**Impact:** 
Governance could accidentally or maliciously configure the pool to reject all deposits.

**Recommendation:**
Add validation:
```solidity
if (newMinDepositAmount >= newMaxDepositAmount) {
    revert ErrorsLib.InvalidDepositAmountConfig();
}
if (newMaxDepositAmount > newMaxTotalValueLocked) {
    revert ErrorsLib.InvalidDepositAmountConfig();
}
```

---

### MED-2: Partial Withdrawal Resets Minimum Pool Time

**Location:** `SplitRiskPool.sol:partialWithdrawInsured()`

**Description:**
When performing a partial withdrawal, a new NFT is minted with `depositTime = block.timestamp`. This effectively resets the `minimumPoolTime` requirement for the remaining position, allowing users to bypass the waiting period through iterative partial withdrawals.

**Attack Scenario:**
1. User deposits 1000 tokens, `minimumPoolTime` is 7 days
2. After 1 day, user performs partial withdrawal of 1 token
3. New NFT has `depositTime = now`, remaining 999 tokens can now wait another 7 days from the new time
4. User repeats, extracting small amounts while resetting the timer

**Impact:**
While each partial withdrawal is subject to fee calculation, the ability to reset the timer could allow users to strategically time their withdrawals around yield events.

**Recommendation:**
Preserve the original deposit time when minting the new NFT:
```solidity
// In partialWithdrawInsured, pass original depositTime to mint
newTokenId = IInsuredReceiptNFT(insuredReceiptNFT).mintWithDepositTime(
    msg.sender, remaining, newValue, newCollateralAmount, pos.depositTime
);
```

---

### MED-3: Fee Accumulator Race Condition

**Location:** `SplitRiskPool.sol:payPoolFee()`, `payProtocolFee()`, `claimCommission()`

**Description:**
Multiple accumulated fee balances (`accumulatedPoolFee`, `accumulatedProtocolFee`, `accumulatedCommissions`) are all drawn from `poolState.insuredTokenBalance`. While each payout function checks `actualBalance`, there's no ordering guarantee. In theory, if all three are called in rapid succession in the same block, the total payouts could exceed the actual balance.

**Scenario:**
1. Pool has 100 tokens, with accumulated fees: poolFee=40, protocolFee=40, commissions=40
2. All three payout functions are called in the same block
3. First two succeed (80 tokens paid), third fails
4. First-come-first-served determines who gets paid

**Impact:**
While unlikely in normal operation, this could cause fee recipients to lose their accumulated fees if the pool is drained.

**Recommendation:**
Consider:
1. Adding a combined `payAllFees()` function that atomically handles all payouts
2. Or reserving fee amounts in a separate accounting variable that can't be spent by withdrawals

---

### MED-4: Oracle Challenge Front-Running Window

**Location:** `MetaOracleAdapter.sol:challengeForToken()`, `finalizeChallenge()`

**Description:**
When a challenge is initiated and before finalization (16-hour window), sophisticated actors could:
1. Observe the pending challenge
2. Calculate whether switching to backup oracle benefits their position
3. Execute large withdrawals or deposits accordingly

**Mitigating Factors:**
- 16-hour timelock provides warning to other participants
- Challenge can be cancelled if deviation resolves
- Cooldown prevents rapid challenge cycling

**Impact:**
Medium - sophisticated actors could front-run oracle switches, but the timelock significantly reduces surprise factor.

**Recommendation:**
Document this behavior clearly and consider adding rate limits on large withdrawals during pending challenges.

---

## Low Severity Findings

### LOW-1: Pool Creator Cannot Be Changed

**Location:** `SplitRiskPool.sol`

**Description:**
The `POOL_CREATOR` address is set during initialization and cannot be updated. If the pool creator's key is compromised or the creator wants to transfer their role, there's no mechanism to do so.

**Current Code:**
```solidity
address public POOL_CREATOR; // Set once in initialize, no setter function
```

**Impact:**
Pool fees will continue flowing to a compromised or abandoned address.

**Recommendation:**
Add a governance function to update pool creator:
```solidity
function setPoolCreator(address newPoolCreator) external onlyGovernance {
    if (newPoolCreator == address(0)) revert ErrorsLib.InvalidAssetAddress();
    address oldCreator = POOL_CREATOR;
    POOL_CREATOR = newPoolCreator;
    emit EventsLib.PoolCreatorUpdated(oldCreator, newPoolCreator);
}
```

---

### LOW-2: TokenInfo Not Cleared on Whitelist Removal

**Location:** `SplitRiskPoolFactory.sol:removeToken()`

**Description:**
When a token is removed from the whitelist, the `tokenInfo[token]` mapping retains the old data.

**Current Code:**
```solidity
function removeToken(address token) external onlyGovernance {
    TokenWhitelistLib.removeToken(whitelistedTokens, isWhitelisted, token);
    // Missing: delete tokenInfo[token];
    emit EventsLib.TokenRemoved(token);
}
```

**Impact:**
Stale data persists, which could confuse off-chain systems reading the mapping.

**Recommendation:**
Add: `delete tokenInfo[token];`

---

### LOW-3: getAvailableForWithdrawal Precision Edge Case

**Location:** `SplitRiskPool.sol:getAvailableForWithdrawal()`

**Description:**
The function calculates `pos.amount - getLockedAmount(tokenId)`. While `getLockedAmount` uses percentage-based calculation that should never exceed `pos.amount`, rounding in Solidity could theoretically cause edge cases in extreme scenarios.

**Current Code:**
```solidity
function getAvailableForWithdrawal(uint256 tokenId) public view returns (uint256) {
    IUnderwriterReceiptNFT.UnderwriterPosition memory pos = ...
    return pos.amount - getLockedAmount(tokenId); // Potential underflow if lockedAmount > pos.amount due to rounding
}
```

**Recommendation:**
Add defensive check:
```solidity
uint256 locked = getLockedAmount(tokenId);
return locked >= pos.amount ? 0 : pos.amount - locked;
```

---

### LOW-4: NFT getPosition Returns Default for Non-Existent Tokens

**Location:** `InsuredReceiptNFT.sol:getPosition()`, `UnderwriterReceiptNFT.sol:getPosition()`

**Description:**
Calling `getPosition()` with a non-existent token ID returns a struct with default (zero) values rather than reverting. This could mislead callers who don't separately verify token existence.

**Recommendation:**
Add existence check:
```solidity
function getPosition(uint256 tokenId) external view returns (InsuredPosition memory) {
    if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
    return positions[tokenId];
}
```

---

### LOW-5: Silent Return on Zero Commission Claim

**Location:** `SplitRiskPool.sol:claimCommission()`

**Description:**
When `claimable == 0`, the function silently completes without emitting an event or reverting. This could confuse users who expect feedback.

**Recommendation:**
Consider emitting an event or reverting with a descriptive message:
```solidity
if (claimable == 0) {
    emit EventsLib.NoCommissionToClaim(msg.sender, tokenId);
    return;
}
```

---

### LOW-6: Missing Maximum Total Fee Validation

**Location:** `SplitRiskPoolFactory.sol:createPool()` and `SplitRiskPool.sol:initialize()`

**Description:**
While individual fee components are validated against maximums, the sum of `commissionRate + poolFee + protocolFee` is not checked. Currently:
- MAX_COMMISSION_RATE = 5000 (50%)
- MAX_POOL_FEE = 2000 (20%)
- MAX_PROTOCOL_FEE = 1000 (10%)
- Total possible = 80%

While 80% is below 100%, having such high combined fees could severely impact user yields.

**Recommendation:**
Add a maximum combined fee check:
```solidity
uint256 totalFees = _commissionRate + _poolFee + 100; // 100 = default protocol fee
if (totalFees > 5000) { // Max 50% total fees
    revert ErrorsLib.CombinedFeesTooHigh();
}
```

---

## Informational Findings

### INFO-1: Inconsistent Error Messages

**Description:**
Error naming conventions are inconsistent:
- Past tense: `PositionAlreadyWithdrawn`, `PoolAlreadySet`
- Present tense: `InsufficientTokenBalance`, `InvalidTokenId`

**Recommendation:**
Standardize on one convention for clarity.

---

### INFO-2: Missing Constants for Magic Numbers

**Location:** `SplitRiskPool.sol:initialize()`

**Description:**
Default values like `100` (1% protocol fee), `10` (minDepositAmount), `1_000_000e18` (maxDepositAmount) are hardcoded.

**Recommendation:**
Define as constants in `ConstantsLib.sol` for easier auditing and updates:
```solidity
uint256 public constant DEFAULT_PROTOCOL_FEE = 100;
uint256 public constant DEFAULT_MIN_DEPOSIT = 10;
uint256 public constant DEFAULT_MAX_DEPOSIT = 1_000_000e18;
uint256 public constant DEFAULT_MAX_TVL = 10_000_000e18;
```

---

### INFO-3: Test Coverage Gap

**Description:**
The test `testRevertWhenMaxPoolsExceeded` in `SplitRiskPoolFactory.t.sol` is failing, indicating incomplete test coverage for the MAX_POOLS limit feature.

**Recommendation:**
Fix the failing test to ensure all security-critical paths have passing tests.

---

## Positive Findings

The following security measures are well implemented:

1. **Reentrancy Protection:** All state-changing functions use `nonReentrant` modifier
2. **Access Control:** Clear separation between owner, governance, and pool-only functions
3. **Pausability:** Emergency pause mechanism in place
4. **Storage Gaps:** Properly reserved for upgradeable contracts
5. **Balance-Delta Pattern:** Fee-on-transfer tokens properly supported
6. **Slippage Protection:** User-specified minimums enforced
7. **Oracle Circuit Breaker:** Dual-oracle with challenge mechanism provides resilience
8. **Overflow Protection:** Using Solidity 0.8+ with built-in checks
9. **Safe Token Transfers:** Using OpenZeppelin's SafeERC20

---

## Conclusion

The YieldShield protocol demonstrates strong security practices overall. The previous audit findings have been well addressed. The remaining issues identified in this audit are primarily edge cases and UX improvements rather than critical vulnerabilities.

**Recommendations for Next Steps:**
1. Address MED-1 (deposit amount validation) immediately
2. Consider MED-2 (partial withdrawal timer reset) based on business requirements
3. Fix the failing test to ensure MAX_POOLS is properly validated
4. Consider adding combined fee maximum validation
5. Add `delete tokenInfo[token]` when removing from whitelist

---

*This audit is provided for informational purposes. A formal security audit by a professional auditing firm is recommended before mainnet deployment.*
