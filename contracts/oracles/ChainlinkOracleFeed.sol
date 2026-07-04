// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

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

/// @title IChainlinkAggregatorProxy
/// @notice Subset of the EACAggregatorProxy interface used to read the
///         underlying aggregator and its min/max answer bounds. Many
///         Chainlink price-feed proxies expose `aggregator()`; the
///         underlying contract exposes `minAnswer()`/`maxAnswer()`.
interface IChainlinkAggregatorProxy {
    function aggregator() external view returns (address);
}

interface IChainlinkAggregatorBounds {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @title ChainlinkOracleFeed
/// @author David Hawig
/// @notice Oracle feed adapter for Chainlink price feeds
/// @dev Implements IOracleFeed interface using Chainlink's AggregatorV3Interface
///      Includes configurable L2 sequencer uptime checks, defaulting on for known supported L2s.
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

    /// @notice Whether this deployment must have a sequencer uptime feed configured
    bool public sequencerUptimeFeedRequired;

    /// @notice Mapping from token address to Chainlink aggregator
    mapping(address => AggregatorV3Interface) public tokenFeeds;

    /// @notice Mapping to track if a token is supported
    mapping(address => bool) public isTokenSupported;

    /// @notice Cached min/max answer bounds for each feed, queried at registration.
    /// @dev If the proxy doesn't expose `aggregator()` or the inner aggregator doesn't
    ///      expose `minAnswer`/`maxAnswer`, both bounds remain zero and the runtime
    ///      check is skipped (logged via FeedBoundsUnavailable on registration).
    mapping(address => int192) public tokenFeedMinAnswer;
    mapping(address => int192) public tokenFeedMaxAnswer;
    mapping(address => address) public tokenFeedBoundsAggregator;

    /// @notice Emitted when a token's feed is set or updated
    event TokenFeedSet(address indexed token, address indexed feed);

