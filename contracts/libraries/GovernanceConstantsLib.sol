// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title GovernanceConstantsLib
/// @notice Shared numerical bounds that must not drift between YSToken and YSGovernor
library GovernanceConstantsLib {
    /// @notice Highest proposal threshold governance may configure
    uint256 internal constant MAX_PROPOSAL_THRESHOLD = 100_000 * 10 ** 18;

    /// @notice Irreducible supply floor used to preserve numerical proposal reachability
    /// @dev YSToken rejects burns that would leave supply at or below this value, so
    ///      total supply remains strictly above every permitted proposal threshold.
    uint256 internal constant MIN_GOVERNANCE_SUPPLY = MAX_PROPOSAL_THRESHOLD;
}
