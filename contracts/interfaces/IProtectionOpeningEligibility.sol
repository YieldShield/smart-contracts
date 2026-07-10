// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

/// @title IProtectionOpeningEligibility
/// @notice Optional oracle-feed capability for gating new protection positions
/// @dev Price reads remain available when opening is disallowed. Consumers should use this
///      capability only before creating or increasing risk, not for withdrawals or settlement.
interface IProtectionOpeningEligibility {
    /// @notice Whether this feed requires an opening-eligibility check for `token`
    function supportsProtectionOpeningEligibility(address token) external view returns (bool supported);

    /// @notice Whether a new protection position may currently be opened for `token`
    /// @dev Implementations should fail closed and return false when their status source is unavailable.
    function isProtectionOpeningAllowed(address token) external view returns (bool allowed);
}
