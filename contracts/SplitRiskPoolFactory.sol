// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { ISplitRiskPoolFactory } from "./interfaces/ISplitRiskPoolFactory.sol";
import { ISplitRiskPool } from "./interfaces/ISplitRiskPool.sol";
import { ICompositeOracle } from "./interfaces/ICompositeOracle.sol";
import { SplitRiskPool } from "./SplitRiskPool.sol";
import { TokenWhitelistLib } from "./libraries/TokenWhitelistLib.sol";
import { ConstantsLib } from "./libraries/ConstantsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";
import { PoolValidationLib } from "./libraries/PoolValidationLib.sol";
import { PoolCreationLib } from "./libraries/PoolCreationLib.sol";
import { PoolOracleValidationLib } from "./libraries/PoolOracleValidationLib.sol";
import { ProtocolAccessControlUpgradeable } from "./base/ProtocolAccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC1822Proxiable } from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOwnableOracleAdmin {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface ICompositeOracleAdmin {
    function setTokenOracleFeed(address token, address oracleFeed) external;
    function setTokenOracleFeedDual(address token, address primaryFeed, address backupFeed) external;
    function scheduleRemoveTokenOracleFeed(address token) external;
    function cancelScheduledRemoveTokenOracleFeed(address token) external;
    function removeTokenOracleFeed(address token) external;
    function setAuthorizedCaller(address caller, bool authorized) external;
    function clearAuthorizedCallers() external;
    function setDeviationThreshold(uint256 newThresholdBps) external;
    function setChallengeDuration(uint256 newDurationSec) external;
    function scheduleForceResetToPrimary(address token) external;
    function forceResetToPrimary(address token) external;
    function scheduleEmergencyCancelChallenge(address token) external;
    function emergencyCancelChallenge(address token) external;
    function cancelScheduledOverride(address token, bytes32 action) external;
}

interface IPythOracleAdmin {
    function setTokenPriceFeed(address token, bytes32 feedId) external;
    function setTokenCompositePriceFeed(address token, bytes32 baseFeedId, bytes32 quoteUsdFeedId) external;
    function scheduleRemoveToken(address token) external;
    function cancelScheduledRemoveToken(address token) external;
    function removeToken(address token) external;
    function setMaxPriceAge(uint256 maxPriceAge) external;
    function setMaxPriceAgeForToken(address token, uint256 maxPriceAge) external;
    function setMaxPriceDeviation(uint256 maxPriceDeviation) external;
    function setMaxConfidenceBps(uint256 maxConfidenceBps) external;
    function setMaxEmaConfidenceBps(uint256 maxEmaConfidenceBps) external;
    function setMaxPriceAgeForFeedId(bytes32 feedId, uint256 maxPriceAge) external;
    function setMaxCompositePublishTimeSkew(uint256 maxSkew) external;
}

interface IERC4626OracleFeedAdmin {
    function setUnderlyingPriceOracle(address underlyingPriceOracle) external;
    function registerVault(address vault, address underlying) external;
    function refreshVaultSharePriceReference(address vault) external;
    function setVaultSharePriceDeviation(address vault, uint256 maxDeviationBps) external;
    function scheduleRemoveVault(address vault) external;
    function cancelScheduledRemoveVault(address vault) external;
    function removeVault(address vault) external;
}

