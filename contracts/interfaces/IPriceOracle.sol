// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceOracle
/// @author David Hawig
/// @notice Interface for price oracle contracts
/// @dev Used to get token prices and calculate equivalent amounts between different tokens.
///      The default `getPrice` / `getValue` / `getEquivalentAmount` entry points are the
///      protected (safe) variants: implementations must apply every protection available
///      (e.g. spot/EMA deviation, share-rate cap, dual-feed challenge gate).
///      `*Unsafe` variants exist for the rare callers (off-chain analytics, NFT metadata,
///      legacy view helpers) that consciously opt out of the protection.
interface IPriceOracle {
    /**
     * @notice Calculate how many tokenB are needed to match the value of tokenA amount
     * @dev Uses circuit-breaker protected prices for both tokens (the safe default).
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     */
    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB) external view returns (uint256);

    /**
     * @notice Get the protected (circuit-breaker validated) price for a token
     * @dev Implementations must apply every available circuit-breaker check
     *      (e.g. spot/EMA deviation, share-rate cap, dual-feed challenge gate).
     * @param token The token address
     * @return price The price in USD with 8 decimals
     */
    function getPrice(address token) external view returns (uint256);

    /**
     * @notice Calculate the protected USD value of an amount of tokens
     * @dev Uses the same protected pricing as `getPrice`.
     * @param token The token address
     * @param amount The amount of tokens in the token's native ERC20 units
     * @return value The value in USD with 8 decimals
     */
    function getValue(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Unprotected price getter (bypasses circuit-breaker checks)
     * @dev Reserved for callers that explicitly want the raw active-feed price.
     *      Production write paths must use `getPrice` instead.
     * @param token The token address
     * @return price The price in USD with 8 decimals
     */
    function getPriceUnsafe(address token) external view returns (uint256);

    /**
     * @notice Unprotected USD value getter (bypasses circuit-breaker checks)
     * @dev Reserved for read-only callers; production write paths must use `getValue`.
     * @param token The token address
     * @param amount The amount of tokens in the token's native ERC20 units
     * @return value The value in USD with 8 decimals
     */
    function getValueUnsafe(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Unprotected equivalent-amount calculator (bypasses circuit-breaker checks)
     * @dev Reserved for read-only callers; production write paths must use `getEquivalentAmount`.
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     */
    function getEquivalentAmountUnsafe(address tokenA, uint256 amountA, address tokenB) external view returns (uint256);
}
