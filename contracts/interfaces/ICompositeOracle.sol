// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceOracle } from "./IPriceOracle.sol";

/// @title ICompositeOracle
/// @author David Hawig
/// @notice Interface for composite oracle that routes pricing to per-token oracle feeds
/// @dev Extends IPriceOracle with token-to-feed mapping management and optional dual-feed support
///      with challenge mechanism for switching between primary and backup feeds.
interface ICompositeOracle is IPriceOracle {
    // ============ Events ============

    /// @notice Emitted when a token's oracle feed is set or updated
    /// @param token The token address
    /// @param oracleFeed The oracle feed address
    event TokenOracleFeedSet(address indexed token, address indexed oracleFeed);

    /// @notice Emitted when a token's oracle feed is removed
    /// @param token The token address
    event TokenOracleFeedRemoved(address indexed token);

    // ============ Custom Errors ============

    /// @notice Custom error for unsupported token (no oracle feed registered)
    /// @param token The unsupported token address
    error TokenNotSupported(address token);

    /// @notice Custom error for invalid oracle feed address
    /// @param oracleFeed The invalid oracle feed address
    error InvalidOracleFeed(address oracleFeed);

    /// @notice Custom error for invalid token address
    /// @param token The invalid token address
    error InvalidTokenAddress(address token);

    // ============ Single-Feed Configuration ============

    /// @notice Set the oracle feed for a token (single-feed mode)
    /// @dev Only callable by owner or authorized callers. Clears any backup feed.
    /// @param token The token address
    /// @param oracleFeed The oracle feed address (must implement IOracleFeed)
    function setTokenOracleFeed(address token, address oracleFeed) external;

    /// @notice Remove the oracle feed for a token
    /// @dev Only callable by owner or authorized callers
    /// @param token The token address
    function removeTokenOracleFeed(address token) external;

    /// @notice Get the oracle feed address for a token (returns primary feed)
    /// @param token The token address
    /// @return oracleFeed The oracle feed address (address(0) if not set)
    function getTokenOracleFeed(address token) external view returns (address oracleFeed);

    /// @notice Check if a token is supported (has an oracle feed registered)
    /// @param token The token address
    /// @return supported True if the token has an oracle feed registered
    function isTokenSupported(address token) external view returns (bool supported);

    /// @notice Get the oracle type for a token (for frontend oracle update logic)
    /// @dev Returns a string identifier like "pyth", "erc4626", "chainlink", "twap", "dual"
    /// @param token The token address
    /// @return oracleType The oracle type identifier
    function getOracleType(address token) external view returns (string memory oracleType);

    // ============ Dual-Feed Configuration ============

    /// @notice Set both primary and backup oracle feeds for a token (dual-feed mode)
    /// @dev Only callable by owner or authorized callers.
    ///      Enables challenge mechanism for this token.
    /// @param token The token address
    /// @param primaryFeed The primary oracle feed address (stability-focused, e.g., NAV)
    /// @param backupFeed The backup oracle feed address (market-responsive, e.g., Pyth)
    function setTokenOracleFeedDual(address token, address primaryFeed, address backupFeed) external;

    /// @notice Require all configured feeds for a token to support circuit-breaker pricing.
    /// @dev Only callable by owner or authorized callers.
    /// @param token The token address
    /// @param required Whether strict circuit-breaker support is required for this token
    function setStrictCircuitBreakerRequired(address token, bool required) external;

    /// @notice Returns whether strict circuit-breaker support is required for a token.
    /// @param token The token address
    /// @return required True if strict support is required
    function strictCircuitBreakerRequired(address token) external view returns (bool required);

    /// @notice Returns the number of active addresses authorized to administer feeds.
    function authorizedCallerCount() external view returns (uint256);

    /// @notice Returns the active authorized caller at `index`.
    function authorizedCallerAt(uint256 index) external view returns (address);

    /// @notice Clears all active authorized callers.
    function clearAuthorizedCallers() external;

    /// @notice Get the dual-feed status for a token
    /// @param token The token address
    /// @return isDualFeed True if token has both primary and backup feeds
    /// @return primaryFeed Address of primary feed
    /// @return backupFeed Address of backup feed (address(0) if single-feed)
    /// @return isBackupActive True if backup oracle is currently active
    /// @return isChallengePending True if a challenge is pending
    /// @return challengeStartTime Timestamp when challenge started (0 if none)
    function getTokenDualFeedStatus(address token)
        external
        view
        returns (
            bool isDualFeed,
            address primaryFeed,
            address backupFeed,
            bool isBackupActive,
            bool isChallengePending,
            uint256 challengeStartTime
        );

    /// @notice Returns true when protected pricing is currently unsafe for a dual-feed token
    /// @dev True covers pending challenges, primary/backup deviation above threshold,
    ///      or an unavailable primary protected path while a usable backup is available.
    /// @param token The token address
    /// @return challengeable True if price-sensitive callers should fail closed
    function isTokenChallengeable(address token) external view returns (bool challengeable);

    /// @notice Check if backup oracle is active for a token
    /// @param token The token address
    /// @return True if backup oracle is active (only relevant for dual-feed tokens)
    function isBackupActiveForToken(address token) external view returns (bool);

    /// @notice Get price using a strict circuit-breaker path.
    /// @dev Reverts unless every configured feed for the token supports circuit-breaker pricing,
    ///      and the active feed returns a protected price. This is useful for integrations
    ///      that require hard guarantees instead of compatibility fallback.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPriceWithStrictCircuitBreaker(address token) external view returns (uint256);

    /// @notice Returns whether this oracle exposes protected and unsafe pricing for a token.
    /// @param token The token address
    /// @return supported True if this oracle advertises circuit-breaker pricing support
    function supportsCircuitBreaker(address token) external view returns (bool supported);

    /// @notice Returns whether the active feed explicitly supports strict protected pricing.
    /// @param token The token address
    /// @return supported True if the active feed advertises strict protected pricing support
    function supportsStrictProtectedPrice(address token) external view returns (bool supported);

    // ============ Challenge Mechanism ============

    /// @notice Initiate a challenge for a dual-feed token
    /// @dev Anyone can call this if deviation between feeds exceeds threshold.
    ///      Starts the timelock period. Reverts if token is not dual-feed.
    /// @param token The token address
    function challengeForToken(address token) external;

    /// @notice Finalize a challenge and switch to backup oracle
    /// @dev Can only be called after timelock expires AND deviation still persists.
    ///      If deviation resolved during timelock, challenge is auto-cancelled.
    /// @param token The token address
    function finalizeChallenge(address token) external;

    /// @notice Cancel a pending challenge if deviation has resolved
    /// @dev Can be called by anyone if deviation < threshold before timelock expires.
    /// @param token The token address
    function cancelChallenge(address token) external;

    /// @notice Revert to primary oracle when market stabilizes
    /// @dev Anyone can call this if backup is active and deviation has returned to normal.
    /// @param token The token address
    function revertToPrimary(address token) external;

    // ============ Graceful Fallback ============

    /// @notice Get value with graceful fallback (tries backup sources, never reverts for configured tokens)
    /// @dev Tries active feed first, then backup if available. Returns (0, false) if all sources fail.
    ///      This is useful for _checkCapacity to get price even when primary oracle is stale.
    /// @param token The token address
    /// @param amount The amount of tokens
    /// @return value USD value (8 decimals), 0 if all sources fail
    /// @return isReliable True if active/primary source succeeded, false if using backup or failed
    function getValueWithFallback(address token, uint256 amount) external view returns (uint256 value, bool isReliable);
}
