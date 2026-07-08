// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";
import { MockChainlinkAggregator } from "../contracts/mocks/MockChainlinkAggregator.sol";
import { MockRobinhoodStockToken } from "../contracts/mocks/MockRobinhoodStockToken.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

contract MockSixDecimalInnerFeed {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract RobinhoodStockOracleFeedTest is Test {
    ChainlinkOracleFeed internal chainlinkFeed;
    RobinhoodStockOracleFeed internal stockFeed;
    MockChainlinkAggregator internal tslaAggregator;
    MockChainlinkAggregator internal wethAggregator;
    MockRobinhoodStockToken internal tsla;
    MockERC20 internal weth;

    int256 internal constant TSLA_PRICE = 33_200_000_000; // $332.00 with 8 decimals
    int256 internal constant TSLA_POST_SPLIT_PRICE = 3_320_000_000; // $33.20 after a 10:1 split
    int256 internal constant WETH_PRICE = 1735e8;
    uint256 internal constant MAX_PRICE_AGE = 3600;

    function setUp() public {
        chainlinkFeed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        tsla = new MockRobinhoodStockToken("Robinhood Test TSLA", "TSLA");
        weth = new MockERC20("Robinhood Test WETH", "WETH");
        tslaAggregator = new MockChainlinkAggregator("TSLA / USD", 8, TSLA_PRICE);
        wethAggregator = new MockChainlinkAggregator("WETH / USD", 8, WETH_PRICE);
        chainlinkFeed.setTokenFeed(address(tsla), address(tslaAggregator));
        chainlinkFeed.setTokenFeed(address(weth), address(wethAggregator));
        stockFeed = new RobinhoodStockOracleFeed(address(chainlinkFeed));
    }

    // ============ Constructor ============

    function test_constructor_RevertsOnZeroInnerFeed() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.InvalidInnerFeed.selector, address(0)));
        new RobinhoodStockOracleFeed(address(0));
    }

    function test_constructor_RevertsOnNonEightDecimalInnerFeed() public {
        MockSixDecimalInnerFeed sixDecimalFeed = new MockSixDecimalInnerFeed();
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodStockOracleFeed.InvalidInnerFeedDecimals.selector, address(sixDecimalFeed), uint8(6)
            )
        );
        new RobinhoodStockOracleFeed(address(sixDecimalFeed));
    }

    function test_constructor_SetsInnerFeed() public view {
        assertEq(stockFeed.innerFeed(), address(chainlinkFeed));
        assertEq(stockFeed.decimals(), 8);
        assertEq(stockFeed.description(), "Robinhood Stock Chainlink Oracle Feed");
    }

    // ============ getPrice ============

    function test_getPrice_ReturnsInnerPriceWhenNotPaused() public view {
        assertEq(stockFeed.getPrice(address(tsla)), uint256(TSLA_PRICE));
        assertEq(stockFeed.getPrice(address(tsla)), chainlinkFeed.getPrice(address(tsla)));
    }

    function test_getPrice_RevertsWhilePausedAndRecoversAfterUnpause() public {
        tsla.setOraclePaused(true);

        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        stockFeed.getPrice(address(tsla));

        tsla.setOraclePaused(false);
        assertEq(stockFeed.getPrice(address(tsla)), uint256(TSLA_PRICE), "price should recover after unpause");
    }

    function test_getPrice_RevertsForTokenWithoutPauseProbe() public {
        // Plain MockERC20 does not implement oraclePaused(); the wrapper must fail closed.
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenPauseProbeFailed.selector, address(weth))
        );
        stockFeed.getPrice(address(weth));
    }

    // ============ isPriceStale ============

    function test_isPriceStale_ReturnsTrueZeroWhilePaused() public {
        tsla.setOraclePaused(true);
        (bool isStale, uint256 updatedAt) = stockFeed.isPriceStale(address(tsla));
        assertTrue(isStale, "paused token must be reported stale");
        assertEq(updatedAt, 0, "paused token must report zero timestamp");
    }

    function test_isPriceStale_ReturnsTrueZeroWhenPauseProbeFails() public view {
        (bool isStale, uint256 updatedAt) = stockFeed.isPriceStale(address(weth));
        assertTrue(isStale, "token without pause probe must be reported stale");
        assertEq(updatedAt, 0);
    }

    function test_isPriceStale_DelegatesWhenNotPaused() public {
        (bool wrapperStale, uint256 wrapperUpdatedAt) = stockFeed.isPriceStale(address(tsla));
        (bool innerStale, uint256 innerUpdatedAt) = chainlinkFeed.isPriceStale(address(tsla));
        assertEq(wrapperStale, innerStale, "fresh staleness must match inner feed");
        assertEq(wrapperUpdatedAt, innerUpdatedAt, "fresh updatedAt must match inner feed");
        assertFalse(wrapperStale, "fresh price should not be stale");

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        (wrapperStale, wrapperUpdatedAt) = stockFeed.isPriceStale(address(tsla));
        (innerStale, innerUpdatedAt) = chainlinkFeed.isPriceStale(address(tsla));
        assertEq(wrapperStale, innerStale, "stale staleness must match inner feed");
        assertEq(wrapperUpdatedAt, innerUpdatedAt, "stale updatedAt must match inner feed");
        assertTrue(wrapperStale, "aged price should be stale");
    }

    // ============ Optional capability delegation ============

    function test_getPriceUnsafe_DelegatesToInnerFeed() public {
        assertEq(stockFeed.getPriceUnsafe(address(tsla)), chainlinkFeed.getPriceUnsafe(address(tsla)));
        assertEq(stockFeed.getPriceUnsafe(address(tsla)), uint256(TSLA_PRICE));

        tsla.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        stockFeed.getPriceUnsafe(address(tsla));
    }

    function test_supportsCircuitBreaker_DelegatesToInnerFeed() public view {
        assertEq(stockFeed.supportsCircuitBreaker(address(tsla)), chainlinkFeed.supportsCircuitBreaker(address(tsla)));
        assertTrue(stockFeed.supportsCircuitBreaker(address(tsla)), "registered token supports circuit breaker");
        assertFalse(stockFeed.supportsCircuitBreaker(address(0xDEAD)), "unregistered token has no circuit breaker");
    }

    function test_supportsStrictProtectedPrice_DelegatesToInnerFeed() public view {
        assertEq(
            stockFeed.supportsStrictProtectedPrice(address(tsla)),
            chainlinkFeed.supportsStrictProtectedPrice(address(tsla))
        );
        // MockChainlinkAggregator reports sentinel bounds (1, type(int192).max), so the inner
        // feed rejects strict protected pricing and the wrapper must mirror that verdict.
        assertFalse(stockFeed.supportsStrictProtectedPrice(address(tsla)));
    }

    // ============ Corporate-action multiplier scenario ============

    function test_multiplierWindow_NoReadablePriceMidWindowAndNewPriceAfter() public {
        // Robinhood schedules a 10:1 split: pending UI multiplier + oracle pause.
        tsla.scheduleUIMultiplier(10e18, block.timestamp + 1 days);
        tsla.setOraclePaused(true);

        // Mid-window: no readable price anywhere on the wrapper.
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        stockFeed.getPrice(address(tsla));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        stockFeed.getPriceUnsafe(address(tsla));
        (bool isStale, uint256 updatedAt) = stockFeed.isPriceStale(address(tsla));
        assertTrue(isStale, "paused token must report stale mid-window");
        assertEq(updatedAt, 0);

        // Corporate action completes: multiplier applies and the aggregator reprices.
        vm.warp(block.timestamp + 1 days);
        tsla.applyPendingUIMultiplier();
        tslaAggregator.setAnswer(TSLA_POST_SPLIT_PRICE);
        tsla.setOraclePaused(false);

        assertEq(tsla.uiMultiplier(), 10e18, "multiplier should be applied");
        assertEq(stockFeed.getPrice(address(tsla)), uint256(TSLA_POST_SPLIT_PRICE), "post-split price should read");
        (isStale,) = stockFeed.isPriceStale(address(tsla));
        assertFalse(isStale, "repriced token should be fresh again");
    }

    // ============ CompositeOracle integration ============

    function test_compositeOracle_DetectsChainlinkStockTypeForWrapper() public {
        CompositeOracle composite = new CompositeOracle();

        composite.setTokenOracleFeed(address(tsla), address(stockFeed));
        assertEq(composite.getOracleType(address(tsla)), "chainlink-stock");
        assertEq(composite.getPrice(address(tsla)), uint256(TSLA_PRICE));

        // Unwrapped ChainlinkOracleFeed must keep detecting as plain "chainlink".
        composite.setTokenOracleFeed(address(weth), address(chainlinkFeed));
        assertEq(composite.getOracleType(address(weth)), "chainlink");
        assertEq(composite.getPrice(address(weth)), uint256(WETH_PRICE));

        // The pause guard propagates through the composite's protected price path.
        tsla.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        composite.getPrice(address(tsla));
    }
}
