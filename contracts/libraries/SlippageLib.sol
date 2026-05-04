// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title SlippageLib
/// @notice Shared helpers to enforce user-provided min-out constraints.
library SlippageLib {
    error SlippageProtectionFailed(uint256 minExpected, uint256 actualReceived);

    function enforceMinReceived(uint256 actual, uint256 minExpected) internal pure {
        if (minExpected == 0) return;
        if (actual < minExpected) revert SlippageProtectionFailed(minExpected, actual);
    }
}
