// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title PythEMAOracleFeed
/// @author David Hawig
/// @notice Oracle feed that returns Pyth EMA prices (stability-focused)
/// @dev Used as primary feed in CompositeOracle dual-feed mode for smoother, more stable pricing
///      All price outputs are normalized to 8 decimals (USD format).
/// - getPrice() returns: EMA price with 8 decimals (e.g., $1.00 = 1e8, $1234.56 = 123456000000)
/// - Pyth native feeds may use different exponents (-8, -9, etc) but are normalized to 8 decimals
/// - EMA prices are smoother and less susceptible to short-term manipulation than spot prices
contract PythEMAOracleFeed is IOracleFeed, Ownable {
    /// @notice Pyth contract instance
    IPyth public immutable pyth;

    /// @notice Maximum age of price data in seconds
    uint256 public maxPriceAge;

    /// @notice Maximum allowed Pyth confidence interval relative to price (basis points, default: 200 = 2%)
    uint256 public maxConfidenceBps;

    /// @notice Mapping from token address to Pyth price feed ID
    mapping(address => bytes32) public tokenToPriceFeedId;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Emitted when a token's price feed ID is set or updated
    event TokenPriceFeedSet(address indexed token, bytes32 indexed feedId);

    /// @notice Emitted when max price age is updated
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for invalid price feed ID
    error InvalidPriceFeedId(bytes32 feedId);
    /// @notice Custom error for invalid/zero price
    error InvalidPrice(address token, int256 price);

    /// @notice Custom error for invalid price age
    error InvalidPriceAge(uint256 provided, uint256 minimum);

    /// @notice Custom error for price age exceeding upper bound
    error PriceAgeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Maximum allowed maxPriceAge value (1 hour)
    uint256 public constant MAX_PRICE_AGE_LIMIT = 3600;

    /// @notice Custom error for invalid price confidence setting
    error InvalidConfidenceBps(uint256 provided, uint256 min, uint256 max);

    /// @notice Custom error for Pyth price confidence exceeding threshold
    error PriceConfidenceTooWide(address token, uint256 confidence, uint256 price, uint256 maxConfidenceBps);

    /// @notice Constructor
    /// @param _pythAddress The address of the Pyth contract
    /// @param _maxPriceAge Maximum age of price data in seconds
    constructor(address _pythAddress, uint256 _maxPriceAge) Ownable(msg.sender) {
        if (_pythAddress == address(0)) revert("Invalid Pyth address");
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        pyth = IPyth(_pythAddress);
        maxPriceAge = _maxPriceAge;
        maxConfidenceBps = 200;
    }

    /// @notice Set the price feed ID for a token
    /// @param token The token address
    /// @param feedId The Pyth price feed ID
    function setTokenPriceFeed(address token, bytes32 feedId) external onlyOwner {
        if (token == address(0)) revert("Invalid token address");
        if (feedId == bytes32(0)) revert InvalidPriceFeedId(feedId);

        tokenToPriceFeedId[token] = feedId;
        isTokenSupported[token] = true;

        emit TokenPriceFeedSet(token, feedId);
    }

    /// @notice Remove a token's price feed
    /// @param token The token address
    function removeToken(address token) external onlyOwner {
        delete tokenToPriceFeedId[token];
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

    /// @notice Set the maximum accepted Pyth confidence interval relative to price
    /// @param _maxConfidenceBps Maximum confidence interval in basis points (0.1%-50%)
    function setMaxConfidenceBps(uint256 _maxConfidenceBps) external onlyOwner {
        if (_maxConfidenceBps < 10 || _maxConfidenceBps > 5000) {
            revert InvalidConfidenceBps(_maxConfidenceBps, 10, 5000);
        }
        maxConfidenceBps = _maxConfidenceBps;
    }

    /// @inheritdoc IOracleFeed
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Get the EMA price through the protected-price selector used by CompositeOracle strict validation.
    /// @dev EMA pricing is already the stability-focused path and is bounded by Pyth's staleness check.
    function getPriceWithCircuitBreaker(address token) external view returns (uint256) {
        return _getPrice(token);
    }

    function _getPrice(address token) internal view returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        bytes32 feedId = tokenToPriceFeedId[token];

        // Get EMA price (time-weighted average, more stable)
        PythStructs.Price memory emaData = pyth.getEmaPriceNoOlderThan(feedId, maxPriceAge);
        _validateConfidence(token, emaData);
        return _convertPrice(token, emaData);
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

        if (adjustment == 0) {
            return uint256(price);
        } else if (adjustment > 0) {
            return uint256(price) * uint256(10 ** uint256(uint32(adjustment)));
        } else {
            return uint256(price) / uint256(10 ** uint256(uint32(-adjustment)));
        }
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
