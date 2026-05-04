# TODO Analysis - YieldShield Smart Contracts

This document provides a comprehensive analysis of all TODO comments found in the `packages/foundry/contracts/` folder. Each TODO is documented with its location, surrounding context, and an explanation of what needs to be done.

---

## 1. YSGovernor.sol - Line 28

**Location:** `packages/foundry/contracts/YSGovernor.sol:28`

**Context:**
```solidity
constructor(IVotes _token, TimelockController _timelock)
    Governor("YSGovernor")
    // TODO: Needs to be adjusted to the actual values for the deployment in production
    GovernorSettings(
        600, // initialVotingDelay (seconds) - 10 minutes (reduced for testing)
        1200, // initialVotingPeriod (seconds) - 20 minutes (reduced for testing)
        1000 * 10 ** 18 // initialProposalThreshold - 1000 YS tokens required to create a proposal
    )
```

**Explanation:**
The governance contract constructor uses test values that need to be adjusted for production deployment. The current values are:
- **Voting Delay:** 600 seconds (10 minutes) - reduced for testing
- **Voting Period:** 1200 seconds (20 minutes) - reduced for testing
- **Proposal Threshold:** 1000 YS tokens

**Action Required:**
Before production deployment, these values should be updated to appropriate production values. Typical governance parameters might include:
- Voting delay: 1-3 days (allows time for proposal review)
- Voting period: 3-7 days (allows sufficient time for token holders to vote)
- Proposal threshold: Should be set based on token distribution and desired governance participation level

---

## 2. YieldBearingTokenAdapter.sol - Line 4

**Location:** `packages/foundry/contracts/adapters/YieldBearingTokenAdapter.sol:4`

**Context:**
```solidity
// TODO: implement this for curve: https://github.com/pendle-finance/Pendle-SY-Public/blob/main/contracts/core/StandardizedYield/implementations/Curve/PendleCurvePool2TokenSYUpg.sol
/// @title YieldBearingTokenAdapter
/// @notice Library for interacting with different types of yield-bearing tokens
/// @dev Handles AToken-style, ERC4626-style, and Aave-style tokens
library YieldBearingTokenAdapter {
```

**Explanation:**
The adapter library currently supports Mock tokens (type 0), ERC4626 tokens (type 1), and Aave tokens (type 2). The TODO indicates that Curve pool token support needs to be implemented.

**Action Required:**
Implement support for Curve pool tokens by:
1. Adding a new token type (e.g., type 3) for Curve tokens
2. Implementing the `previewRedeem` logic for Curve pools, potentially using the Pendle StandardizedYield implementation as a reference
3. Updating the `TokenWhitelistLib` to include the new token type
4. Testing the implementation with actual Curve pool tokens

---

## 3. SplitRiskPool.sol - Line 230

**Location:** `packages/foundry/contracts/SplitRiskPool.sol:230`

**Context:**
```solidity
// Calculate the current assets in the vault based on the original assetsInVault and time elapsed
// TODO: yield bearing stable coins don't change the amount of assets in the vault, so we need to handle this differently
// uint256 timeElapsed = block.timestamp - uint256(poolTime);
// uint256 timeElapsedInDays = Math.mulDiv(timeElapsed, 1, 1 days);
// uint256 currentAssetsAmount = YieldBearingTokenAdapter.previewRedeem(
//     INSURED_TOKEN, assetsInVault, uint64(timeElapsedInDays), INSURED_TOKEN_TYPE, INSURED_VAULT_ADDRESS
// );
```

**Explanation:**
The code currently calculates yield based on the assumption that yield-bearing tokens increase in value over time. However, for yield-bearing stablecoins (like aUSDC, aUSDT), the number of tokens doesn't change - instead, the underlying value accrues through interest. The current implementation may not correctly handle this case.

**Action Required:**
Implement a different yield calculation mechanism for yield-bearing stablecoins:
1. Identify when a token is a yield-bearing stablecoin (may need a flag or token type)
2. For stablecoins, calculate yield based on the interest rate rather than token appreciation
3. Use the oracle or token-specific methods to get the current exchange rate/interest accrued
4. Update the `_calculateAndStoreFees` function to handle both types correctly

---

## 4. SplitRiskPool.sol - Line 468

**Location:** `packages/foundry/contracts/SplitRiskPool.sol:468`

**Context:**
```solidity
// Check if the insured token has already been withdrawn
if (insuredDepositMapped[msg.sender][withdrawIndex].isWithdrawn) revert ErrorsLib.AllreadyWithdrawn();

// Check minimum pool time only if withdrawing underwriter assets TODO: check if this is necessary
if (preferredAsset == UNDERWRITER_TOKEN) {
    uint256 poolTime = insuredDepositMapped[msg.sender][withdrawIndex].poolTime;
    uint256 timeElapsed = block.timestamp - uint256(poolTime);
    if (timeElapsed < poolConfig.minimumPoolTime) {
        revert ErrorsLib.InsufficientPoolTimeWithDetails(poolConfig.minimumPoolTime, timeElapsed);
    }
}
```

