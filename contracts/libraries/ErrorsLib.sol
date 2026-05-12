// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title ErrorsLib
/// @author David Hawig
/// @notice Library containing all custom errors used across the protocol
library ErrorsLib {
    // ============ Input Validation Errors ============
    /// @notice Thrown when an asset address is invalid (zero or same as another)
    error InvalidAssetAddress();
    /// @notice Thrown when minDepositAmount >= maxDepositAmount
    error InvalidDepositAmountBounds();
    /// @notice Thrown when the commission rate is outside allowed bounds
    error InvalidCommissionRate();
    /// @notice Thrown when the pool fee is outside allowed bounds
    error InvalidPoolFee();
    /// @notice Thrown when the protocol fee is outside allowed bounds
    error InvalidProtocolFee();
    /// @notice Thrown when the collateral ratio is outside allowed bounds
    error InvalidCollateralRatio();
    /// @notice Thrown when the collateral ratio is below the token's minimum requirement
    error CollateralBelowTokenMinimum(uint256 provided, uint256 minimum);
    /// @notice Thrown when the governance timelock address is zero
    error InvalidGovernanceTimelock();
    /// @notice Thrown when the pool creator address is invalid
    error InvalidPoolCreator();
    /// @notice Thrown when the shielded token symbol is empty
    error InvalidShieldedTokenSymbol();
    /// @notice Thrown when the backing token symbol is invalid
    error InvalidBackingTokenSymbols();
    /// @notice Thrown when a token ID is invalid or doesn't exist
    error InvalidTokenId();
    /// @notice Thrown when the unlock duration is outside allowed bounds
    error InvalidUnlockDuration();
    /// @notice Thrown when the minimum pool time exceeds maximum allowed
    error InvalidMinimumPoolTime();
    /// @notice Thrown when the protocol fee recipient is zero address
    error InvalidProtocolFeeRecipient();
    /// @notice Thrown when a token address is invalid
    error InvalidTokenAddress();
    /// @notice Thrown when the pool address is invalid
    error InvalidPoolAddress();
    /// @notice Thrown when the access control address is invalid
    error InvalidAccessControlAddress();
    /// @notice Thrown when a token uses unsupported decimals for pool math
    error InvalidTokenDecimals(address token, uint8 decimals);
    /// @notice Thrown when pool creation requires a non-zero bond
    error InitialCreationBondRequired();

    // ============ Insufficient Balance/Amount Errors ============
    /// @notice Thrown when deposit amount is below minimum
    error InsufficientDepositAmount();
    /// @notice Thrown when protector token balance is insufficient for operation
    error InsufficientProtectorTokenBalance();
    /// @notice Thrown when token balance is insufficient for operation
    error InsufficientTokenBalance();
    /// @notice Thrown when pool time requirement is not met
    error InsufficientPoolTime();
    /// @notice Thrown when pool time requirement is not met (with details)
    error InsufficientPoolTimeWithDetails(uint256 requiredTime, uint256 elapsedTime);
    /// @notice Thrown when tokens are not unlocked for withdrawal
    error InsufficientUnlockedTokens();
    /// @notice Thrown when withdrawal would cause USD-based undercollateralization
    error InsufficientCollateralAfterWithdrawal();

    // ============ Already Done/State Errors ============
    /// @notice Thrown when position has already been withdrawn
    error PositionAlreadyWithdrawn();
    /// @notice Thrown when pool address has already been set
    error PoolAlreadySet();
    /// @notice Thrown when unlock process has already started
    error UnlockProcessAlreadyStarted();

    // ============ Not Found/Missing State Errors ============
    /// @notice Thrown when there are no tokens to withdraw
    error NoTokensToWithdraw();
    /// @notice Thrown when there is no unlock process to cancel
    error NoUnlockToCancel();
    /// @notice Thrown when token does not exist
    error TokenDoesNotExist();
    /// @notice Thrown when pool does not exist
    error PoolDoesNotExist();

    // ============ Limit/Permission Exceeded Errors ============
    /// @notice Thrown when deposit amount exceeds maximum
    error DepositAmountTooLarge();
    /// @notice Thrown when TVL limit would be exceeded
    error TVLLimitExceeded();
    /// @notice Thrown when max pools limit is exceeded
    error MaxPoolsExceeded(uint256 current, uint256 max);
    /// @notice Thrown when access control denies operation
    error AccessControlDenied(address account, string operation);
    /// @notice Thrown when a creation bond is below the configured USD minimum
    error CreationBondBelowMinimum(uint256 providedUsd, uint256 minimumUsd);

    // ============ Operation Failed Errors ============
    /// @notice Thrown when token transfer fails
    error TransferOperationFailed();
    /// @notice Thrown when ETH refund fails
    error EtherRefundFailed();
    /// @notice Thrown when ETH transfer is not allowed
    error EtherTransferNotAllowed();
    /// @notice Thrown when a forfeiture or reward cannot be fully reserved
    error RewardAccumulationIncomplete(uint256 expected, uint256 accumulated, uint256 redirected);

    // ============ Unsupported/Not Allowed Errors ============
    /// @notice Thrown when asset is not supported by the pool
    error UnsupportedAsset();
    /// @notice Thrown when token is not whitelisted
    error TokenNotWhitelisted();
    /// @notice Thrown when partial withdrawal would leave below minimum
    error PartialWithdrawalBelowMinimum();
    /// @notice Thrown when a pool is not currently active
    error PoolNotActive();
    /// @notice Thrown when a pool is already inactive
    error PoolAlreadyInactive();
    /// @notice Thrown when a pool is not empty enough to deactivate
    error PoolNotEmptyForDeactivation();

    // ============ Ownership/Authorization Errors ============
    /// @notice Thrown when caller is not the owner
    error NotOwner();
    // ============ Time-Based Errors ============
    /// @notice Thrown when NFT transfer is locked
    error TransferLocked(uint256 unlockTime);
    /// @notice Thrown when claim rewards cooldown is not met
    error ClaimRewardsCooldownNotMet(uint256 availableAt);

    // ============ ERC4626 Validation Errors ============
    /// @notice Thrown when two ERC4626 vaults share the same underlying asset
    error SameUnderlyingAsset(address shieldedToken, address backingToken, address underlyingAsset);

    // ============ Oracle Errors ============
    /// @notice Thrown when an oracle returns a zero or invalid price
    error InvalidOraclePrice();
    /// @notice Thrown when protected shielded-token pricing is unavailable for fee accrual.
    error ShieldedFeePriceUnavailable(address token);
    /// @notice Thrown when a price-sensitive operation is attempted while the token's
    ///         dual-feed oracle has a pending or currently challengeable price dispute.
    error OraclePendingChallenge(address token);
}
