// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { DecimalNormalizationLib } from "../libraries/DecimalNormalizationLib.sol";
import { FullMath } from "./libraries/FullMath.sol";
import { TickMath } from "./libraries/TickMath.sol";

/// @title IUniswapV3Pool
/// @notice Minimal interface for Uniswap V3 pools needed for TWAP
interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title UniswapV3TWAPFeed
/// @author David Hawig
/// @notice Oracle feed that calculates TWAP from Uniswap V3 pools
/// @dev Provides manipulation-resistant pricing for tokens with liquid on-chain markets
///      All price outputs are normalized to 8 decimals (USD format).
/// - getPrice() returns: TWAP price with 8 decimals (e.g., $1.00 = 1e8)
/// - Uniswap V3 tick prices are converted to sqrtPriceX96 format and normalized
/// - Quote token oracle MUST also return 8 decimal prices for proper USD conversion
contract UniswapV3TWAPFeed is IOracleFeed, Ownable {
    using DecimalNormalizationLib for uint256;
    /// @notice TWAP observation period in seconds (default: 30 minutes)

    uint32 public twapPeriod;

    /// @notice Mapping from token address to Uniswap V3 pool address
    mapping(address => address) public tokenPools;

    /// @notice Mapping from token to whether it's token0 in the pool
    mapping(address => bool) public isToken0;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Quote token for USD conversion (e.g., USDC)
    /// @dev I-5 FIX: Made immutable for gas optimization (set only in constructor)
    address public immutable quoteToken;

    /// @notice Oracle for quote token USD price
    IOracleFeed public quoteTokenOracle;

    /// @notice Emitted when a token pool is set
    event TokenPoolSet(address indexed token, address indexed pool, bool isToken0);

    /// @notice Emitted when TWAP period is updated
    event TWAPPeriodUpdated(uint32 oldPeriod, uint32 newPeriod);

    /// @notice Emitted when quote token oracle is updated
    event QuoteTokenOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Minimum allowed TWAP period (5 minutes)
    uint32 public constant MIN_TWAP_PERIOD = 300;

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for invalid pool
    error InvalidPool(address pool);

    /// @notice Custom error for invalid TWAP period
    error InvalidTWAPPeriod(uint32 provided, uint32 minimum);

    /// @notice Constructor
    /// @param _twapPeriod TWAP observation period in seconds
    /// @param _quoteToken Quote token address (e.g., USDC)
    /// @param _quoteTokenOracle Oracle for quote token USD price
    constructor(uint32 _twapPeriod, address _quoteToken, address _quoteTokenOracle) Ownable(msg.sender) {
        if (_twapPeriod < MIN_TWAP_PERIOD) revert InvalidTWAPPeriod(_twapPeriod, MIN_TWAP_PERIOD);
        if (_quoteToken == address(0)) revert("Invalid quote token");
        if (_quoteTokenOracle == address(0)) revert("Invalid quote token oracle");

        twapPeriod = _twapPeriod;
        quoteToken = _quoteToken;
        quoteTokenOracle = IOracleFeed(_quoteTokenOracle);
    }

    /// @notice Set the Uniswap V3 pool for a token
    /// @param token The token address
    /// @param pool The Uniswap V3 pool address (token paired with quoteToken)
    function setTokenPool(address token, address pool) external onlyOwner {
        if (token == address(0)) revert("Invalid token address");
        if (pool == address(0)) revert InvalidPool(pool);

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);

        // Verify pool contains the token
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();

        bool _isToken0 = false;
        if (token0 == token && token1 == quoteToken) {
            _isToken0 = true;
        } else if (token1 == token && token0 == quoteToken) {
            _isToken0 = false;
        } else {
            revert InvalidPool(pool);
        }

        // Note: No cardinality pre-check. pool.observe() will revert if TWAP history is insufficient.

        tokenPools[token] = pool;
        isToken0[token] = _isToken0;
        isTokenSupported[token] = true;

        emit TokenPoolSet(token, pool, _isToken0);
    }

    /// @notice Remove a token pool
    /// @param token The token address
    function removeTokenPool(address token) external onlyOwner {
        delete tokenPools[token];
        delete isToken0[token];
        isTokenSupported[token] = false;
        emit TokenPoolSet(token, address(0), false);
    }

    /// @notice Set the TWAP period
    /// @param _twapPeriod New TWAP period in seconds
    function setTWAPPeriod(uint32 _twapPeriod) external onlyOwner {
        if (_twapPeriod < MIN_TWAP_PERIOD) revert InvalidTWAPPeriod(_twapPeriod, MIN_TWAP_PERIOD);
        uint32 oldPeriod = twapPeriod;
        twapPeriod = _twapPeriod;
        emit TWAPPeriodUpdated(oldPeriod, _twapPeriod);
    }

    /// @notice Set the quote token oracle
    /// @param _quoteTokenOracle New quote token oracle address
    function setQuoteTokenOracle(address _quoteTokenOracle) external onlyOwner {
        if (_quoteTokenOracle == address(0)) revert("Invalid quote token oracle");
        address oldOracle = address(quoteTokenOracle);
        quoteTokenOracle = IOracleFeed(_quoteTokenOracle);
        emit QuoteTokenOracleUpdated(oldOracle, _quoteTokenOracle);
    }

    /// @inheritdoc IOracleFeed
    function getPrice(address token) external view override returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        address pool = tokenPools[token];
        bool _isToken0 = isToken0[token];

        // Get TWAP tick
        int24 twapTick = _getTWAPTick(pool);

        // Convert tick to price
        // price = 1.0001^tick
        // If token is token0, price is in terms of token1 (quoteToken)
        // If token is token1, we need to invert
        uint256 priceInQuoteToken = _getPriceFromTick(twapTick, _isToken0);

        // Convert quote token price to USD
        uint256 quoteTokenUSDPrice = quoteTokenOracle.getPrice(quoteToken);
        uint8 quoteTokenDecimals = quoteTokenOracle.decimals();

        // Normalize quote token price to 18 decimals
        uint256 normalizedQuotePrice = quoteTokenUSDPrice.normalize(quoteTokenDecimals, 18);

        // Calculate token USD price: priceInQuoteToken * quoteTokenUSDPrice
        // priceInQuoteToken is in 18 decimals, normalizedQuotePrice is in 18 decimals
        uint256 tokenUSDPrice = (priceInQuoteToken * normalizedQuotePrice) / 1e18;

        // Return in 8 decimals
        return tokenUSDPrice.normalize(18, 8);
    }

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Uniswap V3 TWAP Oracle Feed";
    }

    /// @notice Check if a price is stale for a given token
    /// @dev TWAP feeds are inherently fresh if pool.observe() succeeds, so always return not-stale.
    ///      This ensures ERC4626OracleFeed can query staleness on TWAP-backed vaults.
    ///      The address parameter is unused but kept for interface compatibility.
    /// @return isStale Always false (TWAP is computed on-chain from recent observations)
    /// @return publishTime Current block timestamp
    function isPriceStale(address) external view returns (bool isStale, uint64 publishTime) {
        return (false, uint64(block.timestamp));
    }

    /// @notice Get the current spot tick from a pool
    /// @param pool The Uniswap V3 pool address
    /// @return tick The current spot tick
    function getSpotTick(address pool) external view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Get the TWAP tick from a pool
    /// @param pool The Uniswap V3 pool address
    /// @return tick The TWAP tick
    function _getTWAPTick(address pool) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24(tickCumulativesDelta / int56(int32(twapPeriod)));

        // Round towards negative infinity for consistent pricing
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapPeriod)) != 0)) {
            twapTick--;
        }

        return twapTick;
    }

    /// @notice Convert a tick to price (in 18 decimals)
    /// @param tick The tick value
    /// @param _isToken0 Whether the target token is token0
    /// @return price The price in 18 decimals
    function _getPriceFromTick(int24 tick, bool _isToken0) internal pure returns (uint256) {
        // price = 1.0001^tick, expressed as token1 per token0 (Uniswap convention)
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return _isToken0
                ? FullMath.mulDiv(ratioX192, 1e18, 1 << 192)
                : FullMath.mulDiv(1 << 192, 1e18, ratioX192);
        }

        uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
        return _isToken0
            ? FullMath.mulDiv(ratioX128, 1e18, 1 << 128)
            : FullMath.mulDiv(1 << 128, 1e18, ratioX128);
    }
}
