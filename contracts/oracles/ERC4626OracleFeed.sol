// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DecimalNormalizationLib } from "../libraries/DecimalNormalizationLib.sol";
import { ConstantsLib } from "../libraries/ConstantsLib.sol";
import { SequencerUptimeGuard } from "./SequencerUptimeGuard.sol";

/// @title ERC4626OracleFeed
/// @author David Hawig
/// @notice NAV-based pricing oracle for ERC4626 yield-bearing vaults
/// @dev Calculates share price using vault's convertToAssets() and underlying asset price oracle.
///      All price outputs are normalized to 8 decimals (USD format).
contract ERC4626OracleFeed is IOracleFeed, SequencerUptimeGuard {
    using DecimalNormalizationLib for uint256;

    struct VaultConfig {
        address underlying;
        uint256 shareUnit;
        uint256 underlyingUnit;
        uint256 minimumSupply;
        uint256 referenceAssetsPerShare;
        uint256 maxSharePriceDeviationBps;
    }

    struct ScheduledReferenceRefresh {
        uint256 executableAt;
        uint256 expiresAt;
        uint256 oldReferenceAssetsPerShare;
        uint256 scheduledReferenceAssetsPerShare;
        uint256 maxSharePriceDeviationBps;
    }

    /// @notice Underlying price oracle for USD conversion

    IOracleFeed public underlyingPriceOracle;

    /// @notice Mapping from vault address to underlying asset address
    mapping(address => address) public vaultToUnderlying;

    /// @notice Cached vault config keyed by vault address
    mapping(address => VaultConfig) private vaultConfigs;

    mapping(address => uint256) public scheduledVaultRemovalTime;

    mapping(address => ScheduledReferenceRefresh) public scheduledVaultSharePriceReferenceRefresh;

    /// @notice Minimum whole-share count required for price validity
    /// @dev The actual threshold is scaled per vault using its native share decimals.
    uint256 public constant MIN_VAULT_SHARE_COUNT = 1000;

    /// @notice Minimum USD value required across vault total assets for price validity
    uint256 public constant MIN_VAULT_VALUE_USD = 1_000e8;

    /// @notice Default maximum share-rate movement before pricing is rejected
    uint256 public constant DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS = 500;

    /// @notice Hard cap for per-vault share-rate deviation settings
    uint256 public constant MAX_SHARE_PRICE_DEVIATION_BPS = 2000;

    uint256 public constant VAULT_REMOVAL_DELAY = 1 days;
    uint256 public constant VAULT_REMOVAL_EXPIRY = 7 days;

    uint256 public constant SHARE_PRICE_REFERENCE_REFRESH_DELAY = 1 days;
    uint256 public constant SHARE_PRICE_REFERENCE_REFRESH_EXPIRY = 7 days;

    /// @notice Emitted when a vault is registered
    event VaultRegistered(address indexed vault, address indexed underlying);

    /// @notice Emitted when a vault is removed
    event VaultRemoved(address indexed vault);

    event VaultRemovalScheduled(address indexed vault, uint256 executableAt);
    event VaultRemovalCancelled(address indexed vault);

    /// @notice Emitted when the share-price reference is refreshed
    event VaultSharePriceReferenceUpdated(
        address indexed vault, uint256 oldReferenceAssetsPerShare, uint256 newReferenceAssetsPerShare
    );

    event VaultSharePriceReferenceRefreshScheduled(
        address indexed vault,
        uint256 oldReferenceAssetsPerShare,
        uint256 scheduledReferenceAssetsPerShare,
        uint256 executableAt,
        uint256 expiresAt
    );

    event VaultSharePriceReferenceRefreshCancelled(address indexed vault);

    /// @notice Emitted when the share-price deviation bound is updated
    event VaultSharePriceDeviationUpdated(address indexed vault, uint256 oldDeviationBps, uint256 newDeviationBps);

    /// @notice Emitted when underlying price oracle is updated
    event UnderlyingPriceOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Custom error for invalid vault address
    error InvalidVaultAddress(address vault);

    /// @notice Custom error for invalid underlying address
    error InvalidUnderlyingAddress(address underlying);

    /// @notice Custom error when a registered vault no longer reports its configured underlying asset
    error VaultUnderlyingAssetMismatch(address vault, address expectedUnderlying, address actualUnderlying);

    /// @notice Custom error when registration would overwrite an existing vault config
    error VaultAlreadyRegistered(address vault);

    /// @notice Custom error for invalid oracle address
    error InvalidOracleAddress(address oracle);

    /// @notice Custom error when the underlying oracle does not expose valid price decimals
    error InvalidUnderlyingPriceOracleDecimals(address oracle);

    /// @notice Custom error for unregistered vault
    error VaultNotRegistered(address vault);

    error VaultRemovalNotScheduled(address vault);
    error VaultRemovalTooEarly(address vault, uint256 executableAt);
    error VaultRemovalExpired(address vault, uint256 expiredAt);

    error VaultSharePriceReferenceRefreshNotScheduled(address vault);
    error VaultSharePriceReferenceRefreshTooEarly(address vault, uint256 executableAt);
    error VaultSharePriceReferenceRefreshExpired(address vault, uint256 expiredAt);

    /// @notice Custom error when token decimals cannot be queried
    error InvalidTokenDecimals(address token);

    /// @notice The underlying oracle does not honour the `getPriceUnsafe` contract.
    /// @dev Raised on the unsafe pricing path when the underlying staticcall returns
    ///      malformed data or the selector is absent. Failing closed prevents the
    ///      unsafe getter from silently upgrading to the protected `getPrice`, which
    ///      would defeat the safe/unsafe split.
    error UnsafeUnderlyingPriceUnavailable(address underlying);

    /// @notice Custom error for token decimal configurations that overflow oracle scaling math
    error UnsupportedTokenDecimals(address token, uint8 decimals);

    /// @notice Custom error for vault with insufficient liquidity (share inflation protection)
    /// @param vault The vault address
    /// @param totalSupply Current total supply of vault shares
    /// @param required Minimum required total supply
    error InsufficientVaultLiquidity(address vault, uint256 totalSupply, uint256 required);

    /// @notice Custom error for vaults whose total assets are too small in USD terms
    error InsufficientVaultValue(address vault, uint256 totalValueUsd, uint256 requiredValueUsd);

    /// @notice Custom error for invalid share-price deviation bounds
    error InvalidSharePriceDeviation(uint256 deviationBps);

    /// @notice Custom error when the vault share rate moves too far from the configured reference
    error SharePriceDeviationTooHigh(
        address vault, uint256 assetsPerShare, uint256 referenceAssetsPerShare, uint256 maxDeviationBps
    );

    /// @notice Custom error for stale underlying price
    /// @param vault The vault address
    /// @param underlying The underlying asset address
    error StaleUnderlyingPrice(address vault, address underlying);

    /// @notice Emitted when a stale price is detected
    /// @param vault The vault address
    /// @param underlying The underlying asset address
    /// @param isStale Whether the price is stale
    event StalePriceDetected(address indexed vault, address indexed underlying, bool isStale);

    /// @notice Constructor
    /// @param _underlyingPriceOracle Address of the oracle that provides USD prices for underlying assets
    constructor(address _underlyingPriceOracle) SequencerUptimeGuard() {
        if (_underlyingPriceOracle == address(0)) {
            revert InvalidOracleAddress(_underlyingPriceOracle);
        }
        _getPriceOracleDecimals(_underlyingPriceOracle);
        underlyingPriceOracle = IOracleFeed(_underlyingPriceOracle);
    }

    /// @notice Set the underlying price oracle
    /// @param _underlyingPriceOracle Address of the new underlying price oracle
    function setUnderlyingPriceOracle(address _underlyingPriceOracle) external onlyOwner {
        if (_underlyingPriceOracle == address(0)) {
            revert InvalidOracleAddress(_underlyingPriceOracle);
        }
        _getPriceOracleDecimals(_underlyingPriceOracle);
        address oldOracle = address(underlyingPriceOracle);
        underlyingPriceOracle = IOracleFeed(_underlyingPriceOracle);
        emit UnderlyingPriceOracleUpdated(oldOracle, _underlyingPriceOracle);
    }

    /// @notice Register a vault and its underlying asset
    /// @param vault Address of the ERC4626 vault
    /// @param underlying Address of the underlying asset token
    function registerVault(address vault, address underlying) external onlyOwner {
        if (vault == address(0)) revert InvalidVaultAddress(vault);
        if (underlying == address(0)) revert InvalidUnderlyingAddress(underlying);
        if (vaultToUnderlying[vault] != address(0)) revert VaultAlreadyRegistered(vault);

        // Verify vault is ERC4626-compliant by checking it has asset() function
        try IERC4626(vault).asset() returns (address vaultAsset) {
            if (vaultAsset != underlying) {
                revert InvalidUnderlyingAddress(underlying);
            }
        } catch {
            revert InvalidVaultAddress(vault);
        }

        uint8 shareDecimals = _getTokenDecimals(vault);
        uint8 underlyingDecimals = _getTokenDecimals(underlying);
        uint256 shareUnit = _getScaleFactor(vault, shareDecimals);
        uint256 underlyingUnit = _getScaleFactor(underlying, underlyingDecimals);
        uint256 minimumSupply = _getMinimumVaultSupply(vault, shareDecimals, shareUnit);
        _requireMinimumVaultSupply(vault, minimumSupply);
        uint256 referenceAssetsPerShare = _conservativeAssetsPerShare(vault, shareUnit);

        VaultConfig memory config = VaultConfig({
            underlying: underlying,
            shareUnit: shareUnit,
            underlyingUnit: underlyingUnit,
            minimumSupply: minimumSupply,
            referenceAssetsPerShare: referenceAssetsPerShare,
            maxSharePriceDeviationBps: DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS
        });
        _requireMinimumVaultValue(vault, config, true);

        vaultToUnderlying[vault] = underlying;
        vaultConfigs[vault] = config;
        _clearScheduledVaultRemoval(vault);
        _clearScheduledVaultSharePriceReferenceRefresh(vault);
        emit VaultRegistered(vault, underlying);
    }

    /// @notice Schedule a reviewed vault share-rate reference refresh.
    /// @param vault Address of the registered vault
    function scheduleVaultSharePriceReferenceRefresh(address vault) external onlyOwner {
        VaultConfig storage config = _getVaultConfigStorage(vault);
        _requireLiveUnderlying(vault, config.underlying);
        _requireMinimumVaultSupply(vault, config.minimumSupply);
        _requireMinimumVaultValue(vault, config, true);

        uint256 scheduledReference = _conservativeAssetsPerShare(vault, config.shareUnit);

        uint256 executableAt = block.timestamp + SHARE_PRICE_REFERENCE_REFRESH_DELAY;
        uint256 expiresAt = executableAt + SHARE_PRICE_REFERENCE_REFRESH_EXPIRY;
        scheduledVaultSharePriceReferenceRefresh[vault] = ScheduledReferenceRefresh({
            executableAt: executableAt,
            expiresAt: expiresAt,
            oldReferenceAssetsPerShare: config.referenceAssetsPerShare,
            scheduledReferenceAssetsPerShare: scheduledReference,
            maxSharePriceDeviationBps: config.maxSharePriceDeviationBps
        });

        emit VaultSharePriceReferenceRefreshScheduled(
            vault, config.referenceAssetsPerShare, scheduledReference, executableAt, expiresAt
        );
    }

    /// @notice Cancel a scheduled vault share-rate reference refresh.
    /// @param vault Address of the registered vault
    function cancelScheduledVaultSharePriceReferenceRefresh(address vault) external onlyOwner {
        if (scheduledVaultSharePriceReferenceRefresh[vault].executableAt == 0) {
            revert VaultSharePriceReferenceRefreshNotScheduled(vault);
        }
        _clearScheduledVaultSharePriceReferenceRefresh(vault);
    }

    /// @notice Execute a scheduled vault share-rate reference refresh.
    /// @param vault Address of the registered vault
    function refreshVaultSharePriceReference(address vault) external onlyOwner {
        VaultConfig storage config = _getVaultConfigStorage(vault);
        ScheduledReferenceRefresh memory scheduled = _consumeScheduledVaultSharePriceReferenceRefresh(vault);
        _requireLiveUnderlying(vault, config.underlying);
        _requireMinimumVaultSupply(vault, config.minimumSupply);
        _requireMinimumVaultValue(vault, config, true);

        uint256 currentAssetsPerShare = _conservativeAssetsPerShare(vault, config.shareUnit);
        _requireAssetsPerShareWithinReference(
            vault,
            currentAssetsPerShare,
            scheduled.scheduledReferenceAssetsPerShare,
            scheduled.maxSharePriceDeviationBps
        );

        uint256 oldReference = config.referenceAssetsPerShare;
        config.referenceAssetsPerShare = scheduled.scheduledReferenceAssetsPerShare;
        emit VaultSharePriceReferenceUpdated(vault, oldReference, scheduled.scheduledReferenceAssetsPerShare);
    }

    /// @notice Update the maximum allowed share-rate deviation for a registered vault
    /// @param vault Address of the registered vault
    /// @param maxDeviationBps Maximum deviation in basis points
    function setVaultSharePriceDeviation(address vault, uint256 maxDeviationBps) external onlyOwner {
        if (maxDeviationBps == 0 || maxDeviationBps > MAX_SHARE_PRICE_DEVIATION_BPS) {
            revert InvalidSharePriceDeviation(maxDeviationBps);
        }

        VaultConfig storage config = _getVaultConfigStorage(vault);
        uint256 oldDeviation = config.maxSharePriceDeviationBps;
        config.maxSharePriceDeviationBps = maxDeviationBps;
        emit VaultSharePriceDeviationUpdated(vault, oldDeviation, maxDeviationBps);
    }

    /// @notice Remove a vault from the feed
    /// @param vault Address of the vault to remove
    function scheduleRemoveVault(address vault) external onlyOwner {
        _getVaultConfigStorage(vault);
        uint256 executableAt = block.timestamp + VAULT_REMOVAL_DELAY;
        scheduledVaultRemovalTime[vault] = executableAt;
        emit VaultRemovalScheduled(vault, executableAt);
    }

    function cancelScheduledRemoveVault(address vault) external onlyOwner {
        if (scheduledVaultRemovalTime[vault] == 0) revert VaultRemovalNotScheduled(vault);
        delete scheduledVaultRemovalTime[vault];
        emit VaultRemovalCancelled(vault);
    }

    function _clearScheduledVaultRemoval(address vault) internal {
        if (scheduledVaultRemovalTime[vault] != 0) {
            delete scheduledVaultRemovalTime[vault];
            emit VaultRemovalCancelled(vault);
        }
    }

    function removeVault(address vault) external onlyOwner {
        _consumeScheduledVaultRemoval(vault);
        delete vaultToUnderlying[vault];
        delete vaultConfigs[vault];
        _clearScheduledVaultSharePriceReferenceRefresh(vault);
        emit VaultRemoved(vault);
    }

    function _consumeScheduledVaultRemoval(address vault) internal {
        uint256 executableAt = scheduledVaultRemovalTime[vault];
        if (executableAt == 0) revert VaultRemovalNotScheduled(vault);
        if (block.timestamp < executableAt) revert VaultRemovalTooEarly(vault, executableAt);
        uint256 expiresAt = executableAt + VAULT_REMOVAL_EXPIRY;
        if (block.timestamp >= expiresAt) {
            delete scheduledVaultRemovalTime[vault];
            revert VaultRemovalExpired(vault, expiresAt);
        }
        delete scheduledVaultRemovalTime[vault];
    }

    function _clearScheduledVaultSharePriceReferenceRefresh(address vault) internal {
        if (scheduledVaultSharePriceReferenceRefresh[vault].executableAt != 0) {
            delete scheduledVaultSharePriceReferenceRefresh[vault];
            emit VaultSharePriceReferenceRefreshCancelled(vault);
        }
    }

    function _consumeScheduledVaultSharePriceReferenceRefresh(address vault)
        internal
        returns (ScheduledReferenceRefresh memory scheduled)
    {
        scheduled = scheduledVaultSharePriceReferenceRefresh[vault];
        if (scheduled.executableAt == 0) {
            revert VaultSharePriceReferenceRefreshNotScheduled(vault);
        }
        if (block.timestamp < scheduled.executableAt) {
            revert VaultSharePriceReferenceRefreshTooEarly(vault, scheduled.executableAt);
        }
        if (block.timestamp >= scheduled.expiresAt) {
            revert VaultSharePriceReferenceRefreshExpired(vault, scheduled.expiresAt);
        }

        delete scheduledVaultSharePriceReferenceRefresh[vault];
    }

    /// @notice Returns the minimum total supply required for a registered vault
    /// @param vault Address of the ERC4626 vault
    function minimumVaultSupply(address vault) external view returns (uint256) {
        return _getVaultConfig(vault).minimumSupply;
    }

    /// @inheritdoc IOracleFeed
    /// @notice Returns the protected (circuit-breaker validated) price of vault shares in USD (8 decimals)
    /// @dev Applies share-rate cap, share inflation attack protection (minimum supply check),
    ///      underlying price staleness, and upward share-rate lagging against the reviewed
    ///      reference. Production callers must use this entry point; live in-band share-rate
    ///      moves remain visible through `getPriceUnsafe`.
    function getPrice(address vault) external view override returns (uint256) {
        return _getValidatedPrice(vault, true, true);
    }

    /// @notice Unprotected price getter that skips underlying circuit-breaker gates
    /// @dev Reserved for read-only callers (off-chain analytics, view helpers). Share-rate
    ///      bounds still fail closed; only the underlying oracle path uses `getPriceUnsafe`.
    /// @param vault The vault address
    /// @return price The price in USD with 8 decimals
    function getPriceUnsafe(address vault) external view returns (uint256) {
        return _getValidatedPrice(vault, false, false);
    }

    /// @notice Fee-accrual price with protected underlying data and live in-band share rate
    /// @dev Keeps all share-rate deviation, minimum-liquidity, and underlying staleness
    ///      checks, but does not clamp organic upward NAV growth to the reviewed
    ///      reference. This is only for fee accounting; payout/collateral paths
    ///      must continue using `getPrice`.
    function getPriceForFeeAccrual(address vault) external view returns (uint256) {
        return _getValidatedPrice(vault, true, false);
    }

    /// @notice Whether this feed exposes protected `getPrice` and explicit unsafe pricing for `vault`.
    function supportsCircuitBreaker(address vault) external view returns (bool) {
        return vaultConfigs[vault].underlying != address(0);
    }

    /// @notice Whether this vault feed satisfies the strict protected-price policy.
    /// @dev ERC4626 strict support is only advertised when the registered underlying oracle
    ///      also advertises strict support for the vault's underlying asset.
    function supportsStrictProtectedPrice(address vault) external view returns (bool) {
        address underlying = vaultConfigs[vault].underlying;
        if (underlying == address(0)) {
            return false;
        }

        (bool success, bytes memory data) = address(underlyingPriceOracle)
            .staticcall(abi.encodeWithSignature("supportsStrictProtectedPrice(address)", underlying));
        if (!success || data.length < 32) {
            return false;
        }
        return abi.decode(data, (bool));
    }

    function _getValidatedPrice(address vault, bool useProtectedUnderlying, bool clampUpwardToReference)
        internal
        view
        returns (uint256)
    {
        // SEC-01: reject prices read while the L2 sequencer is down or within its
        // post-restart grace period. Covers getPrice / getPriceUnsafe /
        // getPriceForFeeAccrual. getPriceWithStaleness guards itself separately.
        _checkSequencerUptime();
        VaultConfig memory config = _getVaultConfig(vault);
        _requireLiveUnderlying(vault, config.underlying);

        if (useProtectedUnderlying) {
            (bool isStale,) = _checkUnderlyingStaleness(config.underlying);
            if (isStale) {
                revert StaleUnderlyingPrice(vault, config.underlying);
            }
        }

        return _getPriceFromConfig(vault, config, useProtectedUnderlying, clampUpwardToReference);
    }

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return ConstantsLib.USD_DECIMALS;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "ERC4626 NAV Oracle Feed";
    }

    /// @notice Check if the underlying price is stale for a vault
    /// @dev Must remain staticcall-safe because CompositeOracle probes this helper via `staticcall`.
    /// @param vault The vault address
    /// @return isStale True if the underlying price is stale
    /// @return publishTime The timestamp of the underlying price (0 if not available)
    function isPriceStale(address vault) external view returns (bool isStale, uint64 publishTime) {
        if (_isSequencerUnavailableForStaleness()) {
            return (true, 0);
        }

        VaultConfig memory config = _getVaultConfig(vault);
        _requireLiveUnderlying(vault, config.underlying);

        // Try to check underlying oracle staleness
        (isStale, publishTime) = _checkUnderlyingStaleness(config.underlying);
    }

    /// @notice Get price with staleness information
    /// @param vault The vault address
    /// @return price The price in USD with 8 decimals
    /// @return isStale True if the underlying price is stale
    function getPriceWithStaleness(address vault) external view returns (uint256 price, bool isStale) {
        // SEC-01 (Codex P2): this helper returns a USD price too, so it must fail
        // closed on the same L2 sequencer gate as _getValidatedPrice — otherwise
        // an integrator using it could receive a price during a sequencer outage.
        _checkSequencerUptime();
        VaultConfig memory config = _getVaultConfig(vault);
        _requireLiveUnderlying(vault, config.underlying);

        // Check staleness
        (isStale,) = _checkUnderlyingStaleness(config.underlying);

        // If stale, still calculate price but return stale flag
        // This allows callers to make informed decisions
        // Note: getPrice() will revert on stale, but this function provides flexibility
        price = _getPriceFromConfig(vault, config, false, false);
    }

    // ============ Internal Helper Functions ============

    function _getVaultConfig(address vault) internal view returns (VaultConfig memory config) {
        config = vaultConfigs[vault];
        if (config.underlying == address(0)) {
            revert VaultNotRegistered(vault);
        }
    }

    function _getVaultConfigStorage(address vault) internal view returns (VaultConfig storage config) {
        config = vaultConfigs[vault];
        if (config.underlying == address(0)) {
            revert VaultNotRegistered(vault);
        }
    }

    function _getPriceFromConfig(
        address vault,
        VaultConfig memory config,
        bool useProtectedUnderlying,
        bool clampUpwardToReference
    ) internal view returns (uint256) {
        uint256 totalSupply = IERC4626(vault).totalSupply();
        _requireMinimumVaultSupply(vault, config.minimumSupply, totalSupply);

        uint256 assetsPerShare = _conservativeAssetsPerShare(vault, config.shareUnit);
        assetsPerShare = _boundedAssetsPerShare(vault, assetsPerShare, config, clampUpwardToReference);
        _requireMinimumVaultValue(vault, config, useProtectedUnderlying);
        // Codex P2 follow-up: preserve the safe/unsafe contract end-to-end —
        // the vault's unsafe getter forwards useCircuitBreaker=false so the
        // underlying read must take the unsafe path too. `_getUnderlyingPrice`
        // (introduced on main alongside this PR) picks the right delegate and
        // propagates revert reasons faithfully.
        uint256 underlyingPrice = _getUnderlyingPrice(config.underlying, useProtectedUnderlying);
        uint8 priceDecimals = _getUnderlyingPriceDecimals();

        uint256 sharePrice = Math.mulDiv(assetsPerShare, underlyingPrice, config.underlyingUnit);
        return sharePrice.normalize(priceDecimals, ConstantsLib.USD_DECIMALS);
    }

    function _requireLiveUnderlying(address vault, address expectedUnderlying) internal view {
        try IERC4626(vault).asset() returns (address actualUnderlying) {
            if (actualUnderlying != expectedUnderlying) {
                revert VaultUnderlyingAssetMismatch(vault, expectedUnderlying, actualUnderlying);
            }
        } catch (bytes memory reason) {
            if (reason.length == 0) revert InvalidVaultAddress(vault);
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _conservativeAssetsPerShare(address vault, uint256 shareUnit) internal view returns (uint256) {
        uint256 convertAssets = IERC4626(vault).convertToAssets(shareUnit);
        uint256 redeemAssets = IERC4626(vault).previewRedeem(shareUnit);
        return redeemAssets < convertAssets ? redeemAssets : convertAssets;
    }

    function _requireAssetsPerShareWithinReference(
        address vault,
        uint256 assetsPerShare,
        uint256 referenceAssetsPerShare,
        uint256 maxDeviationBps
    ) internal pure {
        if (referenceAssetsPerShare == 0) {
            revert SharePriceDeviationTooHigh(vault, assetsPerShare, referenceAssetsPerShare, maxDeviationBps);
        }

        uint256 deviationAmount = Math.mulDiv(referenceAssetsPerShare, maxDeviationBps, ConstantsLib.BASIS_POINT_SCALE);
        uint256 minAssetsPerShare =
            referenceAssetsPerShare > deviationAmount ? referenceAssetsPerShare - deviationAmount : 0;
        uint256 maxAssetsPerShare = referenceAssetsPerShare + deviationAmount;

        if (assetsPerShare < minAssetsPerShare || assetsPerShare > maxAssetsPerShare) {
            revert SharePriceDeviationTooHigh(vault, assetsPerShare, referenceAssetsPerShare, maxDeviationBps);
        }
    }

    function _getUnderlyingPrice(address underlying, bool useCircuitBreaker) internal view returns (uint256) {
        if (useCircuitBreaker) {
            return underlyingPriceOracle.getPrice(underlying);
        }

        (bool success, bytes memory data) =
            address(underlyingPriceOracle).staticcall(abi.encodeWithSignature("getPriceUnsafe(address)", underlying));

        if (success) {
            if (data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            // Malformed success return: the underlying oracle does not honour the
            // unsafe selector contract. Fail closed instead of silently upgrading
            // to the protected getter — that would defeat the safe/unsafe split.
            revert UnsafeUnderlyingPriceUnavailable(underlying);
        }

        if (data.length == 0) {
            // Selector absent: same reasoning — opting into the unsafe path must
            // not transparently fall through to the protected getter.
            revert UnsafeUnderlyingPriceUnavailable(underlying);
        }

        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    function _getUnderlyingPriceDecimals() internal view returns (uint8) {
        return _getPriceOracleDecimals(address(underlyingPriceOracle));
    }

    function _getPriceOracleDecimals(address priceOracle) internal view returns (uint8 priceDecimals) {
        (bool success, bytes memory data) = priceOracle.staticcall(abi.encodeWithSignature("decimals()"));

        if (!success || data.length < 32) {
            revert InvalidUnderlyingPriceOracleDecimals(priceOracle);
        }

        uint256 decodedDecimals = abi.decode(data, (uint256));
        if (decodedDecimals > type(uint8).max) {
            revert InvalidUnderlyingPriceOracleDecimals(priceOracle);
        }
        priceDecimals = uint8(decodedDecimals);
    }

    function _boundedAssetsPerShare(
        address vault,
        uint256 assetsPerShare,
        VaultConfig memory config,
        bool clampUpwardToReference
    ) internal pure returns (uint256) {
        _requireAssetsPerShareWithinReference(
            vault, assetsPerShare, config.referenceAssetsPerShare, config.maxSharePriceDeviationBps
        );
        if (clampUpwardToReference && assetsPerShare > config.referenceAssetsPerShare) {
            return config.referenceAssetsPerShare;
        }
        return assetsPerShare;
    }

    function _getTokenDecimals(address token) internal view returns (uint8 tokenDecimals) {
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert InvalidTokenDecimals(token);
        }
    }

    function _getScaleFactor(address token, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals > 77) {
            revert UnsupportedTokenDecimals(token, tokenDecimals);
        }
        return 10 ** tokenDecimals;
    }

    function _getMinimumVaultSupply(address vault, uint8 shareDecimals, uint256 shareUnit)
        internal
        pure
        returns (uint256)
    {
        if (shareUnit > type(uint256).max / MIN_VAULT_SHARE_COUNT) {
            revert UnsupportedTokenDecimals(vault, shareDecimals);
        }
        return shareUnit * MIN_VAULT_SHARE_COUNT;
    }

    function _requireMinimumVaultSupply(address vault, uint256 minimumSupply) internal view {
        _requireMinimumVaultSupply(vault, minimumSupply, IERC4626(vault).totalSupply());
    }

    function _requireMinimumVaultSupply(address vault, uint256 minimumSupply, uint256 totalSupply) internal pure {
        if (totalSupply < minimumSupply) {
            revert InsufficientVaultLiquidity(vault, totalSupply, minimumSupply);
        }
    }

    function _requireMinimumVaultValue(address vault, VaultConfig memory config, bool useCircuitBreaker) internal view {
        uint256 totalValueUsd = _vaultTotalValueUsd(vault, config, useCircuitBreaker);
        if (totalValueUsd < MIN_VAULT_VALUE_USD) {
            revert InsufficientVaultValue(vault, totalValueUsd, MIN_VAULT_VALUE_USD);
        }
    }

    function _vaultTotalValueUsd(address vault, VaultConfig memory config, bool useCircuitBreaker)
        internal
        view
        returns (uint256)
    {
        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 underlyingPrice = _getUnderlyingPrice(config.underlying, useCircuitBreaker);
        uint8 priceDecimals = _getUnderlyingPriceDecimals();
        uint256 value = Math.mulDiv(totalAssets, underlyingPrice, config.underlyingUnit);
        return value.normalize(priceDecimals, ConstantsLib.USD_DECIMALS);
    }

    /// @notice Check if underlying oracle price is stale
    /// @dev Uses low-level calls to detect and call staleness functions on underlying oracle
    ///      All in-protocol oracles implement isPriceStale(address) -> (bool, uint64).
    ///      Future timestamps beyond the small sequencer-skew tolerance are rejected;
    ///      previously the function accepted publishTimes up to 24h in the future.
    ///      Any oracle that does not expose the helper, or that returns malformed
    ///      data, is treated as stale (fail closed).
    /// @param underlying The underlying asset address
    /// @return isStale True if the price is stale
    /// @return publishTime The timestamp of the price (0 if not available)
    function _checkUnderlyingStaleness(address underlying) internal view returns (bool isStale, uint64 publishTime) {
        address oracleAddress = address(underlyingPriceOracle);

        // Function selector: isPriceStale(address) -> (bool, uint64)
        (bool success, bytes memory data) =
            oracleAddress.staticcall(abi.encodeWithSignature("isPriceStale(address)", underlying));

        // Expected ABI: (bool, uint64) padded to 64 bytes.
        if (success && data.length >= 64) {
            (bool decoded, uint64 time64) = abi.decode(data, (bool, uint64));
            // Reject implausibly future-dated publish times to prevent a malicious
            // or skewed underlying oracle from defeating the staleness check.
            // SEQUENCER_SKEW_TOLERANCE allows a small clock drift only.
            if (time64 == 0 || time64 > uint64(block.timestamp) + SEQUENCER_SKEW_TOLERANCE) {
                return (true, 0);
            }
            return (decoded, time64);
        }

        // Underlying oracle doesn't support staleness checking or call failed
        // Fail-closed: treat as stale to prevent using potentially outdated prices.
        return (true, 0);
    }

    /// @dev Maximum tolerated future-skew (seconds) on an underlying oracle's
    ///      publishTime. Anything beyond this is treated as a stale/invalid value.
    uint64 internal constant SEQUENCER_SKEW_TOLERANCE = 30;
}
