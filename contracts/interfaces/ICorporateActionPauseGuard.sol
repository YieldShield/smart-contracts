// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ICorporateActionPauseGuard
/// @notice Optional oracle-feed capability indicating that corporate-action pauses are enforced
/// @dev Composite oracles use this marker to prevent a dual-feed route from bypassing a token's
///      corporate-action pause when only one configured leg applies the guard.
interface ICorporateActionPauseGuard {
    /// @notice Whether this feed enforces the token's corporate-action pause on every price path
    /// @param token The token whose feed capability is being queried
    /// @return supported True when all price paths fail closed during a corporate-action pause
    function supportsCorporateActionPauseGuard(address token) external view returns (bool supported);
}
