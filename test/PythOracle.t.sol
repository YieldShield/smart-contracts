// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockSequencerUptimeFeed } from "../contracts/mocks/MockSequencerUptimeFeed.sol";

contract RejectingPythRefundCaller {
    receive() external payable {
        revert("refund rejected");
    }

    function updatePriceFeeds(PythOracle oracle, bytes[] calldata priceUpdateData) external payable {
        oracle.updatePriceFeeds{ value: msg.value }(priceUpdateData);
    }

    function updatePriceFeedsWithRefundRecipient(
        PythOracle oracle,
        bytes[] calldata priceUpdateData,
        address refundRecipient
    ) external payable {
        oracle.updatePriceFeedsWithRefundRecipient{ value: msg.value }(priceUpdateData, refundRecipient);
    }
}

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
        assertEq(
            oracle.maxCompositePublishTimeSkew(),
            oracle.DEFAULT_COMPOSITE_PUBLISH_TIME_SKEW(),
            "composite skew should default on"
        );

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

    function _updatePriceFeedWithEmaPublishTime(
        bytes32 feedId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint64 spotPublishTime,
        uint64 emaPublishTime
    ) internal {
        PythStructs.PriceFeed memory priceFeed;
        priceFeed.id = feedId;
        priceFeed.price = PythStructs.Price({ price: price, conf: conf, expo: expo, publishTime: spotPublishTime });
        priceFeed.emaPrice = PythStructs.Price({ price: price, conf: conf, expo: expo, publishTime: emaPublishTime });

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = abi.encode(priceFeed);

        uint256 fee = mockPyth.getUpdateFee(updateDataArray);
        mockPyth.updatePriceFeeds{ value: fee }(updateDataArray);
    }

    function _updatePriceFeedWithEmaPrice(
        bytes32 feedId,
        int64 spotPrice,
        uint64 spotConf,
        int64 emaPrice,
        uint64 emaConf,
        int32 expo,
        uint64 publishTime
    ) internal {
        PythStructs.PriceFeed memory priceFeed;
        priceFeed.id = feedId;
        priceFeed.price = PythStructs.Price({ price: spotPrice, conf: spotConf, expo: expo, publishTime: publishTime });
        priceFeed.emaPrice = PythStructs.Price({ price: emaPrice, conf: emaConf, expo: expo, publishTime: publishTime });

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = abi.encode(priceFeed);

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
        // After the safe-default rename, the circuit-breaker-protected path lives under `getEquivalentAmount`.
        uint256 amountB = oracle.getEquivalentAmount(address(token6), 100e6, address(token8));
        assertEq(amountB, 100e8, "Circuit-breaker path should preserve destination token decimals");
    }

    function testGetEquivalentAmount_PreservesSubUsdPrecisionAcrossDecimals() public {
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_3, 1, 0, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp));

        uint256 amountB = oracle.getEquivalentAmount(address(token6), 1, address(token1));

        assertEq(amountB, 10_000, "direct conversion should preserve sub-USD dust");
    }

    function testSupportsStrictProtectedPriceTracksSupportedTokens() public view {
        assertTrue(
            oracle.supportsStrictProtectedPrice(address(token1)), "configured Pyth feed should support strict path"
        );
        assertFalse(
            oracle.supportsStrictProtectedPrice(address(0xBEEF)), "unsupported token should not support strict path"
        );
    }

    function testSupportsStrictProtectedPriceRequiresSequencerFeedOnKnownL2() public {
        vm.chainId(42161);
        vm.prank(owner);
        PythOracle l2Oracle = new PythOracle(address(mockPyth), MAX_PRICE_AGE);
        vm.prank(owner);
        l2Oracle.setTokenPriceFeed(address(token1), FEED_ID_1);

        assertFalse(
            l2Oracle.supportsStrictProtectedPrice(address(token1)),
            "strict marker should fail closed without required sequencer feed"
        );

        MockSequencerUptimeFeed sequencerFeed = new MockSequencerUptimeFeed();
        vm.prank(owner);
        l2Oracle.setSequencerUptimeFeed(address(sequencerFeed));

        assertTrue(
            l2Oracle.supportsStrictProtectedPrice(address(token1)),
            "strict marker should recover after sequencer feed is configured"
        );
    }

    function testPythFeedCanSatisfyCompositeStrictProtectedPriceRequirement() public {
        CompositeOracle composite = new CompositeOracle();
        composite.setTokenOracleFeed(address(token1), address(oracle));
        composite.setStrictCircuitBreakerRequired(address(token1), true);

        assertEq(composite.getPriceWithStrictCircuitBreaker(address(token1)), 1e8);
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

    function testGetPrice_RevertsForOverflowingPositiveExponent() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, type(int64).max, 0, 70, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPrice(address(token1));
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
        oracle.setMaxPriceAge(86_400); // MAX_PRICE_AGE_LIMIT

        vm.warp(block.timestamp + 60);
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp - 30));

        (bool isStale,) = oracle.isPriceStale(address(token1));
        assertFalse(isStale, "Price should not be stale within max age");
    }

    function testIsPriceStale_FuturePublishTimeFailsClosed() public {
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp + 1));

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "Future publish time should fail closed");
        assertEq(publishTime, uint64(block.timestamp + 1));
    }

    function testIsPriceStale_ChecksEmaLeg() public {
        vm.warp(block.timestamp + 1);
        uint64 staleEmaTime = uint64(block.timestamp - MAX_PRICE_AGE - 1);
        _updatePriceFeedWithEmaPublishTime(FEED_ID_1, 1e8, 1e6, -8, uint64(block.timestamp), staleEmaTime);

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));

        assertTrue(isStale, "Stale EMA leg should make protected price stale");
        assertEq(publishTime, staleEmaTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.StalePrice.selector, address(token1), FEED_ID_1, staleEmaTime, MAX_PRICE_AGE
            )
        );
        oracle.getPrice(address(token1));
    }

    function testIsPriceStale_ChecksCompositeQuoteEmaLeg() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        uint64 staleQuoteEmaTime = uint64(block.timestamp - MAX_PRICE_AGE - 1);
        _updatePriceFeedWithEmaPublishTime(FEED_ID_1, 1e8, 1e4, -8, uint64(block.timestamp), uint64(block.timestamp));
        _updatePriceFeedWithEmaPublishTime(FEED_ID_2, 1e8, 1e4, -8, uint64(block.timestamp), staleQuoteEmaTime);

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));

        assertTrue(isStale, "Stale quote EMA leg should make composite protected price stale");
        assertEq(publishTime, staleQuoteEmaTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.StalePrice.selector, address(token1), FEED_ID_2, staleQuoteEmaTime, MAX_PRICE_AGE
            )
        );
        oracle.getPrice(address(token1));
    }

    function testGetPriceUnsafe_RevertsForFuturePublishTime() public {
        uint256 futurePublishTime = block.timestamp + 1;
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.FuturePrice.selector, address(token1), FEED_ID_1, futurePublishTime, block.timestamp
            )
        );
        oracle.getPriceUnsafe(address(token1));
    }

    function testGetPrice_RevertsForFuturePublishTime() public {
        uint256 futurePublishTime = block.timestamp + 1;
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.FuturePrice.selector, address(token1), FEED_ID_1, futurePublishTime, block.timestamp
            )
        );
        oracle.getPrice(address(token1));
    }

    function testGetPrice_RevertsWithFuturePriceBeforeStaleCheck() public {
        uint256 futurePublishTime = block.timestamp + MAX_PRICE_AGE + 1;
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.FuturePrice.selector, address(token1), FEED_ID_1, futurePublishTime, block.timestamp
            )
        );
        oracle.getPrice(address(token1));
    }

    function testGetPrice_StalenessBoundaryUsesLocalError() public {
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);
        uint64 boundaryPublishTime = uint64(block.timestamp - MAX_PRICE_AGE);
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, boundaryPublishTime);
        assertEq(oracle.getPrice(address(token1)), 1e8, "Boundary age should remain fresh");

        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.StalePrice.selector, address(token1), FEED_ID_1, boundaryPublishTime, MAX_PRICE_AGE
            )
        );
        oracle.getPrice(address(token1));
    }

    function testGetEmaPrice_RevertsForFuturePublishTime() public {
        uint256 futurePublishTime = block.timestamp + 1;
        _updatePriceFeed(FEED_ID_1, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.FuturePrice.selector, address(token1), FEED_ID_1, futurePublishTime, block.timestamp
            )
        );
        oracle.getEmaPrice(address(token1));
    }

    function testGetPrice_RevertsForFutureCompositeQuotePublishTime() public {
        bytes32 baseFeedId = FEED_ID_1;
        bytes32 quoteFeedId = FEED_ID_2;
        uint256 futurePublishTime = block.timestamp + 1;

        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), baseFeedId, quoteFeedId);
        _updatePriceFeed(baseFeedId, 1e8, 1e6, -8, uint64(block.timestamp));
        _updatePriceFeed(quoteFeedId, 1e8, 1e6, -8, uint64(futurePublishTime));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.FuturePrice.selector, address(token1), quoteFeedId, futurePublishTime, block.timestamp
            )
        );
        oracle.getPriceUnsafe(address(token1));
    }

    function testSetMaxPriceAgeForTokenExtendsFreshnessForOneToken() public {
        vm.prank(owner);
        oracle.setMaxPriceAgeForToken(address(token1), 120);

        vm.warp(block.timestamp + 90);

        assertEq(oracle.getPrice(address(token1)), 1e8, "Per-token override should keep token1 fresh");

        vm.expectRevert();
        oracle.getPrice(address(token2));
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

    function testUpdatePriceFeedsWithRefundRecipientKeepsRejectingCallerLive() public {
        vm.warp(block.timestamp + 10);
        bytes memory updateData =
            mockPyth.createPriceFeedUpdateData(FEED_ID_1, 2e8, 1e6, -8, 2e8, 1e6, uint64(block.timestamp));

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);
        uint256 excessAmount = 1e17;
        address refundRecipient = address(0xB0B);
        RejectingPythRefundCaller refundRejectingCaller = new RejectingPythRefundCaller();

        vm.expectRevert(PythOracle.EtherRefundFailed.selector);
        refundRejectingCaller.updatePriceFeeds{ value: fee + excessAmount }(oracle, updateDataArray);
        assertEq(oracle.getPrice(address(token1)), 1e8, "failed refund should revert the update");

        refundRejectingCaller.updatePriceFeedsWithRefundRecipient{ value: fee + excessAmount }(
            oracle, updateDataArray, refundRecipient
        );

        assertEq(refundRecipient.balance, excessAmount, "explicit recipient should receive the refund");
        assertEq(oracle.getPrice(address(token1)), 2e8, "price should update when refund recipient accepts ETH");
    }

    function testUpdatePriceFeedsWithRefundRecipientRejectsZeroRecipient() public {
        bytes memory updateData =
            mockPyth.createPriceFeedUpdateData(FEED_ID_1, 1e8, 1e6, -8, 1e8, 1e6, uint64(block.timestamp));

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidRefundRecipient.selector, address(0)));
        oracle.updatePriceFeedsWithRefundRecipient{ value: fee }(updateDataArray, address(0));
    }

    function testUpdatePriceFeedsExactRejectsFeeMismatch() public {
        bytes memory updateData =
            mockPyth.createPriceFeedUpdateData(FEED_ID_1, 1e8, 1e6, -8, 1e8, 1e6, uint64(block.timestamp));

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;

        uint256 fee = oracle.getUpdateFee(updateDataArray);

        vm.expectRevert(abi.encodeWithSelector(PythOracle.UnexpectedUpdateFee.selector, fee, fee + 1));
        oracle.updatePriceFeedsExact{ value: fee + 1 }(updateDataArray);
    }

    function testUpdatePriceFeedsIfNecessaryWithRefundRecipientUpdatesAndRefunds() public {
        vm.warp(block.timestamp + 10);
        bytes memory updateData =
            mockPyth.createPriceFeedUpdateData(FEED_ID_1, 2e8, 1e6, -8, 2e8, 1e6, uint64(block.timestamp));

        bytes[] memory updateDataArray = new bytes[](1);
        updateDataArray[0] = updateData;
        bytes32[] memory priceIds = new bytes32[](1);
        priceIds[0] = FEED_ID_1;
        uint64[] memory publishTimes = new uint64[](1);
        publishTimes[0] = uint64(block.timestamp);

        uint256 fee = oracle.getUpdateFee(updateDataArray);
        uint256 excessAmount = 1e17;
        address refundRecipient = address(0xB0B);

        oracle.updatePriceFeedsIfNecessaryWithRefundRecipient{ value: fee + excessAmount }(
            updateDataArray, priceIds, publishTimes, refundRecipient
        );

        assertEq(refundRecipient.balance, excessAmount, "explicit recipient should receive the refund");
        assertEq(oracle.getPrice(address(token1)), 2e8, "necessary update should refresh the price");
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
        vm.expectRevert(abi.encodeWithSelector(PythOracle.TokenRemovalNotScheduled.selector, address(token1)));
        vm.prank(owner);
        oracle.removeToken(address(token1));

        vm.prank(owner);
        oracle.scheduleRemoveToken(address(token1));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.TokenRemovalTooEarly.selector,
                address(token1),
                block.timestamp + oracle.TOKEN_REMOVAL_DELAY()
            )
        );
        vm.prank(owner);
        oracle.removeToken(address(token1));

        vm.warp(block.timestamp + oracle.TOKEN_REMOVAL_DELAY());

        vm.prank(owner);
        oracle.removeToken(address(token1));

        assertFalse(oracle.isTokenSupported(address(token1)), "Token should not be supported");
        vm.expectRevert();
        oracle.getPrice(address(token1));
    }

    function testCancelScheduledRemoveToken() public {
        vm.prank(owner);
        oracle.scheduleRemoveToken(address(token1));

        vm.prank(owner);
        oracle.cancelScheduledRemoveToken(address(token1));

        vm.warp(block.timestamp + oracle.TOKEN_REMOVAL_DELAY());

        vm.expectRevert(abi.encodeWithSelector(PythOracle.TokenRemovalNotScheduled.selector, address(token1)));
        vm.prank(owner);
        oracle.removeToken(address(token1));
    }

    function testSetTokenPriceFeedClearsScheduledRemoval() public {
        vm.prank(owner);
        oracle.scheduleRemoveToken(address(token1));

        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token1), FEED_ID_1);

        assertEq(oracle.scheduledTokenRemovalTime(address(token1)), 0, "schedule should be cleared");
        vm.warp(block.timestamp + oracle.TOKEN_REMOVAL_DELAY());
        vm.expectRevert(abi.encodeWithSelector(PythOracle.TokenRemovalNotScheduled.selector, address(token1)));
        vm.prank(owner);
        oracle.removeToken(address(token1));
    }

    function testSetTokenPriceFeedClearsPerTokenMaxAgeOverride() public {
        vm.prank(owner);
        oracle.setMaxPriceAgeForToken(address(token1), 120);

        vm.prank(owner);
        oracle.setTokenPriceFeed(address(token1), FEED_ID_1);

        assertEq(oracle.maxPriceAgeForToken(address(token1)), 0, "override should be cleared");
        assertEq(oracle.effectiveMaxPriceAge(address(token1)), oracle.maxPriceAge(), "global max age should apply");
    }

    function testSetTokenCompositePriceFeedClearsScheduledRemoval() public {
        vm.prank(owner);
        oracle.scheduleRemoveToken(address(token1));

        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        assertEq(oracle.scheduledTokenRemovalTime(address(token1)), 0, "schedule should be cleared");
        vm.warp(block.timestamp + oracle.TOKEN_REMOVAL_DELAY());
        vm.expectRevert(abi.encodeWithSelector(PythOracle.TokenRemovalNotScheduled.selector, address(token1)));
        vm.prank(owner);
        oracle.removeToken(address(token1));
    }

    function testSetTokenCompositePriceFeedClearsPerTokenMaxAgeOverride() public {
        vm.prank(owner);
        oracle.setMaxPriceAgeForToken(address(token1), 120);

        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        assertEq(oracle.maxPriceAgeForToken(address(token1)), 0, "override should be cleared");
        assertEq(oracle.effectiveMaxPriceAge(address(token1)), oracle.maxPriceAge(), "global max age should apply");
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

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "wide confidence should make protected staleness true");
        assertEq(publishTime, uint64(block.timestamp));
    }

    function testGetPrice_AcceptsConfiguredConfidenceBound() public {
        vm.prank(owner);
        oracle.setMaxConfidenceBps(300);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 3e6, -8, uint64(block.timestamp));

        assertEq(oracle.getPrice(address(token1)), 1e8);
    }

    function testGetPriceWithCircuitBreaker_RevertsWhenEmaConfidenceTooWide() public {
        // After the safe-default rename, the protected price is exposed under `getPrice`.
        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 3e6, -8, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(PythOracle.PriceConfidenceTooWide.selector, address(token1), 3e6, 1e8, 200)
        );
        oracle.getPrice(address(token1));
    }

    function testIsPriceStale_ChecksSpotEmaDeviation() public {
        vm.warp(block.timestamp + 1);
        _updatePriceFeedWithEmaPrice(FEED_ID_1, 2e8, 1e4, 1e8, 1e4, -8, uint64(block.timestamp));

        vm.expectRevert();
        oracle.getPrice(address(token1));

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "spot/EMA deviation should make protected staleness true");
        assertEq(publishTime, uint64(block.timestamp));
    }

    function testCompositePriceFeed_MultipliesBaseQuoteByQuoteUsd() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 110e6, 1e4, -8, uint64(block.timestamp)); // 1.10 token/USDS
        _updatePriceFeed(FEED_ID_2, 95e6, 1e4, -8, uint64(block.timestamp)); // 0.95 USDS/USD

        assertEq(oracle.getPrice(address(token1)), 104_500_000, "composite price should be token/USD");
        assertEq(oracle.getPriceUnsafe(address(token1)), 104_500_000);
        assertEq(oracle.getEmaPrice(address(token1)), 104_500_000);
    }

    function testCompositePriceFeed_RevertsWhenProductRoundsToZero() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1, 0, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_2, 1, 0, -8, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPriceUnsafe(address(token1));
    }

    function testSetMaxCompositePublishTimeSkewRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidCompositePublishTimeSkew.selector, 0, 1));
        oracle.setMaxCompositePublishTimeSkew(0);
    }

    function testCompositePriceFeed_UsesSeparateQuoteFeedMaxAge() public {
        vm.startPrank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);
        oracle.setMaxPriceAgeForToken(address(token1), 120);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 1e8, 990_000, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_2, 1e8, 990_000, -8, uint64(block.timestamp));
        vm.warp(block.timestamp + 90);

        vm.expectRevert();
        oracle.getPrice(address(token1));

        vm.prank(owner);
        oracle.setMaxPriceAgeForFeedId(FEED_ID_2, 120);

        assertEq(oracle.getPrice(address(token1)), 1e8, "Quote feed override should be independent");

        vm.prank(owner);
        oracle.setMaxPriceAgeForToken(address(token1), 0);

        vm.expectRevert();
        oracle.getPrice(address(token1));
    }

    function testSetMaxPriceAgeForFeedIdOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setMaxPriceAgeForFeedId(FEED_ID_2, 120);
    }

    function testCompositePriceFeed_RevertsWhenPublishTimeSkewTooHigh() public {
        vm.startPrank(owner);
        oracle.setMaxCompositePublishTimeSkew(10);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        _updatePriceFeed(FEED_ID_1, 110e6, 1e4, -8, uint64(block.timestamp));
        _updatePriceFeed(FEED_ID_2, 95e6, 1e4, -8, uint64(block.timestamp - 11));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracle.CompositePublishTimeSkewTooHigh.selector,
                address(token1),
                FEED_ID_1,
                FEED_ID_2,
                block.timestamp,
                block.timestamp - 11,
                10
            )
        );
        oracle.getPrice(address(token1));

        (bool isStale,) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "Skewed composite feed should report stale");

        _updatePriceFeed(FEED_ID_2, 95e6, 1e4, -8, uint64(block.timestamp - 10));
        assertEq(oracle.getPrice(address(token1)), 104_500_000, "Boundary skew should pass");
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

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "wide quote confidence should make protected staleness true");
        assertEq(publishTime, uint64(block.timestamp));
    }

    function testCompositePriceFeed_RevertsWhenCombinedConfidenceTooWide() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 100e6, 1_010_000, -8, uint64(block.timestamp)); // 1.01%
        _updatePriceFeed(FEED_ID_2, 100e6, 1_000_000, -8, uint64(block.timestamp)); // 1.00%

        vm.expectRevert(
            abi.encodeWithSelector(PythOracle.CompositePriceConfidenceTooWide.selector, address(token1), 203, 200)
        );
        oracle.getPrice(address(token1));

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(address(token1));
        assertTrue(isStale, "wide combined confidence should make protected staleness true");
        assertEq(publishTime, uint64(block.timestamp));
    }

    function testCompositePriceFeed_AllowsCombinedConfidenceAtThreshold() public {
        vm.prank(owner);
        oracle.setTokenCompositePriceFeed(address(token1), FEED_ID_1, FEED_ID_2);

        vm.warp(block.timestamp + 1);
        _updatePriceFeed(FEED_ID_1, 100e6, 1_000_000, -8, uint64(block.timestamp)); // 1.00%
        _updatePriceFeed(FEED_ID_2, 100e6, 990_000, -8, uint64(block.timestamp)); // 0.99%

        assertEq(oracle.getPrice(address(token1)), 100_000_000);
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

    function testSetMaxPriceAgeForTokenOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setMaxPriceAgeForToken(address(token1), 120);
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

    /// @notice Test that the safe-default getEquivalentAmount reverts when priceB is 0
    /// @dev After the safe-default rename, the circuit-breaker-protected path lives under
    ///      `getEquivalentAmount`. When the underlying price is zero, `_convertPrice` reverts
    ///      with `InvalidPrice` before the EMA-deviation check is reached.
    function testGetEquivalentAmountWithCircuitBreaker_ZeroPriceB_Reverts() public {
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_2, 0, 0, -8, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token2), 0));
        oracle.getEquivalentAmount(address(token1), 100e18, address(token2));
    }

    /// @notice Test that the safe-default getPrice reverts when price is 0
    function testGetPriceWithCircuitBreaker_ZeroEMA_Reverts() public {
        // Set price feed with zero price (MockPyth uses same value for spot and EMA)
        vm.warp(block.timestamp + 10);
        _updatePriceFeed(FEED_ID_1, 0, 0, -8, uint64(block.timestamp));

        // After the safe-default rename, the protected price is exposed under `getPrice`.
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, address(token1), 0));
        oracle.getPrice(address(token1));
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

    function testGetPriceWithFallback_StaleSpotDegradesToEma() public {
        // INC-02: getPriceWithFallback must NOT revert when the spot read fails
        // during volatility/staleness — it must degrade to the EMA price with
        // isReliable=false. Here the spot is published 300s ago (> 60s max age)
        // while the EMA is fresh, so the spot read reverts internally and the
        // function must fall back to EMA instead of propagating the revert.
        vm.warp(block.timestamp + 1000);
        uint64 nowTs = uint64(block.timestamp);
        _updatePriceFeedWithEmaPublishTime(FEED_ID_1, 1e8, 1e6, -8, nowTs - 300, nowTs);

        (uint256 price, bool isReliable) = oracle.getPriceWithFallback(address(token1));
        assertEq(price, 1e8, "should degrade to the EMA price");
        assertFalse(isReliable, "stale spot must mark the price unreliable");
    }

    function testGetValueWithFallback_StaleSpotDegradesToEma() public {
        // The value helper delegates to getPriceWithFallback, so it inherits the
        // same graceful degradation (returns EMA-derived value, isReliable=false).
        vm.warp(block.timestamp + 1000);
        uint64 nowTs = uint64(block.timestamp);
        _updatePriceFeedWithEmaPublishTime(FEED_ID_1, 1e8, 1e6, -8, nowTs - 300, nowTs);

        (uint256 value, bool isReliable) = oracle.getValueWithFallback(address(token1), 100e18);
        assertEq(value, 100e8, "should value at the EMA price ($100)");
        assertFalse(isReliable, "stale spot must mark the value unreliable");
    }
}
