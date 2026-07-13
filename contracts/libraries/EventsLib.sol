// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

/// @title EventsLib
/// @author David Hawig
/// @notice Library containing all events used across the protocol
/// @dev I-16: governance-config events (ParameterUpdated, PoolConfigUpdated,
///      ProtocolFeeRecipientUpdated, …) do not currently include the caller as
///      an indexed field. Adding it would break the existing event ABI and
///      require off-chain indexers to migrate. Deferred to the next breaking
///      event-schema change; until then, txn-level metadata (msg.sender on the
///      enclosing call) provides the same information off-chain.
library EventsLib {
    // SplitRiskPool events
    event ShieldActivated(
        address indexed withdrawer, uint256 amount, uint256 shieldedTokenAmount, uint256 backingTokenAmount
    );
    event ShieldedWithdrawal(address indexed withdrawer, uint256 amount, address preferredAsset);
    event UnlockProcessStarted(address indexed protector, uint256 indexed tokenId, uint256 amount);
    event UnlockProcessCancelled(address indexed protector, uint256 indexed tokenId);
    event PoolFeePaid(address indexed creator, uint256 amount);
    event ProtocolFeePaid(address indexed recipient, uint256 amount);
    event ShieldedAssetDeposited(
        address indexed depositor, address indexed asset, uint256 amount, uint256 receiptTokenId
    );
    event ProtectorAssetDeposited(
        address indexed depositor, address indexed asset, uint256 amount, uint256 receiptTokenId
    );
    event ShieldedAssetWithdrawn(address indexed user, uint256 assets, uint256 shares, uint256 coverageId);
    event ProtectorAssetWithdrawn(address indexed user, address indexed asset, uint256 assets, uint256 shares);
    event ProtectorTokensLocked(address indexed protector, uint256 amount, uint256 lockedUntil);
    event ShieldCoverageCreated(
        uint256 indexed coverageId, uint256 shieldedAmount, address[] protectors, uint256[] amounts
    );
    event ShieldCoverageReleased(uint256 indexed coverageId);
    event FeesDistributed(uint256 poolFeeAmount, uint256 protocolFeeAmount, uint256 commissionAmount);
    event CommissionPaid(address indexed protectorAddress, uint256 amount);
    event RewardsClaimed(address indexed shieldedAddress, uint256 feesCharged, address indexed asset);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event ProtocolFeeRecipientUpdated(address oldRecipient, address newRecipient);
    event PoolFeeRecipientUpdated(address oldRecipient, address newRecipient);
    event ParameterUpdated(string parameterName, uint256 newValue);
    event PoolConfigUpdated(
        uint256 shieldedMinDepositAmount,
        uint256 shieldedMaxDepositAmount,
        uint256 backingMinDepositAmount,
        uint256 backingMaxDepositAmount,
        uint256 maxTotalValueLockedUsd,
        uint256 minimumPoolTime,
        uint256 unlockDuration,
        uint256 protocolFee,
        address protocolFeeRecipient,
        address priceOracle
    );
    event GovernanceTimelockUpdated(address indexed previousGovernance, address indexed newGovernance);
    event AccessControlUpdated(address indexed previousAccessControl, address indexed newAccessControl);
    event AccessControlStatusUpdated(
        address indexed accessControl, bool depositsGated, bool withdrawalsGated, bool governanceInstalled
    );

    // NFT-related events
    event ShieldNFTPoolSet(address indexed pool);
    event ProtectorNFTPoolSet(address indexed pool);
    event ShieldNFTMinted(address indexed to, uint256 indexed tokenId, uint256 amount, uint256 valueAtDeposit);
    event ShieldNFTBurned(uint256 indexed tokenId);
    event ProtectorNFTMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event ProtectorNFTBurned(uint256 indexed tokenId);
    event PartialWithdrawal(
        address indexed user,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        uint256 withdrawAmount,
        uint256 remainingAmount
    );
    event CommissionClaimed(address indexed recipient, uint256 indexed tokenId, uint256 amount);
    event CommissionForfeited(address indexed caller, address indexed owner, uint256 indexed tokenId, uint256 amount);
    event CommissionEscrowed(
        address indexed caller,
        address indexed beneficiary,
        uint256 indexed tokenId,
        address escrow,
        address token,
        uint256 amount
    );
    event NoCommissionToClaim(address indexed recipient, uint256 indexed tokenId);
    event ProtectorResidualBackingSwept(address indexed recipient, address indexed asset, uint256 amount);
    event ProtectorResidualBackingReserved(uint256 indexed epoch, address indexed asset, uint256 amount);
    event PoolUnaccountedSurplusSwept(
        address indexed recipient, address indexed asset, uint256 nominalAmount, uint256 receivedAmount
    );

    // SplitRiskPoolFactory events
    event PoolCreated(
        address indexed poolAddress,
        address indexed shieldedToken,
        address indexed backingToken,
        uint256 commissionRate,
        uint256 poolFee,
        uint256 collateralRatio,
        address creator
    );
    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TokenWhitelisted(
        address indexed token,
        string symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    );
    event TokenRemoved(address indexed token);
    event MinimumCollateralUpdated(address indexed token, uint256 oldMinCollateral, uint256 newMinCollateral);
    event TokenStrictProtectedPriceRequirementUpdated(address indexed token, bool oldRequired, bool newRequired);
    event PoolClosed(address indexed pool, address indexed creator);
    event PoolDeactivated(address indexed pool);
    event CreationBondPosted(address indexed pool, address indexed creator, address indexed token, uint256 amount);
    event CreationBondReturned(address indexed pool, address indexed recipient, address indexed token, uint256 amount);
    event CreationBondForfeited(address indexed pool, address indexed recipient, address indexed token, uint256 amount);
    event CreationBondShortfall(
        address indexed pool, address indexed token, uint256 recordedAmount, uint256 paidAmount
    );
    event MinimumCreationBondUsdUpdated(uint256 oldValue, uint256 newValue);
    event MaxActivePoolsUpdated(uint256 oldValue, uint256 newValue);

    // Fee overflow events
    event FeeDropped(string feeType, uint256 droppedAmount, uint256 currentAccumulated);
}
