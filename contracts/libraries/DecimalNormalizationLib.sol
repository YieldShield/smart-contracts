// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title DecimalNormalizationLib
/// @author David Hawig
/// @notice Library for normalizing decimal precision across price feeds
library DecimalNormalizationLib {
    /// @notice Normalize price from one decimal precision to another
    /// @param price Original price value
    /// @param fromDecimals Original decimal precision
    /// @param toDecimals Target decimal precision
    /// @return Price normalized to target decimals
    function normalize(uint256 price, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return price;
        if (fromDecimals < toDecimals) {
            return price * (10 ** (toDecimals - fromDecimals));
        }
        return price / (10 ** (fromDecimals - toDecimals));
    }
}
