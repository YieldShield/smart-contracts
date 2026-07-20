// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IRobinhoodStockOracleFeed
/// @notice Configuration capability exposed by the pinned Robinhood stock oracle wrapper
/// @dev CompositeOracle uses this capability to identify guarded stock tokens without relying
///      on a token-specific marker such as `oraclePaused()`.
interface IRobinhoodStockOracleFeed {
    /// @notice Whether `token` has an explicit, fail-closed pause probe configuration
    function isTokenConfigured(address token) external view returns (bool configured);
}
