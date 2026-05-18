// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { OracleValidationLib } from "../libraries/OracleValidationLib.sol";

/// @title PythOracle
/// @author David Hawig
/// @notice Price oracle implementation using Pyth Network's pull integration
/// @dev Implements IPriceOracle and IOracleFeed interfaces using Pyth Network price feeds with staleness checks.
///      All price outputs are normalized to 8 decimals (USD format) regardless of source feed precision.
contract PythOracle is IPriceOracle, IOracleFeed, Ownable {
    using OracleValidationLib for uint256;

    /// @notice Pyth contract instance
    IPyth public immutable pyth;

    /// @notice Maximum age of price data in seconds (default: 60 seconds)
    uint256 public maxPriceAge;

    /// @notice Maximum allowed deviation between spot and EMA price (in basis points, default: 500 = 5%)
    /// @dev Used by circuit breaker to detect oracle manipulation attempts
    uint256 public maxPriceDeviation;

    /// @notice Maximum allowed Pyth confidence interval relative to price (basis points, default: 200 = 2%)
    uint256 public maxConfidenceBps;

    /// @notice M-6: separate confidence threshold for EMA reads. Pyth's EMA
    ///         conf is systematically wider than spot during volatile windows,
    ///         so EMA needs a more permissive band — otherwise the protected
    ///         circuit-breaker path reverts precisely when EMA is most useful.
    uint256 public maxEmaConfidenceBps;

    /// @notice Mapping from token address to Pyth price feed ID
    mapping(address => bytes32) public tokenToPriceFeedId;

    /// @notice Optional quote/USD feed for redemption-rate feeds (e.g. token/USDS * USDS/USD)
    mapping(address => bytes32) public tokenToQuotePriceFeedId;

    /// @notice Optional per-token price age override. Zero means use maxPriceAge.
    mapping(address => uint256) public maxPriceAgeForToken;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Emitted when a token's price feed ID is set or updated
    event TokenPriceFeedSet(address indexed token, bytes32 indexed feedId);

    /// @notice Emitted when a token's composite price feed IDs are set or updated
    event TokenCompositePriceFeedSet(address indexed token, bytes32 indexed baseFeedId, bytes32 indexed quoteFeedId);

    /// @notice Emitted when max price age is updated
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when a per-token max price age is updated
    event MaxPriceAgeForTokenUpdated(address indexed token, uint256 oldAge, uint256 newAge);

    /// @notice Emitted when max price deviation is updated
    event MaxPriceDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);

    /// @notice Emitted when max accepted Pyth confidence interval is updated
    event MaxConfidenceBpsUpdated(uint256 oldConfidenceBps, uint256 newConfidenceBps);

    /// @notice Emitted when the EMA confidence threshold is updated (M-6)
    event MaxEmaConfidenceBpsUpdated(uint256 oldConfidenceBps, uint256 newConfidenceBps);

    /// @notice Emitted when price feeds are updated
    event PriceFeedsUpdated(bytes32[] feedIds);

    /// @notice Emitted when a stale price is detected
    event StalePriceDetected(address indexed token, bytes32 indexed feedId, uint64 publishTime);

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for stale price
    error StalePrice(address token, bytes32 feedId, uint64 publishTime, uint256 maxAge);

    /// @notice Custom error for invalid price feed ID
    error InvalidPriceFeedId(bytes32 feedId);

    /// @notice Custom error for insufficient update fee
    error InsufficientUpdateFee(uint256 required, uint256 provided);

    /// @notice Custom error for price deviation exceeding threshold
    /// @dev Reverted when spot price deviates too much from EMA, indicating potential manipulation
    error PriceDeviationTooHigh(uint256 spotPrice, uint256 emaPrice, uint256 deviation, uint256 maxDeviation);

    /// @notice Custom error for failed ETH refund
    error EtherRefundFailed();

    /// @notice Custom error for invalid/zero EMA price
    error InvalidEMAPrice(address token, uint256 emaPrice);

    /// @notice Custom error for invalid/zero price (division by zero protection)
    error InvalidPrice(address token, uint256 price);

    /// @notice Custom error for non-ERC20 or malformed token metadata
    error InvalidTokenAddress(address token);

    /// @notice Custom error for decimals values unsupported by scaling math
    error InvalidTokenDecimals(address token, uint8 decimals);

    /// @notice Custom error for invalid price age
    error InvalidPriceAge(uint256 provided, uint256 minimum);

    /// @notice Custom error for price age exceeding upper bound
    error PriceAgeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Maximum allowed maxPriceAge value (24 hours)
    uint256 public constant MAX_PRICE_AGE_LIMIT = 86_400;

    /// @notice Custom error for invalid price deviation setting
    error InvalidDeviation(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for invalid price confidence setting
    error InvalidConfidenceBps(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for Pyth price confidence exceeding threshold
    error PriceConfidenceTooWide(address token, uint256 confidence, uint256 price, uint256 maxConfidenceBps);

    /// @notice Constructor
    /// @param _pythAddress The address of the Pyth contract on the current network
    /// @param _maxPriceAge The maximum age of price data in seconds (default: 60)
    constructor(address _pythAddress, uint256 _maxPriceAge) Ownable(msg.sender) {
        if (_pythAddress == address(0)) revert("Invalid Pyth address");
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        pyth = IPyth(_pythAddress);
        maxPriceAge = _maxPriceAge;
        maxPriceDeviation = 500; // Default 5% deviation threshold
        maxConfidenceBps = 200; // Default 2% spot confidence threshold
        maxEmaConfidenceBps = 1000; // Default 10% EMA confidence threshold (M-6)
    }

    /// @notice Update price feeds with given update data
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @dev Caller must send enough ETH to cover the update fee
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value < updateFee) {
            revert InsufficientUpdateFee(updateFee, msg.value);
        }

        // slither-disable-next-line arbitrary-send-eth — ETH forwarded to trusted Pyth contract; excess refunded to caller
        pyth.updatePriceFeeds{ value: updateFee }(priceUpdateData);

        if (msg.value > updateFee) {
            (bool success,) = payable(msg.sender).call{ value: msg.value - updateFee }("");
            if (!success) revert EtherRefundFailed();
        }
    }

    /// @notice Set the price feed ID for a token
    /// @param token The token address
    /// @param feedId The Pyth price feed ID for the token
    function setTokenPriceFeed(address token, bytes32 feedId) external onlyOwner {
        if (token == address(0)) revert("Invalid token address");
        if (feedId == bytes32(0)) revert InvalidPriceFeedId(feedId);

        tokenToPriceFeedId[token] = feedId;
        tokenToQuotePriceFeedId[token] = bytes32(0);
        isTokenSupported[token] = true;

        emit TokenPriceFeedSet(token, feedId);
    }

    /// @notice Set a composite price feed for a token quoted against a non-USD asset
    /// @param token The token address
    /// @param baseFeedId The Pyth feed ID for token/quote
    /// @param quoteUsdFeedId The Pyth feed ID for quote/USD
    function setTokenCompositePriceFeed(address token, bytes32 baseFeedId, bytes32 quoteUsdFeedId) external onlyOwner {
        if (token == address(0)) revert("Invalid token address");
        if (baseFeedId == bytes32(0)) revert InvalidPriceFeedId(baseFeedId);
        if (quoteUsdFeedId == bytes32(0)) revert InvalidPriceFeedId(quoteUsdFeedId);

        tokenToPriceFeedId[token] = baseFeedId;
        tokenToQuotePriceFeedId[token] = quoteUsdFeedId;
        isTokenSupported[token] = true;

        emit TokenCompositePriceFeedSet(token, baseFeedId, quoteUsdFeedId);
    }

    /// @notice Remove support for a token
    /// @param token The token address to remove
    function removeToken(address token) external onlyOwner {
        delete tokenToPriceFeedId[token];
        delete tokenToQuotePriceFeedId[token];
        isTokenSupported[token] = false;

        emit TokenPriceFeedSet(token, bytes32(0));
    }

    /// @notice Set the maximum age for price data
    /// @param _maxPriceAge The maximum age in seconds (minimum 10)
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        uint256 oldAge = maxPriceAge;
        maxPriceAge = _maxPriceAge;

        emit MaxPriceAgeUpdated(oldAge, _maxPriceAge);
    }

    /// @notice Set a per-token max price age that overrides the global value.
    /// @dev Set to 0 to clear the override and revert to maxPriceAge.
    function setMaxPriceAgeForToken(address token, uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge != 0 && _maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        uint256 oldAge = maxPriceAgeForToken[token];
        maxPriceAgeForToken[token] = _maxPriceAge;
        emit MaxPriceAgeForTokenUpdated(token, oldAge, _maxPriceAge);
    }

    /// @notice Resolve the effective max-price-age for a token.
    function effectiveMaxPriceAge(address token) public view returns (uint256) {
        uint256 perToken = maxPriceAgeForToken[token];
        return perToken == 0 ? maxPriceAge : perToken;
    }

    /// @notice Set the maximum allowed price deviation between spot and EMA
    /// @dev Allows owner to configure circuit breaker sensitivity (1%-50% range)
    /// @param _maxPriceDeviation Maximum deviation in basis points (e.g., 500 = 5%)
    function setMaxPriceDeviation(uint256 _maxPriceDeviation) external onlyOwner {
        if (_maxPriceDeviation < 100 || _maxPriceDeviation > 5000) {
            revert InvalidDeviation(_maxPriceDeviation, 100, 5000);
        }
        uint256 oldDeviation = maxPriceDeviation;
        maxPriceDeviation = _maxPriceDeviation;

        emit MaxPriceDeviationUpdated(oldDeviation, _maxPriceDeviation);
    }

    /// @notice Set the maximum accepted Pyth confidence interval relative to price
    /// @param _maxConfidenceBps Maximum confidence interval in basis points (0.1%-50%)
    function setMaxConfidenceBps(uint256 _maxConfidenceBps) external onlyOwner {
        if (_maxConfidenceBps < 10 || _maxConfidenceBps > 5000) {
            revert InvalidConfidenceBps(_maxConfidenceBps, 10, 5000);
        }
        uint256 oldConfidenceBps = maxConfidenceBps;
        maxConfidenceBps = _maxConfidenceBps;
        emit MaxConfidenceBpsUpdated(oldConfidenceBps, _maxConfidenceBps);
    }

    /// @notice Set the maximum accepted EMA confidence interval relative to price (M-6)
    /// @param _maxEmaConfidenceBps Maximum confidence interval in basis points (0.1%-50%)
    function setMaxEmaConfidenceBps(uint256 _maxEmaConfidenceBps) external onlyOwner {
        if (_maxEmaConfidenceBps < 10 || _maxEmaConfidenceBps > 5000) {
            revert InvalidConfidenceBps(_maxEmaConfidenceBps, 10, 5000);
        }
        uint256 oldConfidenceBps = maxEmaConfidenceBps;
        maxEmaConfidenceBps = _maxEmaConfidenceBps;
        emit MaxEmaConfidenceBpsUpdated(oldConfidenceBps, _maxEmaConfidenceBps);
    }

    /// @notice Get the protected (circuit-breaker validated) price for a token
    /// @dev Compares spot price to EMA and reverts if deviation exceeds threshold.
    ///      Production callers must use this entry point; raw spot-only pricing is
    ///      available via `getPriceUnsafe`.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPrice(address token) external view override(IPriceOracle, IOracleFeed) returns (uint256) {
        return _getPriceWithCircuitBreaker(token);
    }

    /// @notice Get the raw spot price without spot/EMA deviation validation
    /// @dev Reserved for read-only callers; production write paths must use `getPrice`.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPriceUnsafe(address token) external view override returns (uint256) {
        return _getPythPrice(token, false);
    }

    /// @notice Calculate the protected USD value of an amount of tokens
    /// @dev Uses the same circuit-breaker-validated price as `getPrice`.
    function getValue(address token, uint256 amount) external view override returns (uint256) {
        return _getValueForPrice(token, amount, _getPriceWithCircuitBreaker(token));
    }

    /// @notice Unprotected USD value getter (bypasses spot/EMA circuit-breaker check)
    function getValueUnsafe(address token, uint256 amount) external view override returns (uint256) {
        return _getValueForPrice(token, amount, _getPythPrice(token, false));
    }

    /// @notice Calculate how many tokenB are needed to match the value of tokenA amount
    /// @dev Uses the circuit-breaker-validated prices for both tokens (safe default).
    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        uint256 priceA = _getPriceWithCircuitBreaker(tokenA);
        uint256 priceB = _getPriceWithCircuitBreaker(tokenB);

        if (priceB == 0) revert InvalidPrice(tokenB, priceB);

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    /// @notice Unprotected equivalent-amount calculator (bypasses spot/EMA circuit-breaker check)
    function getEquivalentAmountUnsafe(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        uint256 priceA = _getPythPrice(tokenA, false);
        uint256 priceB = _getPythPrice(tokenB, false);

        if (priceB == 0) revert InvalidPrice(tokenB, priceB);

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    /// @notice Check if a price is stale for a given token
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return publishTime The publish time of the current price
    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        bytes32 feedId = _getFeedId(token);
        bytes32 quoteFeedId = tokenToQuotePriceFeedId[token];

        (bool baseStale, uint64 basePublishTime) = _isFeedStale(token, feedId);
        if (quoteFeedId == bytes32(0)) {
            return (baseStale, basePublishTime);
        }

        (bool quoteStale, uint64 quotePublishTime) = _isFeedStale(token, quoteFeedId);
        uint64 oldestPublishTime = basePublishTime < quotePublishTime ? basePublishTime : quotePublishTime;
        return (baseStale || quoteStale, oldestPublishTime);
    }

    /// @notice Get the update fee for price feeds
    /// @param priceUpdateData Array of price update data
    /// @return fee The required fee in wei
    function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee) {
        return pyth.getUpdateFee(priceUpdateData);
    }

    /// @notice Internal function to get feed ID for a token
    /// @param token The token address
    /// @return feedId The price feed ID
    /// @dev Reverts if token is not supported
    function _getFeedId(address token) internal view returns (bytes32 feedId) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }
        feedId = tokenToPriceFeedId[token];
        if (feedId == bytes32(0)) {
            revert TokenNotSupported(token);
        }
    }

    /// @notice Internal function to convert Pyth price data to 8 decimal format
    /// @param priceData The Pyth price data structure
    /// @return price The price in 8 decimals
    function _convertPrice(address token, PythStructs.Price memory priceData) internal pure returns (uint256) {
        int256 price = priceData.price;
        int32 expo = priceData.expo;
        if (price <= 0) revert InvalidPrice(token, 0);

        // Calculate the adjustment needed: 10^(expo + 8)
        int32 adjustment = expo + 8;

        uint256 result;
        if (adjustment == 0) {
            // Already in 8 decimals
            result = uint256(price);
        } else if (adjustment > 0) {
            // Need to multiply: price * 10^adjustment
            result = uint256(price) * uint256(10 ** uint256(uint32(adjustment)));
        } else {
            // Need to divide: price / 10^(-adjustment).
            // Truncation can yield zero for tiny prices with very negative expo;
            // fail closed so a silent zero never propagates into composition.
            result = uint256(price) / uint256(10 ** uint256(uint32(-adjustment)));
        }
        if (result == 0) revert InvalidPrice(token, 0);
        return result;
    }

    function _validateConfidence(address token, PythStructs.Price memory priceData, bool useEma) internal view {
        if (priceData.price <= 0) {
            return;
        }
        uint256 price = uint256(uint64(priceData.price));
        uint256 confidence = uint256(priceData.conf);
        // M-6: EMA conf is systematically wider than spot during volatility —
        // exactly when we want EMA as a stable fallback. Use a relaxed
        // threshold for EMA so the protected path doesn't revert in shocks.
        uint256 threshold = useEma ? maxEmaConfidenceBps : maxConfidenceBps;
        if (confidence * 10_000 > price * threshold) {
            revert PriceConfidenceTooWide(token, confidence, price, threshold);
        }
    }

    function _getPythPrice(address token, bool useEma) internal view returns (uint256) {
        bytes32 feedId = _getFeedId(token);
        uint256 basePrice = _readPythPrice(token, feedId, useEma);

        bytes32 quoteFeedId = tokenToQuotePriceFeedId[token];
        if (quoteFeedId == bytes32(0)) {
            return basePrice;
        }

        uint256 quoteUsdPrice = _readPythPrice(token, quoteFeedId, useEma);
        return Math.mulDiv(basePrice, quoteUsdPrice, 1e8);
    }

    function _readPythPrice(address token, bytes32 feedId, bool useEma) internal view returns (uint256) {
        PythStructs.Price memory priceData;
        if (useEma) {
            priceData = pyth.getEmaPriceNoOlderThan(feedId, effectiveMaxPriceAge(token));
        } else {
            priceData = pyth.getPriceNoOlderThan(feedId, effectiveMaxPriceAge(token));
        }
        _validateConfidence(token, priceData, useEma);
        return _convertPrice(token, priceData);
    }

    function _isFeedStale(address token, bytes32 feedId) internal view returns (bool isStale, uint64 publishTime) {
        try pyth.getPriceUnsafe(feedId) returns (PythStructs.Price memory priceData) {
            uint256 rawPublishTime = priceData.publishTime;
            uint256 currentTime = block.timestamp;
            publishTime = rawPublishTime > type(uint64).max ? type(uint64).max : SafeCast.toUint64(rawPublishTime);
            if (rawPublishTime > currentTime) {
                return (true, publishTime);
            }
            isStale = (currentTime - rawPublishTime) > effectiveMaxPriceAge(token);
        } catch {
            isStale = true;
            publishTime = 0;
        }
    }

    /// @dev Calculate price deviation in basis points using OracleValidationLib
    /// @param spotPrice The spot price
    /// @param emaPrice The EMA price
    /// @return deviation The deviation in basis points (0-10000+), type(uint256).max if either is 0
    function _calculateDeviation(uint256 spotPrice, uint256 emaPrice) internal pure returns (uint256) {
        return OracleValidationLib.calculateDeviation(spotPrice, emaPrice);
    }

    /// @dev Internal helper backing `getPrice` / `getValue` / `getEquivalentAmount`.
    ///      Compares spot price to EMA and reverts if deviation exceeds the configured
    ///      threshold, providing defence against oracle manipulation attacks.
    function _getPriceWithCircuitBreaker(address token) internal view returns (uint256) {
        uint256 spotPrice = _getPythPrice(token, false);
        uint256 emaPrice = _getPythPrice(token, true);

        // Prevent division by zero in deviation calculation
        if (emaPrice == 0) revert InvalidEMAPrice(token, emaPrice);

        uint256 deviation = _calculateDeviation(spotPrice, emaPrice);
        if (deviation > maxPriceDeviation) {
            revert PriceDeviationTooHigh(spotPrice, emaPrice, deviation, maxPriceDeviation);
        }

        return spotPrice;
    }

    // ============ Graceful Degradation (R3 Implementation) ============

    /// @notice Get price with graceful fallback to EMA if circuit breaker triggers
    /// @dev Instead of reverting during high volatility, returns EMA price with reliability flag.
    ///      This prevents users from being trapped during short-term volatility events.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    /// @return isReliable True if spot price passed circuit breaker, false if using EMA fallback
    function getPriceWithFallback(address token) external view returns (uint256 price, bool isReliable) {
        uint256 spotPrice = _getPythPrice(token, false);
        uint256 emaPrice = _getPythPrice(token, true);

        // Prevent division by zero in deviation calculation
        if (emaPrice == 0) revert InvalidEMAPrice(token, emaPrice);

        // Calculate deviation and check threshold
        uint256 deviation = _calculateDeviation(spotPrice, emaPrice);
        if (deviation > maxPriceDeviation) {
            return (emaPrice, false);
        }

        // Spot price passed circuit breaker check
        return (spotPrice, true);
    }

    /// @notice Get value with graceful fallback to EMA if circuit breaker triggers
    /// @param token The token address
    /// @param amount The amount of tokens in the token's native ERC20 units
    /// @return value The value in USD with 8 decimals
    /// @return isReliable True if spot price passed circuit breaker, false if using EMA fallback
    function getValueWithFallback(address token, uint256 amount)
        external
        view
        returns (uint256 value, bool isReliable)
    {
        (uint256 price, bool reliable) = this.getPriceWithFallback(token);
        return (_getValueForPrice(token, amount, price), reliable);
    }

    /// @notice Get EMA price directly (for stability-focused pricing)
    /// @param token The token address
    /// @return price The EMA price in USD with 8 decimals
    function getEmaPrice(address token) external view returns (uint256) {
        return _getPythPrice(token, true);
    }

    // ============ IOracleFeed Interface Implementation ============

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Pyth Network Price Oracle";
    }

    function _getValueForPrice(address token, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, _getTokenScale(token));
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
        uint8 tokenDecimals = 0;
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert InvalidTokenAddress(token);
        }

        if (tokenDecimals > 77) revert InvalidTokenDecimals(token, tokenDecimals);
        tokenScale = 10 ** tokenDecimals;
    }
}
