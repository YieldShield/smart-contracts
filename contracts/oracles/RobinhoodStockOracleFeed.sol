// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { ICorporateActionPauseGuard } from "../interfaces/ICorporateActionPauseGuard.sol";
import { IClosedSessionExitPrice } from "../interfaces/IClosedSessionExitPrice.sol";
import { IProtectionOpeningEligibility } from "../interfaces/IProtectionOpeningEligibility.sol";
import { IRobinhoodStockOracleFeed } from "../interfaces/IRobinhoodStockOracleFeed.sol";

interface IUSMarketSessionGate {
    function isMarketOpen() external view returns (bool);
    function emergencyPaused() external view returns (bool);
}

/// @title IRobinhoodStockToken
/// @notice Minimal interface for Robinhood stock tokens exposing the corporate-action pause flag
interface IRobinhoodStockToken {
    function oraclePaused() external view returns (bool);
}

/// @title ICanonicalRobinhoodStockToken
/// @notice Minimal interface for canonical Robinhood stock tokens
interface ICanonicalRobinhoodStockToken {
    function paused() external view returns (bool);
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
    function protectionOpeningMaxPriceAgeForToken(address token) external view returns (uint256 maxAge);
    function getPriceForClosedSessionExit(address token) external view returns (uint256 price);
    function supportsUserUpdates(address token) external view returns (bool);
    function refreshPrice(address token) external;
}

