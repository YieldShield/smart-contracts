// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DecimalNormalizationLib } from "../libraries/DecimalNormalizationLib.sol";
import { ConstantsLib } from "../libraries/ConstantsLib.sol";

/// @title ERC4626OracleFeed
/// @author David Hawig
/// @notice NAV-based pricing oracle for ERC4626 yield-bearing vaults
/// @dev Calculates share price using vault's convertToAssets() and underlying asset price oracle.
///      All price outputs are normalized to 8 decimals (USD format).
contract ERC4626OracleFeed is IOracleFeed, Ownable {
    using DecimalNormalizationLib for uint256;

    struct VaultConfig {
        address underlying;
        uint256 shareUnit;
        uint256 underlyingUnit;
        uint256 minimumSupply;
        uint256 referenceAssetsPerShare;
        uint256 maxSharePriceDeviationBps;
    }

    /// @notice Underlying price oracle for USD conversion

    IOracleFeed public underlyingPriceOracle;

    /// @notice Mapping from vault address to underlying asset address
    mapping(address => address) public vaultToUnderlying;

    /// @notice Cached vault config keyed by vault address
    mapping(address => VaultConfig) private vaultConfigs;

    /// @notice Minimum whole-share count required for price validity
    /// @dev The actual threshold is scaled per vault using its native share decimals.
    uint256 public constant MIN_VAULT_SHARE_COUNT = 1000;

    /// @notice Default maximum share-rate movement before pricing is rejected
    uint256 public constant DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS = 500;

    /// @notice Hard cap for per-vault share-rate deviation settings
    uint256 public constant MAX_SHARE_PRICE_DEVIATION_BPS = 2000;

    /// @notice Emitted when a vault is registered
    event VaultRegistered(address indexed vault, address indexed underlying);

    /// @notice Emitted when a vault is removed
    event VaultRemoved(address indexed vault);

    /// @notice Emitted when the share-price reference is refreshed
    event VaultSharePriceReferenceUpdated(
        address indexed vault, uint256 oldReferenceAssetsPerShare, uint256 newReferenceAssetsPerShare
    );

    /// @notice Emitted when the share-price deviation bound is updated
    event VaultSharePriceDeviationUpdated(address indexed vault, uint256 oldDeviationBps, uint256 newDeviationBps);

    /// @notice Emitted when underlying price oracle is updated
    event UnderlyingPriceOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Custom error for invalid vault address
    error InvalidVaultAddress(address vault);

    /// @notice Custom error for invalid underlying address
    error InvalidUnderlyingAddress(address underlying);

    /// @notice Custom error for invalid oracle address
    error InvalidOracleAddress(address oracle);

    /// @notice Custom error for unregistered vault
    error VaultNotRegistered(address vault);

    /// @notice Custom error when token decimals cannot be queried
    error InvalidTokenDecimals(address token);

    /// @notice Custom error for token decimal configurations that overflow oracle scaling math
    error UnsupportedTokenDecimals(address token, uint8 decimals);

    /// @notice Custom error for vault with insufficient liquidity (share inflation protection)
    /// @param vault The vault address
    /// @param totalSupply Current total supply of vault shares
    /// @param required Minimum required total supply
    error InsufficientVaultLiquidity(address vault, uint256 totalSupply, uint256 required);

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
    constructor(address _underlyingPriceOracle) Ownable(msg.sender) {
        if (_underlyingPriceOracle == address(0)) {
            revert InvalidOracleAddress(_underlyingPriceOracle);
        }
        underlyingPriceOracle = IOracleFeed(_underlyingPriceOracle);
    }

    /// @notice Set the underlying price oracle
    /// @param _underlyingPriceOracle Address of the new underlying price oracle
    function setUnderlyingPriceOracle(address _underlyingPriceOracle) external onlyOwner {
        if (_underlyingPriceOracle == address(0)) {
            revert InvalidOracleAddress(_underlyingPriceOracle);
        }
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
        uint256 referenceAssetsPerShare = IERC4626(vault).convertToAssets(shareUnit);

        vaultToUnderlying[vault] = underlying;
        vaultConfigs[vault] = VaultConfig({
            underlying: underlying,
            shareUnit: shareUnit,
            underlyingUnit: _getScaleFactor(underlying, underlyingDecimals),
            minimumSupply: _getMinimumVaultSupply(vault, shareDecimals, shareUnit),
            referenceAssetsPerShare: referenceAssetsPerShare,
            maxSharePriceDeviationBps: DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS
        });
        emit VaultRegistered(vault, underlying);
    }

    /// @notice Refresh the vault share-rate reference to the current ERC4626 conversion rate
    /// @param vault Address of the registered vault
    function refreshVaultSharePriceReference(address vault) external onlyOwner {
        VaultConfig storage config = _getVaultConfigStorage(vault);
        uint256 newReference = IERC4626(vault).convertToAssets(config.shareUnit);
        uint256 oldReference = config.referenceAssetsPerShare;
        config.referenceAssetsPerShare = newReference;
        emit VaultSharePriceReferenceUpdated(vault, oldReference, newReference);
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
    function removeVault(address vault) external onlyOwner {
        delete vaultToUnderlying[vault];
        delete vaultConfigs[vault];
        emit VaultRemoved(vault);
    }

    /// @notice Returns the minimum total supply required for a registered vault
    /// @param vault Address of the ERC4626 vault
    function minimumVaultSupply(address vault) external view returns (uint256) {
        return _getVaultConfig(vault).minimumSupply;
    }

    /// @inheritdoc IOracleFeed
    /// @notice Returns the protected (circuit-breaker validated) price of vault shares in USD (8 decimals)
    /// @dev Applies share-rate cap, share inflation attack protection (minimum supply check),
    ///      and underlying price staleness check. Production callers must use this entry point;
    ///      the unprotected share-rate path is available via `getPriceUnsafe`.
    function getPrice(address vault) external view override returns (uint256) {
        return _getValidatedPrice(vault, true);
    }

    /// @notice Unprotected price getter that skips the upper-bound share-rate deviation cap
    /// @dev Reserved for read-only callers (off-chain analytics, view helpers). Still applies
    ///      the lower-bound share-rate floor and underlying staleness check; only the
    ///      upper-bound deviation handling differs from `getPrice`.
    /// @param vault The vault address
    /// @return price The price in USD with 8 decimals
    function getPriceUnsafe(address vault) external view returns (uint256) {
        return _getValidatedPrice(vault, false);
    }

    function _getValidatedPrice(address vault, bool useCircuitBreaker) internal view returns (uint256) {
        VaultConfig memory config = _getVaultConfig(vault);

        (bool isStale,) = _checkUnderlyingStaleness(config.underlying);
        if (isStale) {
            revert StaleUnderlyingPrice(vault, config.underlying);
        }

        return _getPriceFromConfig(vault, config, useCircuitBreaker);
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
        address underlying = vaultToUnderlying[vault];
        if (underlying == address(0)) {
            revert VaultNotRegistered(vault);
        }

        // Try to check underlying oracle staleness
        (isStale, publishTime) = _checkUnderlyingStaleness(underlying);
    }

    /// @notice Get price with staleness information
    /// @param vault The vault address
    /// @return price The price in USD with 8 decimals
    /// @return isStale True if the underlying price is stale
    function getPriceWithStaleness(address vault) external returns (uint256 price, bool isStale) {
        VaultConfig memory config = _getVaultConfig(vault);

        // Check staleness
        (isStale,) = _checkUnderlyingStaleness(config.underlying);

        // Emit event for monitoring
        emit StalePriceDetected(vault, config.underlying, isStale);

        // If stale, still calculate price but return stale flag
        // This allows callers to make informed decisions
        // Note: getPrice() will revert on stale, but this function provides flexibility
        price = _getPriceFromConfig(vault, config, false);
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

    function _getPriceFromConfig(address vault, VaultConfig memory config, bool useCircuitBreaker)
        internal
        view
        returns (uint256)
    {
        uint256 totalSupply = IERC4626(vault).totalSupply();
        if (totalSupply < config.minimumSupply) {
            revert InsufficientVaultLiquidity(vault, totalSupply, config.minimumSupply);
        }

        uint256 assetsPerShare = IERC4626(vault).convertToAssets(config.shareUnit);
        assetsPerShare = _boundedAssetsPerShare(vault, assetsPerShare, config, useCircuitBreaker);
        // After the safe-default rename `getPrice` is the protected variant on every feed
        // (including CompositeOracle, which honours the dual-feed challenge gate). The
        // unprotected path is reserved for explicit read-only callers and is intentionally
        // not used here even when `useCircuitBreaker == false`.
        uint256 underlyingPrice = underlyingPriceOracle.getPrice(config.underlying);
        uint8 priceDecimals = underlyingPriceOracle.decimals();

        uint256 sharePrice = Math.mulDiv(assetsPerShare, underlyingPrice, config.underlyingUnit);
        return sharePrice.normalize(priceDecimals, ConstantsLib.USD_DECIMALS);
    }

    function _boundedAssetsPerShare(
        address vault,
        uint256 assetsPerShare,
        VaultConfig memory config,
        bool failClosedOnUpperDeviation
    ) internal pure returns (uint256) {
        uint256 referenceAssetsPerShare = config.referenceAssetsPerShare;
        if (referenceAssetsPerShare == 0) {
            revert SharePriceDeviationTooHigh(
                vault, assetsPerShare, referenceAssetsPerShare, config.maxSharePriceDeviationBps
            );
        }

        uint256 deviationAmount =
            Math.mulDiv(referenceAssetsPerShare, config.maxSharePriceDeviationBps, ConstantsLib.BASIS_POINT_SCALE);
        uint256 minAssetsPerShare =
            referenceAssetsPerShare > deviationAmount ? referenceAssetsPerShare - deviationAmount : 0;
        uint256 maxAssetsPerShare = referenceAssetsPerShare + deviationAmount;

        if (assetsPerShare < minAssetsPerShare) {
            revert SharePriceDeviationTooHigh(
                vault, assetsPerShare, referenceAssetsPerShare, config.maxSharePriceDeviationBps
            );
        }

        if (failClosedOnUpperDeviation && assetsPerShare > maxAssetsPerShare) {
            revert SharePriceDeviationTooHigh(
                vault, assetsPerShare, referenceAssetsPerShare, config.maxSharePriceDeviationBps
            );
        }

        return assetsPerShare > maxAssetsPerShare ? maxAssetsPerShare : assetsPerShare;
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
