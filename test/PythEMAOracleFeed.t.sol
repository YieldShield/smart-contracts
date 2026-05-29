// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { PythEMAOracleFeed } from "../contracts/oracles/PythEMAOracleFeed.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

contract PythEMAOracleFeedTest is Test {
    PythEMAOracleFeed public feed;
    MockPyth public mockPyth;
    MockERC20 public token;

    bytes32 public constant FEED_ID = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    uint256 public constant MAX_PRICE_AGE = 60;
    uint256 public constant VALID_TIME_PERIOD = 60;
    uint256 public constant SINGLE_UPDATE_FEE = 1e15;

    function setUp() public {
        mockPyth = new MockPyth(VALID_TIME_PERIOD, SINGLE_UPDATE_FEE);
        feed = new PythEMAOracleFeed(address(mockPyth), MAX_PRICE_AGE);

        token = new MockERC20("Token", "TKN");
        feed.setTokenPriceFeed(address(token), FEED_ID);

        _updatePriceFeed(FEED_ID, 1e8, 1e6, -8, uint64(block.timestamp));
    }

    function _updatePriceFeed(bytes32 feedId, int64 price, uint64 conf, int32 expo, uint64 publishTime) internal {
        bytes memory updateData =
            mockPyth.createPriceFeedUpdateData(feedId, price, conf, expo, price, conf, publishTime);

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = mockPyth.getUpdateFee(updateDataArray);
        mockPyth.updatePriceFeeds{ value: fee }(updateDataArray);
    }

    function testGetPrice_NegativePrice_Reverts() public {
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID, -1, 1e6, -8, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.InvalidPrice.selector, address(token), int256(-1)));
        feed.getPrice(address(token));
    }

    function testGetPrice_ZeroAfterTruncation_Reverts() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1, 0, -12, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.InvalidPrice.selector, address(token), int256(0)));
        feed.getPrice(address(token));
    }

    function testGetPrice_RevertsForOverflowingPositiveExponent() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, type(int64).max, 0, 70, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.InvalidPrice.selector, address(token), int256(0)));
        feed.getPrice(address(token));
    }

    function testGetPriceUnsafeSelectorFailsClosed() public view {
        // After the safe-default rename, the marker for "feed advertises the safe/unsafe split"
        // is the `getPriceUnsafe(address)` selector. PythEMA deliberately does not expose it,
        // so CompositeOracle's `_supportsCircuitBreaker` probe must fail for this feed.
        (bool success,) = address(feed).staticcall(abi.encodeWithSignature("getPriceUnsafe(address)", address(token)));

        assertFalse(success);
    }

    function testGetPrice_RevertsWhenConfidenceTooWide() public {
        // M-6: EMA feed's default confidence threshold is 1000 bps (10%) — the
        // permissive band sized for EMA conf widening during volatility. Use
        // a 15% conf to exceed it.
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 15e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythEMAOracleFeed.PriceConfidenceTooWide.selector, address(token), 15e6, 1e8, 1000)
        );
        feed.getPrice(address(token));
    }

    function testGetPrice_AcceptsConfiguredConfidenceBound() public {
        feed.setMaxConfidenceBps(300);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 3e6, -8, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 1e8);
    }

    function testSetMaxPriceAgeForTokenExtendsFreshnessForToken() public {
        feed.setMaxPriceAgeForToken(address(token), 120);

        vm.warp(block.timestamp + 90);

        assertEq(feed.getPrice(address(token)), 1e8);

        feed.setMaxPriceAgeForToken(address(token), 0);

        vm.expectRevert();
        feed.getPrice(address(token));
    }

    function testSetMaxPriceAgeForTokenOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        feed.setMaxPriceAgeForToken(address(token), 120);
    }

    function testGetPrice_RevertsForFuturePublishTime() public {
        uint256 futurePublishTime = block.timestamp + 1;
        _updatePriceFeed(FEED_ID, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythEMAOracleFeed.FuturePrice.selector, address(token), FEED_ID, futurePublishTime, block.timestamp
            )
        );
        feed.getPrice(address(token));
    }

    function testRemoveTokenRequiresSchedule() public {
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.TokenRemovalNotScheduled.selector, address(token)));
        feed.removeToken(address(token));

        feed.scheduleRemoveToken(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythEMAOracleFeed.TokenRemovalTooEarly.selector,
                address(token),
                block.timestamp + feed.TOKEN_REMOVAL_DELAY()
            )
        );
        feed.removeToken(address(token));

        vm.warp(block.timestamp + feed.TOKEN_REMOVAL_DELAY());
        feed.removeToken(address(token));

        assertFalse(feed.isTokenSupported(address(token)));
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.TokenNotSupported.selector, address(token)));
        feed.getPrice(address(token));
    }

    function testSetTokenPriceFeedClearsScheduledRemoval() public {
        feed.scheduleRemoveToken(address(token));
        feed.setTokenPriceFeed(address(token), FEED_ID);

        assertEq(feed.scheduledTokenRemovalTime(address(token)), 0, "schedule should be cleared");
        vm.warp(block.timestamp + feed.TOKEN_REMOVAL_DELAY());
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.TokenRemovalNotScheduled.selector, address(token)));
        feed.removeToken(address(token));
    }

    function testSetTokenPriceFeedClearsPerTokenMaxAgeOverride() public {
        feed.setMaxPriceAgeForToken(address(token), 120);
        feed.setTokenPriceFeed(address(token), FEED_ID);

        assertEq(feed.maxPriceAgeForToken(address(token)), 0, "override should be cleared");
        assertEq(feed.effectiveMaxPriceAge(address(token)), feed.maxPriceAge(), "global max age should apply");
    }

    function testCompositeOracleRejectsEmaFeedForCircuitBreakerPrice() public {
        CompositeOracle compositeOracle = new CompositeOracle();

        // CompositeOracle rejects feeds that do not advertise the safe/unsafe split at
        // configuration time, before a protected pool can route through them.
        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(feed))
        );
        compositeOracle.setTokenOracleFeed(address(token), address(feed));
    }

    function testGetPriceWithPositiveExpo() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 123, 1, 2, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 12_300e8);
    }

    function testGetPriceWithZeroExpo() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 1e6, 0, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 1e16);
    }
}