**Explanation:**
The code enforces a minimum pool time check only when withdrawing underwriter tokens (cross-asset withdrawal). The TODO questions whether this check is necessary or if it should also apply to withdrawals of insured tokens.

**Action Required:**
Clarify the business logic:
1. Determine if the minimum pool time restriction should apply to all withdrawals or only cross-asset withdrawals
2. If it should apply to all withdrawals, add the check before the `preferredAsset` check
3. If it's only needed for cross-asset withdrawals, document why this is the case
4. Consider if there are edge cases where this restriction might be bypassed unintentionally

---

## 5. SplitRiskPool.sol - Line 542

**Location:** `packages/foundry/contracts/SplitRiskPool.sol:542`

**Context:**
```solidity
underwriterDepositMapped[msg.sender].lockedUntil = uint64(block.timestamp + poolConfig.unlockDuration);

// TODO: lock other tokens in the pool as collateral if possible
// if this isn't possible the user needs to get a warning!
emit EventsLib.UnlockProcessStarted(msg.sender);
```

**Explanation:**
When an underwriter starts the unlock process, the system currently only locks their own underwriter tokens. The TODO suggests that if the underwriter doesn't have enough tokens locked, the system should attempt to lock other tokens in the pool as collateral, or warn the user if this isn't possible.

**Action Required:**
Implement additional collateral locking mechanism:
1. Check if the underwriter has sufficient locked tokens to cover all their insured deposits
2. If insufficient, determine if other tokens in the pool can be locked as additional collateral
3. If locking other tokens is possible, implement the logic to do so
4. If it's not possible, emit a warning event or revert with a clear error message
5. Consider the implications for other underwriters and the overall pool health

---

## 6. SplitRiskPool.sol - Line 561

**Location:** `packages/foundry/contracts/SplitRiskPool.sol:561`

**Context:**
```solidity
// Reduce the amount of the insured token (check for underflow)
insuredDepositMapped[insuredAddress][index].amount -= (commissionAmount + poolFeeAmount + protocolFeeAmount);

// Update valueOfDeposit with the latest oracle price for the new reduced amount
// TODO: This is wrong because it's doesn't lock up more tokens for the yield
// uint256 newAmount = insuredDepositMapped[insuredAddress][index].amount;
// insuredDepositMapped[insuredAddress][index].valueOfDeposit = IPriceOracle(poolConfig.priceOracle).getValue(INSURED_TOKEN, newAmount);
```

**Explanation:**
When rewards are claimed, fees are deducted from the insured deposit amount. The commented-out code would update the `valueOfDeposit` to reflect the new reduced amount. However, the TODO indicates this is incorrect because it doesn't account for the fact that as yield accrues, more underwriter tokens should be locked as collateral.

**Action Required:**
Fix the collateral locking mechanism for yield accrual:
1. When yield accrues and rewards are claimed, calculate how much additional collateral is needed
2. Lock additional underwriter tokens to cover the increased value of the insured deposit
3. Update the `valueOfDeposit` correctly, accounting for the new collateral requirements
4. Ensure the underwriter has sufficient unlocked tokens to cover the additional collateral
5. Consider edge cases where the underwriter doesn't have enough tokens to lock

---

## 7. SplitRiskPool.sol - Line 595

**Location:** `packages/foundry/contracts/SplitRiskPool.sol:595`

**Context:**
```solidity
if (ITranche(UNDERWRITER_RECEIPT_TOKEN).balanceOf(msg.sender) < totalTokensToWithdraw) {
    revert ErrorsLib.InsufficientTokenBalance();
}
// Check if the asset is a supported underwriter token
// TODO: implement function for withdrawals of insured tokens as underwriter
if (preferredAsset != UNDERWRITER_TOKEN) revert ErrorsLib.UnsupportedAsset();
```

**Explanation:**
The `underwriterWithdraw` function currently only allows underwriters to withdraw their own underwriter tokens. The TODO indicates that functionality should be added to allow underwriters to withdraw insured tokens instead.

**Action Required:**
Implement insured token withdrawal for underwriters:
1. Determine the business logic: should underwriters be able to withdraw insured tokens they've provided collateral for?
2. Calculate the equivalent amount of insured tokens based on the current exchange rate
3. Check if the pool has sufficient insured token balance
4. Update pool balances accordingly
5. Consider implications for the insured deposits that are backed by this underwriter's collateral
6. Add appropriate access control and validation checks

---

## 8. MockERC20.sol - Line 14

**Location:** `packages/foundry/contracts/mocks/MockERC20.sol:14`

**Context:**
```solidity
/// @title MockERC20 Token
/// @notice This is a simple ERC20 token with ownership control for testing or simulation purposes.
contract MockERC20 is ERC20, Ownable {
    /// @notice The fixed annual yield percentage for this token
    /// TODO: This is not correct, probably oracles need to be used here
    uint256 public immutable YIELD_PERCENTAGE;
```

