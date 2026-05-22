// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title ISplitRiskPoolFactory
/// @author David Hawig
/// @notice Interface for the SplitRiskPoolFactory contract
interface ISplitRiskPoolFactory {
    // Structs
    struct CreationBond {
        address creator;
        address token;
        uint256 amount;
    }

    struct PoolInfo {
        address shieldedToken;
        address backingToken;
        string shieldedTokenSymbol;
        string backingTokenSymbol;
        uint256 commissionRate;
        uint256 poolFee;
        uint256 colleteralRatio;
        uint256 createdAt;
        address creator;
    }

    // State Variables (view functions)
    function governanceTimelock() external view returns (address);
    function splitRiskPoolImplementation() external view returns (address);
    function compositeOracle() external view returns (address);
    function pythOracle() external view returns (address);
    function erc4626OracleFeed() external view returns (address);
    function defaultProtocolFeeRecipient() external view returns (address);
    function whitelistedTokens(uint256 index) external view returns (address);
    function isWhitelisted(address token) external view returns (bool);
    function tokenRequiresStrictProtectedPrice(address token) external view returns (bool);
    function tokenInfo(address)
        external
        view
        returns (
            string memory name,
            string memory symbol,
            address token,
            address primaryOracleFeed,
            address backupOracleFeed,
            uint256 minCollateralRatioBp
        );
    function pools(uint256 index) external view returns (address);
    function activePools(uint256 index) external view returns (address);
    function activePoolCount() external view returns (uint256);
    function isPoolActive(address pool) external view returns (bool);
    function creationBonds(address pool) external view returns (address creator, address token, uint256 amount);
    function minimumCreationBondUsd() external view returns (uint256);
    function bootstrapModeEnabled() external view returns (bool);
    function poolCount() external view returns (uint256);
    function getPoolInfo(address pool) external view returns (ISplitRiskPoolFactory.PoolInfo memory);

    // Pool Creation
    function createPool(
        address _shieldedToken,
        string memory _shieldedTokenSymbol,
        address _backingToken,
        string memory _backingTokenSymbol,
        uint256 _commissionRate,
        uint256 _poolFee,
        uint256 _colleteralRatio,
        uint256 _creationBondAmount
    ) external returns (address poolAddress);
    function createPoolWithAccessControl(
        address _shieldedToken,
        string memory _shieldedTokenSymbol,
        address _backingToken,
        string memory _backingTokenSymbol,
        uint256 _commissionRate,
        uint256 _poolFee,
        uint256 _colleteralRatio,
        uint256 _creationBondAmount,
        address initialAccessControl
    ) external returns (address poolAddress);

    // View Functions
    function getPools(uint256 offset, uint256 limit) external view returns (address[] memory);
    function getPoolsInfo(uint256 offset, uint256 limit) external view returns (ISplitRiskPoolFactory.PoolInfo[] memory);
    function getActivePools() external view returns (address[] memory);
    function getActivePoolsInfo() external view returns (ISplitRiskPoolFactory.PoolInfo[] memory);
    function getWhitelistedTokens() external view returns (address[] memory);

    // Governance Functions
    function deactivatePool(address pool) external;
    function closePool(address pool) external;
    function setMinimumCreationBondUsd(uint256 newMinUsd) external;
    function setPoolImplementation(address newImplementation) external;
    function removeToken(address token) external;
    function addToken(
        address token,
        string memory name,
        string memory symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    ) external;
    function updateMinimumCollateral(address token, uint256 newMinCollateralRatioBp) external;
    function setTokenRequiresStrictProtectedPrice(address token, bool required) external;
    function setGovernanceTimelock(address newGovernanceTimelock) external;
    function acceptGovernanceTimelock() external;
    function pendingGovernanceTimelock() external view returns (address);
    function finalizeBootstrap() external;
    function setCompositeOracle(address newOracle) external;
    function setDefaultProtocolFeeRecipient(address newRecipient) external;
    function setManagedPythOracle(address newOracle) external;
    function setManagedERC4626OracleFeed(address newOracle) external;
    function transferManagedOracleOwnership(address oracle, address newOwner) external;
    function setCompositeOracleAuthorizedCaller(address caller, bool authorized) external;
    function setCompositeOracleDeviationThreshold(uint256 newThresholdBps) external;
    function setCompositeOracleChallengeDuration(uint256 newDurationSec) external;
    function setCompositeOracleTokenFeed(address token, address oracleFeed) external;
    function setCompositeOracleTokenFeedDual(address token, address primaryFeed, address backupFeed) external;
    function scheduleCompositeOracleTokenFeedRemoval(address token) external;
    function cancelScheduledCompositeOracleTokenFeedRemoval(address token) external;
    function removeCompositeOracleTokenFeed(address token) external;
    function scheduleCompositeOracleForceResetToPrimary(address token) external;
    function executeCompositeOracleForceResetToPrimary(address token) external;
    function scheduleCompositeOracleEmergencyCancelChallenge(address token) external;
    function executeCompositeOracleEmergencyCancelChallenge(address token) external;
    function cancelCompositeOracleScheduledOverride(address token, bytes32 action) external;
    function setPythTokenPriceFeed(address token, bytes32 feedId) external;
    function setPythTokenCompositePriceFeed(address token, bytes32 baseFeedId, bytes32 quoteUsdFeedId) external;
    function schedulePythTokenRemoval(address token) external;
    function cancelScheduledPythTokenRemoval(address token) external;
    function removePythToken(address token) external;
    function setPythMaxPriceAge(uint256 maxPriceAge) external;
    function setPythMaxPriceAgeForToken(address token, uint256 maxPriceAge) external;
    function setPythMaxPriceDeviation(uint256 maxPriceDeviation) external;
    function setPythMaxConfidenceBps(uint256 maxConfidenceBps) external;
    function setPythMaxEmaConfidenceBps(uint256 maxEmaConfidenceBps) external;
    function setERC4626UnderlyingPriceOracle(address underlyingPriceOracle) external;
    function registerERC4626Vault(address vault, address underlying) external;
    function refreshERC4626VaultSharePriceReference(address vault) external;
    function setERC4626VaultSharePriceDeviation(address vault, uint256 maxDeviationBps) external;
    function scheduleERC4626VaultRemoval(address vault) external;
    function cancelScheduledERC4626VaultRemoval(address vault) external;
    function removeERC4626Vault(address vault) external;

    // Owner Functions (initial deployment only)
    function addTokenInitial(
        address token,
        string memory name,
        string memory symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    ) external;
}
