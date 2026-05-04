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
        uint256 priceX192 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        uint256 price = FullMath.mulDiv(priceX192, 1e18, 1);

        if (!isToken0) {
            // L-3 FIX: Prevent division by zero when price rounds to 0
            if (price == 0) {
                price = FullMath.mulDiv(1e36, 1 << 192, uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
            } else {
                price = FullMath.mulDiv(1e36, 1, price);
            }
        }

        return price;
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
}
