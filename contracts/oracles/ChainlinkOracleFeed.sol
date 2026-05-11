// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { DecimalNormalizationLib } from "../libraries/DecimalNormalizationLib.sol";
import { OracleValidationLib } from "../libraries/OracleValidationLib.sol";

/// @title AggregatorV3Interface
/// @notice Minimal interface for Chainlink price feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkOracleFeed
/// @author David Hawig
/// @notice Oracle feed adapter for Chainlink price feeds
/// @dev Implements IOracleFeed interface using Chainlink's AggregatorV3Interface
///      Includes L2 sequencer uptime check for Arbitrum/Optimism/Base deployments
///      All price outputs are normalized to 8 decimals (USD format) regardless of source feed precision.
/// - getPrice() returns: price with 8 decimals (e.g., $1.00 = 1e8, $1234.56 = 123456000000)
/// - Chainlink feeds may use 8, 6, or other decimal formats but are normalized to 8 decimals
/// - The DecimalNormalizationLib handles this conversion automatically
contract ChainlinkOracleFeed is IOracleFeed, Ownable {
    using DecimalNormalizationLib for uint256;

    /// @notice Grace period after sequencer comes back up (1 hour)
    /// @dev Prices may be stale during this period as oracles catch up
    uint256 public constant GRACE_PERIOD_TIME = 3600;

    /// @notice Maximum age of price data in seconds
    uint256 public maxPriceAge;

    /// @notice L2 sequencer uptime feed (optional, only for L2 deployments)
    /// @dev Set to address(0) on L1 or if sequencer check not needed
    AggregatorV3Interface public sequencerUptimeFeed;

    /// @notice Mapping from token address to Chainlink aggregator
    mapping(address => AggregatorV3Interface) public tokenFeeds;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Emitted when a token's feed is set or updated
    event TokenFeedSet(address indexed token, address indexed feed);

    /// @notice Emitted when max price age is updated
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when sequencer uptime feed is set
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);

    /// @notice Custom error for unsupported token
    error TokenNotSupported(address token);

    /// @notice Custom error for stale price
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge);

    /// @notice Custom error for invalid price
    error InvalidPrice(address token, int256 price);

    /// @notice Custom error for invalid feed address
    error InvalidFeedAddress(address feed);

    /// @notice Custom error when L2 sequencer is down
    error SequencerDown();

    /// @notice Custom error when sequencer grace period not over
    /// @param timeSinceUp Seconds since sequencer came back up
    /// @param gracePeriod Required grace period in seconds
    error GracePeriodNotOver(uint256 timeSinceUp, uint256 gracePeriod);

    /// @notice Custom error for invalid price age
    error InvalidPriceAge(uint256 provided, uint256 minimum);

    /// @notice Custom error for price age exceeding upper bound
    error PriceAgeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Maximum allowed maxPriceAge value (1 hour)
    uint256 public constant MAX_PRICE_AGE_LIMIT = 3600;

    /// @notice Constructor
    /// @param _maxPriceAge Maximum age of price data in seconds
    constructor(uint256 _maxPriceAge) Ownable(msg.sender) {
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        maxPriceAge = _maxPriceAge;
    }

    /// @notice Set the Chainlink feed for a token
    /// @param token The token address
    /// @param feed The Chainlink aggregator address
    function setTokenFeed(address token, address feed) external onlyOwner {
        if (token == address(0)) revert InvalidFeedAddress(token);
        if (feed == address(0)) revert InvalidFeedAddress(feed);

        // Verify feed is valid by attempting to read
        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        try aggregator.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            OracleValidationLib.validatePositivePrice(answer, token);
        } catch {
            revert InvalidFeedAddress(feed);
        }

        tokenFeeds[token] = aggregator;
        isTokenSupported[token] = true;

        emit TokenFeedSet(token, feed);
    }

    /// @notice Remove a token feed
    /// @param token The token address to remove
    function removeTokenFeed(address token) external onlyOwner {
        delete tokenFeeds[token];
        isTokenSupported[token] = false;
        emit TokenFeedSet(token, address(0));
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

    /// @notice Set the L2 sequencer uptime feed (for Arbitrum/Optimism/Base)
    /// @dev Set to address(0) to disable sequencer check (for L1 or if not needed)
    /// @param _sequencerUptimeFeed The Chainlink sequencer uptime feed address
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyOwner {
        address oldFeed = address(sequencerUptimeFeed);

        // If setting a non-zero address, verify the feed is valid
        if (_sequencerUptimeFeed != address(0)) {
            AggregatorV3Interface feed = AggregatorV3Interface(_sequencerUptimeFeed);
            // Verify feed responds correctly
            try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
                // Sequencer status: 0 = up, 1 = down
                // Just verify we can read it, don't validate the value
                if (answer != 0 && answer != 1) {
                    revert InvalidFeedAddress(_sequencerUptimeFeed);
                }
            } catch {
                revert InvalidFeedAddress(_sequencerUptimeFeed);
            }
        }

        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        emit SequencerUptimeFeedSet(oldFeed, _sequencerUptimeFeed);
    }

    /// @inheritdoc IOracleFeed
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Get the price through the protected-price selector used by CompositeOracle strict validation.
    /// @dev Chainlink protection is provided by stale-round, answered-in-round, and optional sequencer checks.
    function getPriceWithCircuitBreaker(address token) external view returns (uint256) {
        return _getPrice(token);
    }

    function _getPrice(address token) internal view returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        // L2 sequencer uptime check (only if sequencer feed is configured)
        _checkSequencerUptime();

        AggregatorV3Interface feed = tokenFeeds[token];

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        // Validate price data using shared library
        OracleValidationLib.validatePositivePrice(answer, token);
        if (answeredInRound < roundId) revert StalePrice(token, updatedAt, maxPriceAge);
        OracleValidationLib.validateStaleness(updatedAt, maxPriceAge, token);

        // Convert to 8 decimals if necessary
        uint8 feedDecimals = feed.decimals();
        return uint256(answer).normalize(feedDecimals, 8);
    }

    /// @inheritdoc IOracleFeed
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IOracleFeed
    function description() external pure override returns (string memory) {
        return "Chainlink Oracle Feed";
    }

    /// @notice Get the decimals of a specific token's feed
    /// @param token The token address
    /// @return The number of decimals for the feed
    function getTokenFeedDecimals(address token) external view returns (uint8) {
        AggregatorV3Interface feed = tokenFeeds[token];
        if (address(feed) == address(0)) revert TokenNotSupported(token);
        return feed.decimals();
    }

    /// @notice Check if a price is stale for a given token
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return updatedAt The timestamp of the last update
    function isPriceStale(address token) external view returns (bool isStale, uint256 updatedAt) {
        if (!isTokenSupported[token]) {
            return (true, 0);
        }

        AggregatorV3Interface feed = tokenFeeds[token];
        (,,, uint256 _updatedAt,) = feed.latestRoundData();
        updatedAt = _updatedAt;
        isStale = block.timestamp - updatedAt > maxPriceAge;
    }

    /// @notice Check L2 sequencer status (for monitoring/frontend)
    /// @return isUp True if sequencer is up (or no sequencer feed configured)
    /// @return gracePeriodPassed True if grace period has passed (or no sequencer feed)
    /// @return timeSinceUp Seconds since sequencer came back up (0 if no feed)
    function getSequencerStatus() external view returns (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) {
        if (address(sequencerUptimeFeed) == address(0)) {
            return (true, true, 0); // No sequencer feed = always OK
        }

        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();

        isUp = answer == 0;
        timeSinceUp = block.timestamp - startedAt;
        gracePeriodPassed = timeSinceUp > GRACE_PERIOD_TIME;
    }

    /// @notice Check if L2 sequencer is up and grace period has passed
    /// @dev Only performs check if sequencerUptimeFeed is set (non-zero address)
    function _checkSequencerUptime() internal view {
        if (address(sequencerUptimeFeed) == address(0)) {
            return; // No sequencer feed configured, skip check (L1 or not needed)
        }

        (
            /* uint80 roundId */
            ,
            int256 answer,
            uint256 startedAt,
            /* uint256 updatedAt */
            ,
            /* uint80 answeredInRound */
        ) = sequencerUptimeFeed.latestRoundData();

        // Reject incomplete rounds. A `startedAt == 0` reading would otherwise let
        // `block.timestamp - 0` trivially clear the grace-period gate, treating an
        // uninitialised feed as "sequencer up forever".
        if (startedAt == 0) {
            revert SequencerDown();
        }

        // Answer: 0 = sequencer is up, 1 = sequencer is down. Anything else is malformed
        // and treated as down.
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        // Check grace period after sequencer comes back up
        // startedAt is the timestamp when the sequencer status last changed
        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver(timeSinceUp, GRACE_PERIOD_TIME);
        }
    }
}
