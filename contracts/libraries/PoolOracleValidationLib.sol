// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ICompositeOracle } from "../interfaces/ICompositeOracle.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { ConstantsLib } from "./ConstantsLib.sol";
import { DecimalNormalizationLib } from "./DecimalNormalizationLib.sol";
import { ErrorsLib } from "./ErrorsLib.sol";

/// @title PoolOracleValidationLib
/// @author David Hawig
/// @notice Shared validation logic for price oracles used by SplitRiskPool instances
/// @dev After the safe-default rename, `getPrice` is the circuit-breaker-validated price
///      on every oracle. Pools rely on two distinct oracle paths:
///      - shielded asset accounting uses getPrice(shieldedToken)
///      - backing asset protection uses getPrice(backingToken)
///      A configured oracle (or sub-feed of a CompositeOracle) must publish the safe/unsafe
///      split — marked by exposing `getPriceUnsafe(address)` — and answer both safe getters
///      with a non-zero price before it can be used by a pool.
library PoolOracleValidationLib {
    using DecimalNormalizationLib for uint256;

    bytes4 private constant INVALID_PRICE_UINT_SELECTOR = bytes4(keccak256("InvalidPrice(address,uint256)"));
    bytes4 private constant INVALID_PRICE_INT_SELECTOR = bytes4(keccak256("InvalidPrice(address,int256)"));
    bytes4 private constant INSUFFICIENT_VAULT_VALUE_SELECTOR =
        bytes4(keccak256("InsufficientVaultValue(address,uint256,uint256)"));

    /// @notice Validate that an oracle supports the pool's required pricing paths
    /// @param oracle The oracle address to validate
    /// @param shieldedToken The shielded token address
    /// @param backingToken The backing token address
    /// @param requiresStrictProtectedPrice Whether the backing token must use the strict circuit-breaker path
    function validatePoolOracle(
        address oracle,
        address shieldedToken,
        address backingToken,
        bool requiresStrictProtectedPrice
    ) internal view {
        validateShieldedTokenOracle(oracle, shieldedToken);
        validateBackingTokenOracle(oracle, backingToken, requiresStrictProtectedPrice);
    }

    /// @notice Validate the shielded-token pricing path required by a pool
    /// @param oracle The oracle address to validate
    /// @param shieldedToken The shielded token address
    function validateShieldedTokenOracle(address oracle, address shieldedToken) internal view {
        if (oracle == address(0)) revert ErrorsLib.InvalidAssetAddress();

        _validateProtectedPriceSelector(oracle, shieldedToken);
        _validateNonZeroOracleResponse(oracle, abi.encodeCall(IPriceOracle.getPrice, (shieldedToken)));
        // Codex P2: when the wrapper is a CompositeOracle, walk the configured
        // sub-feeds for the shielded token too. Otherwise a primary feed
        // lacking the safe/unsafe split (e.g. PythEMA-only, TWAP-only) could
        // silently get used at runtime — the wrapper itself advertises the
        // selector, but its delegated sub-feed has no circuit-breaker
        // discipline, regressing what the old getPriceWithCircuitBreaker
        // probe would have rejected.
        _validateCompositeFeedsAdvertiseProtectedSelector(oracle, shieldedToken);
    }

    /// @notice Validate the backing-token pricing path required by a pool
    /// @param oracle The oracle address to validate
    /// @param backingToken The backing token address
    /// @param requiresStrictProtectedPrice Whether the backing token must use the strict circuit-breaker path
    function validateBackingTokenOracle(address oracle, address backingToken, bool requiresStrictProtectedPrice)
        internal
        view
    {
        _rejectERC4626NavFeedForBacking(oracle, backingToken);

        if (requiresStrictProtectedPrice) {
            (bool strictSuccess, bytes memory strictData) =
                oracle.staticcall(abi.encodeCall(ICompositeOracle.getPriceWithStrictCircuitBreaker, (backingToken)));

            if (!strictSuccess || strictData.length < 32) revert ErrorsLib.InvalidAssetAddress();
            _validateDecodedPrice(strictData);
            _validateStrictProtectedPriceSupport(oracle, backingToken);
            _validateCompositeConfiguredProtectedPrices(oracle, backingToken);
            return;
        }

        _validateProtectedPriceSelector(oracle, backingToken);
        _validateNonZeroOracleResponse(oracle, abi.encodeCall(IPriceOracle.getPrice, (backingToken)));

        // For wrapping composite oracles, also require that the configured primary feed
        // advertises the safe/unsafe split: otherwise a pool would silently rely on a
        // feed (e.g. PythEMA-only, ad-hoc fallback) that has no circuit-breaker discipline.
        _validateCompositeFeedsAdvertiseProtectedSelector(oracle, backingToken);
    }

    /// @dev ERC4626 NAV feeds intentionally lag in-band share-rate increases on
    ///      their protected path. That is conservative for shielded-value
    ///      accounting, but unsafe as the backing-token denominator because it
    ///      overpays backing shares when a vault's live NAV has risen. Reject
    ///      those feeds anywhere they can price the backing token.
    function _rejectERC4626NavFeedForBacking(address oracle, address backingToken) private view {
        if (_feedPricesERC4626Vault(oracle, backingToken)) {
            revert ErrorsLib.ERC4626BackingOracleUnsupported(backingToken, oracle);
        }

        (bool statusSuccess, bytes memory statusData) =
            oracle.staticcall(abi.encodeCall(ICompositeOracle.getTokenDualFeedStatus, (backingToken)));
        if (!statusSuccess || statusData.length < 192) {
            return;
        }

        (bool isDualFeed, address primaryFeed, address backupFeed,,,) =
            abi.decode(statusData, (bool, address, address, bool, bool, uint256));
        if (primaryFeed != address(0) && _feedPricesERC4626Vault(primaryFeed, backingToken)) {
            revert ErrorsLib.ERC4626BackingOracleUnsupported(backingToken, primaryFeed);
        }
        if (isDualFeed && backupFeed != address(0) && _feedPricesERC4626Vault(backupFeed, backingToken)) {
            revert ErrorsLib.ERC4626BackingOracleUnsupported(backingToken, backupFeed);
        }
    }

    function _feedPricesERC4626Vault(address feed, address token) private view returns (bool) {
        if (feed.code.length == 0) {
            return false;
        }

        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeWithSignature("vaultToUnderlying(address)", token));
        if (!success || data.length < 32) {
            return false;
        }

        return abi.decode(data, (address)) != address(0);
    }

    /// @dev Walks the CompositeOracle's configured primary/backup feeds for a token and
    ///      requires each to expose `getPriceUnsafe(address)`. No-op for oracles that do
    ///      not implement the CompositeOracle interface (the top-level selector check is
    ///      sufficient in that case).
    function _validateCompositeFeedsAdvertiseProtectedSelector(address oracle, address token) private view {
        (bool statusSuccess, bytes memory statusData) =
            oracle.staticcall(abi.encodeCall(ICompositeOracle.getTokenDualFeedStatus, (token)));

        if (!statusSuccess || statusData.length < 192) {
            return;
        }

        (bool isDualFeed, address primaryFeed, address backupFeed,,,) =
            abi.decode(statusData, (bool, address, address, bool, bool, uint256));

        if (primaryFeed != address(0)) {
            _validateCompositeFeedProtectedPrice(primaryFeed, token);
        }
        if (isDualFeed && backupFeed != address(0)) {
            _validateCompositeFeedProtectedPrice(backupFeed, token);
        }
    }

    /// @dev CompositeOracle strict pricing reads the active feed. For strict backing assets,
    ///      also require every configured feed to expose a currently usable protected path
    ///      before accepting the oracle for a pool.
    function _validateCompositeConfiguredProtectedPrices(address oracle, address backingToken) private view {
        (bool statusSuccess, bytes memory statusData) =
            oracle.staticcall(abi.encodeCall(ICompositeOracle.getTokenDualFeedStatus, (backingToken)));

        if (!statusSuccess || statusData.length < 192) {
            return;
        }

        (bool isDualFeed, address primaryFeed, address backupFeed,,,) =
            abi.decode(statusData, (bool, address, address, bool, bool, uint256));

        if (primaryFeed != address(0)) {
            _validateCompositeFeedProtectedPrice(primaryFeed, backingToken);
            _validateStrictProtectedPriceSupport(primaryFeed, backingToken);
        }

        if (isDualFeed && backupFeed != address(0)) {
            _validateCompositeFeedProtectedPrice(backupFeed, backingToken);
            _validateStrictProtectedPriceSupport(backupFeed, backingToken);
        }
    }

    /// @dev Ensures the target oracle call succeeds and returns a non-zero uint256 price.
    function _validateNonZeroOracleResponse(address oracle, bytes memory payload) private view {
        (bool success, bytes memory data) = oracle.staticcall(payload);
        if (!success || data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        _validateDecodedPrice(data);
    }

    function _validateStrictProtectedPriceSupport(address oracle, address token) private view {
        (bool success, bytes memory data) =
            oracle.staticcall(abi.encodeWithSignature("supportsStrictProtectedPrice(address)", token));

        if (!success || data.length < 32) revert ErrorsLib.InvalidAssetAddress();
        if (!abi.decode(data, (bool))) revert ErrorsLib.InvalidAssetAddress();
    }

    /// @dev Confirms the oracle advertises the safe/unsafe split (i.e. exposes the
    ///      `getPriceUnsafe(address)` selector). Before the safe-default rename this
    ///      enforcement was implicit in the `getPriceWithCircuitBreaker` probe; preserve
    ///      it here so pool creation continues to reject oracles or feeds that lack a
    ///      circuit-breaker discipline (PythEMA-only feeds, ad-hoc price-only mocks).
    function _validateProtectedPriceSelector(address oracle, address token) private view {
        if (oracle.code.length == 0) revert ErrorsLib.InvalidAssetAddress();

        (bool success, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("getPriceUnsafe(address)", token));

        if (!success) _revertOracleResponseFailure(data);
        if (data.length < 32) revert ErrorsLib.InvalidAssetAddress();
        if (abi.decode(data, (uint256)) == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    function _validateCompositeFeedProtectedPrice(address feed, address token) private view {
        _validateProtectedPriceSelector(feed, token);
        _validateNonZeroNormalizedOracleResponse(feed, abi.encodeCall(IPriceOracle.getPrice, (token)));
        _validateNonZeroNormalizedOracleResponse(feed, abi.encodeWithSignature("getPriceUnsafe(address)", token));
    }

    function _validateNonZeroNormalizedOracleResponse(address oracle, bytes memory payload) private view {
        (bool success, bytes memory data) = oracle.staticcall(payload);
        if (!success || data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        uint256 price = _decodeNonZeroPrice(data);
        uint8 oracleDecimals = _readOracleDecimals(oracle);
        uint256 normalizedPrice = price.normalize(oracleDecimals, ConstantsLib.USD_DECIMALS);
        if (normalizedPrice == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    function _readOracleDecimals(address oracle) private view returns (uint8 oracleDecimals) {
        (bool success, bytes memory data) = oracle.staticcall(abi.encodeCall(IOracleFeed.decimals, ()));
        if (!success || data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        uint256 decodedDecimals = abi.decode(data, (uint256));
        if (decodedDecimals > 77) revert ErrorsLib.InvalidAssetAddress();
        oracleDecimals = uint8(decodedDecimals);
    }

    function _validateDecodedPrice(bytes memory data) private pure {
        if (data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        _decodeNonZeroPrice(data);
    }

    function _decodeNonZeroPrice(bytes memory data) private pure returns (uint256 price) {
        price = abi.decode(data, (uint256));
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    function _revertOracleResponseFailure(bytes memory data) private pure {
        if (data.length >= 4) {
            bytes4 selector = bytes4(data);
            if (
                selector == INVALID_PRICE_UINT_SELECTOR || selector == INVALID_PRICE_INT_SELECTOR
                    || selector == INSUFFICIENT_VAULT_VALUE_SELECTOR
                    || selector == ErrorsLib.InvalidOraclePrice.selector
            ) {
                revert ErrorsLib.InvalidOraclePrice();
            }
        }
        revert ErrorsLib.InvalidAssetAddress();
    }
}
