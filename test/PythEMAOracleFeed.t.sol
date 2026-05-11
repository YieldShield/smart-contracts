// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    function testGetPriceWithCircuitBreaker_ReturnsEmaPrice() public view {
        assertEq(feed.getPriceWithCircuitBreaker(address(token)), 1e8);
    }

    function testGetPrice_RevertsWhenConfidenceTooWide() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 3e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythEMAOracleFeed.PriceConfidenceTooWide.selector, address(token), 3e6, 1e8, 200)
        );
        feed.getPrice(address(token));
    }

    function testGetPrice_AcceptsConfiguredConfidenceBound() public {
        feed.setMaxConfidenceBps(300);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 3e6, -8, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 1e8);
    }

    function testCompositeOracleUsesEmaCircuitBreakerPrice() public {
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeed(address(token), address(feed));

        assertEq(compositeOracle.getPriceWithCircuitBreaker(address(token)), 1e8);
    }

    function testGetPriceWithPositiveExpo() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 123, 1, 2, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 12_300e8);
        assertEq(feed.getPriceWithCircuitBreaker(address(token)), 12_300e8);
    }

    function testGetPriceWithZeroExpo() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID, 1e8, 1e6, 0, uint64(block.timestamp));

        assertEq(feed.getPrice(address(token)), 1e16);
        assertEq(feed.getPriceWithCircuitBreaker(address(token)), 1e16);
    }
}
