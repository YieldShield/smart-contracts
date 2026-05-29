// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IOracleFeed
/// @author David Hawig
/// @notice Minimal interface for individual price feed sources
/// @dev Used by CompositeOracle to interact with different oracle implementations.
///      `getPrice` is the canonical, safest-available price for the feed: implementations
///      that expose a distinct unprotected variant must publish it under
///      `getPriceUnsafe(address)` (not part of this interface) so consumers can probe for it.
interface IOracleFeed {
    /// @notice Get the safest-available price for a token from this feed
    /// @dev Implementations with a distinct unprotected path (Pyth spot, ERC4626 NAV
    ///      without share-rate cap, etc.) must apply every protection available here
    ///      and expose the raw path under `getPriceUnsafe(address)`.
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
