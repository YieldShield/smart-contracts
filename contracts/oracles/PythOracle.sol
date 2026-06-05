// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { OracleValidationLib } from "../libraries/OracleValidationLib.sol";
import { SequencerUptimeGuard } from "./SequencerUptimeGuard.sol";

/// @title PythOracle
/// @author David Hawig
/// @notice Price oracle implementation using Pyth Network's pull integration
/// @dev Implements IPriceOracle and IOracleFeed interfaces using Pyth Network price feeds with staleness checks.
///      All price outputs are normalized to 8 decimals (USD format) regardless of source feed precision.
contract PythOracle is IPriceOracle, IOracleFeed, SequencerUptimeGuard {
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

    /// @notice Optional per-feed price age override. Zero means use maxPriceAge.
    /// @dev Used for quote legs in composite feeds so a slow redemption-rate
    ///      base feed does not implicitly relax a fast quote/USD market feed.
    mapping(bytes32 => uint256) public maxPriceAgeForFeedId;

    /// @notice Maximum publish-time distance between composite base and quote feeds.
    /// @dev Applies to both spot and EMA composite reads.
    uint256 public maxCompositePublishTimeSkew;

    mapping(address => uint256) public scheduledTokenRemovalTime;

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

    /// @notice Emitted when a per-feed max price age is updated
    event MaxPriceAgeForFeedIdUpdated(bytes32 indexed feedId, uint256 oldAge, uint256 newAge);

    /// @notice Emitted when composite feed publish-time skew tolerance is updated
    event MaxCompositePublishTimeSkewUpdated(uint256 oldSkew, uint256 newSkew);

    /// @notice Emitted when max price deviation is updated
    event MaxPriceDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);

    /// @notice Emitted when max accepted Pyth confidence interval is updated
    event MaxConfidenceBpsUpdated(uint256 oldConfidenceBps, uint256 newConfidenceBps);

    /// @notice Emitted when the EMA confidence threshold is updated (M-6)
    event MaxEmaConfidenceBpsUpdated(uint256 oldConfidenceBps, uint256 newConfidenceBps);

    /// @notice Emitted when price feeds are updated
    event PriceFeedsUpdated(bytes32[] feedIds);

    event TokenRemovalScheduled(address indexed token, uint256 executableAt);
    event TokenRemovalCancelled(address indexed token);

    /// @notice Emitted when a stale price is detected
    event StalePriceDetected(address indexed token, bytes32 indexed feedId, uint64 publishTime);

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for stale price
    error StalePrice(address token, bytes32 feedId, uint64 publishTime, uint256 maxAge);

    /// @notice Custom error for prices published after the current block timestamp
    error FuturePrice(address token, bytes32 feedId, uint256 publishTime, uint256 currentTime);

    /// @notice Custom error for invalid price feed ID
    error InvalidPriceFeedId(bytes32 feedId);

    /// @notice Custom error for insufficient update fee
    error InsufficientUpdateFee(uint256 required, uint256 provided);

    /// @notice Custom error for price deviation exceeding threshold
    /// @dev Reverted when spot price deviates too much from EMA, indicating potential manipulation
    error PriceDeviationTooHigh(uint256 spotPrice, uint256 emaPrice, uint256 deviation, uint256 maxDeviation);

    /// @notice Custom error for failed ETH refund
    error EtherRefundFailed();

    /// @notice Custom error for exact-fee update calls with a mismatched payment
    error UnexpectedUpdateFee(uint256 required, uint256 provided);

    /// @notice Custom error for invalid refund recipient
    error InvalidRefundRecipient(address recipient);

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

    error InvalidCompositePublishTimeSkew(uint256 provided, uint256 minimum);

    /// @notice Maximum allowed maxPriceAge value (24 hours)
    uint256 public constant MAX_PRICE_AGE_LIMIT = 86_400;
    uint256 public constant DEFAULT_COMPOSITE_PUBLISH_TIME_SKEW = 300;

    uint256 public constant TOKEN_REMOVAL_DELAY = 1 days;
    uint256 public constant TOKEN_REMOVAL_EXPIRY = 7 days;

    error TokenRemovalNotScheduled(address token);
    error TokenRemovalTooEarly(address token, uint256 executableAt);
    error TokenRemovalExpired(address token, uint256 expiredAt);

    /// @notice Custom error for invalid price deviation setting
    error InvalidDeviation(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for invalid price confidence setting
    error InvalidConfidenceBps(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for Pyth price confidence exceeding threshold
    error PriceConfidenceTooWide(address token, uint256 confidence, uint256 price, uint256 maxConfidenceBps);

    /// @notice Custom error when composite base and quote publish times diverge too far
    error CompositePublishTimeSkewTooHigh(
        address token,
        bytes32 baseFeedId,
        bytes32 quoteFeedId,
        uint256 basePublishTime,
        uint256 quotePublishTime,
        uint256 maxSkew
    );
    error CompositePriceConfidenceTooWide(address token, uint256 combinedConfidenceBps, uint256 maxConfidenceBps);

    /// @notice Constructor
    /// @param _pythAddress The address of the Pyth contract on the current network
    /// @param _maxPriceAge The maximum age of price data in seconds (default: 60)
    constructor(address _pythAddress, uint256 _maxPriceAge) SequencerUptimeGuard() {
        if (_pythAddress == address(0)) revert("Invalid Pyth address");
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        pyth = IPyth(_pythAddress);
        maxPriceAge = _maxPriceAge;
        maxPriceDeviation = 500; // Default 5% deviation threshold
        maxConfidenceBps = 200; // Default 2% spot confidence threshold
        maxEmaConfidenceBps = 1000; // Default 10% EMA confidence threshold (M-6)
        maxCompositePublishTimeSkew = DEFAULT_COMPOSITE_PUBLISH_TIME_SKEW;
    }

    /// @notice Update price feeds with given update data
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @dev Caller must send enough ETH to cover the update fee
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
        _updatePriceFeeds(priceUpdateData, msg.sender);
    }

    /// @notice Update price feeds and refund excess ETH to an explicit recipient
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @param refundRecipient Recipient for any ETH above the Pyth update fee
    /// @dev Useful for contract callers that cannot safely receive native-token refunds.
    function updatePriceFeedsWithRefundRecipient(bytes[] calldata priceUpdateData, address refundRecipient)
        external
        payable
    {
        _requireRefundRecipient(refundRecipient);
        _updatePriceFeeds(priceUpdateData, refundRecipient);
    }

    /// @notice Update price feeds only when the caller provides exactly the Pyth fee
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @dev Avoids any refund path and reverts on both underpayment and overpayment.
    // slither-disable-next-line arbitrary-send-eth
    function updatePriceFeedsExact(bytes[] calldata priceUpdateData) external payable {
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value != updateFee) {
            revert UnexpectedUpdateFee(updateFee, msg.value);
        }

        pyth.updatePriceFeeds{ value: updateFee }(priceUpdateData);
    }

    /// @notice Update price feeds only if Pyth reports an update is still necessary
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @param priceIds Feed IDs to compare against the provided publish times
    /// @param publishTimes Expected publish times for each feed ID
    function updatePriceFeedsIfNecessary(
        bytes[] calldata priceUpdateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable {
        _updatePriceFeedsIfNecessary(priceUpdateData, priceIds, publishTimes, msg.sender);
    }

    /// @notice Update price feeds if necessary and refund excess ETH to an explicit recipient
    /// @param priceUpdateData Array of price update data from Pyth's Hermes API
    /// @param priceIds Feed IDs to compare against the provided publish times
    /// @param publishTimes Expected publish times for each feed ID
    /// @param refundRecipient Recipient for any ETH above the Pyth update fee
    function updatePriceFeedsIfNecessaryWithRefundRecipient(
        bytes[] calldata priceUpdateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes,
        address refundRecipient
    ) external payable {
        _requireRefundRecipient(refundRecipient);
        _updatePriceFeedsIfNecessary(priceUpdateData, priceIds, publishTimes, refundRecipient);
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
        _clearTokenMaxPriceAge(token);
        _clearScheduledTokenRemoval(token);

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
        if (maxCompositePublishTimeSkew == 0) revert InvalidCompositePublishTimeSkew(0, 1);

        tokenToPriceFeedId[token] = baseFeedId;
        tokenToQuotePriceFeedId[token] = quoteUsdFeedId;
        isTokenSupported[token] = true;
        _clearTokenMaxPriceAge(token);
        _clearScheduledTokenRemoval(token);

        emit TokenCompositePriceFeedSet(token, baseFeedId, quoteUsdFeedId);
    }

    /// @notice Remove support for a token
    /// @param token The token address to remove
    function scheduleRemoveToken(address token) external onlyOwner {
        if (!isTokenSupported[token]) revert TokenNotSupported(token);
        uint256 executableAt = block.timestamp + TOKEN_REMOVAL_DELAY;
        scheduledTokenRemovalTime[token] = executableAt;
        emit TokenRemovalScheduled(token, executableAt);
    }

    function cancelScheduledRemoveToken(address token) external onlyOwner {
        if (scheduledTokenRemovalTime[token] == 0) revert TokenRemovalNotScheduled(token);
        delete scheduledTokenRemovalTime[token];
        emit TokenRemovalCancelled(token);
    }

    function _clearScheduledTokenRemoval(address token) internal {
        if (scheduledTokenRemovalTime[token] != 0) {
            delete scheduledTokenRemovalTime[token];
            emit TokenRemovalCancelled(token);
        }
    }

    function _clearTokenMaxPriceAge(address token) internal {
        uint256 oldAge = maxPriceAgeForToken[token];
        if (oldAge != 0) {
            delete maxPriceAgeForToken[token];
            emit MaxPriceAgeForTokenUpdated(token, oldAge, 0);
        }
    }

    function removeToken(address token) external onlyOwner {
        _consumeScheduledTokenRemoval(token);
        delete tokenToPriceFeedId[token];
        delete tokenToQuotePriceFeedId[token];
        delete maxPriceAgeForToken[token];
        isTokenSupported[token] = false;

        emit TokenPriceFeedSet(token, bytes32(0));
    }

    function _consumeScheduledTokenRemoval(address token) internal {
        uint256 executableAt = scheduledTokenRemovalTime[token];
        if (executableAt == 0) revert TokenRemovalNotScheduled(token);
        if (block.timestamp < executableAt) revert TokenRemovalTooEarly(token, executableAt);
        uint256 expiresAt = executableAt + TOKEN_REMOVAL_EXPIRY;
        if (block.timestamp >= expiresAt) {
            delete scheduledTokenRemovalTime[token];
            revert TokenRemovalExpired(token, expiresAt);
        }
        delete scheduledTokenRemovalTime[token];
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

    /// @notice Set a per-feed max price age used by composite quote legs.
    /// @dev Set to 0 to clear the override and revert to maxPriceAge.
    function setMaxPriceAgeForFeedId(bytes32 feedId, uint256 _maxPriceAge) external onlyOwner {
        if (feedId == bytes32(0)) revert InvalidPriceFeedId(feedId);
        if (_maxPriceAge != 0 && _maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        uint256 oldAge = maxPriceAgeForFeedId[feedId];
        maxPriceAgeForFeedId[feedId] = _maxPriceAge;
        emit MaxPriceAgeForFeedIdUpdated(feedId, oldAge, _maxPriceAge);
    }

    /// @notice Set max publish-time skew between composite base and quote feeds.
    function setMaxCompositePublishTimeSkew(uint256 maxSkew) external onlyOwner {
        if (maxSkew == 0) revert InvalidCompositePublishTimeSkew(maxSkew, 1);
        if (maxSkew > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(maxSkew, MAX_PRICE_AGE_LIMIT);
        uint256 oldSkew = maxCompositePublishTimeSkew;
        maxCompositePublishTimeSkew = maxSkew;
        emit MaxCompositePublishTimeSkewUpdated(oldSkew, maxSkew);
    }

    /// @notice Resolve the effective max-price-age for a token.
    function effectiveMaxPriceAge(address token) public view returns (uint256) {
        uint256 perToken = maxPriceAgeForToken[token];
        return perToken == 0 ? maxPriceAge : perToken;
    }

    /// @notice Resolve the effective max-price-age for an individual feed ID.
    function effectiveMaxPriceAgeForFeedId(bytes32 feedId) public view returns (uint256) {
        uint256 perFeed = maxPriceAgeForFeedId[feedId];
        return perFeed == 0 ? maxPriceAge : perFeed;
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

    /// @notice Whether this feed exposes protected `getPrice` and explicit unsafe pricing for `token`.
    function supportsCircuitBreaker(address token) external view returns (bool) {
        return isTokenSupported[token];
    }

    /// @notice Whether this token feed satisfies the strict protected-price policy.
    /// @dev Pyth's protected path checks freshness, confidence width, and spot/EMA deviation.
    function supportsStrictProtectedPrice(address token) external view returns (bool) {
        return isTokenSupported[token];
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

        uint256 baseMaxAge = effectiveMaxPriceAge(token);
        (bool baseSpotStale, uint64 baseSpotPublishTime) = _isFeedStale(feedId, baseMaxAge, false);
        (bool baseEmaStale, uint64 baseEmaPublishTime) = _isFeedStale(feedId, baseMaxAge, true);
        bool baseStale = baseSpotStale || baseEmaStale;
        uint64 baseOldestPublishTime = _olderPublishTime(baseSpotPublishTime, baseEmaPublishTime);
        if (quoteFeedId == bytes32(0)) {
            return (baseStale, baseOldestPublishTime);
        }

        uint256 quoteMaxAge = effectiveMaxPriceAgeForFeedId(quoteFeedId);
        (bool quoteSpotStale, uint64 quoteSpotPublishTime) = _isFeedStale(quoteFeedId, quoteMaxAge, false);
        (bool quoteEmaStale, uint64 quoteEmaPublishTime) = _isFeedStale(quoteFeedId, quoteMaxAge, true);
        bool quoteStale = quoteSpotStale || quoteEmaStale;
        uint64 quoteOldestPublishTime = _olderPublishTime(quoteSpotPublishTime, quoteEmaPublishTime);
        uint64 oldestPublishTime = _olderPublishTime(baseOldestPublishTime, quoteOldestPublishTime);
        bool spotSkewStale = _isCompositePublishTimeSkewTooHigh(baseSpotPublishTime, quoteSpotPublishTime);
        bool emaSkewStale = _isCompositePublishTimeSkewTooHigh(baseEmaPublishTime, quoteEmaPublishTime);
        return (baseStale || quoteStale || spotSkewStale || emaSkewStale, oldestPublishTime);
    }

    /// @notice Get the update fee for price feeds
    /// @param priceUpdateData Array of price update data
    /// @return fee The required fee in wei
    function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee) {
        return pyth.getUpdateFee(priceUpdateData);
    }

    function _updatePriceFeeds(bytes[] calldata priceUpdateData, address refundRecipient) internal {
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value < updateFee) {
            revert InsufficientUpdateFee(updateFee, msg.value);
        }

        // slither-disable-next-line arbitrary-send-eth — ETH forwarded to trusted Pyth contract; excess refunded below
        pyth.updatePriceFeeds{ value: updateFee }(priceUpdateData);
        _refundExcess(refundRecipient, msg.value - updateFee);
    }

    function _updatePriceFeedsIfNecessary(
        bytes[] calldata priceUpdateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes,
        address refundRecipient
    ) internal {
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value < updateFee) {
            revert InsufficientUpdateFee(updateFee, msg.value);
        }

        // slither-disable-next-line arbitrary-send-eth — ETH forwarded to trusted Pyth contract; excess refunded below
        pyth.updatePriceFeedsIfNecessary{ value: updateFee }(priceUpdateData, priceIds, publishTimes);
        _refundExcess(refundRecipient, msg.value - updateFee);
    }

    function _requireRefundRecipient(address refundRecipient) internal pure {
        if (refundRecipient == address(0)) revert InvalidRefundRecipient(refundRecipient);
    }

    function _refundExcess(address refundRecipient, uint256 refundAmount) internal {
        if (refundAmount == 0) {
            return;
        }
        (bool success,) = payable(refundRecipient).call{ value: refundAmount }("");
        if (!success) revert EtherRefundFailed();
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
            uint256 scale = _pythPriceScaleOrRevert(token, uint256(uint32(adjustment)));
            uint256 unsignedPrice = uint256(price);
            if (unsignedPrice > type(uint256).max / scale) revert InvalidPrice(token, 0);
            result = unsignedPrice * scale;
        } else {
            // Need to divide: price / 10^(-adjustment).
            // Truncation can yield zero for tiny prices with very negative expo;
            // fail closed so a silent zero never propagates into composition.
            result = uint256(price) / _pythPriceScaleOrRevert(token, uint256(uint32(-adjustment)));
        }
        if (result == 0) revert InvalidPrice(token, 0);
        return result;
    }

    function _pythPriceScaleOrRevert(address token, uint256 exponent) internal pure returns (uint256) {
        if (exponent > 77) revert InvalidPrice(token, 0);
        return 10 ** exponent;
    }

    function _validateConfidence(address token, PythStructs.Price memory priceData, bool useEma)
        internal
        view
        returns (uint256 confidenceBps)
    {
        if (priceData.price <= 0) {
            return 0;
        }
        uint256 price = uint256(uint64(priceData.price));
        uint256 confidence = uint256(priceData.conf);
        // M-6: EMA conf is systematically wider than spot during volatility —
        // exactly when we want EMA as a stable fallback. Use a relaxed
        // threshold for EMA so the protected path doesn't revert in shocks.
        uint256 threshold = useEma ? maxEmaConfidenceBps : maxConfidenceBps;
        confidenceBps = Math.mulDiv(confidence, 10_000, price, Math.Rounding.Ceil);
        if (confidenceBps > threshold) {
            revert PriceConfidenceTooWide(token, confidence, price, threshold);
        }
    }

    function _getPythPrice(address token, bool useEma) internal view returns (uint256) {
        // SEC-01: reject prices read while the L2 sequencer is down or within its
        // post-restart grace period. Every Pyth read funnels through here.
        _checkSequencerUptime();
        bytes32 feedId = _getFeedId(token);
        (uint256 basePrice, uint256 basePublishTime, uint256 baseConfidenceBps) =
            _readPythPrice(token, feedId, useEma, effectiveMaxPriceAge(token));

        bytes32 quoteFeedId = tokenToQuotePriceFeedId[token];
        if (quoteFeedId == bytes32(0)) {
            return basePrice;
        }

        (uint256 quoteUsdPrice, uint256 quotePublishTime, uint256 quoteConfidenceBps) =
            _readPythPrice(token, quoteFeedId, useEma, effectiveMaxPriceAgeForFeedId(quoteFeedId));
        _validateCompositePublishTimeSkew(token, feedId, quoteFeedId, basePublishTime, quotePublishTime);
        _validateCompositeConfidence(token, baseConfidenceBps, quoteConfidenceBps, useEma);
        return Math.mulDiv(basePrice, quoteUsdPrice, 1e8);
    }

    function _readPythPrice(address token, bytes32 feedId, bool useEma, uint256 priceAge)
        internal
        view
        returns (uint256 price, uint256 publishTime, uint256 confidenceBps)
    {
        PythStructs.Price memory priceData = useEma ? pyth.getEmaPriceUnsafe(feedId) : pyth.getPriceUnsafe(feedId);
        _validatePublishTimeNotFuture(token, feedId, priceData.publishTime);
        _validatePriceNotStale(token, feedId, priceData.publishTime, priceAge);
        confidenceBps = _validateConfidence(token, priceData, useEma);
        price = _convertPrice(token, priceData);
        publishTime = priceData.publishTime;
    }

    function _validateCompositeConfidence(
        address token,
        uint256 baseConfidenceBps,
        uint256 quoteConfidenceBps,
        bool useEma
    ) internal view {
        uint256 combinedConfidenceBps = baseConfidenceBps + quoteConfidenceBps
            + Math.mulDiv(baseConfidenceBps, quoteConfidenceBps, 10_000, Math.Rounding.Ceil);
        uint256 threshold = useEma ? maxEmaConfidenceBps : maxConfidenceBps;
        if (combinedConfidenceBps > threshold) {
            revert CompositePriceConfidenceTooWide(token, combinedConfidenceBps, threshold);
        }
    }

    function _validatePublishTimeNotFuture(address token, bytes32 feedId, uint256 publishTime) internal view {
        uint256 currentTime = block.timestamp;
        if (publishTime > currentTime) {
            revert FuturePrice(token, feedId, publishTime, currentTime);
        }
    }

    function _validateCompositePublishTimeSkew(
        address token,
        bytes32 baseFeedId,
        bytes32 quoteFeedId,
        uint256 basePublishTime,
        uint256 quotePublishTime
    ) internal view {
        if (_isCompositePublishTimeSkewTooHigh(basePublishTime, quotePublishTime)) {
            revert CompositePublishTimeSkewTooHigh(
                token, baseFeedId, quoteFeedId, basePublishTime, quotePublishTime, maxCompositePublishTimeSkew
            );
        }
    }

    function _isCompositePublishTimeSkewTooHigh(uint256 basePublishTime, uint256 quotePublishTime)
        internal
        view
        returns (bool)
    {
        uint256 maxSkew = maxCompositePublishTimeSkew;
        uint256 skew = basePublishTime > quotePublishTime
            ? basePublishTime - quotePublishTime
            : quotePublishTime - basePublishTime;
        return skew > maxSkew;
    }

    function _isFeedStale(bytes32 feedId, uint256 priceAge, bool useEma)
        internal
        view
        returns (bool isStale, uint64 publishTime)
    {
        if (useEma) {
            try pyth.getEmaPriceUnsafe(feedId) returns (PythStructs.Price memory priceData) {
                return _isPriceDataStale(priceData, priceAge);
            } catch {
                return (true, 0);
            }
        } else {
            try pyth.getPriceUnsafe(feedId) returns (PythStructs.Price memory priceData) {
                return _isPriceDataStale(priceData, priceAge);
            } catch {
                return (true, 0);
            }
        }
    }

    function _isPriceDataStale(PythStructs.Price memory priceData, uint256 priceAge)
        internal
        view
        returns (bool isStale, uint64 publishTime)
    {
        uint256 rawPublishTime = priceData.publishTime;
        uint256 currentTime = block.timestamp;
        publishTime = rawPublishTime > type(uint64).max ? type(uint64).max : SafeCast.toUint64(rawPublishTime);
        if (rawPublishTime > currentTime) {
            return (true, publishTime);
        }
        isStale = (currentTime - rawPublishTime) > priceAge;
    }

    function _validatePriceNotStale(address token, bytes32 feedId, uint256 publishTime, uint256 priceAge)
        internal
        view
    {
        if (block.timestamp - publishTime > priceAge) {
            uint64 boundedPublishTime =
                publishTime > type(uint64).max ? type(uint64).max : SafeCast.toUint64(publishTime);
            revert StalePrice(token, feedId, boundedPublishTime, priceAge);
        }
    }

    function _olderPublishTime(uint64 a, uint64 b) internal pure returns (uint64) {
        if (a == 0 || b == 0) return 0;
        return a < b ? a : b;
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
        // EMA is the stable fallback; if EMA itself is unusable there is nothing
        // safer to return, so let that revert propagate (fail closed).
        uint256 emaPrice = _getPythPrice(token, true);
        if (emaPrice == 0) revert InvalidEMAPrice(token, emaPrice);

        // INC-02: this helper must degrade — not revert — during volatility. The
        // spot read can revert on wide confidence / staleness (exactly when the
        // EMA fallback is wanted), so route it through an external self-call to
        // catch that and fall back to EMA. `_getPythPrice` is internal, so a
        // try/catch needs an external boundary.
        try this.getPythPriceExternal(token, false) returns (uint256 spotPrice) {
            uint256 deviation = _calculateDeviation(spotPrice, emaPrice);
            if (deviation > maxPriceDeviation) {
                return (emaPrice, false);
            }
            // Spot price passed circuit breaker check.
            return (spotPrice, true);
        } catch {
            // Spot unusable during volatility: degrade to EMA, mark unreliable.
            return (emaPrice, false);
        }
    }

    /// @notice External self-call shim so `getPriceWithFallback` can `try/catch`
    ///         the spot read. `_getPythPrice` is internal and try/catch requires
    ///         an external call. Not for protected write paths — use `getPrice`.
    /// @param token The token address
    /// @param useEma Whether to read the EMA price instead of the spot price
    /// @return price The price in USD with 8 decimals
    function getPythPriceExternal(address token, bool useEma) external view returns (uint256 price) {
        return _getPythPrice(token, useEma);
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
