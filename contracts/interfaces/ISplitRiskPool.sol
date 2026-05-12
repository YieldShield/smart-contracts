// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { TokenWhitelistLib } from "../libraries/TokenWhitelistLib.sol";

/// @title ISplitRiskPool
/// @author David Hawig
/// @notice Interface for the SplitRiskPool contract
interface ISplitRiskPool {
    function initialize(
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo,
        TokenWhitelistLib.TokenInfo memory backingTokenInfo,
        uint256 commissionRate,
        uint256 poolFee,
        address poolCreator,
        uint256 collateralRatio,
        address governanceTimelock,
        address priceOracle,
        address protocolFeeRecipient,
        address shieldReceiptNFT,
        address protectorReceiptNFT,
        address initialOwner
    ) external;

    // Core Pool Parameters are accessible via immutable variables in the contract

    // Pool Configuration and State (struct-based access)
    function poolConfig()
        external
        view
        returns (
            uint256 shieldedMinDepositAmount,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,
            uint256 maxTotalValueLockedUsd,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address protocolFeeRecipient,
            uint96 protocolFee,
            address priceOracle
        );
    function requiresStrictProtectedBackingPrice() external view returns (bool);

    function poolState() external view returns (uint256 shieldedTokenBalance, uint256 totalBackingTokenBalance);

    // NFT contracts
    function shieldReceiptNFT() external view returns (address);
    function protectorReceiptNFT() external view returns (address);

    // Pool-level state (TOKEN-BASED)
    function totalShieldedTokens() external view returns (uint256);
    function totalProtectorTokens() external view returns (uint256);
    function hasEverLaunched() external view returns (bool);
    function getUtilizationRatio() external view returns (uint256);

    // Deposit Functions (return tokenId)
    function depositBackingAsset(address asset, uint256 depositAmount, uint256 minReceivedAmount)
        external
        returns (uint256 tokenId);
    function depositShieldedAsset(address asset, uint256 depositAmount, uint256 minReceivedAmount)
        external
        returns (uint256 tokenId);

    // Withdrawal Functions
    function shieldedWithdraw(uint256 tokenId, address preferredAsset, uint256 minAmountOut) external;
    function partialWithdrawShielded(
        uint256 tokenId,
        uint256 withdrawAmount,
        address preferredAsset,
        uint256 minAmountOut
    ) external returns (uint256 newTokenId);
    function protectorWithdraw(uint256 tokenId, uint256 amount, address preferredAsset, uint256 minAmountOut) external;
    function startUnlockProcess(uint256 tokenId) external;
    function cancelUnlockProcess(uint256 tokenId) external;

    // Reward Functions
    function claimRewards(uint256 tokenId) external;
    function claimCommission(uint256 tokenId) external;
    function settleExpiredProtectorPosition(uint256 tokenId) external;

    // View Functions
    function getUserNFTCounts(address user) external view returns (uint256 shieldNFTCount, uint256 protectorNFTCount);
    function getPoolBalances()
        external
        view
        returns (uint256 shieldedTokenPoolBalance, uint256 totalBackingTokenPoolBalance);
    function isAssetSupported(address asset) external view returns (bool supported);
    function getLockedAmount(uint256 tokenId) external view returns (uint256);
    function getAvailableForWithdrawal(uint256 tokenId) external view returns (uint256);
    function getReservedFees() external view returns (uint256);
    function getWithdrawableBalance() external view returns (uint256);
    function getClaimableCommission(uint256 tokenId) external view returns (uint256);
    function getProtectorPositionAmount(uint256 tokenId) external view returns (uint256);
    function getProtectorDepositInfo(uint256 tokenId)
        external
        view
        returns (
            uint256 amount,
            uint64 depositTime,
            uint64 unlockRequestTime,
            uint256 lockedAmount,
            uint256 availableAmount,
            uint256 claimableCommission
        );
    function getShieldDepositInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint64 depositTime, uint256 valueAtDeposit, uint64 lastFeeClaimTime, bool isWithdrawn);

    // Access Control functions
    function accessControl() external view returns (address);
    function setAccessControl(address newAccessControl) external;
    function pause() external;
    function paused() external view returns (bool);

    // Governance Functions
    function updatePoolConfig(
        uint256 newShieldedMinDepositAmount,
        uint256 newShieldedMaxDepositAmount,
        uint256 newBackingMinDepositAmount,
        uint256 newBackingMaxDepositAmount,
        uint256 newMaxTotalValueLockedUsd,
        uint256 newMinimumPoolTime,
        uint256 newUnlockDuration,
        uint256 newProtocolFee,
        address newProtocolFeeRecipient,
        address newPriceOracle
    ) external;

    // Payment Functions
    function payPoolFee() external;
    function payProtocolFee() external;

    // Preview Functions - Simulate operations without executing them
}
