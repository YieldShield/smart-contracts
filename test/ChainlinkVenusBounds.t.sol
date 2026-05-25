// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";

contract MockAggregatorBounds {
    int192 public minAnswer;
    int192 public maxAnswer;

    constructor(int192 _min, int192 _max) {
        minAnswer = _min;
        maxAnswer = _max;
    }
}

contract MockAggregatorWithoutBounds { }

contract MockChainlinkProxyWithBounds {
    int256 internal _price;
    uint8 internal _decimals;
    uint80 internal _roundId;
    uint256 internal _updatedAt;
    address public aggregator;

    constructor(int256 price, uint8 feedDecimals, int192 minA, int192 maxA) {
        _price = price;
        _decimals = feedDecimals;
        _roundId = 1;
        _updatedAt = block.timestamp;
        aggregator = address(new MockAggregatorBounds(minA, maxA));
    }

    function setPrice(int256 price) external {
        _price = price;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    function setAggregator(address newAgg) external {
        aggregator = newAgg;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract MockChainlinkProxyWithoutBounds {
    int256 internal _price;
    uint8 internal _decimals;
    uint80 internal _roundId;
    uint256 internal _updatedAt;
    address public aggregator;

    constructor(int256 price, uint8 feedDecimals) {
        _price = price;
        _decimals = feedDecimals;
        _roundId = 1;
        _updatedAt = block.timestamp;
        aggregator = address(new MockAggregatorWithoutBounds());
    }

    function setAggregator(address newAgg) external {
        aggregator = newAgg;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract ChainlinkVenusBoundsTest is Test {
    ChainlinkOracleFeed internal feed;
    address internal token = address(0xABCD);

    int192 internal constant MIN_BOUND = 0.1e8; // $0.10 floor
    int192 internal constant MAX_BOUND = 100_000e8; // $100k ceiling

    function setUp() public {
        feed = new ChainlinkOracleFeed(3600);
    }

    function test_setTokenFeed_CachesBounds() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        assertEq(feed.tokenFeedMinAnswer(token), MIN_BOUND);
        assertEq(feed.tokenFeedMaxAnswer(token), MAX_BOUND);
        assertEq(feed.tokenFeedBoundsAggregator(token), proxy.aggregator());
        assertTrue(feed.supportsStrictProtectedPrice(token));
    }

    function test_removeTokenFeed_RequiresSchedule() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.TokenFeedRemovalNotScheduled.selector, token));
        feed.removeTokenFeed(token);

        feed.scheduleRemoveTokenFeed(token);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleFeed.TokenFeedRemovalTooEarly.selector,
                token,
                block.timestamp + feed.TOKEN_FEED_REMOVAL_DELAY()
            )
        );
        feed.removeTokenFeed(token);

        vm.warp(block.timestamp + feed.TOKEN_FEED_REMOVAL_DELAY());
        feed.removeTokenFeed(token);

        assertFalse(feed.isTokenSupported(token));
        assertEq(address(feed.tokenFeeds(token)), address(0));
        assertEq(feed.tokenFeedMinAnswer(token), 0);
        assertEq(feed.tokenFeedMaxAnswer(token), 0);
    }

    function test_setTokenFeed_ClearsScheduledRemoval() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        feed.scheduleRemoveTokenFeed(token);

        feed.setTokenFeed(token, address(proxy));

        assertEq(feed.scheduledTokenFeedRemovalTime(token), 0, "schedule should be cleared");
        vm.warp(block.timestamp + feed.TOKEN_FEED_REMOVAL_DELAY());
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.TokenFeedRemovalNotScheduled.selector, token));
        feed.removeTokenFeed(token);
    }

    function test_getPrice_RevertsWhenPinnedAtFloor() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        proxy.setPrice(MIN_BOUND); // saturated at floor
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleFeed.PriceOutsideAggregatorBounds.selector,
                token,
                int256(MIN_BOUND),
                MIN_BOUND,
                MAX_BOUND
            )
        );
        feed.getPrice(token);
    }

    function test_getPrice_RevertsWhenPinnedAtCeiling() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        proxy.setPrice(MAX_BOUND);
        vm.expectRevert();
        feed.getPrice(token);
    }

    function test_getPrice_AcceptsValueStrictlyInsideBounds() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        assertEq(feed.getPrice(token), 2_000e8);
    }

    function test_setTokenFeed_AllowsBoundsUnavailableButSignalsAndCanRefreshLater() public {
        MockChainlinkProxyWithoutBounds proxy = new MockChainlinkProxyWithoutBounds(2_000e8, 8);

        vm.expectEmit(true, true, false, false);
        emit ChainlinkOracleFeed.FeedBoundsUnavailable(token, address(proxy));
        feed.setTokenFeed(token, address(proxy));

        assertEq(feed.tokenFeedMinAnswer(token), 0);
        assertEq(feed.tokenFeedMaxAnswer(token), 0);
        assertFalse(feed.supportsStrictProtectedPrice(token));
        assertEq(feed.getPrice(token), 2_000e8, "price should still work without optional bounds");

        MockAggregatorBounds compatible = new MockAggregatorBounds(MIN_BOUND, MAX_BOUND);
        proxy.setAggregator(address(compatible));
        feed.refreshFeedBounds(token);

        assertEq(feed.tokenFeedMinAnswer(token), MIN_BOUND);
        assertEq(feed.tokenFeedMaxAnswer(token), MAX_BOUND);
        assertTrue(feed.supportsStrictProtectedPrice(token));
    }

    // A1 (2026-05-19): Chainlink proxies can rotate the underlying aggregator
    // over time. Without a refresh path the cached min/max-answer bounds go
    // stale silently, weakening the H-1 saturation check. `refreshFeedBounds`
    // re-runs the aggregator probe for an already-registered token.
    function test_refreshFeedBounds_PicksUpRotatedAggregator() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        assertEq(feed.tokenFeedMinAnswer(token), MIN_BOUND);
        assertEq(feed.tokenFeedMaxAnswer(token), MAX_BOUND);

        // Chainlink swaps the proxy's underlying aggregator to one with wider bounds.
        int192 newMin = 0.01e8;
        int192 newMax = 1_000_000e8;
        MockAggregatorBounds rotated = new MockAggregatorBounds(newMin, newMax);
        proxy.setAggregator(address(rotated));

        // Until the protocol calls refresh, the cache still reflects the OLD bounds.
        assertEq(feed.tokenFeedMinAnswer(token), MIN_BOUND, "stale bound before refresh");
        assertEq(feed.tokenFeedMaxAnswer(token), MAX_BOUND, "stale bound before refresh");
        assertFalse(feed.supportsStrictProtectedPrice(token), "rotated bounds are not strict-safe before refresh");

        feed.refreshFeedBounds(token);

        assertEq(feed.tokenFeedMinAnswer(token), newMin, "refresh must pick up new aggregator's min");
        assertEq(feed.tokenFeedMaxAnswer(token), newMax, "refresh must pick up new aggregator's max");
        assertEq(feed.tokenFeedBoundsAggregator(token), address(rotated), "refresh must pin rotated aggregator");
        assertTrue(feed.supportsStrictProtectedPrice(token));
    }

    function test_getPrice_RevertsWhenAggregatorRotatesBeforeRefresh() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));
        address oldAggregator = proxy.aggregator();

        int192 newMin = 1_000e8;
        int192 newMax = 3_000e8;
        MockAggregatorBounds rotated = new MockAggregatorBounds(newMin, newMax);
        proxy.setAggregator(address(rotated));

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleFeed.FeedBoundsStale.selector, token, address(proxy), oldAggregator, address(rotated)
            )
        );
        feed.getPrice(token);

        feed.refreshFeedBounds(token);
        assertEq(feed.getPrice(token), 2_000e8, "price should work after bounds refresh");
    }

    function test_refreshFeedBounds_RevertsForUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.TokenNotSupported.selector, token));
        feed.refreshFeedBounds(token);
    }

    function test_refreshFeedBounds_OnlyOwner() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        feed.refreshFeedBounds(token);
    }

    function test_compositeStrictRequirementRejectsChainlinkFeedWithoutBounds() public {
        MockChainlinkProxyWithoutBounds proxy = new MockChainlinkProxyWithoutBounds(2_000e8, 8);
        feed.setTokenFeed(token, address(proxy));

        CompositeOracle composite = new CompositeOracle();
        composite.setTokenOracleFeed(token, address(feed));

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.CircuitBreakerNotSupported.selector, token, address(feed))
        );
        composite.setStrictCircuitBreakerRequired(token, true);
    }

    function test_compositeStrictRequirementAcceptsChainlinkFeedWithBounds() public {
        MockChainlinkProxyWithBounds proxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(proxy));

        CompositeOracle composite = new CompositeOracle();
        composite.setTokenOracleFeed(token, address(feed));
        composite.setStrictCircuitBreakerRequired(token, true);

        assertTrue(composite.strictCircuitBreakerRequired(token));
        assertEq(composite.getPriceWithStrictCircuitBreaker(token), 2_000e8);
    }

    function test_compositeStrictRequirementRejectsInactiveBackupWithoutBounds() public {
        MockChainlinkProxyWithBounds boundedProxy = new MockChainlinkProxyWithBounds(2_000e8, 8, MIN_BOUND, MAX_BOUND);
        feed.setTokenFeed(token, address(boundedProxy));

        MockChainlinkProxyWithoutBounds unboundedProxy = new MockChainlinkProxyWithoutBounds(2_000e8, 8);
        ChainlinkOracleFeed backupFeed = new ChainlinkOracleFeed(3600);
        backupFeed.setTokenFeed(token, address(unboundedProxy));

        CompositeOracle composite = new CompositeOracle();
        composite.setTokenOracleFeed(token, address(feed));
        composite.setStrictCircuitBreakerRequired(token, true);

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.CircuitBreakerNotSupported.selector, token, address(backupFeed))
        );
        composite.setTokenOracleFeedDual(token, address(feed), address(backupFeed));
    }
}
