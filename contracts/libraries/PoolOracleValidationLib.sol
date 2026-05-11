// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ICompositeOracle } from "../interfaces/ICompositeOracle.sol";
import { ErrorsLib } from "./ErrorsLib.sol";

/// @title PoolOracleValidationLib
/// @author David Hawig
/// @notice Shared validation logic for price oracles used by SplitRiskPool instances
/// @dev Pools rely on two distinct oracle paths:
///      - shielded asset accounting uses getPriceWithCircuitBreaker(shieldedToken)
///      - backing asset protection uses getPriceWithCircuitBreaker(backingToken)
///      A configured oracle must satisfy both before it can be used by a pool.
library PoolOracleValidationLib {
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
        if (oracle == address(0)) revert ErrorsLib.InvalidAssetAddress();

        _validateNonZeroOracleResponse(oracle, abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (shieldedToken)));
        validateBackingTokenOracle(oracle, backingToken, requiresStrictProtectedPrice);
    }

    /// @notice Validate the backing-token pricing path required by a pool
    /// @param oracle The oracle address to validate
    /// @param backingToken The backing token address
    /// @param requiresStrictProtectedPrice Whether the backing token must use the strict circuit-breaker path
    function validateBackingTokenOracle(address oracle, address backingToken, bool requiresStrictProtectedPrice)
        internal
        view
    {
        if (requiresStrictProtectedPrice) {
            (bool strictSuccess, bytes memory strictData) =
                oracle.staticcall(abi.encodeCall(ICompositeOracle.getPriceWithStrictCircuitBreaker, (backingToken)));

            if (strictSuccess) {
                _validateDecodedPrice(strictData);
                _validateCompositeConfiguredProtectedPrices(oracle, backingToken);
                return;
            }

            // Oracle does not expose the strict entrypoint. Fall back to the generic circuit-breaker API,
            // which is the strongest guarantee available on non-composite implementations.
            if (strictData.length != 0) revert ErrorsLib.InvalidAssetAddress();
        }

        _validateNonZeroOracleResponse(oracle, abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (backingToken)));
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
            _validateNonZeroOracleResponse(
                primaryFeed, abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (backingToken))
            );
        }

        if (isDualFeed && backupFeed != address(0)) {
            _validateNonZeroOracleResponse(
                backupFeed, abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (backingToken))
            );
        }
    }

    /// @dev Ensures the target oracle call succeeds and returns a non-zero uint256 price.
    function _validateNonZeroOracleResponse(address oracle, bytes memory payload) private view {
        (bool success, bytes memory data) = oracle.staticcall(payload);
        if (!success || data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        _validateDecodedPrice(data);
    }

    function _validateDecodedPrice(bytes memory data) private pure {
        if (data.length < 32) revert ErrorsLib.InvalidAssetAddress();

        uint256 price = abi.decode(data, (uint256));
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }
}
