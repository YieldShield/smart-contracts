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

    /// @notice Thrown when price deviation exceeds threshold
    /// @param token The token address
    /// @param price1 First price value
    /// @param price2 Second price value
    /// @param deviationBps Actual deviation in basis points
    /// @param maxDeviationBps Maximum allowed deviation
    error PriceDeviationExceeded(
        address token, uint256 price1, uint256 price2, uint256 deviationBps, uint256 maxDeviationBps
    );

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
    /// @param updatedAt Timestamp of last price update
    /// @param maxAge Maximum allowed age in seconds
    /// @param token The token address (for error reporting)
    function validateStaleness(uint256 updatedAt, uint256 maxAge, address token) internal view {
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

        return (diff * 10000) / minPrice;
    }

    /// @notice Validate that price deviation is within threshold
    /// @param price1 First price
    /// @param price2 Second price
    /// @param maxDeviationBps Maximum allowed deviation in basis points
    /// @param token The token address (for error reporting)
    function validateDeviation(uint256 price1, uint256 price2, uint256 maxDeviationBps, address token) internal pure {
        uint256 deviation = calculateDeviation(price1, price2);
        if (deviation > maxDeviationBps) {
            revert PriceDeviationExceeded(token, price1, price2, deviation, maxDeviationBps);
        }
    }

    /// @notice Check if price deviation exceeds threshold (non-reverting)
    /// @param price1 First price
    /// @param price2 Second price
    /// @param maxDeviationBps Maximum allowed deviation in basis points
    /// @return exceeds True if deviation exceeds threshold
    /// @return deviation The calculated deviation in basis points
    function checkDeviation(uint256 price1, uint256 price2, uint256 maxDeviationBps)
        internal
        pure
        returns (bool exceeds, uint256 deviation)
    {
        deviation = calculateDeviation(price1, price2);
        exceeds = deviation > maxDeviationBps;
    }
}
