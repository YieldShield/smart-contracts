// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

/// @title SlippageLib
/// @notice Shared helpers to enforce user-provided min-out constraints.
library SlippageLib {
    error SlippageProtectionFailed(uint256 minExpected, uint256 actualReceived);

    /// @notice Enforce that `actual` is at least `minExpected`.
    /// @dev Convention: `minExpected == 0` is the sentinel meaning "no slippage
    ///      check requested". This applies to BOTH deposit and withdraw paths.
    ///      Callers that want to require a positive payout MUST validate the
    ///      received amount independently before calling. Frontends defaulting
    ///      `minAmountOut` to zero silently opt out of slippage protection.
    function enforceMinReceived(uint256 actual, uint256 minExpected) internal pure {
        if (minExpected == 0) return;
        if (actual < minExpected) revert SlippageProtectionFailed(minExpected, actual);
    }
}