    /// @notice Emitted when max price age is updated
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when sequencer uptime feed is set
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);

    /// @notice Emitted when the sequencer uptime feed requirement changes
    event SequencerUptimeFeedRequiredSet(bool oldRequired, bool newRequired);

    /// @notice Emitted when min/max answer bounds are cached for a feed
    event FeedBoundsCached(address indexed token, address indexed feed, int192 minAnswer, int192 maxAnswer);

    /// @notice Emitted when a feed proxy does not expose min/max answer bounds
    event FeedBoundsUnavailable(address indexed token, address indexed feed);

    /// @notice Emitted when `refreshFeedBounds` is called on an already-registered token.
    /// @dev Separate from `FeedBoundsCached`/`FeedBoundsUnavailable` so off-chain
    ///      monitoring can distinguish operator-initiated cache refreshes from
    ///      initial registration. The follow-up `FeedBoundsCached` or
    ///      `FeedBoundsUnavailable` event still fires from `_cacheFeedBounds`,
    ///      carrying the new bound values.
    event FeedBoundsRefreshed(address indexed token, address indexed feed);

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

    /// @notice Custom error when a known L2 deployment has no sequencer uptime feed configured
    error SequencerUptimeFeedRequired(uint256 chainId);

    /// @notice Custom error when the feed answer has saturated at its min/max bound
    ///         (Venus-style attack pattern: aggregator pins at floor/ceiling instead
    ///         of reporting the true price).
    error PriceOutsideAggregatorBounds(address token, int256 answer, int192 minAnswer, int192 maxAnswer);

    /// @notice Custom error when a Chainlink proxy rotated away from the aggregator
    ///         whose bounds are cached locally.
    error FeedBoundsStale(address token, address feed, address cachedAggregator, address currentAggregator);

    /// @notice Custom error when sequencer grace period not over
    /// @param timeSinceUp Seconds since sequencer came back up
    /// @param gracePeriod Required grace period in seconds
    error GracePeriodNotOver(uint256 timeSinceUp, uint256 gracePeriod);

    /// @notice Custom error for invalid price age
    error InvalidPriceAge(uint256 provided, uint256 minimum);

    /// @notice Custom error for price age exceeding upper bound
    error PriceAgeTooHigh(uint256 provided, uint256 maximum);

    /// @notice Maximum allowed maxPriceAge value (24h, to accommodate long-heartbeat
    ///         RWA feeds like LBTC, sDAI, USDY whose Chainlink publish cadence is daily).
    /// @dev M-1: raised from 1h. Pair with per-token overrides via
    ///      `setMaxPriceAgeForToken` when a specific feed needs a tighter bound.
    uint256 public constant MAX_PRICE_AGE_LIMIT = 86_400;

    /// @notice Per-token max price age override. Zero means "use the global maxPriceAge".
    mapping(address => uint256) public maxPriceAgeForToken;

    mapping(address => uint256) public scheduledTokenFeedRemovalTime;

    /// @notice Emitted when a per-token max price age is set
    event MaxPriceAgeForTokenUpdated(address indexed token, uint256 oldAge, uint256 newAge);

    event TokenFeedRemovalScheduled(address indexed token, uint256 executableAt);
    event TokenFeedRemovalCancelled(address indexed token);

    uint256 public constant TOKEN_FEED_REMOVAL_DELAY = 1 days;
    uint256 public constant TOKEN_FEED_REMOVAL_EXPIRY = 7 days;

    error TokenFeedRemovalNotScheduled(address token);
    error TokenFeedRemovalTooEarly(address token, uint256 executableAt);
    error TokenFeedRemovalExpired(address token, uint256 expiredAt);

    /// @notice Constructor
    /// @param _maxPriceAge Maximum age of price data in seconds
    constructor(uint256 _maxPriceAge) Ownable(msg.sender) {
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        maxPriceAge = _maxPriceAge;
        sequencerUptimeFeedRequired = _isKnownL2RequiringSequencer(block.chainid);
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
        _clearTokenMaxPriceAge(token);
        _clearScheduledTokenFeedRemoval(token);

        // Best-effort cache of the underlying aggregator's min/max answer
        // bounds. Used at runtime to reject prices saturated at the floor or
        // ceiling (the Venus-style failure mode where the feed pins at a
        // hard-coded bound instead of reporting the true price).
        _cacheFeedBounds(token, feed);

        emit TokenFeedSet(token, feed);
    }

    /// @dev Resolves the underlying aggregator behind a Chainlink proxy and
    ///      caches its min/max answer. If any step fails (non-proxy feed,
    ///      bounds not exposed), both bounds are cleared and an event is
    ///      emitted so the operator can decide whether to accept the feed.
    function _cacheFeedBounds(address token, address feed) internal {
        address underlying = _resolveUnderlyingAggregator(feed);

        try IChainlinkAggregatorBounds(underlying).minAnswer() returns (int192 minA) {
            try IChainlinkAggregatorBounds(underlying).maxAnswer() returns (int192 maxA) {
                tokenFeedMinAnswer[token] = minA;
                tokenFeedMaxAnswer[token] = maxA;
                tokenFeedBoundsAggregator[token] = underlying;
                emit FeedBoundsCached(token, feed, minA, maxA);
                return;
            } catch {
                // fall through
            }
        } catch {
            // fall through
        }

        // Bounds not retrievable: clear cache and signal explicitly.
        tokenFeedMinAnswer[token] = 0;
        tokenFeedMaxAnswer[token] = 0;
        delete tokenFeedBoundsAggregator[token];
        emit FeedBoundsUnavailable(token, feed);
    }

    function _resolveUnderlyingAggregator(address feed) internal view returns (address underlying) {
        underlying = feed;
        try IChainlinkAggregatorProxy(feed).aggregator() returns (address agg) {
            underlying = agg;
        } catch { }
    }

    /// @notice Re-cache the aggregator min/max-answer bounds for an already-registered token.
    /// @dev Chainlink proxies can rotate the underlying aggregator over time. This
    ///      function is permissionless because it only consumes on-chain feed
    ///      metadata and keeps price reads live after routine aggregator rotation.
    ///      Emits `FeedBoundsRefreshed` first so subscribers can distinguish explicit
    ///      cache refreshes from registration; the follow-up `FeedBoundsCached`/
    ///      `FeedBoundsUnavailable` event from `_cacheFeedBounds` still carries the
    ///      new bound values.
    /// @param token The token address whose feed bounds should be refreshed.
    function refreshFeedBounds(address token) external {
        if (!isTokenSupported[token]) revert TokenNotSupported(token);
        address feed = address(tokenFeeds[token]);
        emit FeedBoundsRefreshed(token, feed);
        _cacheFeedBounds(token, feed);
    }

    /// @notice Remove a token feed
    /// @param token The token address to remove
    function scheduleRemoveTokenFeed(address token) external onlyOwner {
        if (!isTokenSupported[token]) revert TokenNotSupported(token);
        uint256 executableAt = block.timestamp + TOKEN_FEED_REMOVAL_DELAY;
        scheduledTokenFeedRemovalTime[token] = executableAt;
        emit TokenFeedRemovalScheduled(token, executableAt);
    }

    function cancelScheduledRemoveTokenFeed(address token) external onlyOwner {
        if (scheduledTokenFeedRemovalTime[token] == 0) revert TokenFeedRemovalNotScheduled(token);
        delete scheduledTokenFeedRemovalTime[token];
        emit TokenFeedRemovalCancelled(token);
    }

    function _clearScheduledTokenFeedRemoval(address token) internal {
        if (scheduledTokenFeedRemovalTime[token] != 0) {
            delete scheduledTokenFeedRemovalTime[token];
            emit TokenFeedRemovalCancelled(token);
        }
    }

    function _clearTokenMaxPriceAge(address token) internal {
        uint256 oldAge = maxPriceAgeForToken[token];
        if (oldAge != 0) {
            delete maxPriceAgeForToken[token];
            emit MaxPriceAgeForTokenUpdated(token, oldAge, 0);
        }
    }

    function removeTokenFeed(address token) external onlyOwner {
        _consumeScheduledTokenFeedRemoval(token);
        delete tokenFeeds[token];
        delete tokenFeedMinAnswer[token];
        delete tokenFeedMaxAnswer[token];
        delete tokenFeedBoundsAggregator[token];
        delete maxPriceAgeForToken[token];
        isTokenSupported[token] = false;
        emit TokenFeedSet(token, address(0));
    }

    function _consumeScheduledTokenFeedRemoval(address token) internal {
        uint256 executableAt = scheduledTokenFeedRemovalTime[token];
        if (executableAt == 0) revert TokenFeedRemovalNotScheduled(token);
        if (block.timestamp < executableAt) revert TokenFeedRemovalTooEarly(token, executableAt);
        uint256 expiresAt = executableAt + TOKEN_FEED_REMOVAL_EXPIRY;
        if (block.timestamp >= expiresAt) {
            delete scheduledTokenFeedRemovalTime[token];
            revert TokenFeedRemovalExpired(token, expiresAt);
        }
        delete scheduledTokenFeedRemovalTime[token];
    }

    /// @notice Set the global maximum age for price data
    /// @param _maxPriceAge The maximum age in seconds (minimum 10)
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        uint256 oldAge = maxPriceAge;
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(oldAge, _maxPriceAge);
    }

    /// @notice Set a per-token max price age that overrides the global value.
    /// @dev Set to 0 to clear the override and revert to the global maxPriceAge.
    function setMaxPriceAgeForToken(address token, uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge != 0 && _maxPriceAge < 10) revert InvalidPriceAge(_maxPriceAge, 10);
        if (_maxPriceAge > MAX_PRICE_AGE_LIMIT) revert PriceAgeTooHigh(_maxPriceAge, MAX_PRICE_AGE_LIMIT);
        uint256 oldAge = maxPriceAgeForToken[token];
        maxPriceAgeForToken[token] = _maxPriceAge;
        emit MaxPriceAgeForTokenUpdated(token, oldAge, _maxPriceAge);
    }

    /// @notice Resolve the effective max-price-age for a token (override or global)
    function effectiveMaxPriceAge(address token) public view returns (uint256) {
        uint256 perToken = maxPriceAgeForToken[token];
        return perToken == 0 ? maxPriceAge : perToken;
    }

    /// @notice Set the L2 sequencer uptime feed (for Arbitrum/Optimism/Base)
    /// @dev Set to address(0) to disable sequencer check (for L1 or if not needed)
    /// @param _sequencerUptimeFeed The Chainlink sequencer uptime feed address
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyOwner {
        address oldFeed = address(sequencerUptimeFeed);
        if (_sequencerUptimeFeed == address(0) && _requiresSequencerUptimeFeed()) {
            revert SequencerUptimeFeedRequired(block.chainid);
        }

        // If setting a non-zero address, verify the feed is valid
        if (_sequencerUptimeFeed != address(0)) {
            AggregatorV3Interface feed = AggregatorV3Interface(_sequencerUptimeFeed);
            // Verify feed responds correctly
            try feed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
                // Sequencer status: 0 = up, 1 = down
                if (answer != 0 && answer != 1) {
                    revert InvalidFeedAddress(_sequencerUptimeFeed);
                }
                // Reject feeds that report an uninitialized or future-dated startedAt
                // at registration; both would brick every L2 price read at runtime.
                if (startedAt == 0 || startedAt > block.timestamp) {
                    revert InvalidFeedAddress(_sequencerUptimeFeed);
                }
            } catch {
                revert InvalidFeedAddress(_sequencerUptimeFeed);
            }
        }

        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        emit SequencerUptimeFeedSet(oldFeed, _sequencerUptimeFeed);
    }

    /// @notice Configure whether this deployment must use a sequencer uptime feed.
    /// @dev Defaults to true for known L2 chain IDs, but can be enabled for newly
    ///      supported L2s without redeploying a new oracle implementation.
    function setSequencerUptimeFeedRequired(bool required) external onlyOwner {
        bool oldRequired = sequencerUptimeFeedRequired;
        sequencerUptimeFeedRequired = required;
        emit SequencerUptimeFeedRequiredSet(oldRequired, required);
    }

    /// @inheritdoc IOracleFeed
    /// @dev Chainlink protection is provided by stale-round, answered-in-round, and optional
    ///      sequencer checks built into `_getPrice`. There is no separate "unsafe" computation
    ///      path; `getPriceUnsafe` is exposed as an alias so consumers can probe whether the
    ///      feed advertises the safe/unsafe split.
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Unprotected price getter exposed as an alias so consumers (e.g. CompositeOracle)
    ///         can detect that this feed advertises a circuit-breaker discipline.
    /// @dev Chainlink has no distinct unprotected path; this function returns the same
    ///      stale-round + sequencer validated price as `getPrice`.
    function getPriceUnsafe(address token) external view returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Whether this feed exposes a protected price path for `token`.
    /// @dev Chainlink does not have a weaker raw path here; `getPriceUnsafe` aliases the
    ///      same stale-round, bounds, and sequencer-checked read so consumers can detect support.
    function supportsCircuitBreaker(address token) external view returns (bool) {
        return isTokenSupported[token];
    }

    /// @notice Whether this token feed satisfies the stricter protected-collateral policy.
    /// @dev Non-strict consumers may accept Chainlink feeds without retrievable aggregator
    ///      bounds. Strict backing collateral must have fresh usable bounds so pinned
    ///      min/max-answer circuit-breaker values cannot be treated as valid prices.
    function supportsStrictProtectedPrice(address token) external view returns (bool) {
        if (!isTokenSupported[token]) {
            return false;
        }
        if (_requiresSequencerUptimeFeed() && address(sequencerUptimeFeed) == address(0)) {
            return false;
        }

        int192 minA = tokenFeedMinAnswer[token];
        int192 maxA = tokenFeedMaxAnswer[token];
        if (minA == 0 && maxA == 0) {
            return false;
        }

        address cachedAggregator = tokenFeedBoundsAggregator[token];
        if (cachedAggregator == address(0)) {
            return false;
        }

        return _resolveUnderlyingAggregator(address(tokenFeeds[token])) == cachedAggregator;
    }

    function _getPrice(address token) internal view returns (uint256) {
        if (!isTokenSupported[token]) {
            revert TokenNotSupported(token);
        }

        // L2 sequencer uptime check (only if sequencer feed is configured)
        _checkSequencerUptime();

        AggregatorV3Interface feed = tokenFeeds[token];
        _requireFreshFeedBounds(token, address(feed));

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        // Validate price data using shared library. Use per-token max-age if
        // overridden — long-heartbeat RWA feeds need their own bound. (M-1)
        uint256 effectiveAge = effectiveMaxPriceAge(token);
        OracleValidationLib.validatePositivePrice(answer, token);
        if (answeredInRound < roundId) revert StalePrice(token, updatedAt, effectiveAge);
        OracleValidationLib.validateStaleness(updatedAt, effectiveAge, token);

        // Venus-style protection: if the underlying aggregator's min/max answer
        // bounds were retrievable at registration time, reject prices that have
        // saturated at either bound. A pinned price during a real depeg lets
        // the protocol mis-value assets if the true off-chain price is past
        // the configured floor/ceiling.
        int192 minA = tokenFeedMinAnswer[token];
        int192 maxA = tokenFeedMaxAnswer[token];
        if (minA != 0 || maxA != 0) {
            if (answer <= int256(minA) || answer >= int256(maxA)) {
                revert PriceOutsideAggregatorBounds(token, answer, minA, maxA);
            }
        }

        // Convert to 8 decimals if necessary
        uint8 feedDecimals = feed.decimals();
        if (feedDecimals > 77) revert InvalidPrice(token, answer);
        uint256 normalizedPrice = uint256(answer).normalize(feedDecimals, 8);
        if (normalizedPrice == 0) revert InvalidPrice(token, 0);
        return normalizedPrice;
    }

    function _requireFreshFeedBounds(address token, address feed) internal view {
        address cachedAggregator = tokenFeedBoundsAggregator[token];
        if (cachedAggregator == address(0)) {
            return;
        }

        address currentAggregator = _resolveUnderlyingAggregator(feed);
        if (currentAggregator != cachedAggregator) {
            revert FeedBoundsStale(token, feed, cachedAggregator, currentAggregator);
        }
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
    /// @dev Mirrors `validateStaleness`: future-dated feed timestamps are treated
    ///      as stale instead of underflowing the unsigned subtraction below.
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return updatedAt The timestamp of the last update
    function isPriceStale(address token) external view returns (bool isStale, uint256 updatedAt) {
        if (!isTokenSupported[token]) {
            return (true, 0);
        }

        if (_isSequencerUnavailableForStaleness()) {
            return (true, 0);
        }

        AggregatorV3Interface feed = tokenFeeds[token];
        address cachedAggregator = tokenFeedBoundsAggregator[token];
        if (cachedAggregator != address(0) && _resolveUnderlyingAggregator(address(feed)) != cachedAggregator) {
            return (true, 0);
        }

        try feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 _updatedAt, uint80 answeredInRound
        ) {
            updatedAt = _updatedAt;
            if (answer <= 0 || answeredInRound < roundId) {
                return (true, updatedAt);
            }
            int192 minA = tokenFeedMinAnswer[token];
            int192 maxA = tokenFeedMaxAnswer[token];
            if ((minA != 0 || maxA != 0) && (answer <= int256(minA) || answer >= int256(maxA))) {
                return (true, updatedAt);
            }
        } catch {
            return (true, 0);
        }
        if (updatedAt > block.timestamp) {
            return (true, updatedAt);
        }
        isStale = block.timestamp - updatedAt > effectiveMaxPriceAge(token);
    }

    /// @notice Check L2 sequencer status (for monitoring/frontend)
    /// @return isUp True if sequencer is up (or no sequencer feed configured)
    /// @return gracePeriodPassed True if grace period has passed (or no sequencer feed)
    /// @return timeSinceUp Seconds since sequencer came back up (0 if no feed)
    function getSequencerStatus() external view returns (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) {
        if (address(sequencerUptimeFeed) == address(0)) {
            if (_requiresSequencerUptimeFeed()) {
                return (false, false, 0);
            }
            return (true, true, 0); // No sequencer feed = always OK
        }

        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();

        isUp = answer == 0;
        if (startedAt == 0) {
            return (false, false, 0);
        }
        // A future `startedAt` means the status cannot be trusted yet.
        if (startedAt > block.timestamp) {
            return (false, false, 0);
        }
        timeSinceUp = block.timestamp - startedAt;
        gracePeriodPassed = timeSinceUp > GRACE_PERIOD_TIME;
    }

    function _isSequencerUnavailableForStaleness() internal view returns (bool) {
        if (address(sequencerUptimeFeed) == address(0)) {
            return _requiresSequencerUptimeFeed();
        }

        try sequencerUptimeFeed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (startedAt == 0) {
                return true;
            }
            if (answer != 0) {
                return true;
            }
            if (startedAt > block.timestamp) {
                return true;
            }

            return block.timestamp - startedAt <= GRACE_PERIOD_TIME;
        } catch {
            return true;
        }
    }

    /// @notice Check if L2 sequencer is up and grace period has passed
    /// @dev Only performs check if sequencerUptimeFeed is set (non-zero address)
    function _checkSequencerUptime() internal view {
        if (address(sequencerUptimeFeed) == address(0)) {
            if (_requiresSequencerUptimeFeed()) {
                revert SequencerUptimeFeedRequired(block.chainid);
            }
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

        // Check grace period after sequencer comes back up.
        // startedAt is the timestamp when the sequencer status last changed.
        // A future-dated `startedAt` (reporter clock skew) would underflow the unsigned
        // subtraction below; treat it as "grace period not yet elapsed" instead.
        if (startedAt > block.timestamp) {
            revert GracePeriodNotOver(0, GRACE_PERIOD_TIME);
        }
        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver(timeSinceUp, GRACE_PERIOD_TIME);
        }
    }

    function _requiresSequencerUptimeFeed() internal view returns (bool) {
        return sequencerUptimeFeedRequired;
    }

    function _isKnownL2RequiringSequencer(uint256 chainId) internal pure returns (bool) {
        return chainId == 10 || chainId == 11155420 || chainId == 8453 || chainId == 84532 || chainId == 42161
            || chainId == 421614 || chainId == 4663 || chainId == 46630;
    }
}
