// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { UniswapV3TWAPFeed } from "../contracts/oracles/UniswapV3TWAPFeed.sol";
import { FullMath } from "../contracts/oracles/libraries/FullMath.sol";
import { TickMath } from "../contracts/oracles/libraries/TickMath.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

contract UniswapV3TWAPHarness is UniswapV3TWAPFeed {
    constructor(address quoteToken, address quoteOracle) UniswapV3TWAPFeed(1800, quoteToken, quoteOracle) { }

    function priceFromTick(int24 tick, bool isToken0, uint256 tokenScale, uint256 quoteScale)
        external
        pure
        returns (uint256)
    {
        return _getPriceFromTick(tick, isToken0, tokenScale, quoteScale);
    }
}

contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    int24 public tick;
    uint128 public averageLiquidity;
    bool public shouldRevertObserve;
    bool public shouldReturnDescendingLiquidityCumulatives;

    constructor(address token0_, address token1_, int24 tick_, uint128 averageLiquidity_) {
        token0 = token0_;
        token1 = token1_;
        tick = tick_;
        averageLiquidity = averageLiquidity_;
    }

    function setAverageLiquidity(uint128 averageLiquidity_) external {
        averageLiquidity = averageLiquidity_;
    }

    function setShouldRevertObserve(bool shouldRevertObserve_) external {
        shouldRevertObserve = shouldRevertObserve_;
    }

    function setShouldReturnDescendingLiquidityCumulatives(bool enabled) external {
        shouldReturnDescendingLiquidityCumulatives = enabled;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (shouldRevertObserve) revert("observe unavailable");

        uint32 period = secondsAgos[0];
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(uint56(period));

        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        if (shouldReturnDescendingLiquidityCumulatives) {
            secondsPerLiquidityCumulativeX128s[0] = 2;
            secondsPerLiquidityCumulativeX128s[1] = 1;
            return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
        }
        secondsPerLiquidityCumulativeX128s[0] = 0;
        secondsPerLiquidityCumulativeX128s[1] =
            averageLiquidity == 0 ? type(uint160).max : uint160((uint256(period) << 128) / averageLiquidity);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, tick, 0, 0, 0, 0, true);
    }
}

