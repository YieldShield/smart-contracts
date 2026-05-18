// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";

contract PythOracleTest is Test {
    PythOracle public oracle;
    MockPyth public mockPyth;
    MockERC20 public token1;
    MockERC20 public token2;
    MockUSDC public token6;
    MockERC20Decimals public token8;

    bytes32 public constant FEED_ID_1 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 public constant FEED_ID_2 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 public constant FEED_ID_3 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 public constant FEED_ID_4 = 0x4444444444444444444444444444444444444444444444444444444444444444;

    address public owner = address(1);
    address public user = address(2);

    uint256 public constant MAX_PRICE_AGE = 60; // 60 seconds
    uint256 public constant VALID_TIME_PERIOD = 60;
    uint256 public constant SINGLE_UPDATE_FEE = 1e15; // 0.001 ETH

    function setUp() public {
        // Deploy MockPyth
        mockPyth = new MockPyth(VALID_TIME_PERIOD, SINGLE_UPDATE_FEE);

        // Deploy PythOracle
        vm.prank(owner);
        oracle = new PythOracle(address(mockPyth), MAX_PRICE_AGE);

        // Deploy test tokens
        token1 = new MockERC20("Token 1", "T1");
        token2 = new MockERC20("Token 2", "T2");
        token6 = new MockUSDC();
        token8 = new MockERC20Decimals("Token 8", "T8", 8);

        // Set up token to feed ID mappings
        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token1), FEED_ID_1);
        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token2), FEED_ID_2);
        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token6), FEED_ID_3);
        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token8), FEED_ID_4);

        // Set initial prices in MockPyth
        // Price: $1.00 (1e8) with expo = -8 means price = 1e8, expo = -8
        // Actual price = 1e8 * 10^-8 = 1.0
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_2, 1e8, 1e6, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_3, 1e8, 1e6, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_4, 1e8, 1e6, -8, uint64(block.timestamp));
    }

    function _updatePriceFeed(bytes32 feedId, int64 price, uint64 conf, int32 expo, uint64 publishTime) internal {
        bytes memory updateData = mockPyth.createPriceFeedUpdateData(
            feedId,
            price,
            conf,
            expo,
            price, // emaPrice (same as price for simplicity)
            conf, // emaConf
            publishTime
        );

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = mockPyth.getUpdateFee(updateDataArray);
        mockPyth.updatePriceFeeds{ value: fee }(updateDataArray);
    }

    /* ============ Basic Price Reading Tests ============ */

    function testGetPrice() public view {
        uint256 price = oracle.getPrice(address(token1));
        // Price should be 1e8 (8 decimals) for $1.00
        assertEq(price, 1e8, "Price should be $1.00 (1e8)");
    }

    function testGetValue() public view {
        uint256 amount = 100e18; // 100 tokens
        uint256 value = oracle.getValue(address(token1), amount);
        // 100 tokens * $1.00 = $100.00
        // value = (100e18 * 1e8) / 1e18 = 100e8
        assertEq(value, 100e8, "Value should be $100.00 (100e8)");
    }

    function testGetEquivalentAmount() public view {
        uint256 amountA = 100e18; // 100 tokens of token1
        uint256 amountB = oracle.getEquivalentAmount(address(token1), amountA, address(token2));
        // At equal prices, should get same amount
        assertEq(amountB, 100e18, "Should get equivalent amount at equal prices");
    }

    function testGetValue_SixDecimalToken() public view {
        uint256 amount = 100e6;
        uint256 value = oracle.getValue(address(token6), amount);
        assertEq(value, 100e8, "6-decimal token value should preserve native token scale");
    }

    function testGetValue_EightDecimalToken() public view {
        uint256 amount = 100e8;
        uint256 value = oracle.getValue(address(token8), amount);
        assertEq(value, 100e8, "8-decimal token value should preserve native token scale");
    }

    function testGetEquivalentAmount_SixToEighteenDecimals() public view {
        uint256 amountB = oracle.getEquivalentAmount(address(token6), 100e6, address(token1));
        assertEq(amountB, 100e18, "Equivalent amount should scale up to 18 decimals");
    }

    function testGetEquivalentAmount_EighteenToSixDecimals() public view {
        uint256 amountB = oracle.getEquivalentAmount(address(token1), 100e18, address(token6));
        assertEq(amountB, 100e6, "Equivalent amount should scale down to 6 decimals");
    }

    function testGetEquivalentAmountWithCircuitBreaker_SixToEightDecimals() public view {
        uint256 amountB = oracle.getEquivalentAmountWithCircuitBreaker(address(token6), 100e6, address(token8));
        assertEq(amountB, 100e8, "Circuit-breaker path should preserve destination token decimals");
    }

    /* ============ Staleness Tests ============ */

    function testStalePriceReverts() public {
        // Advance time beyond the max price age
        vm.warp(block.timestamp + MAX_PRICE_AGE + 10);

        // The original price from setUp is now stale
        // Should revert when trying to get price
        vm.expectRevert();
        oracle.getPrice(address(token1));
    }

    function testFreshPriceWorks() public {
        // Update price with recent publish time
        uint64 recentPublishTime = uint64(block.timestamp - 10); // 10 seconds ago
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, recentPublishTime);

        // Should work
        uint256 price = oracle.getPrice(address(token1));
        assertEq(price, 1e8, "Fresh price should work");
    }

    function testIsPriceStale() public {
        // Fresh price
        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertFalse(isStale, "Price should not be stale");
        assertGt(publishTime, 0, "Publish time should be set");

        // Make price stale by advancing time
        vm.warp(block.timestamp + MAX_PRICE_AGE + 10);

        (isStale, publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "Price should be stale");
    }

    function testIsPriceStale_UsesMaxAllowedAge() public {
        vm.prank(owner);
        oracle.setMaxPriceAge(3600); // MAX_PRICE_AGE_LIMIT

        vm.warp(block.timestamp + 60);
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp - 30));

        (bool isStale,) = oracle.isPriceStale(address(token1));
        assertFalse(isStale, "Price should not be stale within max age");
    }

    /* ============ Price Update Tests ============ */

    function testUpdatePriceFeeds() public {
        // Advance time to ensure new price is considered fresh
        vm.warp(block.timestamp + 10);

        // Create new price update with newer timestamp
        int64 newPrice = 2e8; // $2.00
        bytes memory updateData = mockPyth.createPriceFeedUpdateData(
            FEED_ID_1,
            newPrice,
            1e6,
            -8,
            newPrice, // emaPrice
            1e6, // emaConf
            uint64(block.timestamp)
        );

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);

        // Update prices
        vm.deal(user, fee);
        vm.prank(user);
        oracle.updatePriceFeeds{ value: fee }(updateDataArray);

        // Verify new price
        uint256 price = oracle.getPrice(address(token1));
        assertEq(price, 2e8, "Price should be updated to $2.00");
    }

    function testUpdatePriceFeedsRefundsExcess() public {
        bytes memory updateData = mockPyth.createPriceFeedUpdateData(
            FEED_ID_1,
            1e8,
            1e6,
            -8,
            1e8, // emaPrice
            1e6, // emaConf
            uint64(block.timestamp)
        );

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);
        uint256 excessAmount = 1e17; // 0.1 ETH excess

        vm.deal(user, fee + excessAmount);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        oracle.updatePriceFeeds{ value: fee + excessAmount }(updateDataArray);

        uint256 balanceAfter = user.balance;
        // Should refund the excess
        assertEq(balanceAfter, balanceBefore - fee, "Excess should be refunded");
    }

    function testUpdatePriceFeedsInsufficientFee() public {
        bytes memory updateData = mockPyth.createPriceFeedUpdateData(
            FEED_ID_1,
            1e8,
            1e6,
            -8,
            1e8, // emaPrice
            1e6, // emaConf
            uint64(block.timestamp)
        );

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);

        vm.deal(user, fee - 1);
        vm.prank(user);
        vm.expectRevert();
        oracle.updatePriceFeeds{ value: fee - 1 }(updateDataArray);
    }

    /* ============ Token Management Tests ============ */

    function testSetTokenPriceFeed() public {
        MockERC20 newToken = new MockERC20("Token 3", "T3");
        bytes32 newFeedId = 0x3333333333333333333333333333333333333333333333333333333333333333;

        vm.prank(owner);
        oracle.setTokenPriceFeed(address(newToken), newFeedId);

        assertTrue(oracle.isTokenSupported(address(newToken)), "Token should be supported");
        assertEq(oracle.tokenToPriceFeedId(address(newToken)), newFeedId, "Feed ID should be set");
    }

    function testRemoveToken() public {
        vm.prank(owner);
        oracle.removeToken(address(token1));

        assertFalse(oracle.isTokenSupported(address(token1)), "Token should not be supported");
        vm.expectRevert();
        oracle.getPrice(address(token1));
    }

    function testSetTokenPriceFeedOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setTokenPriceFeed(address(token1), FEED_ID_1);
    }

    /* ============ Price Conversion Tests ============ */

    function testPriceWithDifferentExpo() public {
        // Test with expo = -6 (price stored as 100 * 10^-6 = 0.0001)
        // But we want $1.00, so price should be 1e8
        // Actual: price * 10^-6 = 1.0, so price = 1e6
        _updatePriceFeed(FEED_ID_1, 1e6, 1e6, -6, uint64(block.timestamp));

        uint256 price = oracle.getPrice(address(token1));
        // Should convert to 8 decimals: 1e6 * 10^(-6 + 8) = 1e6 * 10^2 = 1e8
        assertEq(price, 1e8, "Price should convert correctly with expo = -6");
    }

    function testPriceWithPositiveExpo() public {
        // price=123, expo=2 means the raw Pyth value is 123 * 10^2 = 12,300.
        // Normalized to 8 USD decimals, that is 12,300e8.
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 123, 1, 2, uint64(block.timestamp));

        uint256 price = oracle.getPrice(address(token1));
        assertEq(price, 12_300e8, "Price should convert correctly with positive expo");
    }

    function testPriceWithNegativeExpoThatTruncatesToZeroReverts() public {
        // price = 1, expo = -12. adjustment = -4, so result = 1 / 10^4 = 0.
        // Must revert as InvalidPrice instead of silently propagating 0.
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1, 0, -12, uint64(block.timestamp));

        vm.expectRevert();
        oracle.getPrice(address(token1));
    }

    function testPriceWithZeroExpo() public {
        // price=1e8, expo=0 means the raw Pyth value is 100,000,000.
        // Normalized to 8 USD decimals, that is 1e8 * 1e8 = 1e16.
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, 0, uint64(block.timestamp));

        uint256 price = oracle.getPrice(address(token1));
        assertEq(price, 1e16, "Price should convert correctly with zero expo");
    }

    function testGetPrice_RevertsWhenConfidenceTooWide() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 3e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythOracle.PriceConfidenceTooWide.selector, address(token1), 3e6, 1e8, 200)
        );
        oracle.getPrice(address(token1));
    }

    function testGetPrice_AcceptsConfiguredConfidenceBound() public {
        vm.prank(owner);
        oracle.setMaxConfidenceBps(300);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 3e6, -8, uint64(block.timestamp));

        assertEq(oracle.getPrice(address(token1)), 1e8);
    }

    function testGetPriceWithCircuitBreaker_RevertsWhenEmaConfidenceTooWide() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 3e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythOracle.PriceConfidenceTooWide.selector, address(token1), 3e6, 1e8, 200)
        );
        oracle.getPriceWithCircuitBreaker(address(token1));
    }

    function testCompositePriceFeed_MultipliesBaseQuoteByQuoteUsd() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 110e6, 1e4, -8, uint64(block.timestamp)); // 1.10 token/USDS
        _updatePriceFeed(FEED_ID_2, 95e6, 1e4, -8, uint64(block.timestamp)); // 0.95 USDS/USD

        assertEq(oracle.getPrice(address(token1)), 104_500_000, "composite price should be token/USD");
        assertEq(oracle.getPriceWithCircuitBreaker(address(token1)), 104_500_000);
        assertEq(oracle.getEmaPrice(address(token1)), 104_500_000);
    }

    function testCompositePriceFeed_RevertsWhenQuoteConfidenceTooWide() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 110e6, 1e4, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_2, 95e6, 3e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythOracle.PriceConfidenceTooWide.selector, address(token1), 3e6, 95e6, 200)
        );
        oracle.getPrice(address(token1));
    }

    function testSetTokenPriceFeed_ClearsCompositeQuoteFeed() public {
        vm.startPrank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);
        assertEq(oracle.tokenToQuotePriceFeedId(address(token1)), FEED_ID_2);

        oracle.setTokenPriceFeed(address(token1), FEED_ID_1);
        vm.stopPrank();

        assertEq(oracle.tokenToQuotePriceFeedId(address(token1)), bytes32(0));
    }

    function testGetPrice_NegativePrice_Reverts() public {
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_1, -1, 1e6, -8, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPrice(address(token1));
    }

    /* ============ Edge Cases ============ */

    function testUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");

        vm.expectRevert();
        oracle.getPrice(address(unsupportedToken));
    }

    function testSetMaxPriceAge() public {
        uint256 newMaxAge = 120; // 2 minutes

        vm.prank(owner);
        oracle.setMaxPriceAge(newMaxAge);

        assertEq(oracle.maxPriceAge(), newMaxAge, "Max price age should be updated");
    }

    function testSetMaxPriceAgeOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setMaxPriceAge(120);
    }

    /* ============ Integration Tests ============ */

    function testMultipleTokens() public {
        // Advance time to ensure new prices are considered fresh
        vm.warp(block.timestamp + 10);

        // Set different prices with newer timestamp
        _updatePriceFeed(FEED_ID_1, 2e8, 1e6, -8, uint64(block.timestamp)); // $2.00
        _updatePriceFeed(FEED_ID_2, 0.5e8, 1e6, -8, uint64(block.timestamp)); // $0.50

        uint256 price1 = oracle.getPrice(address(token1));
        uint256 price2 = oracle.getPrice(address(token2));

        assertEq(price1, 2e8, "Token1 should be $2.00");
        assertEq(price2, 0.5e8, "Token2 should be $0.50");

        // Test equivalent amount
        uint256 amountA = 100e18; // 100 tokens of token1 = $200
        uint256 amountB = oracle.getEquivalentAmount(address(token1), amountA, address(token2));
        // $200 / $0.50 = 400 tokens
        assertEq(amountB, 400e18, "Should get 400 tokens of token2 for $200 value");
    }

    /* ============ Zero Price Protection Tests ============ */

    /// @notice Test that getEquivalentAmountWithCircuitBreaker reverts when priceB is 0
    /// @dev When price is 0, getPriceWithCircuitBreaker reverts with InvalidEMAPrice first
    ///      (since EMA is also 0). The InvalidPrice check in getEquivalentAmountWithCircuitBreaker
    ///      is defense-in-depth for cases where getPriceWithCircuitBreaker might return 0.
    function testGetEquivalentAmountWithCircuitBreaker_ZeroPriceB_Reverts() public {
        // Set token2 price to 0 (both spot and EMA)
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_2, 0, 0, -8, uint64(block.timestamp));

        // getPriceWithCircuitBreaker(tokenB) is called, which calls _convertPrice first
        // Since spot price is 0, _convertPrice reverts with InvalidPrice before EMA check
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token2), 0));
        oracle.getEquivalentAmountWithCircuitBreaker(address(token1), 100e18, address(token2));
    }

    /// @notice Test that getPriceWithCircuitBreaker reverts when price is 0
    function testGetPriceWithCircuitBreaker_ZeroEMA_Reverts() public {
        // Set price feed with zero price (MockPyth uses same value for spot and EMA)
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_1, 0, 0, -8, uint64(block.timestamp));

        // Should revert with InvalidPrice (spot price check happens before EMA check)
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPriceWithCircuitBreaker(address(token1));
    }

    /// @notice Test that getPriceWithFallback reverts when price is 0
    function testGetPriceWithFallback_ZeroEMA_Reverts() public {
        // Set price feed with zero price (MockPyth uses same value for spot and EMA)
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_1, 0, 0, -8, uint64(block.timestamp));

        // Should revert with InvalidPrice (spot price check happens before EMA check)
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPriceWithFallback(address(token1));
    }
}
