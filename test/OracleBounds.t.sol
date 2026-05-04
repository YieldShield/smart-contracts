// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythEMAOracleFeed } from "../contracts/oracles/PythEMAOracleFeed.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { UniswapV3TWAPFeed } from "../contracts/oracles/UniswapV3TWAPFeed.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

/// @title OracleBoundsTest
/// @notice Tests for oracle parameter upper/lower bounds (M-1, M-2, M-3 fixes)
contract OracleBoundsTest is Test {
    MockPyth public mockPyth;
    MockOracle public quoteOracle;
    MockERC20 public quoteToken;

    function setUp() public {
        mockPyth = new MockPyth(60, 1e15);
        quoteOracle = new MockOracle();
        quoteToken = new MockERC20("Quote", "QUOTE");
    }

    // ============ PythOracle: maxPriceAge bounds ============

    function testPythOracle_SetMaxPriceAge_RevertsAboveMaximum() public {
        PythOracle oracle = new PythOracle(address(mockPyth), 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.PriceAgeTooHigh.selector, 3601, 3600));
        oracle.setMaxPriceAge(3601);
    }

    function testPythOracle_SetMaxPriceAge_AcceptsMaximum() public {
        PythOracle oracle = new PythOracle(address(mockPyth), 60);
        oracle.setMaxPriceAge(3600);
        assertEq(oracle.maxPriceAge(), 3600);
    }

    function testPythOracle_SetMaxPriceAge_AcceptsMinimum() public {
        PythOracle oracle = new PythOracle(address(mockPyth), 60);
        oracle.setMaxPriceAge(10);
        assertEq(oracle.maxPriceAge(), 10);
    }

    function testPythOracle_SetMaxPriceAge_RevertsBelowMinimum() public {
        PythOracle oracle = new PythOracle(address(mockPyth), 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPriceAge.selector, 9, 10));
        oracle.setMaxPriceAge(9);
    }

    function testPythOracle_Constructor_RevertsAboveMaxPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(PythOracle.PriceAgeTooHigh.selector, 7200, 3600));
        new PythOracle(address(mockPyth), 7200);
    }

    function testPythOracle_Constructor_RevertsBelowMinPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPriceAge.selector, 5, 10));
        new PythOracle(address(mockPyth), 5);
    }

    function testPythOracle_Constructor_AcceptsBoundaryValues() public {
        PythOracle oracleMin = new PythOracle(address(mockPyth), 10);
        assertEq(oracleMin.maxPriceAge(), 10);

        PythOracle oracleMax = new PythOracle(address(mockPyth), 3600);
        assertEq(oracleMax.maxPriceAge(), 3600);
    }

    // ============ PythEMAOracleFeed: maxPriceAge bounds ============

    function testPythEMA_SetMaxPriceAge_RevertsAboveMaximum() public {
        PythEMAOracleFeed feed = new PythEMAOracleFeed(address(mockPyth), 60);
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.PriceAgeTooHigh.selector, 3601, 3600));
        feed.setMaxPriceAge(3601);
    }

    function testPythEMA_SetMaxPriceAge_AcceptsMaximum() public {
        PythEMAOracleFeed feed = new PythEMAOracleFeed(address(mockPyth), 60);
        feed.setMaxPriceAge(3600);
        assertEq(feed.maxPriceAge(), 3600);
    }

    function testPythEMA_Constructor_RevertsAboveMaxPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.PriceAgeTooHigh.selector, 7200, 3600));
        new PythEMAOracleFeed(address(mockPyth), 7200);
    }

    function testPythEMA_Constructor_RevertsBelowMinPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(PythEMAOracleFeed.InvalidPriceAge.selector, 5, 10));
        new PythEMAOracleFeed(address(mockPyth), 5);
    }

    function testPythEMA_Constructor_AcceptsBoundaryValues() public {
        PythEMAOracleFeed feedMin = new PythEMAOracleFeed(address(mockPyth), 10);
        assertEq(feedMin.maxPriceAge(), 10);

        PythEMAOracleFeed feedMax = new PythEMAOracleFeed(address(mockPyth), 3600);
        assertEq(feedMax.maxPriceAge(), 3600);
    }

    // ============ ChainlinkOracleFeed: maxPriceAge bounds ============

    function testChainlink_SetMaxPriceAge_RevertsAboveMaximum() public {
        ChainlinkOracleFeed feed = new ChainlinkOracleFeed(60);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.PriceAgeTooHigh.selector, 3601, 3600));
        feed.setMaxPriceAge(3601);
    }

    function testChainlink_SetMaxPriceAge_AcceptsMaximum() public {
        ChainlinkOracleFeed feed = new ChainlinkOracleFeed(60);
        feed.setMaxPriceAge(3600);
        assertEq(feed.maxPriceAge(), 3600);
    }

    function testChainlink_Constructor_RevertsAboveMaxPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.PriceAgeTooHigh.selector, 7200, 3600));
        new ChainlinkOracleFeed(7200);
    }

    function testChainlink_Constructor_RevertsBelowMinPriceAge() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.InvalidPriceAge.selector, 5, 10));
        new ChainlinkOracleFeed(5);
    }

    function testChainlink_Constructor_AcceptsBoundaryValues() public {
        ChainlinkOracleFeed feedMin = new ChainlinkOracleFeed(10);
        assertEq(feedMin.maxPriceAge(), 10);

        ChainlinkOracleFeed feedMax = new ChainlinkOracleFeed(3600);
        assertEq(feedMax.maxPriceAge(), 3600);
    }

    // ============ UniswapV3TWAPFeed: TWAP period bounds ============

    function testTWAP_SetTWAPPeriod_RevertsBelowMinimum() public {
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(1800, address(quoteToken), address(quoteOracle));
        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.InvalidTWAPPeriod.selector, 299, 300));
        feed.setTWAPPeriod(299);
    }

    function testTWAP_SetTWAPPeriod_AcceptsMinimum() public {
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(1800, address(quoteToken), address(quoteOracle));
        feed.setTWAPPeriod(300);
        assertEq(feed.twapPeriod(), 300);
    }

    function testTWAP_SetTWAPPeriod_AcceptsLargeValue() public {
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(1800, address(quoteToken), address(quoteOracle));
        feed.setTWAPPeriod(7200); // 2 hours
        assertEq(feed.twapPeriod(), 7200);
    }

    function testTWAP_Constructor_RevertsBelowMinTWAP() public {
        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.InvalidTWAPPeriod.selector, 60, 300));
        new UniswapV3TWAPFeed(60, address(quoteToken), address(quoteOracle));
    }

    function testTWAP_Constructor_RevertsAtZero() public {
        vm.expectRevert(abi.encodeWithSelector(UniswapV3TWAPFeed.InvalidTWAPPeriod.selector, 0, 300));
        new UniswapV3TWAPFeed(0, address(quoteToken), address(quoteOracle));
    }

    function testTWAP_Constructor_AcceptsMinimum() public {
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(300, address(quoteToken), address(quoteOracle));
        assertEq(feed.twapPeriod(), 300);
    }

    // ============ Constants are correct ============

    function testPythOracle_MaxPriceAgeLimit() public {
        PythOracle oracle = new PythOracle(address(mockPyth), 60);
        assertEq(oracle.MAX_PRICE_AGE_LIMIT(), 3600);
    }

    function testPythEMA_MaxPriceAgeLimit() public {
        PythEMAOracleFeed feed = new PythEMAOracleFeed(address(mockPyth), 60);
        assertEq(feed.MAX_PRICE_AGE_LIMIT(), 3600);
    }

    function testChainlink_MaxPriceAgeLimit() public {
        ChainlinkOracleFeed feed = new ChainlinkOracleFeed(60);
        assertEq(feed.MAX_PRICE_AGE_LIMIT(), 3600);
    }

    function testTWAP_MinTwapPeriod() public {
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(1800, address(quoteToken), address(quoteOracle));
        assertEq(feed.MIN_TWAP_PERIOD(), 300);
    }
}