/// @title RobinhoodStockOracleFeed
/// @author David Hawig
/// @notice IOracleFeed wrapper that guards Robinhood stock-token pricing with an explicitly
///         configured pause probe and new-protection openings with an explicit market calendar
/// @dev Both the legacy demo token's `oraclePaused()` probe and the canonical Robinhood token's
///      `paused()` probe are supported. Tokens default to `Unset`, and every price read fails
///      closed unless the owner has selected the exact probe expected for that token. A paused
///      token reverts with `StockTokenOraclePaused`; an absent, reverting, or malformed configured
///      probe reverts with `StockTokenPauseProbeFailed`. All other behaviour is delegated to the
///      wrapped ChainlinkOracleFeed, including the optional capability functions CompositeOracle probes
///      (`getPriceUnsafe`, `supportsCircuitBreaker`, `supportsStrictProtectedPrice`,
///      `isPriceStale`), so wrapping does not weaken the inner feed's protections.
contract RobinhoodStockOracleFeed is
    IOracleFeed,
    ICorporateActionPauseGuard,
    IProtectionOpeningEligibility,
    IClosedSessionExitPrice,
    IRobinhoodStockOracleFeed,
    Ownable
{
    /// @notice The supported corporate-action pause probes
    /// @dev `Unset` is intentionally fail-closed. Probe selection is explicit so a reverting
    ///      implementation can never be mistaken for a token that simply lacks the legacy hook.
    enum PauseProbeMode {
        Unset,
        OraclePaused,
        TokenPaused
    }

    /// @notice Maximum reviewed freshness window for opening Robinhood equity protection
    /// @dev Individual tokens must configure an explicit non-zero value on the inner feed and
    ///      may use a tighter bound. Ordinary and closed-session price reads are unchanged.
    uint256 public constant MAX_PROTECTION_OPENING_PRICE_AGE = 1 hours;

    /// @notice The wrapped ChainlinkOracleFeed that performs the actual price reads
    address public immutable innerFeed;

    /// @notice Fail-closed calendar used only when opening new protection positions
    address public immutable marketSessionGate;

    /// @notice Explicit pause probe selected for each guarded stock token
    mapping(address token => PauseProbeMode mode) public pauseProbeMode;

    /// @notice Emitted when a token's fail-closed pause probe configuration changes
    event PauseProbeModeSet(address indexed token, PauseProbeMode previousMode, PauseProbeMode newMode);

    /// @notice Custom error for zero inner feed address
    error InvalidInnerFeed(address feed);

    /// @notice Custom error when the inner feed does not report 8 decimals
    error InvalidInnerFeedDecimals(address feed, uint8 feedDecimals);

    /// @notice Custom error for an invalid market-session gate
    error InvalidMarketSessionGate(address gate);

    /// @notice Custom error when the stock token's oracle is paused for a corporate action
    error StockTokenOraclePaused(address token);

    /// @notice Custom error when no pause probe has been configured for a token
    error StockTokenPauseProbeNotConfigured(address token);

    /// @notice Custom error when the configured pause probe reverts or returns malformed data
    error StockTokenPauseProbeFailed(address token);

    /// @notice Custom error for a zero token address in pause-probe configuration
    error InvalidStockToken(address token);

    /// @notice Custom error when the extended exit-price path is requested during an open session
    error MarketSessionOpen(address token);

    /// @notice Custom error when emergency pause must not be treated as a scheduled market closure
    error MarketSessionEmergencyPaused(address token);

    /// @notice Custom error when the market-session gate cannot be read
    error MarketSessionStatusUnavailable(address gate);

    /// @notice Constructor
    /// @param _innerFeed The ChainlinkOracleFeed address to wrap
    /// @param _marketSessionGate Fail-closed US-equity session calendar
    constructor(address _innerFeed, address _marketSessionGate) Ownable(msg.sender) {
        if (_innerFeed == address(0)) revert InvalidInnerFeed(_innerFeed);
        if (_marketSessionGate == address(0) || _marketSessionGate.code.length == 0) {
            revert InvalidMarketSessionGate(_marketSessionGate);
        }
        uint8 innerDecimals = IOracleFeed(_innerFeed).decimals();
        if (innerDecimals != 8) revert InvalidInnerFeedDecimals(_innerFeed, innerDecimals);
        innerFeed = _innerFeed;
        marketSessionGate = _marketSessionGate;
    }

    /// @notice Configure the exact pause probe used for `token`
    /// @dev Setting `Unset` disables the token and makes every guarded path fail closed.
    function setPauseProbeMode(address token, PauseProbeMode newMode) external onlyOwner {
        if (token == address(0)) revert InvalidStockToken(token);
        PauseProbeMode previousMode = pauseProbeMode[token];
        pauseProbeMode[token] = newMode;
        emit PauseProbeModeSet(token, previousMode, newMode);
    }

    /// @inheritdoc IRobinhoodStockOracleFeed
    function isTokenConfigured(address token) public view returns (bool configured) {
        return pauseProbeMode[token] != PauseProbeMode.Unset;
    }

    /// @dev Reads the configured pause probe with canonical ABI validation.
    /// @return configured Whether an explicit probe mode is configured
    /// @return readable Whether the configured probe returned a canonical ABI boolean
    /// @return paused The decoded pause state when readable
    function _tryReadPauseState(address token) internal view returns (bool configured, bool readable, bool paused) {
        PauseProbeMode mode = pauseProbeMode[token];
        if (mode == PauseProbeMode.Unset) return (false, false, false);

        bytes4 selector = mode == PauseProbeMode.OraclePaused
            ? IRobinhoodStockToken.oraclePaused.selector
            : ICanonicalRobinhoodStockToken.paused.selector;
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length < 32) return (true, false, false);

        uint256 encodedBool;
        assembly ("memory-safe") {
            encodedBool := mload(add(data, 32))
        }
        if (encodedBool > 1) return (true, false, false);
        return (true, true, encodedBool == 1);
    }

    /// @dev Reverts unless the token's explicitly configured pause flag is readable and false.
    function _requireNotPaused(address token) internal view {
        (bool configured, bool readable, bool paused) = _tryReadPauseState(token);
        if (!configured) revert StockTokenPauseProbeNotConfigured(token);
        if (!readable) revert StockTokenPauseProbeFailed(token);
        if (paused) revert StockTokenOraclePaused(token);
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

    /// @inheritdoc ICorporateActionPauseGuard
    function supportsCorporateActionPauseGuard(address token) external view returns (bool supported) {
        return isTokenConfigured(token);
    }

    /// @inheritdoc IClosedSessionExitPrice
    function supportsClosedSessionExitPrice(address token) external view returns (bool supported) {
        return isTokenConfigured(token);
    }

    /// @inheritdoc IClosedSessionExitPrice
    /// @dev The extended Chainlink freshness window is reachable only while the configured
    ///      calendar reports the market closed, the emergency guardian has not paused sessions,
    ///      and the token's pause probe is readable and false.
    function getPriceForClosedSessionExit(address token) external view returns (uint256 price) {
        _requireNotPaused(token);

        bool emergencyPauseActive;
        try IUSMarketSessionGate(marketSessionGate).emergencyPaused() returns (bool paused) {
            emergencyPauseActive = paused;
        } catch {
            revert MarketSessionStatusUnavailable(marketSessionGate);
        }
        if (emergencyPauseActive) revert MarketSessionEmergencyPaused(token);

        bool marketOpen;
        try IUSMarketSessionGate(marketSessionGate).isMarketOpen() returns (bool open) {
            marketOpen = open;
        } catch {
            revert MarketSessionStatusUnavailable(marketSessionGate);
        }
        if (marketOpen) revert MarketSessionOpen(token);

        return IChainlinkOracleFeedOptional(innerFeed).getPriceForClosedSessionExit(token);
    }

    /// @notice Whether the underlying Chainlink-compatible feed supports user refreshes.
    function supportsUserUpdates(address token) external view returns (bool supported) {
        return IChainlinkOracleFeedOptional(innerFeed).supportsUserUpdates(token);
    }

    /// @notice Refresh a user-updatable underlying feed while preserving the stock pause guard.
    function refreshPrice(address token) external {
        _requireNotPaused(token);
        IChainlinkOracleFeedOptional(innerFeed).refreshPrice(token);
    }

    /// @notice Check if a price is stale for a given token
    /// @dev A paused token (or one with an unconfigured/unreadable probe) is reported as
    ///      stale with a zero timestamp so staleness-aware consumers fail closed during
    ///      corporate actions; otherwise delegates to the inner feed's `isPriceStale`.
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return updatedAt The timestamp of the last update
    function isPriceStale(address token) external view returns (bool isStale, uint256 updatedAt) {
        (bool configured, bool readable, bool paused) = _tryReadPauseState(token);
        if (!configured || !readable || paused) return (true, 0);
        return IChainlinkOracleFeedOptional(innerFeed).isPriceStale(token);
    }

    /// @inheritdoc IProtectionOpeningEligibility
    function supportsProtectionOpeningEligibility(address token) external view returns (bool supported) {
        return isTokenConfigured(token);
    }

    /// @notice Whether a token has an explicit reviewed opening-specific freshness policy
    /// @dev Fails closed for incompatible inner feeds, missing policies, and values above the
    ///      immutable Robinhood equity ceiling.
    function isProtectionOpeningFreshnessConfigured(address token) public view returns (bool configured) {
        if (!isTokenConfigured(token)) return false;
        try IChainlinkOracleFeedOptional(innerFeed).protectionOpeningMaxPriceAgeForToken(token) returns (
            uint256 maxAge
        ) {
            return maxAge != 0 && maxAge <= MAX_PROTECTION_OPENING_PRICE_AGE;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IProtectionOpeningEligibility
    /// @dev This does not gate price reads or exits. Missing token pause status, a failed market
    ///      status call, a closed calendar day, or an emergency pause all fail closed for openings.
    function isProtectionOpeningAllowed(address token) external view returns (bool allowed) {
        (bool configured, bool readable, bool paused) = _tryReadPauseState(token);
        if (!configured || !readable || paused) return false;

        try IUSMarketSessionGate(marketSessionGate).isMarketOpen() returns (bool marketOpen) {
            if (!marketOpen) return false;
        } catch {
            return false;
        }

        uint256 openingMaxAge;
        try IChainlinkOracleFeedOptional(innerFeed).protectionOpeningMaxPriceAgeForToken(token) returns (
            uint256 configuredMaxAge
        ) {
            if (configuredMaxAge == 0 || configuredMaxAge > MAX_PROTECTION_OPENING_PRICE_AGE) return false;
            openingMaxAge = configuredMaxAge;
        } catch {
            return false;
        }

        try IChainlinkOracleFeedOptional(innerFeed).isPriceStale(token) returns (bool isStale, uint256 updatedAt) {
            if (isStale || updatedAt == 0 || updatedAt > block.timestamp) return false;
            return block.timestamp - updatedAt <= openingMaxAge;
        } catch {
            return false;
        }
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
