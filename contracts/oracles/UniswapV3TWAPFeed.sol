// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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

    /// @notice Mapping from token to its ERC20 scale
    mapping(address => uint256) public tokenScales;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    mapping(address => uint256) public scheduledTokenPoolRemovalTime;

    /// @notice Minimum harmonic-average pool liquidity required across the TWAP window
    uint128 public minimumAverageLiquidity;

    /// @notice Quote token for USD conversion (e.g., USDC)
    /// @dev I-5 FIX: Made immutable for gas optimization (set only in constructor)
    address public immutable quoteToken;

    /// @notice Oracle for quote token USD price
    IOracleFeed public quoteTokenOracle;

    address public scheduledQuoteTokenOracle;
    uint256 public scheduledQuoteTokenOracleTime;
    uint256 public scheduledQuoteTokenOraclePrice;

    /// @notice ERC20 scale for the quote token
    uint256 public immutable quoteTokenScale;

    /// @notice Emitted when a token pool is set
    event TokenPoolSet(address indexed token, address indexed pool, bool isToken0);

    event TokenPoolRemovalScheduled(address indexed token, uint256 executableAt);
    event TokenPoolRemovalCancelled(address indexed token);

    /// @notice Emitted when TWAP period is updated
    event TWAPPeriodUpdated(uint32 oldPeriod, uint32 newPeriod);

    /// @notice Emitted when quote token oracle is updated
    event QuoteTokenOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Emitted with the old/new quote-token prices observed during an oracle swap (L-6)
    event QuoteTokenOracleSwapPrices(uint256 oldPrice, uint256 newPrice, uint256 deviationBps);
    event QuoteTokenOracleFailoverScheduled(address indexed newOracle, uint256 executableAt);
    event QuoteTokenOracleFailoverCancelled(address indexed newOracle);

    /// @notice Maximum allowed deviation between old and new quote-token oracle prices at swap-time
    uint256 public constant MAX_QUOTE_ORACLE_SWAP_DEVIATION_BPS = 1000; // 10%
    uint256 public constant QUOTE_ORACLE_FAILOVER_DELAY = 1 days;
    uint256 public constant QUOTE_ORACLE_FAILOVER_EXPIRY = 7 days;

    error QuoteOracleSwapDeviationTooHigh(uint256 oldPrice, uint256 newPrice, uint256 deviationBps);
    error QuoteOracleFailoverNotScheduled();
    error QuoteOracleFailoverTooEarly(uint256 executableAt);
    error QuoteOracleFailoverExpired(uint256 expiredAt);

    /// @notice Emitted when minimum average liquidity is updated
    event MinimumAverageLiquidityUpdated(uint128 oldMinimum, uint128 newMinimum);

    /// @notice Minimum allowed TWAP period (5 minutes)
    uint32 public constant MIN_TWAP_PERIOD = 300;

    uint256 public constant TOKEN_POOL_REMOVAL_DELAY = 1 days;
    uint256 public constant TOKEN_POOL_REMOVAL_EXPIRY = 7 days;

    /// @notice Default minimum harmonic-average liquidity across the TWAP window
    uint128 public constant DEFAULT_MINIMUM_AVERAGE_LIQUIDITY = 1_000_000;

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    error TokenPoolRemovalNotScheduled(address token);
    error TokenPoolRemovalTooEarly(address token, uint256 executableAt);
    error TokenPoolRemovalExpired(address token, uint256 expiredAt);

    /// @notice Custom error for invalid pool
    error InvalidPool(address pool);

    /// @notice Custom error for invalid TWAP period
    error InvalidTWAPPeriod(uint32 provided, uint32 minimum);

    /// @notice Custom error when token decimals cannot be queried
    error InvalidTokenDecimals(address token);

    /// @notice Custom error for token decimal configurations that overflow scaling math
    error UnsupportedTokenDecimals(address token, uint8 decimals);

    /// @notice Custom error for pools below the configured average-liquidity floor
    error InsufficientTWAPLiquidity(address pool, uint128 observedLiquidity, uint128 minimumLiquidity);

    /// @notice Thrown when the computed TWAP price truncates to zero after decimal normalization
    error PriceTruncatedToZero(address token);

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
        quoteTokenScale = _getTokenScale(_quoteToken);
        minimumAverageLiquidity = DEFAULT_MINIMUM_AVERAGE_LIQUIDITY;
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

        (, uint160[] memory secondsPerLiquidityCumulativeX128s) = _safeObserveTwapWindow(v3Pool, pool);
        _validateAverageLiquidity(pool, secondsPerLiquidityCumulativeX128s);

        tokenPools[token] = pool;
        isToken0[token] = _isToken0;
        tokenScales[token] = _getTokenScale(token);
        isTokenSupported[token] = true;
        _clearScheduledTokenPoolRemoval(token);

        emit TokenPoolSet(token, pool, _isToken0);
    }

    /// @notice Remove a token pool
    /// @param token The token address
    function scheduleRemoveTokenPool(address token) external onlyOwner {
        if (!isTokenSupported[token]) revert TokenNotSupported(token);
        uint256 executableAt = block.timestamp + TOKEN_POOL_REMOVAL_DELAY;
        scheduledTokenPoolRemovalTime[token] = executableAt;
        emit TokenPoolRemovalScheduled(token, executableAt);
    }

    function cancelScheduledRemoveTokenPool(address token) external onlyOwner {
        if (scheduledTokenPoolRemovalTime[token] == 0) revert TokenPoolRemovalNotScheduled(token);
        delete scheduledTokenPoolRemovalTime[token];
        emit TokenPoolRemovalCancelled(token);
    }

    function _clearScheduledTokenPoolRemoval(address token) internal {
        if (scheduledTokenPoolRemovalTime[token] != 0) {
            delete scheduledTokenPoolRemovalTime[token];
            emit TokenPoolRemovalCancelled(token);
        }
    }

    function removeTokenPool(address token) external onlyOwner {
        _consumeScheduledTokenPoolRemoval(token);
        delete tokenPools[token];
        delete isToken0[token];
        delete tokenScales[token];
        isTokenSupported[token] = false;
        emit TokenPoolSet(token, address(0), false);
    }

    function _consumeScheduledTokenPoolRemoval(address token) internal {
        uint256 executableAt = scheduledTokenPoolRemovalTime[token];
        if (executableAt == 0) revert TokenPoolRemovalNotScheduled(token);
        if (block.timestamp < executableAt) revert TokenPoolRemovalTooEarly(token, executableAt);
        uint256 expiresAt = executableAt + TOKEN_POOL_REMOVAL_EXPIRY;
        if (block.timestamp >= expiresAt) {
            delete scheduledTokenPoolRemovalTime[token];
            revert TokenPoolRemovalExpired(token, expiresAt);
        }
        delete scheduledTokenPoolRemovalTime[token];
    }

    /// @notice Set the TWAP period
    /// @param _twapPeriod New TWAP period in seconds
    function setTWAPPeriod(uint32 _twapPeriod) external onlyOwner {
        if (_twapPeriod < MIN_TWAP_PERIOD) revert InvalidTWAPPeriod(_twapPeriod, MIN_TWAP_PERIOD);
        uint32 oldPeriod = twapPeriod;
        twapPeriod = _twapPeriod;
        emit TWAPPeriodUpdated(oldPeriod, _twapPeriod);
    }

    /// @notice Set the minimum harmonic-average liquidity required across the TWAP window
    /// @dev L-1: zero is rejected because it silently disables manipulation
    ///      protection for every Uniswap-priced asset. Use a separate explicit
    ///      `emergencyDisableLiquidityFloor` (not implemented here) if a real
    ///      emergency requires it; otherwise pick a non-zero floor.
    function setMinimumAverageLiquidity(uint128 newMinimum) external onlyOwner {
        if (newMinimum == 0) revert InvalidPool(address(0));
        uint128 oldMinimum = minimumAverageLiquidity;
        minimumAverageLiquidity = newMinimum;
        emit MinimumAverageLiquidityUpdated(oldMinimum, newMinimum);
    }

    /// @notice Set the quote token oracle
    /// @dev L-6: a swap to a quote oracle whose reported price diverges from
    ///      the existing oracle's by more than MAX_QUOTE_ORACLE_SWAP_DEVIATION_BPS
    ///      is rejected. The quote oracle multiplies every TWAP price; an
    ///      unbounded swap with a wildly inflated quote price would
    ///      mis-value every Uniswap-priced asset in a single tx. Emit
    ///      old/new prices so monitoring can flag suspicious approved swaps.
    /// @param _quoteTokenOracle New quote token oracle address
    function setQuoteTokenOracle(address _quoteTokenOracle) external onlyOwner {
        if (_quoteTokenOracle == address(0)) revert("Invalid quote token oracle");
        address oldOracle = address(quoteTokenOracle);

        if (oldOracle != address(0)) {
            uint256 oldPrice = _getNormalizedQuoteTokenPrice(oldOracle);
            uint256 newPrice = _getNormalizedQuoteTokenPrice(_quoteTokenOracle);
            uint256 deviationBps = _absoluteDeviationBps(oldPrice, newPrice);
            if (deviationBps > MAX_QUOTE_ORACLE_SWAP_DEVIATION_BPS) {
                revert QuoteOracleSwapDeviationTooHigh(oldPrice, newPrice, deviationBps);
            }
            emit QuoteTokenOracleSwapPrices(oldPrice, newPrice, deviationBps);
        }

        quoteTokenOracle = IOracleFeed(_quoteTokenOracle);
        scheduledQuoteTokenOracle = address(0);
        scheduledQuoteTokenOracleTime = 0;
        scheduledQuoteTokenOraclePrice = 0;
        emit QuoteTokenOracleUpdated(oldOracle, _quoteTokenOracle);
    }

    function scheduleQuoteTokenOracleFailover(address _quoteTokenOracle) external onlyOwner {
        if (_quoteTokenOracle == address(0)) revert("Invalid quote token oracle");
        uint256 newPrice = _getNormalizedQuoteTokenPrice(_quoteTokenOracle);

        scheduledQuoteTokenOracle = _quoteTokenOracle;
        scheduledQuoteTokenOracleTime = block.timestamp + QUOTE_ORACLE_FAILOVER_DELAY;
        scheduledQuoteTokenOraclePrice = newPrice;
        emit QuoteTokenOracleFailoverScheduled(_quoteTokenOracle, scheduledQuoteTokenOracleTime);
    }

    function cancelQuoteTokenOracleFailover() external onlyOwner {
        address scheduled = scheduledQuoteTokenOracle;
        scheduledQuoteTokenOracle = address(0);
        scheduledQuoteTokenOracleTime = 0;
        scheduledQuoteTokenOraclePrice = 0;
        emit QuoteTokenOracleFailoverCancelled(scheduled);
    }

    function executeQuoteTokenOracleFailover() external onlyOwner {
        address newOracle = scheduledQuoteTokenOracle;
        uint256 executableAt = scheduledQuoteTokenOracleTime;
        if (newOracle == address(0) || executableAt == 0) revert QuoteOracleFailoverNotScheduled();
        if (block.timestamp < executableAt) revert QuoteOracleFailoverTooEarly(executableAt);
        uint256 expiresAt = executableAt + QUOTE_ORACLE_FAILOVER_EXPIRY;
        if (block.timestamp > expiresAt) revert QuoteOracleFailoverExpired(expiresAt);

        uint256 newPrice = _getNormalizedQuoteTokenPrice(newOracle);
        uint256 scheduledPrice = scheduledQuoteTokenOraclePrice;
        uint256 deviationBps = _absoluteDeviationBps(scheduledPrice, newPrice);
        if (deviationBps > MAX_QUOTE_ORACLE_SWAP_DEVIATION_BPS) {
            revert QuoteOracleSwapDeviationTooHigh(scheduledPrice, newPrice, deviationBps);
        }

        address oldOracle = address(quoteTokenOracle);
        if (oldOracle != address(0)) {
            (bool oldPriceAvailable, uint256 oldPrice) = _tryGetNormalizedQuoteTokenPrice(oldOracle);
            if (oldPriceAvailable) {
                uint256 oldDeviationBps = _absoluteDeviationBps(oldPrice, newPrice);
                emit QuoteTokenOracleSwapPrices(oldPrice, newPrice, oldDeviationBps);
            }
        }
        quoteTokenOracle = IOracleFeed(newOracle);
        scheduledQuoteTokenOracle = address(0);
        scheduledQuoteTokenOracleTime = 0;
        scheduledQuoteTokenOraclePrice = 0;
        emit QuoteTokenOracleSwapPrices(scheduledPrice, newPrice, deviationBps);
        emit QuoteTokenOracleUpdated(oldOracle, newOracle);
    }

    function _absoluteDeviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return type(uint256).max;
        uint256 diff = a > b ? a - b : b - a;
        uint256 anchor = a > b ? b : a; // smaller value as denominator → larger bps
        return FullMath.mulDiv(diff, 10_000, anchor);
    }

    function _getNormalizedQuoteTokenPrice(address oracle) internal view returns (uint256 normalizedPrice) {
        uint256 price = IOracleFeed(oracle).getPrice(quoteToken);
        if (price == 0) revert PriceTruncatedToZero(quoteToken);
        normalizedPrice = price.normalize(IOracleFeed(oracle).decimals(), 18);
        if (normalizedPrice == 0) revert PriceTruncatedToZero(quoteToken);
    }

    function _tryGetNormalizedQuoteTokenPrice(address oracle)
        internal
        view
        returns (bool success, uint256 normalizedPrice)
    {
        try IOracleFeed(oracle).getPrice(quoteToken) returns (uint256 price) {
            if (price == 0) return (false, 0);
            try IOracleFeed(oracle).decimals() returns (uint8 priceDecimals) {
                normalizedPrice = price.normalize(priceDecimals, 18);
                if (normalizedPrice == 0) return (false, 0);
                return (true, normalizedPrice);
            } catch {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc IOracleFeed
    function getPrice(address token) external view override returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        address pool = tokenPools[token];
        bool _isToken0 = isToken0[token];

        // Get liquidity-validated TWAP tick
        int24 twapTick = _getTWAPTick(pool);

        // Convert tick to price
        // price = 1.0001^tick
        // If token is token0, price is in terms of token1 (quoteToken)
        // If token is token1, we need to invert
        uint256 priceInQuoteToken = _getPriceFromTick(twapTick, _isToken0, tokenScales[token], quoteTokenScale);

        uint256 normalizedQuotePrice = _getNormalizedQuoteTokenPrice(address(quoteTokenOracle));

        // Calculate token USD price: priceInQuoteToken * quoteTokenUSDPrice
        // priceInQuoteToken is in 18 decimals, normalizedQuotePrice is in 18 decimals
        uint256 tokenUSDPrice = FullMath.mulDiv(priceInQuoteToken, normalizedQuotePrice, 1e18);

        // Return in 8 decimals. If stacked divisions during normalization
        // truncate to zero (micro-USD-priced assets), fail closed rather than
        // letting downstream consumers treat the asset as worthless.
        uint256 normalized = tokenUSDPrice.normalize(18, 8);
        if (normalized == 0) revert PriceTruncatedToZero(token);
        return normalized;
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
    /// @dev Returns stale if the pool can no longer serve the TWAP window or falls below the liquidity floor.
    /// @return isStale True when the TWAP window is unavailable or below the liquidity floor
    /// @return publishTime Current block timestamp when fresh, zero when stale
    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        if (!isTokenSupported[token]) {
            return (true, 0);
        }

        address pool = tokenPools[token];
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s
        ) {
            if (tickCumulatives.length != 2 || secondsPerLiquidityCumulativeX128s.length != 2) {
                return (true, 0);
            }
            uint128 averageLiquidity = _getAverageLiquidity(secondsPerLiquidityCumulativeX128s);
            uint128 minimumLiquidity = minimumAverageLiquidity;
            if (minimumLiquidity != 0 && averageLiquidity < minimumLiquidity) {
                return (true, 0);
            }
            return (false, uint64(block.timestamp));
        } catch {
            return (true, 0);
        }
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
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            _safeObserveTwapWindow(IUniswapV3Pool(pool), pool);
        _validateAverageLiquidity(pool, secondsPerLiquidityCumulativeX128s);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24(tickCumulativesDelta / int56(int32(twapPeriod)));

        // Round towards negative infinity for consistent pricing
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapPeriod)) != 0)) {
            twapTick--;
        }

        return twapTick;
    }

    /// @notice Convert a tick to a human-unit token price in quote-token terms (18 decimals)
    /// @param tick The tick value
    /// @param _isToken0 Whether the target token is token0
    /// @param tokenScale ERC20 scale for the target token
    /// @param quoteScale ERC20 scale for the quote token
    /// @return price The price in 18 decimals
    function _getPriceFromTick(int24 tick, bool _isToken0, uint256 tokenScale, uint256 quoteScale)
        internal
        pure
        returns (uint256)
    {
        // price = 1.0001^tick, expressed as raw token1 units per raw token0 unit.
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 rawPriceX18;

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            rawPriceX18 =
                _isToken0 ? FullMath.mulDiv(ratioX192, 1e18, 1 << 192) : FullMath.mulDiv(1 << 192, 1e18, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
            rawPriceX18 =
                _isToken0 ? FullMath.mulDiv(ratioX128, 1e18, 1 << 128) : FullMath.mulDiv(1 << 128, 1e18, ratioX128);
        }

        return FullMath.mulDiv(rawPriceX18, tokenScale, quoteScale);
    }

    function _safeObserveTwapWindow(IUniswapV3Pool pool, address poolAddress)
        internal
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (
            int56[] memory observedTickCumulatives, uint160[] memory observedSecondsPerLiquidityCumulativeX128s
        ) {
            tickCumulatives = observedTickCumulatives;
            secondsPerLiquidityCumulativeX128s = observedSecondsPerLiquidityCumulativeX128s;
        } catch {
            revert InvalidPool(poolAddress);
        }

        if (tickCumulatives.length != 2 || secondsPerLiquidityCumulativeX128s.length != 2) {
            revert InvalidPool(poolAddress);
        }
    }

    function _validateAverageLiquidity(address pool, uint160[] memory secondsPerLiquidityCumulativeX128s)
        internal
        view
    {
        uint128 minimumLiquidity = minimumAverageLiquidity;
        if (minimumLiquidity == 0) {
            return;
        }

        uint128 averageLiquidity = _getAverageLiquidity(secondsPerLiquidityCumulativeX128s);
        if (averageLiquidity < minimumLiquidity) {
            revert InsufficientTWAPLiquidity(pool, averageLiquidity, minimumLiquidity);
        }
    }

    function _getAverageLiquidity(uint160[] memory secondsPerLiquidityCumulativeX128s) internal view returns (uint128) {
        if (secondsPerLiquidityCumulativeX128s[1] <= secondsPerLiquidityCumulativeX128s[0]) {
            return 0;
        }
        uint160 delta = secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];
        if (delta == 0) {
            // Fail closed: a zero delta means no liquidity-weighted activity was
            // recorded across the TWAP window (drained pool, observation overflow,
            // freshly re-initialised cardinality). Returning `type(uint128).max`
            // would silently pass the minimum-liquidity floor on the very edge
            // cases the floor is meant to catch.
            return 0;
        }

        uint256 averageLiquidity = (uint256(twapPeriod) << 128) / uint256(delta);
        return averageLiquidity > type(uint128).max ? type(uint128).max : uint128(averageLiquidity);
    }

    function _getTokenScale(address token) internal view returns (uint256) {
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            if (tokenDecimals > 77) {
                revert UnsupportedTokenDecimals(token, tokenDecimals);
            }
            return 10 ** tokenDecimals;
        } catch (bytes memory reason) {
            if (reason.length > 0) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            revert InvalidTokenDecimals(token);
        }
    }
}
