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
    function setCompositeOracle(address newOracle) external;
    function setDefaultProtocolFeeRecipient(address newRecipient) external;

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
