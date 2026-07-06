// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IOracleFeed } from "../interfaces/IOracleFeed.sol";

/// @title IRobinhoodStockToken
/// @notice Minimal interface for Robinhood stock tokens exposing the corporate-action pause flag
interface IRobinhoodStockToken {
    function oraclePaused() external view returns (bool);
}

/// @title IChainlinkOracleFeedOptional
/// @notice Optional ChainlinkOracleFeed functions mirrored by this wrapper. CompositeOracle
///         probes feeds for these selectors (`getPriceUnsafe`, `supportsCircuitBreaker`,
///         `supportsStrictProtectedPrice`, `isPriceStale`), so the wrapper must delegate each
///         of them to avoid silently downgrading the inner feed's advertised capabilities.
interface IChainlinkOracleFeedOptional {
    function getPriceUnsafe(address token) external view returns (uint256);
    function supportsCircuitBreaker(address token) external view returns (bool);
    function supportsStrictProtectedPrice(address token) external view returns (bool);
    function isPriceStale(address token) external view returns (bool isStale, uint256 updatedAt);
}

/// @title RobinhoodStockOracleFeed
/// @author David Hawig
/// @notice Stateless IOracleFeed wrapper that guards Robinhood stock-token pricing with the
///         token's `oraclePaused()` corporate-action flag
/// @dev Robinhood stock tokens pause their oracle around corporate actions (splits, reverse
///      splits, dividends) while the UI multiplier is rebased; during that window the Chainlink
///      price for the token must be treated as unavailable. Every price read here first probes
///      the token's pause flag and fails closed: a paused token reverts with
///      `StockTokenOraclePaused`, and a token that does not implement the probe reverts with
///      `StockTokenPauseProbeFailed`. All other behaviour is delegated unchanged to the wrapped
///      ChainlinkOracleFeed, including the optional capability functions CompositeOracle probes
///      (`getPriceUnsafe`, `supportsCircuitBreaker`, `supportsStrictProtectedPrice`,
///      `isPriceStale`), so wrapping does not weaken the inner feed's protections.
contract RobinhoodStockOracleFeed is IOracleFeed {
    /// @notice The wrapped ChainlinkOracleFeed that performs the actual price reads
    address public immutable innerFeed;

    /// @notice Custom error for zero inner feed address
    error InvalidInnerFeed(address feed);

    /// @notice Custom error when the inner feed does not report 8 decimals
    error InvalidInnerFeedDecimals(address feed, uint8 feedDecimals);

    /// @notice Custom error when the stock token's oracle is paused for a corporate action
    error StockTokenOraclePaused(address token);

    /// @notice Custom error when the token does not implement the `oraclePaused()` probe
    error StockTokenPauseProbeFailed(address token);

    /// @notice Constructor
    /// @param _innerFeed The ChainlinkOracleFeed address to wrap
    constructor(address _innerFeed) {
        if (_innerFeed == address(0)) revert InvalidInnerFeed(_innerFeed);
        uint8 innerDecimals = IOracleFeed(_innerFeed).decimals();
        if (innerDecimals != 8) revert InvalidInnerFeedDecimals(_innerFeed, innerDecimals);
        innerFeed = _innerFeed;
    }

    /// @dev Reverts unless the token's corporate-action pause flag is readable and false.
    ///      Fails closed: tokens that do not implement `oraclePaused()` are rejected so a
    ///      token without the probe can never bypass the pause guard.
    function _requireNotPaused(address token) internal view {
        try IRobinhoodStockToken(token).oraclePaused() returns (bool paused) {
            if (paused) revert StockTokenOraclePaused(token);
        } catch {
            revert StockTokenPauseProbeFailed(token);
        }
    }

    /// @inheritdoc IOracleFeed
    /// @dev Reverts while the token's oracle is paused for a corporate action; otherwise
    ///      delegates to the inner ChainlinkOracleFeed's protected price path.
    function getPrice(address token) external view override returns (uint256) {
        _requireNotPaused(token);
        return IOracleFeed(innerFeed).getPrice(token);
    }

    /// @notice Unprotected price getter mirroring the inner feed's `getPriceUnsafe` alias.
    /// @dev The corporate-action pause guard still applies — a paused stock token has no
    ///      readable price on any path. Otherwise delegates to the inner feed's `getPriceUnsafe`.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPriceUnsafe(address token) external view returns (uint256 price) {
        _requireNotPaused(token);
        return IChainlinkOracleFeedOptional(innerFeed).getPriceUnsafe(token);
    }

    /// @notice Whether the inner feed exposes a protected price path for `token`.
    /// @param token The token address
    /// @return supported True if the inner feed supports circuit-breaker pricing for the token
    function supportsCircuitBreaker(address token) external view returns (bool supported) {
        return IChainlinkOracleFeedOptional(innerFeed).supportsCircuitBreaker(token);
    }

    /// @notice Whether the inner token feed satisfies the stricter protected-collateral policy.
    /// @param token The token address
    /// @return supported True if the inner feed supports strict protected pricing for the token
    function supportsStrictProtectedPrice(address token) external view returns (bool supported) {
        return IChainlinkOracleFeedOptional(innerFeed).supportsStrictProtectedPrice(token);
    }

    /// @notice Check if a price is stale for a given token
    /// @dev A paused token (or one that does not implement the pause probe) is reported as
    ///      stale with a zero timestamp so staleness-aware consumers fail closed during
    ///      corporate actions; otherwise delegates to the inner feed's `isPriceStale`.
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return updatedAt The timestamp of the last update
    function isPriceStale(address token) external view returns (bool isStale, uint256 updatedAt) {
        try IRobinhoodStockToken(token).oraclePaused() returns (bool paused) {
            if (paused) {
                return (true, 0);
            }
        } catch {
            return (true, 0);
        }
        return IChainlinkOracleFeedOptional(innerFeed).isPriceStale(token);
    }

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Robinhood Stock Chainlink Oracle Feed";
    }
}
