// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { SequencerUptimeGuard } from "./SequencerUptimeGuard.sol";

/// @title PythEMAOracleFeed
/// @author David Hawig
/// @notice Oracle feed that returns Pyth EMA prices (stability-focused)
/// @dev Used as a plain-price feed in CompositeOracle dual-feed mode for smoother, more stable pricing.
///      EMA-only pricing intentionally does not advertise the safe/unsafe split (no
///      `getPriceUnsafe(address)` selector); protected pool paths must use a feed that
///      validates spot/EMA deviation or another independent circuit breaker.
///      All price outputs are normalized to 8 decimals (USD format).
/// - getPrice() returns: EMA price with 8 decimals (e.g., $1.00 = 1e8, $1234.56 = 123456000000)
/// - Pyth native feeds may use different exponents (-8, -9, etc) but are normalized to 8 decimals
/// - EMA prices are smoother and less susceptible to short-term manipulation than spot prices
contract PythEMAOracleFeed is IOracleFeed, SequencerUptimeGuard {
    /// @notice Pyth contract instance
    IPyth public immutable pyth;

    /// @notice Maximum age of price data in seconds
    uint256 public maxPriceAge;

    /// @notice Maximum allowed Pyth confidence interval relative to price (basis points, default: 200 = 2%)
    uint256 public maxConfidenceBps;

    /// @notice Mapping from token address to Pyth price feed ID
    mapping(address => bytes32) public tokenToPriceFeedId;

    /// @notice Optional per-token price age override. Zero means use maxPriceAge.
    mapping(address => uint256) public maxPriceAgeForToken;

    mapping(address => uint256) public scheduledTokenRemovalTime;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Emitted when a token's price feed ID is set or updated
    event TokenPriceFeedSet(address indexed token, bytes32 indexed feedId);

    /// @notice Emitted when max price age is updated
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when a per-token max price age is updated
    event MaxPriceAgeForTokenUpdated(address indexed token, uint256 oldAge, uint256 newAge);

    /// @notice Emitted when max accepted Pyth confidence interval is updated
    event MaxConfidenceBpsUpdated(uint256 oldConfidenceBps, uint256 newConfidenceBps);

    event TokenRemovalScheduled(address indexed token, uint256 executableAt);
    event TokenRemovalCancelled(address indexed token);

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for invalid price feed ID
    error InvalidPriceFeedId(bytes32 feedId);
    /// @notice Custom error for invalid/zero price
    error InvalidPrice(address token, int256 price);

    /// @notice Custom error for prices published after the current block timestamp
    error FuturePrice(address token, bytes32 feedId, uint256 publishTime, uint256 currentTime);

    /// @notice Custom error for invalid price age
    error InvalidPriceAge(uint256 provided, uint256 minimum);

    /// @notice Custom error for price age exceeding upper bound
    error PriceAgeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Maximum allowed maxPriceAge value (24 hours)
    uint256 public constant MAX_PRICE_AGE_LIMIT = 86_400;

    uint256 public constant TOKEN_REMOVAL_DELAY = 1 days;
    uint256 public constant TOKEN_REMOVAL_EXPIRY = 7 days;

    error TokenRemovalNotScheduled(address token);
    error TokenRemovalTooEarly(address token, uint256 executableAt);
    error TokenRemovalExpired(address token, uint256 expiredAt);

    /// @notice Custom error for invalid price confidence setting
    error InvalidConfidenceBps(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for Pyth price confidence exceeding threshold
    error PriceConfidenceTooWide(address token, uint256 confidence, uint256 price, uint256 maxConfidenceBps);

    /// @notice Constructor
    /// @param _pythAddress The address of the Pyth contract
    /// @param _maxPriceAge Maximum age of price data in seconds
    constructor(address _pythAddress, uint256 _maxPriceAge) SequencerUptimeGuard() {
        if (_pythAddress == address(0)) revert("Invalid Pyth address");
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        pyth = IPyth(_pythAddress);
        maxPriceAge = _maxPriceAge;
        // M-6: this feed only ever reads EMA prices, so default the confidence
        // threshold to the more permissive EMA band (10%) rather than the
        // 2% spot threshold. Pyth EMA conf is systematically wider during
        // volatile windows — using the spot threshold here causes reverts
        // precisely when an EMA fallback would be most useful.
        maxConfidenceBps = 1000;
    }

    /// @notice Set the price feed ID for a token
    /// @param token The token address
    /// @param feedId The Pyth price feed ID
    function setTokenPriceFeed(address token, bytes32 feedId) external onlyOwner {
        if (token == address(0)) revert("Invalid token address");
        if (feedId == bytes32(0)) revert InvalidPriceFeedId(feedId);

        tokenToPriceFeedId[token] = feedId;
        isTokenSupported[token] = true;
        _clearTokenMaxPriceAge(token);
        _clearScheduledTokenRemoval(token);

        emit TokenPriceFeedSet(token, feedId);
    }

    /// @notice Remove a token's price feed
    /// @param token The token address
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

    /// @notice Resolve the effective max-price-age for a token.
    function effectiveMaxPriceAge(address token) public view returns (uint256) {
        uint256 perToken = maxPriceAgeForToken[token];
        return perToken == 0 ? maxPriceAge : perToken;
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

    /// @inheritdoc IOracleFeed
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    function _getPrice(address token) internal view returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        // SEC-01: reject prices read while the L2 sequencer is down or within its
        // post-restart grace period.
        _checkSequencerUptime();

        bytes32 feedId = tokenToPriceFeedId[token];

        // Get EMA price (time-weighted average, more stable)
        PythStructs.Price memory emaData = pyth.getEmaPriceNoOlderThan(feedId, effectiveMaxPriceAge(token));
        _validatePublishTimeNotFuture(token, feedId, emaData.publishTime);
        _validateConfidence(token, emaData);
        return _convertPrice(token, emaData);
    }

    function _validatePublishTimeNotFuture(address token, bytes32 feedId, uint256 publishTime) internal view {
        uint256 currentTime = block.timestamp;
        if (publishTime > currentTime) {
            revert FuturePrice(token, feedId, publishTime, currentTime);
        }
    }

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Pyth EMA Oracle Feed";
    }

    /// @notice Internal function to convert Pyth price data to 8 decimal format
    /// @param priceData The Pyth price data structure
    /// @return price The price in 8 decimals
    function _convertPrice(address token, PythStructs.Price memory priceData) internal pure returns (uint256) {
        int256 price = priceData.price;
        int32 expo = priceData.expo;
        if (price <= 0) revert InvalidPrice(token, price);

        // Calculate the adjustment needed: 10^(expo + 8)
        int32 adjustment = expo + 8;

        uint256 result;
        if (adjustment == 0) {
            result = uint256(price);
        } else if (adjustment > 0) {
            uint256 scale = _pythPriceScaleOrRevert(token, uint256(uint32(adjustment)));
            uint256 unsignedPrice = uint256(price);
            if (unsignedPrice > type(uint256).max / scale) revert InvalidPrice(token, 0);
            result = unsignedPrice * scale;
        } else {
            result = uint256(price) / _pythPriceScaleOrRevert(token, uint256(uint32(-adjustment)));
        }
        if (result == 0) revert InvalidPrice(token, 0);
        return result;
    }

    function _pythPriceScaleOrRevert(address token, uint256 exponent) internal pure returns (uint256) {
        if (exponent > 77) revert InvalidPrice(token, 0);
        return 10 ** exponent;
    }

    function _validateConfidence(address token, PythStructs.Price memory priceData) internal view {
        if (priceData.price <= 0) {
            return;
        }
        uint256 price = uint256(uint64(priceData.price));
        uint256 confidence = uint256(priceData.conf);
        if (confidence * 10_000 > price * maxConfidenceBps) {
            revert PriceConfidenceTooWide(token, confidence, price, maxConfidenceBps);
        }
    }
}