/// @title SplitRiskPoolFactory
/// @author David Hawig
/// @notice Factory contract for deploying and managing SplitRiskPool instances
contract SplitRiskPoolFactory is
    Initializable,
    ISplitRiskPoolFactory,
    ProtocolAccessControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    error CompositeOracleAuthorizationClosed();

    // Governance-controlled protocol parameters
    address public splitRiskPoolImplementation;
    address public compositeOracle;
    address public pythOracle;
    address public erc4626OracleFeed;
    address public defaultProtocolFeeRecipient;

    /// @notice Maximum number of active pools that can exist at the same time
    uint256 public constant MAX_POOLS = 1000;
    uint256 public constant DEFAULT_MINIMUM_CREATION_BOND_USD = 500e8;
    uint256 public constant PROTECTOR_ONLY_POOL_DEACTIVATION_DELAY = 7 days;

    // Token whitelist (governance-controlled) - all whitelisted tokens use TokenInfo
    address[] public whitelistedTokens;
    mapping(address => bool) public isWhitelisted;
    // Mapping from token address to TokenInfo
    mapping(address => TokenWhitelistLib.TokenInfo) public tokenInfo;

    /* State Variables */
    address[] public pools;
    /// @dev Mapping from pool address to pool info
    mapping(address => ISplitRiskPoolFactory.PoolInfo) private _poolInfo;
    // Backing-asset policy: require the strict protected-price path instead of compatibility fallback.
    mapping(address => bool) public tokenRequiresStrictProtectedPrice;

    /*
     * Storage layout note:
     * This ordering becomes the v1 baseline on first deployment. The fields above,
     * including minimumCreationBondUsd below, are part of that initial baseline and
     * are populated by initialize() on first deploy.
     *
     * After deployment, future upgrades must append new storage below this marker and
     * initialize newly-added config through a reinitializer called with upgradeToAndCall.
     * Do not rely on initialize() to seed config added in later versions.
     */
    address[] public activePools;
    mapping(address => uint256) private _activePoolIndexPlusOne;
    mapping(address => bool) public isPoolActive;
    mapping(address => ISplitRiskPoolFactory.CreationBond) public creationBonds;
    uint256 public minimumCreationBondUsd;
    bool public bootstrapModeEnabled;

    address[] private _trackedCompositeOracleAuthorizedCallers;
    mapping(address => bool) private _compositeOracleAuthorizedCallerSeen;
    mapping(address => bool) private _compositeOracleAuthorizedCallerActive;

    event PoolImplementationUpdated(address indexed previousImplementation, address indexed newImplementation);
    event BootstrapModeFinalized(address indexed caller);
    event ManagedOracleUpdated(bytes32 indexed oracleRole, address indexed previousOracle, address indexed newOracle);

    bytes32 public constant PYTH_ORACLE_ROLE = keccak256("PYTH_ORACLE");
    bytes32 public constant ERC4626_ORACLE_FEED_ROLE = keccak256("ERC4626_ORACLE_FEED");

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory contract
     * @dev Sets up access control, governance timelock, pool implementation address,
     *      and the v1 creation-bond baseline. Can only be called once during deployment.
     *      minimumCreationBondUsd is seeded here for first deployment only because it is part of the
     *      original storage baseline. Future upgrades must not rely on initialize; any config added
     *      after deployment must use a reinitializer executed via upgradeToAndCall.
     * @param initialOwner Initial owner address
     * @param governanceTimelock_ Governance timelock address
     * @param poolImplementation_ Address of the SplitRiskPool implementation contract
     */
    function initialize(address initialOwner, address governanceTimelock_, address poolImplementation_)
        external
        initializer
    {
        if (governanceTimelock_ == address(0)) revert GovernanceZeroAddress();
        _validatePoolImplementation(poolImplementation_);
        __ProtocolAccessControl_init(initialOwner, governanceTimelock_);
        splitRiskPoolImplementation = poolImplementation_;
        minimumCreationBondUsd = DEFAULT_MINIMUM_CREATION_BOND_USD;
        maxActivePools = MAX_POOLS;
        bootstrapModeEnabled = true;
    }

    /**
     * @notice Sets the pool implementation address for new pool deployments
     * @dev Only callable by governance. Updates the implementation used for UUPS proxy deployments.
     * @param newImplementation Address of the new pool implementation contract
     * @custom:error InvalidAssetAddress If newImplementation is zero address
     */
    function setPoolImplementation(address newImplementation) external onlyGovernance {
        _validatePoolImplementation(newImplementation);
        emit PoolImplementationUpdated(splitRiskPoolImplementation, newImplementation);
        splitRiskPoolImplementation = newImplementation;
    }

    /**
     * @notice Returns the governance timelock address
     * @return The address of the governance timelock contract
     */
    function governanceTimelock()
        public
        view
        override(ISplitRiskPoolFactory, ProtocolAccessControlUpgradeable)
        returns (address)
    {
        return ProtocolAccessControlUpgradeable.governanceTimelock();
    }

    /**
     * @notice Sets the governance timelock address
     * @dev Only callable by governance. Updates the timelock address used
     *      for governance-controlled operations.
     * @param newGovernanceTimelock The new governance timelock address
     * @custom:error GovernanceZeroAddress If new address is zero
     */
    function setGovernanceTimelock(address newGovernanceTimelock)
        public
        override(ProtocolAccessControlUpgradeable, ISplitRiskPoolFactory)
        onlyGovernance
    {
        ProtocolAccessControlUpgradeable.setGovernanceTimelock(newGovernanceTimelock);
    }

    /// @notice Completes the two-step governance transfer
    /// @dev Only callable by the pending governance address
    function acceptGovernanceTimelock() public override(ProtocolAccessControlUpgradeable, ISplitRiskPoolFactory) {
        address previousGovernance = governanceTimelock();
        ProtocolAccessControlUpgradeable.acceptGovernanceTimelock();

        if (defaultProtocolFeeRecipient == previousGovernance) {
            address newGovernance = governanceTimelock();
            defaultProtocolFeeRecipient = newGovernance;
            emit EventsLib.ProtocolFeeRecipientUpdated(previousGovernance, newGovernance);
        }
    }

    /// @notice Starts the same pending governance transfer on a page of historical pools.
    /// @dev Call after `setGovernanceTimelock` and before the factory accepts the new timelock.
    function startPoolGovernanceTimelockTransfers(uint256 offset, uint256 limit) external override onlyGovernance {
        address pendingGovernance = pendingGovernanceTimelock();
        if (pendingGovernance == address(0)) revert NoPendingGovernance();
        uint256 end = _poolPageEnd(offset, limit);
        for (uint256 i = offset; i < end;) {
            SplitRiskPool(payable(pools[i])).setGovernanceTimelockFromFactory(pendingGovernance);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Accepts the factory's current governance timelock on pools that were pre-staged.
    /// @dev Call after `acceptGovernanceTimelock` on the factory. Pools outside the requested
    ///      page, or pools not staged for the current timelock, are left untouched.
    function acceptPoolGovernanceTimelockTransfers(uint256 offset, uint256 limit) external override onlyGovernance {
        address currentGovernance = governanceTimelock();
        uint256 end = _poolPageEnd(offset, limit);
        for (uint256 i = offset; i < end;) {
            SplitRiskPool pool = SplitRiskPool(payable(pools[i]));
            if (pool.pendingGovernanceTimelock() == currentGovernance) {
                pool.acceptGovernanceTimelockFromFactory(currentGovernance);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the pending governance timelock address
    function pendingGovernanceTimelock()
        public
        view
        override(ProtocolAccessControlUpgradeable, ISplitRiskPoolFactory)
        returns (address)
    {
        return ProtocolAccessControlUpgradeable.pendingGovernanceTimelock();
    }

    function _poolPageEnd(uint256 offset, uint256 limit) internal view returns (uint256 end) {
        uint256 totalPools = pools.length;
        if (offset >= totalPools || limit == 0) {
            return offset;
        }
        end = offset + limit;
        if (end > totalPools) {
            end = totalPools;
        }
    }

    /**
     * @notice Sets the composite oracle address for all new pools
     * @dev Only callable by governance. During bootstrap, the current owner may seed
     *      the oracle before any pools exist and before governance takes over.
     *      This oracle routes pricing to
     *      per-token oracle feeds. All pools use this composite oracle.
     * @param newOracle Address of the new composite oracle
     * @custom:error InvalidAssetAddress If newOracle is zero address
     */
    function setCompositeOracle(address newOracle) external {
        _requireGovernanceOrBootstrapOwner(compositeOracle == address(0) && _bootstrapOwnerActionsAllowed());
        if (newOracle == address(0)) revert ErrorsLib.InvalidAssetAddress();
        _requireOwnedByFactory(newOracle);

        uint256 tokenCount = whitelistedTokens.length;
        for (uint256 i = 0; i < tokenCount;) {
            address token = whitelistedTokens[i];
            TokenWhitelistLib.TokenInfo memory info = tokenInfo[token];

            if (info.token != address(0)) {
                _configureOracleFeedsForOracle(newOracle, token, info.primaryOracleFeed, info.backupOracleFeed);
                _syncCompositeOracleStrictRequirementForOracle(
                    newOracle, token, tokenRequiresStrictProtectedPrice[token]
                );
            }

            if (tokenRequiresStrictProtectedPrice[token]) {
                PoolOracleValidationLib.validateBackingTokenOracle(newOracle, token, true);
            }

            unchecked {
                ++i;
            }
        }

        address previousOracle = compositeOracle;
        compositeOracle = newOracle;
        emit EventsLib.PriceOracleUpdated(previousOracle, newOracle);
    }

    /**
     * @notice Sets the default protocol fee recipient address for all new pools
     * @dev Only callable by governance. During bootstrap, the current owner may seed
     *      the recipient before any pools exist and before governance takes over.
     *      This recipient will receive protocol
     *      fees from all pools created after this update. Existing pools are not affected.
     * @param newRecipient Address of the new default protocol fee recipient
     * @custom:error InvalidAssetAddress If newRecipient is zero address or this factory
     */
    function setDefaultProtocolFeeRecipient(address newRecipient) external {
        _requireGovernanceOrBootstrapOwner(defaultProtocolFeeRecipient == address(0) && _bootstrapOwnerActionsAllowed());
        if (newRecipient == address(0) || newRecipient == address(this)) revert ErrorsLib.InvalidAssetAddress();
        address previousRecipient = defaultProtocolFeeRecipient;
        defaultProtocolFeeRecipient = newRecipient;
        emit EventsLib.ProtocolFeeRecipientUpdated(previousRecipient, newRecipient);
    }

    /// @notice Sets the factory-owned Pyth oracle used for governance-managed price feed admin
    /// @dev During bootstrap, the owner may register it once before governance takes over.
    function setManagedPythOracle(address newOracle) external {
        _requireGovernanceOrBootstrapOwner(pythOracle == address(0) && _bootstrapOwnerActionsAllowed());
        if (newOracle == address(0)) revert ErrorsLib.InvalidAssetAddress();
        _requireOwnedByFactory(newOracle);
        address previousOracle = pythOracle;
        pythOracle = newOracle;
        emit ManagedOracleUpdated(PYTH_ORACLE_ROLE, previousOracle, newOracle);
    }

    /// @notice Sets the factory-owned ERC4626 oracle feed used for governance-managed vault admin
    /// @dev During bootstrap, the owner may register it once before governance takes over.
    function setManagedERC4626OracleFeed(address newOracle) external {
        _requireGovernanceOrBootstrapOwner(erc4626OracleFeed == address(0) && _bootstrapOwnerActionsAllowed());
        if (newOracle == address(0)) revert ErrorsLib.InvalidAssetAddress();
        _requireOwnedByFactory(newOracle);
        address previousOracle = erc4626OracleFeed;
        erc4626OracleFeed = newOracle;
        emit ManagedOracleUpdated(ERC4626_ORACLE_FEED_ROLE, previousOracle, newOracle);
    }

    /// @notice Transfers ownership of a factory-owned oracle to another admin if governance chooses to unwind custody
    function transferManagedOracleOwnership(address oracle, address newOwner) external onlyGovernance {
        if (newOwner == address(0)) revert ErrorsLib.InvalidAssetAddress();
        _requireOwnedByFactory(oracle);
        IOwnableOracleAdmin(oracle).transferOwnership(newOwner);
    }

    function setCompositeOracleAuthorizedCaller(address caller, bool authorized) external {
        _requireGovernanceOrBootstrapOwner(_bootstrapOwnerActionsAllowed());
        _requireManagedOracleConfigured(compositeOracle);
        if (caller == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (authorized && !_bootstrapOwnerActionsAllowed()) revert CompositeOracleAuthorizationClosed();
        _setCompositeOracleAuthorizedCaller(caller, authorized);
    }

    function setCompositeOracleDeviationThreshold(uint256 newThresholdBps) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).setDeviationThreshold(newThresholdBps);
    }

    function setCompositeOracleChallengeDuration(uint256 newDurationSec) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).setChallengeDuration(newDurationSec);
    }

    function setCompositeOracleTokenFeed(address token, address oracleFeed) external onlyGovernance {
        if (!isWhitelisted[token]) revert TokenWhitelistLib.TokenNotWhitelisted();
        _compositeOracleAdmin().setTokenOracleFeed(token, oracleFeed);
        _validateCompositeOracleTokenFeed(token);
        tokenInfo[token].primaryOracleFeed = oracleFeed;
        tokenInfo[token].backupOracleFeed = address(0);
    }

    function setCompositeOracleTokenFeedDual(address token, address primaryFeed, address backupFeed)
        external
        onlyGovernance
    {
        if (!isWhitelisted[token]) revert TokenWhitelistLib.TokenNotWhitelisted();
        _compositeOracleAdmin().setTokenOracleFeedDual(token, primaryFeed, backupFeed);
        _validateCompositeOracleTokenFeed(token);
        tokenInfo[token].primaryOracleFeed = primaryFeed;
        tokenInfo[token].backupOracleFeed = backupFeed;
    }

    function scheduleCompositeOracleTokenFeedRemoval(address token) external onlyGovernance {
        _compositeOracleAdmin().scheduleRemoveTokenOracleFeed(token);
    }

    function cancelScheduledCompositeOracleTokenFeedRemoval(address token) external onlyGovernance {
        _compositeOracleAdmin().cancelScheduledRemoveTokenOracleFeed(token);
    }

    function removeCompositeOracleTokenFeed(address token) external onlyGovernance {
        if (!isWhitelisted[token]) revert TokenWhitelistLib.TokenNotWhitelisted();
        _requireTokenUnusedByActivePools(token);
        _compositeOracleAdmin().removeTokenOracleFeed(token);
        TokenWhitelistLib.removeToken(whitelistedTokens, isWhitelisted, token);
        delete tokenInfo[token];
        delete tokenRequiresStrictProtectedPrice[token];
        emit EventsLib.TokenRemoved(token);
    }

    function scheduleCompositeOracleForceResetToPrimary(address token) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).scheduleForceResetToPrimary(token);
    }

    function executeCompositeOracleForceResetToPrimary(address token) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).forceResetToPrimary(token);
    }

    function scheduleCompositeOracleEmergencyCancelChallenge(address token) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).scheduleEmergencyCancelChallenge(token);
    }

    function executeCompositeOracleEmergencyCancelChallenge(address token) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).emergencyCancelChallenge(token);
    }

    function cancelCompositeOracleScheduledOverride(address token, bytes32 action) external onlyGovernance {
        _requireManagedOracleConfigured(compositeOracle);
        ICompositeOracleAdmin(compositeOracle).cancelScheduledOverride(token, action);
    }

    function setPythTokenPriceFeed(address token, bytes32 feedId) external onlyGovernance {
        _pythOracleAdmin().setTokenPriceFeed(token, feedId);
        _validateWhitelistedCompositeOracleTokenFeed(token);
    }

    function setPythTokenCompositePriceFeed(address token, bytes32 baseFeedId, bytes32 quoteUsdFeedId)
        external
        onlyGovernance
    {
        _pythOracleAdmin().setTokenCompositePriceFeed(token, baseFeedId, quoteUsdFeedId);
        _validateWhitelistedCompositeOracleTokenFeed(token);
    }

    function schedulePythTokenRemoval(address token) external onlyGovernance {
        _pythOracleAdmin().scheduleRemoveToken(token);
    }

    function cancelScheduledPythTokenRemoval(address token) external onlyGovernance {
        _pythOracleAdmin().cancelScheduledRemoveToken(token);
    }

    function removePythToken(address token) external onlyGovernance {
        _requireTokenUnusedByActivePools(token);
        _pythOracleAdmin().removeToken(token);
        _validateWhitelistedCompositeOracleTokenFeed(token);
    }

    function setPythMaxPriceAge(uint256 maxPriceAge) external onlyGovernance {
        _pythOracleAdmin().setMaxPriceAge(maxPriceAge);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setPythMaxPriceAgeForToken(address token, uint256 maxPriceAge) external onlyGovernance {
        _pythOracleAdmin().setMaxPriceAgeForToken(token, maxPriceAge);
        _validateWhitelistedCompositeOracleTokenFeed(token);
    }

    function setPythMaxPriceAgeForFeedId(bytes32 feedId, uint256 maxPriceAge) external onlyGovernance {
        _pythOracleAdmin().setMaxPriceAgeForFeedId(feedId, maxPriceAge);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setPythMaxCompositePublishTimeSkew(uint256 maxSkew) external onlyGovernance {
        _pythOracleAdmin().setMaxCompositePublishTimeSkew(maxSkew);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setPythMaxPriceDeviation(uint256 maxPriceDeviation) external onlyGovernance {
        _pythOracleAdmin().setMaxPriceDeviation(maxPriceDeviation);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setPythMaxConfidenceBps(uint256 maxConfidenceBps) external onlyGovernance {
        _pythOracleAdmin().setMaxConfidenceBps(maxConfidenceBps);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setPythMaxEmaConfidenceBps(uint256 maxEmaConfidenceBps) external onlyGovernance {
        _pythOracleAdmin().setMaxEmaConfidenceBps(maxEmaConfidenceBps);
        _validateCompositeOracleFeedsUsing(pythOracle);
    }

    function setERC4626UnderlyingPriceOracle(address underlyingPriceOracle) external onlyGovernance {
        _erc4626OracleFeedAdmin().setUnderlyingPriceOracle(underlyingPriceOracle);
        _validateCompositeOracleFeedsUsing(erc4626OracleFeed);
    }

    function registerERC4626Vault(address vault, address underlying) external onlyGovernance {
        _erc4626OracleFeedAdmin().registerVault(vault, underlying);
        _validateWhitelistedCompositeOracleTokenFeed(vault);
    }

    function refreshERC4626VaultSharePriceReference(address vault) external onlyGovernance {
        _erc4626OracleFeedAdmin().refreshVaultSharePriceReference(vault);
        _validateWhitelistedCompositeOracleTokenFeed(vault);
    }

    function setERC4626VaultSharePriceDeviation(address vault, uint256 maxDeviationBps) external onlyGovernance {
        _erc4626OracleFeedAdmin().setVaultSharePriceDeviation(vault, maxDeviationBps);
        _validateWhitelistedCompositeOracleTokenFeed(vault);
    }

    function scheduleERC4626VaultRemoval(address vault) external onlyGovernance {
        _erc4626OracleFeedAdmin().scheduleRemoveVault(vault);
    }

    function cancelScheduledERC4626VaultRemoval(address vault) external onlyGovernance {
        _erc4626OracleFeedAdmin().cancelScheduledRemoveVault(vault);
    }

    function removeERC4626Vault(address vault) external onlyGovernance {
        _requireTokenUnusedByActivePools(vault);
        _erc4626OracleFeedAdmin().removeVault(vault);
        _validateWhitelistedCompositeOracleTokenFeed(vault);
    }

    /**
     * @notice Permanently disables owner bootstrap actions before the first pool launch
     * @dev Governance can always finalize. The owner may only finalize while bootstrap mode
     *      is still active and before any pools exist.
     */
    function finalizeBootstrap() external {
        _requireGovernanceOrBootstrapOwner(_bootstrapOwnerActionsAllowed());
        _finalizeBootstrapMode();
    }

    function _finalizeBootstrapMode() internal {
        if (!bootstrapModeEnabled) return;
        _clearCompositeOracleAuthorizedCallers();
        bootstrapModeEnabled = false;
        emit BootstrapModeFinalized(msg.sender);
    }

    /**
     * @notice Creates a new SplitRiskPool instance with associated NFT contracts
     * @dev Deploys a new pool using UUPS proxy pattern, creates NFT contracts,
     *      and sets up all necessary relationships. Validates that ERC4626
     *      vaults don't share the same underlying asset. Enforces pool count limit.
     * @param _shieldedToken Address of the shielded yield-bearing token
     * @param _shieldedTokenSymbol Symbol for the shielded token
     * @param _backingToken Backing token address
     * @param _backingTokenSymbol Symbol for the backing token
     * @param _commissionRate Commission rate for the pool (in basis points)
     * @param _poolFee Pool creator fee rate (in basis points)
     * @param _colleteralRatio Collateral ratio for the pool (in basis points)
     * @return poolAddress Address of the newly created pool
     * @custom:error MaxPoolsExceeded If pool count limit is reached
     * @custom:error InvalidAssetAddress If oracle, fee recipient, or tokens are invalid
     * @custom:error TokenNotWhitelisted If tokens are not whitelisted
     * @custom:error SameUnderlyingAsset If both tokens are ERC4626 vaults with same underlying
     * @custom:error InvalidCommissionRate If commission rate is outside bounds
     * @custom:error InvalidPoolFee If pool fee is outside bounds
     * @custom:error InvalidCollateralRatio If collateral ratio is outside bounds
     */
    function createPool(
        address _shieldedToken,
        string memory _shieldedTokenSymbol,
        address _backingToken,
        string memory _backingTokenSymbol,
        uint256 _commissionRate,
        uint256 _poolFee,
        uint256 _colleteralRatio,
        uint256 _creationBondAmount
    ) external nonReentrant whenNotPaused returns (address poolAddress) {
        return _createPool(
            _shieldedToken,
            _shieldedTokenSymbol,
            _backingToken,
            _backingTokenSymbol,
            _commissionRate,
            _poolFee,
            _colleteralRatio,
            _creationBondAmount,
            address(0)
        );
    }

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
    ) external nonReentrant whenNotPaused returns (address poolAddress) {
        return _createPool(
            _shieldedToken,
            _shieldedTokenSymbol,
            _backingToken,
            _backingTokenSymbol,
            _commissionRate,
            _poolFee,
            _colleteralRatio,
            _creationBondAmount,
            initialAccessControl
        );
    }

    function _createPool(
        address _shieldedToken,
        string memory _shieldedTokenSymbol,
        address _backingToken,
        string memory _backingTokenSymbol,
        uint256 _commissionRate,
        uint256 _poolFee,
        uint256 _colleteralRatio,
        uint256 _creationBondAmount,
        address initialAccessControl
    ) internal returns (address poolAddress) {
        uint256 activePoolLimit = _activePoolLimit();
        if (activePools.length >= activePoolLimit) {
            revert ErrorsLib.MaxPoolsExceeded(activePools.length, activePoolLimit);
        }

        _finalizeBootstrapMode();

        // Validate that composite oracle and protocol fee recipient are set
        if (compositeOracle == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (defaultProtocolFeeRecipient == address(0)) revert ErrorsLib.InvalidAssetAddress();

        // Validate all parameters using library
        PoolValidationLib.validateBasicParams(_shieldedToken, _backingToken, _shieldedTokenSymbol, _backingTokenSymbol);
        PoolValidationLib.validateWhitelist(_shieldedToken, _backingToken, whitelistedTokens, isWhitelisted);
        PoolValidationLib.validatePoolParams(_commissionRate, _poolFee, _colleteralRatio);
        PoolValidationLib.validateERC4626Underlying(_shieldedToken, _backingToken);

        // Build TokenInfo structs from whitelisted tokens
        // Both tokens must be whitelisted (enforced by validateWhitelist above)
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = tokenInfo[_shieldedToken];
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = tokenInfo[_backingToken];

        // Validate that TokenInfo exists (tokens must be whitelisted)
        if (shieldedTokenInfo.token == address(0)) {
            revert ErrorsLib.TokenNotWhitelisted();
        }
        if (backingTokenInfo.token == address(0)) {
            revert ErrorsLib.TokenNotWhitelisted();
        }
        if (keccak256(bytes(_shieldedTokenSymbol)) != keccak256(bytes(shieldedTokenInfo.symbol))) {
            revert ErrorsLib.InvalidShieldedTokenSymbol();
        }
        if (keccak256(bytes(_backingTokenSymbol)) != keccak256(bytes(backingTokenInfo.symbol))) {
            revert ErrorsLib.InvalidBackingTokenSymbols();
        }

        _validateTokenDecimals(_shieldedToken);
        _validateTokenDecimals(_backingToken);
        bool requiresStrictProtectedPrice = tokenRequiresStrictProtectedPrice[_backingToken];
        PoolOracleValidationLib.validatePoolOracle(
            compositeOracle, _shieldedToken, _backingToken, requiresStrictProtectedPrice
        );

        // Validate that collateral ratio meets the minimum requirement for the backing token
        if (backingTokenInfo.minCollateralRatioBp > 0 && _colleteralRatio < backingTokenInfo.minCollateralRatioBp) {
            revert ErrorsLib.CollateralBelowTokenMinimum(_colleteralRatio, backingTokenInfo.minCollateralRatioBp);
        }

        uint256 receivedBond = _collectAndValidateCreationBond(_backingToken, _creationBondAmount);

        // Create and deploy pool using library
        if (splitRiskPoolImplementation == address(0)) revert ErrorsLib.InvalidAssetAddress();

        ISplitRiskPoolFactory.PoolInfo memory info;
        (poolAddress, info) = PoolCreationLib.createAndStorePool(
            splitRiskPoolImplementation,
            shieldedTokenInfo,
            backingTokenInfo,
            _commissionRate,
            _poolFee,
            _colleteralRatio,
            msg.sender,
            governanceTimelock(),
            compositeOracle,
            defaultProtocolFeeRecipient,
            initialAccessControl
        );

        // Store pool data
        pools.push(poolAddress);
        activePools.push(poolAddress);
        isPoolActive[poolAddress] = true;
        _activePoolIndexPlusOne[poolAddress] = activePools.length;
        _poolInfo[poolAddress] = info;

        // Emit pool created event (must be emitted from factory, not library)
        emit EventsLib.PoolCreated(
            poolAddress, _shieldedToken, _backingToken, _commissionRate, _poolFee, _colleteralRatio, msg.sender
        );

        if (receivedBond > 0) {
            creationBonds[poolAddress] =
                ISplitRiskPoolFactory.CreationBond({ creator: msg.sender, token: _backingToken, amount: receivedBond });
            emit EventsLib.CreationBondPosted(poolAddress, msg.sender, _backingToken, receivedBond);
        }

        return poolAddress;
    }

    /* View Functions */
    /**
     * @notice Returns the total number of historical pools created by this factory
     * @return count Number of pools recorded in the historical registry
     */
    function poolCount() external view returns (uint256 count) {
        return pools.length;
    }

    /**
     * @notice Gets a paginated slice of historical pool addresses
     * @param offset Zero-based starting index in the historical pool registry
     * @param limit Maximum number of pool addresses to return
     * @return poolSlice Historical pool address slice
     */
    function getPools(uint256 offset, uint256 limit) external view returns (address[] memory poolSlice) {
        uint256 totalPools = pools.length;
        if (offset >= totalPools || limit == 0) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > totalPools) {
            end = totalPools;
        }

        uint256 resultLength = end - offset;
        poolSlice = new address[](resultLength);
        for (uint256 i = 0; i < resultLength;) {
            poolSlice[i] = pools[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Gets all currently active pool addresses
     * @return Array of active pool addresses
     */
    function getActivePools() external view returns (address[] memory) {
        return activePools;
    }

    /**
     * @notice Returns the number of currently active pools
     * @return count Number of active pools
     */
    function activePoolCount() external view returns (uint256 count) {
        return activePools.length;
    }

    /**
     * @notice Gets a paginated slice of historical pool info
     * @param offset Zero-based starting index in the historical pool registry
     * @param limit Maximum number of pool infos to return
     * @return poolInfoSlice Historical pool info slice
     */
    function getPoolsInfo(uint256 offset, uint256 limit)
        external
        view
        returns (ISplitRiskPoolFactory.PoolInfo[] memory poolInfoSlice)
    {
        uint256 totalPools = pools.length;
        if (offset >= totalPools || limit == 0) {
            return new ISplitRiskPoolFactory.PoolInfo[](0);
        }

        uint256 end = offset + limit;
        if (end > totalPools) {
            end = totalPools;
        }

        uint256 resultLength = end - offset;
        poolInfoSlice = new ISplitRiskPoolFactory.PoolInfo[](resultLength);

        for (uint256 i = 0; i < resultLength;) {
            poolInfoSlice[i] = _poolInfo[pools[offset + i]];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Gets pool information for all active pools
     * @return activePoolsInfo Array of PoolInfo structs for active pools
     */
    function getActivePoolsInfo() external view returns (ISplitRiskPoolFactory.PoolInfo[] memory) {
        uint256 activePoolCount_ = activePools.length;
        ISplitRiskPoolFactory.PoolInfo[] memory activePoolsInfo = new ISplitRiskPoolFactory.PoolInfo[](activePoolCount_);

        for (uint256 i = 0; i < activePoolCount_;) {
            activePoolsInfo[i] = _poolInfo[activePools[i]];
            unchecked {
                ++i;
            }
        }

        return activePoolsInfo;
    }

    /**
     * @notice Gets pool information for a specific pool address
     * @dev Returns PoolInfo struct containing pool metadata. Reverts if pool doesn't exist.
     * @param _poolAddress Address of the pool
     * @return info PoolInfo struct containing pool metadata
     * @custom:error PoolDoesNotExist If pool address is not found
     */
    function getPoolInfo(address _poolAddress) external view returns (ISplitRiskPoolFactory.PoolInfo memory) {
        ISplitRiskPoolFactory.PoolInfo memory info = _poolInfo[_poolAddress];
        if (info.shieldedToken == address(0)) revert ErrorsLib.PoolDoesNotExist();
        return info;
    }

    /* Governance Functions */

    /**
     * @notice Removes a token from the whitelist
     * @dev Only callable by governance timelock. Removes token from whitelist,
     *      preventing it from being used in new pool creations.
     *      Also clears tokenInfo to prevent stale data.
     * @param token Address of the token to remove
     */
    function removeToken(address token) external onlyGovernance {
        _requireTokenUnusedByActivePools(token);
        _syncCompositeOracleStrictRequirement(token, false);
        TokenWhitelistLib.removeToken(whitelistedTokens, isWhitelisted, token);
        delete tokenInfo[token]; // Clear stale tokenInfo
        delete tokenRequiresStrictProtectedPrice[token];
        emit EventsLib.TokenRemoved(token);
    }

    /**
     * @notice Adds a token to the whitelist with its oracle feeds and minimum collateral requirement
     * @dev Only callable by governance timelock. Whitelisted tokens can be used
     *      in pool creation. Creates TokenInfo struct for the token and registers
     *      the oracle feed(s) in the CompositeOracle. If backupOracleFeed is provided,
     *      dual-feed mode is enabled with challenge mechanism support.
     *      Tokens must expose a valid ERC20 decimals() value supported by pool scaling math.
     * @param token Address of the token to add
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param primaryOracleFeed Address of the primary oracle feed for this token's price
     * @param backupOracleFeed Address of the backup oracle feed (address(0) for single-feed mode)
     * @param minCollateralRatioBp Minimum collateral ratio (basis points) when used as backing asset
     */
    function addToken(
        address token,
        string memory name,
        string memory symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    ) external onlyGovernance {
        _addToken(token, name, symbol, primaryOracleFeed, backupOracleFeed, minCollateralRatioBp);
    }

    /**
     * @notice Adds a token to the whitelist during initial deployment with its oracle feeds
     * @dev During bootstrap, the owner may whitelist tokens before governance fully takes over.
     *      After bootstrap is finalized, only governance can continue onboarding tokens.
     *      If backupOracleFeed is provided, dual-feed mode is enabled.
     *      Tokens must expose a valid ERC20 decimals() value supported by pool scaling math.
     * @param token Address of the token to add
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param primaryOracleFeed Address of the primary oracle feed for this token's price
     * @param backupOracleFeed Address of the backup oracle feed (address(0) for single-feed mode)
     * @param minCollateralRatioBp Minimum collateral ratio (basis points) when used as backing asset
     */
    function addTokenInitial(
        address token,
        string memory name,
        string memory symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    ) external {
        _requireGovernanceOrBootstrapOwner(_bootstrapOwnerActionsAllowed());
        _addToken(token, name, symbol, primaryOracleFeed, backupOracleFeed, minCollateralRatioBp);
    }

    /**
     * @notice Updates the minimum collateral ratio for a whitelisted token
     * @dev Only callable by governance timelock. This allows adjusting the minimum
     *      collateral requirement for existing tokens without removing and re-adding them.
     * @param token Address of the whitelisted token to update
     * @param newMinCollateralRatioBp New minimum collateral ratio in basis points
     * @custom:error TokenNotWhitelisted If the token is not whitelisted
     */
    function updateMinimumCollateral(address token, uint256 newMinCollateralRatioBp) external onlyGovernance {
        if (!isWhitelisted[token]) revert TokenWhitelistLib.TokenNotWhitelisted();
        _validateMinCollateralRatioBp(newMinCollateralRatioBp);

        uint256 oldMinCollateral = tokenInfo[token].minCollateralRatioBp;
        tokenInfo[token].minCollateralRatioBp = newMinCollateralRatioBp;

        emit EventsLib.MinimumCollateralUpdated(token, oldMinCollateral, newMinCollateralRatioBp);
    }

    /**
     * @notice Updates the minimum USD-denominated creation bond for new pools
     * @param newMinUsd New minimum creation bond value with 8 decimals
     */
    function setMinimumCreationBondUsd(uint256 newMinUsd) external onlyGovernance {
        uint256 previousValue = minimumCreationBondUsd;
        minimumCreationBondUsd = newMinUsd;
        emit EventsLib.MinimumCreationBondUsdUpdated(previousValue, newMinUsd);
    }

    /**
     * @notice Updates the active pool cap.
     * @dev Allows governance to raise capacity if active slots are economically occupied.
     *      The cap cannot be lowered below the number of pools currently active.
     * @param newMaxActivePools New active pool cap
     */
    function setMaxActivePools(uint256 newMaxActivePools) external onlyGovernance {
        uint256 activePoolLength = activePools.length;
        if (newMaxActivePools == 0 || newMaxActivePools < activePoolLength) {
            revert ErrorsLib.MaxPoolsExceeded(activePoolLength, newMaxActivePools);
        }

        uint256 previousValue = _activePoolLimit();
        maxActivePools = newMaxActivePools;
        emit EventsLib.MaxActivePoolsUpdated(previousValue, newMaxActivePools);
    }

    /**
     * @notice Deactivates an empty pool and frees its active slot
     * @dev Historical pool records remain intact in `pools`.
     * @param pool Address of the pool to deactivate
     */
    function deactivatePool(address pool) external onlyGovernance nonReentrant {
        if (_poolInfo[pool].shieldedToken == address(0)) revert ErrorsLib.PoolDoesNotExist();
        if (!isPoolActive[pool]) revert ErrorsLib.PoolAlreadyInactive();

        _pauseAndRequirePoolEmpty(pool);
        _removeActivePool(pool);
        _forfeitCreationBond(pool);
        emit EventsLib.PoolDeactivated(pool);
    }

    /// @notice Deactivates a dust-only pool and frees its active slot.
    /// @dev Governance-only escape hatch for pool-cap griefing. The pool itself enforces
    ///      that no shielded liabilities or reserved fees remain and that protector backing
    ///      is at or below its configured minimum deposit amount before sweeping it.
    function deactivateDustPool(address pool) external onlyGovernance nonReentrant {
        if (_poolInfo[pool].shieldedToken == address(0)) revert ErrorsLib.PoolDoesNotExist();
        if (!isPoolActive[pool]) revert ErrorsLib.PoolAlreadyInactive();

        ISplitRiskPool targetPool = ISplitRiskPool(pool);
        if (!targetPool.paused()) {
            SplitRiskPool(payable(pool)).pauseFromFactory();
        }
        targetPool.sweepInactiveProtectorBackingDustFromFactory();
        _pauseAndRequirePoolEmpty(pool);
        _removeActivePool(pool);
        _forfeitCreationBond(pool);
        emit EventsLib.PoolDeactivated(pool);
    }

    /// @notice Deactivates a protector-only pool without sweeping valid protector backing.
    /// @dev Frees the active slot after a grace delay when no shielded liabilities or fees
    ///      remain. The pool is left unpaused so protectors can unlock and withdraw normally;
    ///      the pool itself blocks new deposits once removed from the factory active registry.
    function deactivateProtectorOnlyPool(address pool) external onlyGovernance nonReentrant {
        ISplitRiskPoolFactory.PoolInfo memory info = _poolInfo[pool];
        if (info.shieldedToken == address(0)) revert ErrorsLib.PoolDoesNotExist();
        if (!isPoolActive[pool]) revert ErrorsLib.PoolAlreadyInactive();

        uint256 executableAt = info.createdAt + PROTECTOR_ONLY_POOL_DEACTIVATION_DELAY;
        if (block.timestamp < executableAt) {
            revert ErrorsLib.PoolDeactivationTooEarly(executableAt);
        }

        _requireProtectorOnlyPool(pool);
        _removeActivePool(pool);
        _forfeitCreationBond(pool);
        emit EventsLib.PoolDeactivated(pool);
    }

    /**
     * @notice Closes an empty pool and returns the active-slot stake to the creator
     * @param pool Address of the pool to close
     */
    function closePool(address pool) external nonReentrant {
        ISplitRiskPoolFactory.PoolInfo memory info = _poolInfo[pool];
        if (info.shieldedToken == address(0)) revert ErrorsLib.PoolDoesNotExist();
        if (!isPoolActive[pool]) revert ErrorsLib.PoolAlreadyInactive();
        if (msg.sender != info.creator) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "closePool");
        }

        _pauseAndRequirePoolEmpty(pool);
        _removeActivePool(pool);
        _returnCreationBond(pool, info.creator);
        emit EventsLib.PoolClosed(pool, info.creator);
    }

    /**
     * @notice Updates whether a token must use the strict protected-price path when used as backing collateral
     * @dev Only callable by governance. During bootstrap, the current owner may seed
     *      strict-price requirements before any pools exist and before bootstrap is finalized.
     *      If enabling strict mode and a default oracle is configured,
     *      the current oracle must already satisfy the strict pricing requirement for that token.
     * @param token Address of the whitelisted token to update
     * @param required Whether strict protected pricing is required for this backing asset
     */
    function setTokenRequiresStrictProtectedPrice(address token, bool required) external {
        _requireGovernanceOrBootstrapOwner(_bootstrapOwnerActionsAllowed());
        if (!isWhitelisted[token]) revert TokenWhitelistLib.TokenNotWhitelisted();

        bool previousRequirement = tokenRequiresStrictProtectedPrice[token];
        _syncCompositeOracleStrictRequirement(token, required);
        tokenRequiresStrictProtectedPrice[token] = required;

        emit EventsLib.TokenStrictProtectedPriceRequirementUpdated(token, previousRequirement, required);
    }

    /**
     * @notice Gets all whitelisted token addresses
     * @dev Returns the complete array of whitelisted token addresses.
     *      These tokens can be used in pool creation.
     * @return Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }

    function _validateTokenDecimals(address token) internal view {
        uint8 tokenDecimals = 0;
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert ErrorsLib.InvalidTokenAddress();
        }
        if (
            tokenDecimals < ConstantsLib.MIN_POOL_TOKEN_DECIMALS || tokenDecimals > ConstantsLib.MAX_POOL_TOKEN_DECIMALS
        ) {
            revert ErrorsLib.InvalidTokenDecimals(token, tokenDecimals);
        }
    }

    function _validateCompositeOracleTokenFeed(address token) internal view {
        PoolOracleValidationLib.validateBackingTokenOracle(
            compositeOracle, token, tokenRequiresStrictProtectedPrice[token]
        );
    }

    function _validateWhitelistedCompositeOracleTokenFeed(address token) internal view {
        if (!isWhitelisted[token]) {
            return;
        }
        _validateCompositeOracleTokenFeed(token);
    }

    function _validateCompositeOracleFeedsUsing(address oracleFeed) internal view {
        if (oracleFeed == address(0)) {
            return;
        }
        uint256 tokenCount = whitelistedTokens.length;
        for (uint256 i = 0; i < tokenCount;) {
            address token = whitelistedTokens[i];
            TokenWhitelistLib.TokenInfo memory info = tokenInfo[token];
            if (info.primaryOracleFeed == oracleFeed || info.backupOracleFeed == oracleFeed) {
                _validateCompositeOracleTokenFeed(token);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _requireTokenUnusedByActivePools(address token) internal view {
        uint256 activePoolLength = activePools.length;
        for (uint256 i = 0; i < activePoolLength;) {
            address pool = activePools[i];
            ISplitRiskPoolFactory.PoolInfo storage info = _poolInfo[pool];
            if (info.shieldedToken == token || info.backingToken == token) {
                revert ErrorsLib.TokenUsedByActivePool(token, pool);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _activePoolLimit() internal view returns (uint256) {
        uint256 configuredLimit = maxActivePools;
        return configuredLimit == 0 ? MAX_POOLS : configuredLimit;
    }

    /// @dev Bounds the per-token minimum collateral ratio. Zero is the sentinel for
    ///      "no per-token override" (consumers gate on `> 0` in PoolValidationLib).
    ///      Non-zero values must lie within the global pool-creation collateral bounds;
    ///      a value below the global minimum would be silently shadowed by it, and a
    ///      value above the global maximum would lock out all pool creation for the token.
    function _validateMinCollateralRatioBp(uint256 minCollateralRatioBp) internal pure {
        if (minCollateralRatioBp == 0) return;
        if (
            minCollateralRatioBp < ConstantsLib.MIN_COLLATERAL_RATIO
                || minCollateralRatioBp > ConstantsLib.MAX_COLLATERAL_RATIO
        ) revert ErrorsLib.InvalidCollateralRatio();
    }

    function _collectAndValidateCreationBond(address token, uint256 creationBondAmount)
        internal
        returns (uint256 receivedBond)
    {
        if (minimumCreationBondUsd > 0 && creationBondAmount == 0) {
            revert ErrorsLib.InitialCreationBondRequired();
        }

        if (creationBondAmount == 0) {
            return 0;
        }

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), creationBondAmount);
        receivedBond = IERC20(token).balanceOf(address(this)) - balanceBefore;

        // Skip the oracle valuation when no USD floor is enforced — querying the
        // composite oracle here would otherwise let an unrelated stale or
        // misconfigured backing-token feed DoS pool creation that doesn't actually
        // need a bond floor.
        if (minimumCreationBondUsd == 0) {
            return receivedBond;
        }

        uint256 receivedUsd = ICompositeOracle(compositeOracle).getValue(token, receivedBond);
        if (receivedUsd < minimumCreationBondUsd) {
            revert ErrorsLib.CreationBondBelowMinimum(receivedUsd, minimumCreationBondUsd);
        }
    }

    function _pauseAndRequirePoolEmpty(address pool) internal {
        ISplitRiskPool targetPool = ISplitRiskPool(pool);
        if (!targetPool.paused()) {
            SplitRiskPool(payable(pool)).pauseFromFactory();
        }

        (uint256 shieldedTokenPoolBalance, uint256 totalBackingTokenPoolBalance) = targetPool.getPoolBalances();
        if (
            targetPool.totalShieldedTokens() != 0 || targetPool.totalProtectorTokens() != 0
                || targetPool.getReservedFees() != 0 || shieldedTokenPoolBalance != 0
                || totalBackingTokenPoolBalance != 0
        ) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }
    }

    function _requireProtectorOnlyPool(address pool) internal view {
        SplitRiskPool targetPool = SplitRiskPool(payable(pool));
        (uint256 shieldedTokenPoolBalance, uint256 totalBackingTokenPoolBalance) = targetPool.getPoolBalances();
        if (
            targetPool.totalShieldedTokens() != 0 || targetPool.totalValueAtDeposit() != 0
                || targetPool.totalShieldCollateralAmount() != 0 || targetPool.getReservedFees() != 0
                || shieldedTokenPoolBalance != 0 || totalBackingTokenPoolBalance != targetPool.totalProtectorTokens()
        ) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }
    }

    function _returnCreationBond(address pool, address recipient) internal {
        ISplitRiskPoolFactory.CreationBond memory bond = creationBonds[pool];
        if (bond.creator == address(0) || bond.amount == 0) {
            return;
        }

        delete creationBonds[pool];
        uint256 payoutAmount = _availableBondPayout(pool, bond.token, bond.amount);
        if (payoutAmount != 0) {
            IERC20(bond.token).safeTransfer(recipient, payoutAmount);
        }
        emit EventsLib.CreationBondReturned(pool, recipient, bond.token, payoutAmount);
    }

    function _forfeitCreationBond(address pool) internal {
        ISplitRiskPoolFactory.CreationBond memory bond = creationBonds[pool];
        if (bond.creator == address(0) || bond.amount == 0) {
            return;
        }

        delete creationBonds[pool];
        uint256 payoutAmount = _availableBondPayout(pool, bond.token, bond.amount);
        if (payoutAmount != 0) {
            IERC20(bond.token).safeTransfer(defaultProtocolFeeRecipient, payoutAmount);
        }
        emit EventsLib.CreationBondForfeited(pool, defaultProtocolFeeRecipient, bond.token, payoutAmount);
    }

    function _availableBondPayout(address pool, address token, uint256 recordedAmount) internal returns (uint256) {
        uint256 availableBalance = IERC20(token).balanceOf(address(this));
        uint256 payoutAmount = recordedAmount < availableBalance ? recordedAmount : availableBalance;
        if (payoutAmount != recordedAmount) {
            emit EventsLib.CreationBondShortfall(pool, token, recordedAmount, payoutAmount);
        }
        return payoutAmount;
    }

    function _requireGovernanceOrBootstrapOwner(bool ownerBootstrapAllowed) internal view {
        if (msg.sender == _governanceTimelock) {
            return;
        }
        if (msg.sender == owner() && ownerBootstrapAllowed) {
            return;
        }
        revert UnauthorizedGovernance(msg.sender);
    }

    function _requireManagedOracleConfigured(address oracle) internal pure {
        if (oracle == address(0)) revert ErrorsLib.InvalidAssetAddress();
    }

    function _requireOwnedByFactory(address oracle) internal view {
        _requireManagedOracleConfigured(oracle);
        if (oracle.code.length == 0) revert ErrorsLib.InvalidAssetAddress();
        try IOwnableOracleAdmin(oracle).owner() returns (address oracleOwner) {
            if (oracleOwner != address(this)) revert UnauthorizedGovernance(oracleOwner);
        } catch {
            revert ErrorsLib.InvalidAssetAddress();
        }
    }

    function _compositeOracleAdmin() internal view returns (ICompositeOracleAdmin) {
        _requireManagedOracleConfigured(compositeOracle);
        return ICompositeOracleAdmin(compositeOracle);
    }

    function _setCompositeOracleAuthorizedCaller(address caller, bool authorized) internal {
        if (authorized && !_compositeOracleAuthorizedCallerSeen[caller]) {
            _compositeOracleAuthorizedCallerSeen[caller] = true;
            _trackedCompositeOracleAuthorizedCallers.push(caller);
        }

        if (_compositeOracleAuthorizedCallerSeen[caller]) {
            _compositeOracleAuthorizedCallerActive[caller] = authorized;
        }

        ICompositeOracleAdmin(compositeOracle).setAuthorizedCaller(caller, authorized);
    }

    function _clearCompositeOracleAuthorizedCallers() internal {
        if (compositeOracle == address(0)) {
            return;
        }

        ICompositeOracleAdmin oracleAdmin = ICompositeOracleAdmin(compositeOracle);
        bool clearedAll;
        try oracleAdmin.clearAuthorizedCallers() {
            clearedAll = true;
        } catch { }

        uint256 callerCount = _trackedCompositeOracleAuthorizedCallers.length;
        for (uint256 i = 0; i < callerCount;) {
            address caller = _trackedCompositeOracleAuthorizedCallers[i];
            if (_compositeOracleAuthorizedCallerActive[caller]) {
                _compositeOracleAuthorizedCallerActive[caller] = false;
                if (!clearedAll) {
                    oracleAdmin.setAuthorizedCaller(caller, false);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _pythOracleAdmin() internal view returns (IPythOracleAdmin) {
        _requireManagedOracleConfigured(pythOracle);
        return IPythOracleAdmin(pythOracle);
    }

    function _erc4626OracleFeedAdmin() internal view returns (IERC4626OracleFeedAdmin) {
        _requireManagedOracleConfigured(erc4626OracleFeed);
        return IERC4626OracleFeedAdmin(erc4626OracleFeed);
    }

    function _bootstrapOwnerActionsAllowed() internal view returns (bool) {
        return bootstrapModeEnabled && pools.length == 0;
    }

    function _removeActivePool(address pool) internal {
        uint256 indexPlusOne = _activePoolIndexPlusOne[pool];
        if (indexPlusOne == 0) revert ErrorsLib.PoolNotActive();

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = activePools.length - 1;

        if (index != lastIndex) {
            address lastPool = activePools[lastIndex];
            activePools[index] = lastPool;
            _activePoolIndexPlusOne[lastPool] = index + 1;
        }

        activePools.pop();
        delete _activePoolIndexPlusOne[pool];
        isPoolActive[pool] = false;
    }

    function _validatePoolImplementation(address implementation) internal view {
        if (implementation == address(0) || implementation.code.length == 0) revert ErrorsLib.InvalidAssetAddress();
        try IERC1822Proxiable(implementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != ERC1967Utils.IMPLEMENTATION_SLOT) revert ErrorsLib.InvalidAssetAddress();
        } catch {
            revert ErrorsLib.InvalidAssetAddress();
        }
    }

    function _addToken(
        address token,
        string memory name,
        string memory symbol,
        address primaryOracleFeed,
        address backupOracleFeed,
        uint256 minCollateralRatioBp
    ) internal {
        if (primaryOracleFeed == address(0)) revert ErrorsLib.InvalidAssetAddress();
        _validateMinCollateralRatioBp(minCollateralRatioBp);
        _validateTokenDecimals(token);
        TokenWhitelistLib.addToken(whitelistedTokens, isWhitelisted, token);

        tokenInfo[token] = TokenWhitelistLib.TokenInfo({
            name: name,
            symbol: symbol,
            token: token,
            primaryOracleFeed: primaryOracleFeed,
            backupOracleFeed: backupOracleFeed,
            minCollateralRatioBp: minCollateralRatioBp
        });

        _configureOracleFeeds(token, primaryOracleFeed, backupOracleFeed);

        emit EventsLib.TokenWhitelisted(token, symbol, primaryOracleFeed, backupOracleFeed, minCollateralRatioBp);
    }

    function _configureOracleFeeds(address token, address primaryOracleFeed, address backupOracleFeed) internal {
        if (compositeOracle == address(0)) {
            return;
        }

        _configureOracleFeedsForOracle(compositeOracle, token, primaryOracleFeed, backupOracleFeed);
    }

    function _configureOracleFeedsForOracle(
        address oracle,
        address token,
        address primaryOracleFeed,
        address backupOracleFeed
    ) internal {
        if (backupOracleFeed != address(0)) {
            ICompositeOracle(oracle).setTokenOracleFeedDual(token, primaryOracleFeed, backupOracleFeed);
        } else {
            ICompositeOracle(oracle).setTokenOracleFeed(token, primaryOracleFeed);
        }
    }

    function _syncCompositeOracleStrictRequirement(address token, bool required) internal {
        if (compositeOracle == address(0)) {
            return;
        }

        _syncCompositeOracleStrictRequirementForOracle(compositeOracle, token, required);
    }

    function _syncCompositeOracleStrictRequirementForOracle(address oracle, address token, bool required) internal {
        (bool success, bytes memory data) =
            oracle.call(abi.encodeCall(ICompositeOracle.setStrictCircuitBreakerRequired, (token, required)));

        if (success) {
            return;
        }

        if (data.length == 0) {
            if (required) {
                PoolOracleValidationLib.validateBackingTokenOracle(oracle, token, true);
            }
            return;
        }

        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    /* ETH Transfer Protection */

    /// @notice Reject direct ETH transfers
    receive() external payable {
        revert ErrorsLib.EtherTransferNotAllowed();
    }

    /// @notice Reject unknown function calls
    fallback() external {
        revert ErrorsLib.EtherTransferNotAllowed();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance { }

    /// @notice Governance-configurable active pool cap. Zero falls back to MAX_POOLS for legacy upgrades.
    uint256 public maxActivePools;

    /**
     * @dev Storage gap for future upgrades.
     * This ensures that future versions of this contract can add new storage variables
     * without colliding with storage variables in derived contracts.
     */
    uint256[38] private __gap;
}
