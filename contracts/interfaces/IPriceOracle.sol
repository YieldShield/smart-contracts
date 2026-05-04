// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPriceOracle
/// @author David Hawig
/// @notice Interface for price oracle contracts
/// @dev Used to get token prices and calculate equivalent amounts between different tokens
interface IPriceOracle {
    /**
     * @notice Calculate how many tokenB are needed to match the value of tokenA amount
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     */
    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB) external view returns (uint256);

    /**
     * @notice Get the price for a token
     * @param token The token address
     * @return price The price in USD with 8 decimals
     */
    function getPrice(address token) external view returns (uint256);

    /**
     * @notice Calculate the value of an amount of tokens in USD
     * @param token The token address
     * @param amount The amount of tokens in the token's native ERC20 units
     * @return value The value in USD with 8 decimals
     */
    function getValue(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Get price with circuit breaker protection (compares spot vs EMA)
     * @dev Reverts if spot price deviates too much from EMA price.
     *      This prevents oracle manipulation attacks by detecting sudden price swings.
     *      that could be used to drain pool funds via cross-asset withdrawals.
     * @param token The token address
     * @return price The spot price in USD with 8 decimals (if within deviation threshold)
     */
    function getPriceWithCircuitBreaker(address token) external view returns (uint256);

    /**
     * @notice Calculate equivalent amount with circuit breaker protection
     * @dev Uses circuit breaker protected prices for both tokens.
     *      Prevents manipulation during deposit collateral calculations.
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     */
    function getEquivalentAmountWithCircuitBreaker(address tokenA, uint256 amountA, address tokenB)
        external
        view
        returns (uint256);
}