**Explanation:**
The mock token uses a fixed, immutable yield percentage. The TODO suggests that in a real implementation, the yield should be determined dynamically, likely through an oracle that provides current yield/interest rates.

**Action Required:**
This is a mock contract for testing, so the action depends on the use case:
1. If this mock is sufficient for testing purposes, the TODO can remain as documentation
2. If a more realistic mock is needed, implement oracle integration to fetch current yield rates
3. Consider if this mock should be replaced with a more sophisticated test token that simulates real yield-bearing token behavior
4. Document that this is intentionally simplified for testing

---

## 9. MockOracle.sol - Line 69

**Location:** `packages/foundry/contracts/mocks/MockOracle.sol:69`

**Context:**
```solidity
function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB) external view returns (uint256) {
    // TODO: update the prices

    uint256 priceA = prices[tokenA];
    uint256 priceB = prices[tokenB];
    // ... rest of function
}
```

**Explanation:**
The `getEquivalentAmount` function has a TODO comment suggesting that prices need to be updated. However, the function already retrieves prices from the `prices` mapping. The TODO may be incomplete or referring to a need for automatic price updates.

**Action Required:**
Clarify and implement price update mechanism:
1. Determine if the TODO refers to automatic price updates (e.g., from an external oracle)
2. If automatic updates are needed, implement a keeper or update mechanism
3. If manual updates are sufficient for testing, remove or update the TODO comment
4. Consider if this mock should simulate price volatility for more realistic testing

---

## 10. MockERC4626.sol - Line 16

**Location:** `packages/foundry/contracts/mocks/MockERC4626.sol:16`

**Context:**
```solidity
contract MockERC4626 is ERC4626, Ownable {
    /// @notice The fixed annual yield percentage for this token
    /// TODO: This is just for testing purposes, in production the previewRedeem function will return a bigger number of assets over time
    uint256 public immutable YIELD_PERCENTAGE;
```

**Explanation:**
The mock ERC4626 vault uses a fixed yield percentage and a simplified `previewRedeem` implementation. The TODO notes that this is for testing only and that in production, the `previewRedeem` function should return increasing asset amounts over time as yield accrues.

**Action Required:**
This is a mock contract, so:
1. If this is sufficient for testing, document that this is intentionally simplified
2. If more realistic behavior is needed, implement time-based yield accrual in `previewRedeem`
3. Consider tracking deposit timestamps to calculate yield based on time elapsed
4. Ensure the mock accurately simulates real ERC4626 vault behavior for comprehensive testing

---

## 11. TokenWhitelistLib.sol - Line 18

**Location:** `packages/foundry/contracts/libraries/TokenWhitelistLib.sol:18`

**Context:**
```solidity
struct TokenInfo {
    string name; // the name of the token
    string symbol; // the symbol of the token
    address token; // the token address
    address vault; // in case of Aave, this is the pool address for the token
    uint16 tokenType; // 0: Mock, 1: ERC4626, 2: Aave, 3: TODO: add other token types here
}
```

**Explanation:**
The `TokenInfo` struct includes a `tokenType` field with documented types 0-2, and a TODO indicating that additional token types should be added. This relates to TODO #2 (Curve token support) and potentially other yield-bearing token types.

**Action Required:**
Expand token type support:
1. Define additional token types (e.g., 3: Curve, 4: Compound, 5: Yearn, etc.)
2. Update the `YieldBearingTokenAdapter` to handle new token types
3. Update documentation and comments to reflect all supported token types
4. Ensure the token type enum/constants are well-documented
5. Consider using an enum instead of magic numbers for better type safety

---

## Summary

**Total TODOs Found:** 11

**By Priority:**
- **High Priority (Production Impact):**
  1. YSGovernor.sol - Line 28: Governance parameters need production values
  2. SplitRiskPool.sol - Line 230: Yield calculation for stablecoins
  3. SplitRiskPool.sol - Line 561: Collateral locking for yield accrual
  4. SplitRiskPool.sol - Line 542: Additional collateral locking mechanism

- **Medium Priority (Feature Completeness):**
  5. YieldBearingTokenAdapter.sol - Line 4: Curve token support
  6. SplitRiskPool.sol - Line 595: Insured token withdrawal for underwriters
  7. TokenWhitelistLib.sol - Line 18: Additional token types

- **Low Priority (Testing/Clarification):**
  8. SplitRiskPool.sol - Line 468: Minimum pool time check clarification
  9. MockERC20.sol - Line 14: Oracle integration for yield (mock contract)
  10. MockOracle.sol - Line 69: Price update mechanism (mock contract)
  11. MockERC4626.sol - Line 16: Time-based yield accrual (mock contract)

---

**Document Generated:** $(date)
**Last Updated:** Review all TODOs before production deployment

