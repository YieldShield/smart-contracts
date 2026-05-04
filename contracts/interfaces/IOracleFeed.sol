// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IOracleFeed
/// @author David Hawig
/// @notice Minimal interface for individual price feed sources
/// @dev Used by CompositeOracle to interact with different oracle implementations
interface IOracleFeed {
    /// @notice Get the price for a token
    /// @param token The token address
    /// @return price The price in USD with decimals as specified by decimals()
    function getPrice(address token) external view returns (uint256 price);

    /// @notice Get the number of decimals for price values
    /// @return decimals The number of decimals (typically 8 for USD prices)
    function decimals() external view returns (uint8);

    /// @notice Get a human-readable description of the feed
    /// @return description A string describing the oracle feed
    function description() external view returns (string memory);
}
