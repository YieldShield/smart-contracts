// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";

contract MockAggregatorBounds {
    int192 public minAnswer;
    int192 public maxAnswer;

    constructor(int192 _min, int192 _max) {
        minAnswer = _min;
        maxAnswer = _max;
    }
}

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
}
