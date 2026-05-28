// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title OracleValidationLib
/// @author David Hawig
/// @notice Shared validation logic for oracle contracts
/// @dev Centralizes price and staleness validation to reduce code duplication across oracle implementations.
///      All oracle contracts should use this library for consistent error handling.
library OracleValidationLib {
    // ============ Errors ============

    /// @notice Thrown when price is zero or negative
    /// @param token The token address
    /// @param price The invalid price value
    error InvalidPrice(address token, int256 price);

    /// @notice Thrown when price data is stale
    /// @param token The token address
    /// @param updatedAt Timestamp of last price update
    /// @param maxAge Maximum allowed age in seconds
    /// @param currentTime Current block timestamp
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge, uint256 currentTime);

    // ============ Validation Functions ============

    /// @notice Validate that a price is positive (for Chainlink int256 prices)
    /// @param price The price to validate
    /// @param token The token address (for error reporting)
    function validatePositivePrice(int256 price, address token) internal pure {
        if (price <= 0) revert InvalidPrice(token, price);
    }

    /// @notice Validate that a price is non-zero (for uint256 prices)
    /// @param price The price to validate
    /// @param token The token address (for error reporting)
    function validateNonZeroPrice(uint256 price, address token) internal pure {
        if (price == 0) revert InvalidPrice(token, 0);
    }

    /// @notice Validate price staleness
    /// @dev Future-dated `updatedAt` values would otherwise panic via the unsigned
    ///      subtraction below. Fail closed by treating them as stale, since a feed
    ///      reporting a timestamp ahead of `block.timestamp` is either skewed or
    ///      manipulated and should not be silently trusted.
    /// @param updatedAt Timestamp of last price update
    /// @param maxAge Maximum allowed age in seconds
    /// @param token The token address (for error reporting)
    function validateStaleness(uint256 updatedAt, uint256 maxAge, address token) internal view {
        if (updatedAt > block.timestamp) {
            revert StalePrice(token, updatedAt, maxAge, block.timestamp);
        }
        uint256 age = block.timestamp - updatedAt;
        if (age > maxAge) {
            revert StalePrice(token, updatedAt, maxAge, block.timestamp);
        }
    }

    /// @notice Calculate deviation between two prices in basis points
    /// @dev Uses the smaller price as denominator for conservative (larger) deviation percentage.
    ///      Example: $100 vs $90 → diff=10, divides by 90 → 11.1% deviation
    /// @param price1 First price
    /// @param price2 Second price
    /// @return deviationBps Deviation in basis points (0-10000+), or type(uint256).max if either price is 0
    function calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        if (price1 == 0 || price2 == 0) return type(uint256).max;

        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 minPrice = price1 < price2 ? price1 : price2;

        if (diff > type(uint256).max / 10_000) {
            return type(uint256).max;
        }
        return (diff * 10000) / minPrice;
    }
}
