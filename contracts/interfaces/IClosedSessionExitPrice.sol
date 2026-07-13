// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IClosedSessionExitPrice
/// @notice Optional feed capability for settling exits from assets whose oracle does not
///         publish while its primary market is closed
/// @dev Implementations must fail closed unless the market closure can be verified. This
///      capability is intentionally separate from ordinary protected pricing so openings and
///      cross-asset valuation never inherit the extended freshness window.
interface IClosedSessionExitPrice {
    /// @notice Whether the feed supports bounded closed-session exit pricing for `token`
    function supportsClosedSessionExitPrice(address token) external view returns (bool supported);

    /// @notice Return a protected price under the feed's bounded closed-session policy
    function getPriceForClosedSessionExit(address token) external view returns (uint256 price);
}
