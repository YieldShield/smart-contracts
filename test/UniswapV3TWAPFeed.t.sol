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

    function priceFromTick(int24 tick, bool isToken0) external pure returns (uint256) {
        return _getPriceFromTick(tick, isToken0);
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
        uint256 actual = harness.priceFromTick(tick, true);
        assertEq(actual, expected, "price should match TickMath for token0");
    }

    function test_priceFromTick_MatchesTickMath_NegativeTick() public view {
        int24 tick = -20000;
        uint256 expected = _expectedPriceFromTick(tick, false);
        uint256 actual = harness.priceFromTick(tick, false);
        assertEq(actual, expected, "price should match TickMath for token1");
    }

    function test_priceFromTick_PreservesFractionalPriceBeforeScaling() public view {
        int24 tick = 4055;

        uint256 token0Price = harness.priceFromTick(tick, true);
        uint256 token1Price = harness.priceFromTick(tick, false);

        assertEq(token0Price, _expectedPriceFromTick(tick, true), "token0 price should keep sub-unit precision");
        assertEq(token1Price, _expectedPriceFromTick(tick, false), "token1 inverse should keep sub-unit precision");
        assertGt(token0Price, 1.4e18, "old math truncated token0 price to 1e18");
        assertLt(token1Price, 0.7e18, "old math truncated token1 inverse to 1e18");
    }
}
