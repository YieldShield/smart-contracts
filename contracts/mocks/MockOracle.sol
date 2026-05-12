// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";

/// @title MockOracle
/// @author David Hawig
/// @notice Mock price oracle for testing purposes
/// @dev Returns hardcoded prices for tokens, simulating a real oracle like Chainlink
contract MockOracle is IPriceOracle, IOracleFeed, Ownable {
    /// @notice Mapping from token address to price in USD (with 8 decimals precision)
    mapping(address => uint256) internal _prices;

    /// @notice Mapping to track if a price was explicitly set (allows setting to 0)
    mapping(address => bool) internal _priceIsSet;

    /// @notice Flag to make getEquivalentAmount revert (for testing fallback paths)
    bool public shouldRevertOnEquivalent;

    /// @notice Flag to make circuit-breaker-protected price reads revert
    bool public shouldRevertOnCircuitBreaker;

    /// @notice Emitted when a price is updated
    event PriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);

    /// @notice Custom error for controlled revert
    error MockOracleRevert();
    error MockCircuitBreakerTriggered(address token);
    error InvalidTokenAddress(address token);
    error InvalidTokenDecimals(address token, uint8 decimals);

    constructor() Ownable(msg.sender) { }

    /// @notice Set whether getEquivalentAmount should revert
    /// @param _shouldRevert True to make getEquivalentAmount revert
    function setShouldRevertOnEquivalent(bool _shouldRevert) external onlyOwner {
        shouldRevertOnEquivalent = _shouldRevert;
    }

    /// @notice Set whether circuit-breaker price reads should revert
    /// @param _shouldRevert True to make getPriceWithCircuitBreaker revert
    function setShouldRevertOnCircuitBreaker(bool _shouldRevert) external onlyOwner {
        shouldRevertOnCircuitBreaker = _shouldRevert;
    }

    /**
     * @notice Set the price for a token
     * @param token The token address
     * @param price The price in USD with 8 decimals (e.g., 1 USD = 1e8)
     * @dev Setting to 0 will make oracle return 0 (for testing zero price handling)
     */
    function setPrice(address token, uint256 price) external onlyOwner {
        uint256 oldPrice = _prices[token];
        _prices[token] = price;
        _priceIsSet[token] = true;
        emit PriceUpdated(token, oldPrice, price);
    }

    /**
     * @notice Get the price for a token
     * @param token The token address
     * @return price The price in USD with 8 decimals
     * @dev Returns $1.00 (1e8) as default if price is not set
     *      Returns 0 if explicitly set to 0 (for testing zero price scenarios)
     */
    function getPrice(address token) external view override(IPriceOracle, IOracleFeed) returns (uint256) {
        if (!_priceIsSet[token]) {
            return 1e8; // Default to $1.00 (8 decimals)
        }
        return _prices[token];
    }

    /**
     * @notice Calculate the value of an amount of tokens in USD
     * @param token The token address
     * @param amount The amount of tokens in the token's native ERC20 units
     * @return value The value in USD with 8 decimals
     * @dev Returns value based on $1.00 default if price is not set
     */
    function getValue(address token, uint256 amount) external view override returns (uint256) {
        uint256 price = _priceIsSet[token] ? _prices[token] : 1e8;
        return Math.mulDiv(amount, price, _getTokenScale(token));
    }

    /**
     * @notice Calculate how many tokenB are needed to match the value of tokenA amount
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     * @dev Returns equivalent amount based on $1.00 default for any unset prices
     */
    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        if (shouldRevertOnEquivalent) revert MockOracleRevert();

        uint256 priceA = _priceIsSet[tokenA] ? _prices[tokenA] : 1e8;
        uint256 priceB = _priceIsSet[tokenB] ? _prices[tokenB] : 1e8;

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    /**
     * @notice Get price with circuit breaker protection (mock - same as getPrice)
     * @dev In mock oracle, no EMA available, so just returns spot price
     *      This allows tests to work without Pyth infrastructure
     * @param token The token address
     * @return price The price in USD with 8 decimals
     */
    function getPriceWithCircuitBreaker(address token) external view override returns (uint256) {
        if (shouldRevertOnCircuitBreaker) revert MockCircuitBreakerTriggered(token);
        if (!_priceIsSet[token]) {
            return 1e8; // Default to $1.00 (8 decimals)
        }
        return _prices[token];
    }

    /**
     * @notice Calculate equivalent amount with circuit breaker (mock - same as getEquivalentAmount)
     * @dev In mock oracle, no EMA available, so just returns standard calculation
     *      This allows tests to work without Pyth infrastructure
     * @param tokenA The first token address
     * @param amountA The amount of tokenA in tokenA's native ERC20 units
     * @param tokenB The second token address
     * @return amountB The amount of tokenB in tokenB's native ERC20 units
     */
    function getEquivalentAmountWithCircuitBreaker(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        if (shouldRevertOnCircuitBreaker) revert MockCircuitBreakerTriggered(tokenA);
        uint256 priceA = _priceIsSet[tokenA] ? _prices[tokenA] : 1e8;
        uint256 priceB = _priceIsSet[tokenB] ? _prices[tokenB] : 1e8;

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    // ============ IOracleFeed Implementation ============

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Mock Oracle Feed";
    }

    /**
     * @notice Check if price is stale for a token
     * @dev Mock oracle prices never go stale - always returns false
     *      This prevents false "stale price" warnings in the frontend
     * @param token The token address (unused, but required for interface)
     * @return isStale Always false - mock prices don't expire
     * @return publishTime Current block timestamp
     */
    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        token; // Silence unused parameter warning
        return (false, uint64(block.timestamp));
    }

    function _getEquivalentAmountForPrices(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 priceA,
        uint256 priceB
    ) internal view returns (uint256) {
        uint256 amountAValueUsd = Math.mulDiv(amountA, priceA, _getTokenScale(tokenA));
        return Math.mulDiv(amountAValueUsd, _getTokenScale(tokenB), priceB);
    }

    function _getTokenScale(address token) internal view returns (uint256 tokenScale) {
        uint8 tokenDecimals;
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert InvalidTokenAddress(token);
        }

        if (tokenDecimals > 77) revert InvalidTokenDecimals(token, tokenDecimals);
        tokenScale = 10 ** tokenDecimals;
    }
}
