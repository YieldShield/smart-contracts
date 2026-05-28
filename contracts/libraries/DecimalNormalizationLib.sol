// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title DecimalNormalizationLib
/// @author David Hawig
/// @notice Library for normalizing decimal precision across price feeds
library DecimalNormalizationLib {
    error DecimalNormalizationOverflow(uint256 price, uint8 fromDecimals, uint8 toDecimals);

    /// @notice Normalize price from one decimal precision to another
    /// @param price Original price value
    /// @param fromDecimals Original decimal precision
    /// @param toDecimals Target decimal precision
    /// @return Price normalized to target decimals
    function normalize(uint256 price, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return price;
        if (fromDecimals < toDecimals) {
            uint8 exponent = toDecimals - fromDecimals;
            uint256 scale = _pow10OrRevert(price, fromDecimals, toDecimals, exponent);
            if (price > type(uint256).max / scale) {
                revert DecimalNormalizationOverflow(price, fromDecimals, toDecimals);
            }
            return price * scale;
        }
        return price / _pow10OrRevert(price, fromDecimals, toDecimals, fromDecimals - toDecimals);
    }

    function _pow10OrRevert(uint256 price, uint8 fromDecimals, uint8 toDecimals, uint8 exponent)
        private
        pure
        returns (uint256)
    {
        if (exponent > 77) {
            revert DecimalNormalizationOverflow(price, fromDecimals, toDecimals);
        }
        return 10 ** exponent;
    }
}