contract UniswapV3TWAPFeedTest is Test {
    UniswapV3TWAPHarness public harness;
    MockOracle public quoteOracle;
    MockERC20 public quoteToken;

    function setUp() public {
        quoteOracle = new MockOracle();
        quoteToken = new MockERC20("Quote", "QUOTE");
        harness = new UniswapV3TWAPHarness(address(quoteToken), address(quoteOracle));
    }

    function _expectedPriceFromTick(int24 tick, bool isToken0) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return isToken0 ? FullMath.mulDiv(ratioX192, 1e18, 1 << 192) : FullMath.mulDiv(1 << 192, 1e18, ratioX192);
        }

        uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
        return isToken0 ? FullMath.mulDiv(ratioX128, 1e18, 1 << 128) : FullMath.mulDiv(1 << 128, 1e18, ratioX128);
    }

    function test_priceFromTick_MatchesTickMath_PositiveTick() public view {
        int24 tick = 20000;
        uint256 expected = _expectedPriceFromTick(tick, true);
        uint256 actual = harness.priceFromTick(tick, true, 1e18, 1e18);
        assertEq(actual, expected, "price should match TickMath for token0");
    }

    function test_priceFromTick_MatchesTickMath_NegativeTick() public view {
        int24 tick = -20000;
        uint256 expected = _expectedPriceFromTick(tick, false);
        uint256 actual = harness.priceFromTick(tick, false, 1e18, 1e18);
        assertEq(actual, expected, "price should match TickMath for token1");
    }

    function test_priceFromTick_PreservesFractionalPriceBeforeScaling() public view {
        int24 tick = 4055;

        uint256 token0Price = harness.priceFromTick(tick, true, 1e18, 1e18);
        uint256 token1Price = harness.priceFromTick(tick, false, 1e18, 1e18);

        assertEq(token0Price, _expectedPriceFromTick(tick, true), "token0 price should keep sub-unit precision");
        assertEq(token1Price, _expectedPriceFromTick(tick, false), "token1 inverse should keep sub-unit precision");
        assertGt(token0Price, 1.4e18, "old math truncated token0 price to 1e18");
        assertLt(token1Price, 0.7e18, "old math truncated token1 inverse to 1e18");
    }

    function test_priceFromTick_AdjustsEighteenDecimalTokenAgainstSixDecimalQuote() public view {
        int24 tick = -276_324;

        uint256 rawUnitPrice = harness.priceFromTick(tick, true, 1e18, 1e18);
        uint256 humanUnitPrice = harness.priceFromTick(tick, true, 1e18, 1e6);

        assertEq(humanUnitPrice, rawUnitPrice * 1e12, "18/6 pair must scale raw pool ratio up");
        assertApproxEqRel(humanUnitPrice, 1e18, 1e15, "one whole token should price near one whole quote");
    }

    function test_priceFromTick_AdjustsSixDecimalTokenAgainstEighteenDecimalQuote() public view {
        int24 tick = 276_324;

        uint256 rawUnitPrice = harness.priceFromTick(tick, true, 1e18, 1e18);
        uint256 humanUnitPrice = harness.priceFromTick(tick, true, 1e6, 1e18);

        assertEq(humanUnitPrice, rawUnitPrice / 1e12, "6/18 pair must scale raw pool ratio down");
        assertApproxEqRel(humanUnitPrice, 1e18, 1e15, "one whole token should price near one whole quote");
    }

    function test_setTokenPool_RevertsWhenAverageLiquidityBelowFloor() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool = new MockUniswapV3Pool(
            address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY() - 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TWAPFeed.InsufficientTWAPLiquidity.selector,
                address(pool),
                harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY() - 1,
                harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY()
            )
        );
        harness.setTokenPool(address(token), address(pool));
    }

    function test_removeTokenPool_RequiresSchedule() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool =
            new MockUniswapV3Pool(address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());
        harness.setTokenPool(address(token), address(pool));

        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.TokenPoolRemovalNotScheduled.selector, address(token)));
        harness.removeTokenPool(address(token));

        harness.scheduleRemoveTokenPool(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TWAPFeed.TokenPoolRemovalTooEarly.selector,
                address(token),
                block.timestamp + harness.TOKEN_POOL_REMOVAL_DELAY()
            )
        );
        harness.removeTokenPool(address(token));

        vm.warp(block.timestamp + harness.TOKEN_POOL_REMOVAL_DELAY());
        harness.removeTokenPool(address(token));

        assertFalse(harness.isTokenSupported(address(token)));
        assertEq(harness.tokenPools(address(token)), address(0));
    }

    function test_setTokenPool_ClearsScheduledRemoval() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool =
            new MockUniswapV3Pool(address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());
        harness.setTokenPool(address(token), address(pool));
        harness.scheduleRemoveTokenPool(address(token));

        harness.setTokenPool(address(token), address(pool));

        assertEq(harness.scheduledTokenPoolRemovalTime(address(token)), 0, "schedule should be cleared");
        vm.warp(block.timestamp + harness.TOKEN_POOL_REMOVAL_DELAY());
        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.TokenPoolRemovalNotScheduled.selector, address(token)));
        harness.removeTokenPool(address(token));
    }

    function test_getPrice_RevertsWhenRegisteredPoolLiquidityFallsBelowFloor() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool =
            new MockUniswapV3Pool(address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());

        harness.setTokenPool(address(token), address(pool));
        assertEq(harness.getPrice(address(token)), 1e8);

        pool.setAverageLiquidity(harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY() - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TWAPFeed.InsufficientTWAPLiquidity.selector,
                address(pool),
                harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY() - 1,
                harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY()
            )
        );
        harness.getPrice(address(token));
    }

    function test_setQuoteTokenOracle_RejectsLargeInstantDeviation() public {
        MockOracle newQuoteOracle = new MockOracle();
        newQuoteOracle.setPrice(address(quoteToken), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TWAPFeed.QuoteOracleSwapDeviationTooHigh.selector, 1e8, 2e8, 10000)
        );
        harness.setQuoteTokenOracle(address(newQuoteOracle));
    }

    function test_quoteTokenOracleFailover_RecoversWhenOldOracleReverts() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool =
            new MockUniswapV3Pool(address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());
        harness.setTokenPool(address(token), address(pool));

        MockOracle newQuoteOracle = new MockOracle();
        newQuoteOracle.setPrice(address(quoteToken), 1e8);

        quoteOracle.setShouldRevertOnCircuitBreaker(true);
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(quoteToken)));
        harness.getPrice(address(token));

        harness.scheduleQuoteTokenOracleFailover(address(newQuoteOracle));
        uint256 executableAt = block.timestamp + harness.QUOTE_ORACLE_FAILOVER_DELAY();
        assertEq(harness.scheduledQuoteTokenOraclePrice(), 1e8);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.QuoteOracleFailoverTooEarly.selector, executableAt));
        harness.executeQuoteTokenOracleFailover();

        vm.warp(executableAt);
        harness.executeQuoteTokenOracleFailover();

        assertEq(address(harness.quoteTokenOracle()), address(newQuoteOracle));
        assertEq(harness.scheduledQuoteTokenOraclePrice(), 0);
        assertEq(harness.getPrice(address(token)), 1e8);
    }

    function test_quoteTokenOracleFailover_RevertsWhenScheduledOraclePriceDrifts() public {
        MockOracle newQuoteOracle = new MockOracle();
        newQuoteOracle.setPrice(address(quoteToken), 1e8);

        harness.scheduleQuoteTokenOracleFailover(address(newQuoteOracle));
        uint256 executableAt = block.timestamp + harness.QUOTE_ORACLE_FAILOVER_DELAY();

        newQuoteOracle.setPrice(address(quoteToken), 2e8);
        vm.warp(executableAt);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TWAPFeed.QuoteOracleSwapDeviationTooHigh.selector, 1e8, 2e8, 10000)
        );
        harness.executeQuoteTokenOracleFailover();

        assertEq(address(harness.quoteTokenOracle()), address(quoteOracle));
        assertEq(address(harness.scheduledQuoteTokenOracle()), address(newQuoteOracle));
        assertEq(harness.scheduledQuoteTokenOraclePrice(), 1e8);
    }

    function test_quoteTokenOracleFailover_RevertsWhenOldOracleStillDisagrees() public {
        MockOracle newQuoteOracle = new MockOracle();
        newQuoteOracle.setPrice(address(quoteToken), 2e8);

        harness.scheduleQuoteTokenOracleFailover(address(newQuoteOracle));
        uint256 executableAt = block.timestamp + harness.QUOTE_ORACLE_FAILOVER_DELAY();
        vm.warp(executableAt);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TWAPFeed.QuoteOracleSwapDeviationTooHigh.selector, 1e8, 2e8, 10000)
        );
        harness.executeQuoteTokenOracleFailover();

        assertEq(address(harness.quoteTokenOracle()), address(quoteOracle));
        assertEq(address(harness.scheduledQuoteTokenOracle()), address(newQuoteOracle));
        assertEq(harness.scheduledQuoteTokenOraclePrice(), 2e8);
    }

    function test_isPriceStale_ReflectsObserveAndLiquidityFailures() public {
        MockERC20 token = new MockERC20("Token", "TOKEN");
        MockUniswapV3Pool pool =
            new MockUniswapV3Pool(address(token), address(quoteToken), 0, harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());
        harness.setTokenPool(address(token), address(pool));

        (bool isStale, uint64 publishTime) = harness.isPriceStale(address(token));
        assertFalse(isStale);
        assertEq(publishTime, uint64(block.timestamp));

        pool.setAverageLiquidity(harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY() - 1);
        (isStale, publishTime) = harness.isPriceStale(address(token));
        assertTrue(isStale);
        assertEq(publishTime, 0);

        pool.setAverageLiquidity(harness.DEFAULT_MINIMUM_AVERAGE_LIQUIDITY());
        pool.setShouldRevertObserve(true);
        (isStale, publishTime) = harness.isPriceStale(address(token));
        assertTrue(isStale);
        assertEq(publishTime, 0);

        pool.setShouldRevertObserve(false);
        pool.setShouldReturnDescendingLiquidityCumulatives(true);
        (isStale, publishTime) = harness.isPriceStale(address(token));
        assertTrue(isStale);
        assertEq(publishTime, 0);
    }
}
