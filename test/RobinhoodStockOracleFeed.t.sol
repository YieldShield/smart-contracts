// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";
import { USMarketSessionGate } from "../contracts/oracles/USMarketSessionGate.sol";
import { MockChainlinkAggregator } from "../contracts/mocks/MockChainlinkAggregator.sol";
import { MockRobinhoodStockToken } from "../contracts/mocks/MockRobinhoodStockToken.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { ICorporateActionPauseGuard } from "../contracts/interfaces/ICorporateActionPauseGuard.sol";
import { IOracleFeed } from "../contracts/interfaces/IOracleFeed.sol";
import { OracleValidationLib } from "../contracts/libraries/OracleValidationLib.sol";

contract MockSixDecimalInnerFeed {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract LegacyEightDecimalInnerFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract RevertingMarketSessionGate {
    function emergencyPaused() external pure returns (bool) {
        return false;
    }

    function isMarketOpen() external pure returns (bool) {
        revert("status unavailable");
    }
}

contract RevertingEmergencyPauseMarketSessionGate {
    function emergencyPaused() external pure returns (bool) {
        revert("emergency status unavailable");
    }

    function isMarketOpen() external pure returns (bool) {
        return false;
    }
}

contract RevertingOpeningFreshnessInnerFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function protectionOpeningMaxPriceAgeForToken(address) external pure returns (uint256) {
        return 1 hours;
    }

    function isPriceStale(address) external pure returns (bool, uint256) {
        revert("staleness unavailable");
    }
}

contract CorporateGuardWithoutClosedSessionExitFeed is IOracleFeed, ICorporateActionPauseGuard {
    function getPrice(address) external pure returns (uint256) {
        return 1e8;
    }

    function getPriceUnsafe(address) external pure returns (uint256) {
        return 1e8;
    }

    function supportsCircuitBreaker(address) external pure returns (bool) {
        return true;
    }

    function supportsCorporateActionPauseGuard(address) external pure returns (bool) {
        return true;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Corporate Guard Only";
    }
}

contract RobinhoodStockOracleFeedTest is Test {
    ChainlinkOracleFeed internal chainlinkFeed;
    RobinhoodStockOracleFeed internal stockFeed;
    USMarketSessionGate internal marketSessionGate;
    MockChainlinkAggregator internal tslaAggregator;
    MockChainlinkAggregator internal wethAggregator;
    MockRobinhoodStockToken internal tsla;
    MockERC20 internal weth;

    int256 internal constant TSLA_PRICE = 33_200_000_000; // $332.00 with 8 decimals
    int256 internal constant TSLA_POST_SPLIT_PRICE = 3_320_000_000; // $33.20 after a 10:1 split
    int256 internal constant WETH_PRICE = 1735e8;
    uint256 internal constant MAX_PRICE_AGE = 1 days;
    uint256 internal constant OPENING_MAX_PRICE_AGE = 1 hours;

    function setUp() public {
        chainlinkFeed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        tsla = new MockRobinhoodStockToken("Robinhood Test TSLA", "TSLA");
        weth = new MockERC20("Robinhood Test WETH", "WETH");
        tslaAggregator = new MockChainlinkAggregator("TSLA / USD", 8, TSLA_PRICE);
        wethAggregator = new MockChainlinkAggregator("WETH / USD", 8, WETH_PRICE);
        chainlinkFeed.setTokenFeed(address(tsla), address(tslaAggregator));
        chainlinkFeed.setTokenFeed(address(weth), address(wethAggregator));
        chainlinkFeed.setProtectionOpeningMaxPriceAgeForToken(address(tsla), OPENING_MAX_PRICE_AGE);
        marketSessionGate = new USMarketSessionGate(address(this), address(0xBEEF));
        marketSessionGate.setDailySession(uint64(block.timestamp / 1 days), 0, uint32(1 days));
        stockFeed = new RobinhoodStockOracleFeed(address(chainlinkFeed), address(marketSessionGate));
    }

    // ============ Constructor ============

    function test_constructor_RevertsOnZeroInnerFeed() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.InvalidInnerFeed.selector, address(0)));
        new RobinhoodStockOracleFeed(address(0), address(marketSessionGate));
    }

    function test_constructor_RevertsOnNonEightDecimalInnerFeed() public {
        MockSixDecimalInnerFeed sixDecimalFeed = new MockSixDecimalInnerFeed();
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodStockOracleFeed.InvalidInnerFeedDecimals.selector, address(sixDecimalFeed), uint8(6)
            )
        );
        new RobinhoodStockOracleFeed(address(sixDecimalFeed), address(marketSessionGate));
    }

    function test_constructor_RevertsOnInvalidMarketSessionGate() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.InvalidMarketSessionGate.selector, address(0)));
        new RobinhoodStockOracleFeed(address(chainlinkFeed), address(0));
    }

    function test_constructor_SetsInnerFeed() public view {
        assertEq(stockFeed.innerFeed(), address(chainlinkFeed));
        assertEq(stockFeed.marketSessionGate(), address(marketSessionGate));
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

    function test_supportsCorporateActionPauseGuard_ReportsTrue() public view {
        assertTrue(stockFeed.supportsCorporateActionPauseGuard(address(tsla)));
    }

    // ============ Closed-session exit pricing ============

    function test_closedSessionExitPrice_AllowsSevenDayBoundaryAndRejectsOlderPrice() public {
        (,,, uint256 lastCloseTimestamp,) = tslaAggregator.latestRoundData();
        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        vm.warp(lastCloseTimestamp + chainlinkFeed.MAX_CLOSED_SESSION_EXIT_PRICE_AGE());

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleValidationLib.StalePrice.selector,
                address(tsla),
                lastCloseTimestamp,
                MAX_PRICE_AGE,
                block.timestamp
            )
        );
        stockFeed.getPrice(address(tsla));
        assertEq(stockFeed.getPriceForClosedSessionExit(address(tsla)), uint256(TSLA_PRICE));

        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleValidationLib.StalePrice.selector,
                address(tsla),
                lastCloseTimestamp,
                chainlinkFeed.MAX_CLOSED_SESSION_EXIT_PRICE_AGE(),
                block.timestamp
            )
        );
        stockFeed.getPriceForClosedSessionExit(address(tsla));
    }

    function test_closedSessionExitPrice_RejectsStalePriceWhileMarketIsOpen() public {
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);
        marketSessionGate.setDailySession(uint64(block.timestamp / 1 days), 0, uint32(1 days));

        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.MarketSessionOpen.selector, address(tsla)));
        stockFeed.getPriceForClosedSessionExit(address(tsla));
    }

    function test_closedSessionExitPrice_RejectsEmergencyPauseInsteadOfTreatingItAsScheduledClosure() public {
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);
        marketSessionGate.setDailySession(uint64(block.timestamp / 1 days), 0, uint32(1 days));
        vm.prank(address(0xBEEF));
        marketSessionGate.emergencyPause();

        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleFeed.MarketSessionEmergencyPaused.selector, address(tsla))
        );
        stockFeed.getPriceForClosedSessionExit(address(tsla));
    }

    function test_closedSessionExitPrice_FailsClosedForCorporatePauseAndMissingPauseProbe() public {
        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        tsla.setOraclePaused(true);

        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        stockFeed.getPriceForClosedSessionExit(address(tsla));

        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenPauseProbeFailed.selector, address(weth))
        );
        stockFeed.getPriceForClosedSessionExit(address(weth));
    }

    function test_closedSessionExitPrice_FailsClosedWhenMarketStatusReverts() public {
        RevertingMarketSessionGate revertingGate = new RevertingMarketSessionGate();
        RobinhoodStockOracleFeed feedWithBrokenGate =
            new RobinhoodStockOracleFeed(address(chainlinkFeed), address(revertingGate));

        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodStockOracleFeed.MarketSessionStatusUnavailable.selector, address(revertingGate)
            )
        );
        feedWithBrokenGate.getPriceForClosedSessionExit(address(tsla));
    }

    function test_closedSessionExitPrice_FailsClosedWhenEmergencyStatusReverts() public {
        RevertingEmergencyPauseMarketSessionGate revertingGate = new RevertingEmergencyPauseMarketSessionGate();
        RobinhoodStockOracleFeed feedWithBrokenGate =
            new RobinhoodStockOracleFeed(address(chainlinkFeed), address(revertingGate));

        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodStockOracleFeed.MarketSessionStatusUnavailable.selector, address(revertingGate)
            )
        );
        feedWithBrokenGate.getPriceForClosedSessionExit(address(tsla));
    }

    // ============ Protection opening eligibility ============

    function test_openingEligibility_AllowsConfiguredOpenSession() public view {
        assertTrue(stockFeed.supportsProtectionOpeningEligibility(address(tsla)));
        assertTrue(stockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertTrue(stockFeed.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_openingEligibility_RequiresExplicitReviewedFreshnessPolicy() public {
        chainlinkFeed.setProtectionOpeningMaxPriceAgeForToken(address(tsla), 0);

        assertFalse(stockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));
        assertEq(stockFeed.getPrice(address(tsla)), uint256(TSLA_PRICE), "ordinary pricing must remain available");

        chainlinkFeed.setProtectionOpeningMaxPriceAgeForToken(
            address(tsla), stockFeed.MAX_PROTECTION_OPENING_PRICE_AGE() + 1
        );
        assertFalse(stockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_openingEligibility_FailsClosedWhenInnerFeedLacksOpeningFreshnessInterface() public {
        LegacyEightDecimalInnerFeed legacyInner = new LegacyEightDecimalInnerFeed();
        RobinhoodStockOracleFeed legacyStockFeed =
            new RobinhoodStockOracleFeed(address(legacyInner), address(marketSessionGate));

        assertFalse(legacyStockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertFalse(legacyStockFeed.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_openingEligibility_UsesTighterOpeningAgeWithoutShorteningOrdinaryPrice() public {
        (,,, uint256 updatedAt,) = tslaAggregator.latestRoundData();
        vm.warp(updatedAt + OPENING_MAX_PRICE_AGE);
        assertTrue(stockFeed.isProtectionOpeningAllowed(address(tsla)), "exact opening-age boundary must pass");

        vm.warp(block.timestamp + 1);
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)), "opening-age boundary + 1 must fail");
        assertEq(
            chainlinkFeed.getPrice(address(tsla)),
            uint256(TSLA_PRICE),
            "generic 24-hour price path must remain available"
        );
    }

    function test_openingEligibility_FeedReplacementClearsReviewedFreshnessPolicy() public {
        chainlinkFeed.setTokenFeed(address(tsla), address(tslaAggregator));

        assertEq(chainlinkFeed.protectionOpeningMaxPriceAgeForToken(address(tsla)), 0);
        assertFalse(stockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_openingEligibility_FailsClosedForFutureTimestampAndRevertingStaleness() public {
        tslaAggregator.setRoundData(2, TSLA_PRICE, block.timestamp, block.timestamp + 1, 2);
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));

        RevertingOpeningFreshnessInnerFeed revertingInner = new RevertingOpeningFreshnessInnerFeed();
        RobinhoodStockOracleFeed revertingStockFeed =
            new RobinhoodStockOracleFeed(address(revertingInner), address(marketSessionGate));
        assertTrue(revertingStockFeed.isProtectionOpeningFreshnessConfigured(address(tsla)));
        assertFalse(revertingStockFeed.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_openingEligibility_ClosedSessionDoesNotDisablePriceReads() public {
        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));

        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));
        assertEq(stockFeed.getPrice(address(tsla)), uint256(TSLA_PRICE));
    }

    function test_openingEligibility_FailsClosedForPausedOrUnsupportedToken() public {
        tsla.setOraclePaused(true);
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(tsla)));
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(weth)));
    }

    function test_openingEligibility_FailsClosedWhenMarketStatusCallReverts() public {
        RevertingMarketSessionGate revertingGate = new RevertingMarketSessionGate();
        RobinhoodStockOracleFeed feedWithBrokenGate =
            new RobinhoodStockOracleFeed(address(chainlinkFeed), address(revertingGate));

        assertFalse(feedWithBrokenGate.isProtectionOpeningAllowed(address(tsla)));
        assertEq(feedWithBrokenGate.getPrice(address(tsla)), uint256(TSLA_PRICE));
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
        assertTrue(composite.protectionOpeningEligibilityRequired(address(tsla)));
        assertTrue(composite.isProtectionOpeningAllowed(address(tsla)));

        // Unwrapped ChainlinkOracleFeed must keep detecting as plain "chainlink".
        composite.setTokenOracleFeed(address(weth), address(chainlinkFeed));
        assertEq(composite.getOracleType(address(weth)), "chainlink");
        assertEq(composite.getPrice(address(weth)), uint256(WETH_PRICE));

        // The pause guard propagates through the composite's protected price path.
        tsla.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, address(tsla)));
        composite.getPrice(address(tsla));
    }

    function test_compositeOracle_ClosedPrimaryGateAppliesWhileBackupIsActive() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupFeed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE * 2);
        backupFeed.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed guardedBackupFeed =
            new RobinhoodStockOracleFeed(address(backupFeed), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(guardedBackupFeed));

        composite.challengeForToken(address(tsla));
        vm.warp(block.timestamp + composite.challengeDurationSec() + 1);
        backupAggregator.setAnswer(TSLA_PRICE * 2);
        composite.finalizeChallenge(address(tsla));
        assertTrue(composite.isBackupActiveForToken(address(tsla)));

        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        // Opening policy must still come from the primary stock wrapper rather than the
        // now-active plain backup feed.
        assertFalse(composite.isProtectionOpeningAllowed(address(tsla)));
    }

    function test_compositeOracle_RejectsDualRouteWhenOnlyPrimaryHasCorporateActionPauseGuard() public {
        CompositeOracle composite = new CompositeOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CorporateActionPauseGuardMismatch.selector,
                address(tsla),
                address(stockFeed),
                address(chainlinkFeed)
            )
        );
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(chainlinkFeed));
    }

    function test_compositeOracle_RejectsDualRouteWhenOnlyBackupHasCorporateActionPauseGuard() public {
        CompositeOracle composite = new CompositeOracle();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CorporateActionPauseGuardMismatch.selector,
                address(tsla),
                address(chainlinkFeed),
                address(stockFeed)
            )
        );
        composite.setTokenOracleFeedDual(address(tsla), address(chainlinkFeed), address(stockFeed));
    }

    function test_compositeOracle_RejectsDualRouteWithClosedSessionCapabilityMismatch() public {
        CompositeOracle composite = new CompositeOracle();
        CorporateGuardWithoutClosedSessionExitFeed backup = new CorporateGuardWithoutClosedSessionExitFeed();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ClosedSessionExitPriceMismatch.selector,
                address(tsla),
                address(stockFeed),
                address(backup)
            )
        );
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));
    }

    function test_compositeOracle_ClosedSessionExitPreservesPendingChallengeGate() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupInner = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE * 2);
        backupInner.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed backup = new RobinhoodStockOracleFeed(address(backupInner), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));

        composite.challengeForToken(address(tsla));
        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(tsla)));
        composite.getPriceForClosedSessionExit(address(tsla));
    }

    function test_compositeOracle_ClosedSessionDualRouteSucceedsWhenExtendedPricesAgree() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupInner = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE);
        backupInner.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed backup = new RobinhoodStockOracleFeed(address(backupInner), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));

        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        assertEq(composite.getPriceForClosedSessionExit(address(tsla)), uint256(TSLA_PRICE));
    }

    function test_compositeOracle_ClosedSessionDualRouteRejectsExtendedPriceDeviation() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupInner = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE * 2);
        backupInner.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed backup = new RobinhoodStockOracleFeed(address(backupInner), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));

        marketSessionGate.clearDailySession(uint64(block.timestamp / 1 days));
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(tsla)));
        composite.getPriceForClosedSessionExit(address(tsla));
    }

    function test_compositeOracle_ClosedSessionActiveBackupSurvivesUnavailablePrimary() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupInner = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE * 2);
        backupInner.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed backup = new RobinhoodStockOracleFeed(address(backupInner), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));

        composite.challengeForToken(address(tsla));
        vm.warp(block.timestamp + composite.challengeDurationSec() + 1);
        backupAggregator.setAnswer(TSLA_PRICE * 2);
        composite.finalizeChallenge(address(tsla));
        assertTrue(composite.isBackupActiveForToken(address(tsla)));

        vm.warp(block.timestamp + chainlinkFeed.MAX_CLOSED_SESSION_EXIT_PRICE_AGE() + 1);
        backupAggregator.setAnswer(TSLA_PRICE * 2);
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        assertEq(composite.getPriceForClosedSessionExit(address(tsla)), uint256(TSLA_PRICE * 2));
    }

    function test_compositeOracle_ClosedSessionActivePrimaryRejectsUnavailableBackup() public {
        CompositeOracle composite = new CompositeOracle();
        ChainlinkOracleFeed backupInner = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        MockChainlinkAggregator backupAggregator = new MockChainlinkAggregator("TSLA backup / USD", 8, TSLA_PRICE);
        backupInner.setTokenFeed(address(tsla), address(backupAggregator));
        RobinhoodStockOracleFeed backup = new RobinhoodStockOracleFeed(address(backupInner), address(marketSessionGate));
        composite.setTokenOracleFeedDual(address(tsla), address(stockFeed), address(backup));

        vm.warp(block.timestamp + chainlinkFeed.MAX_CLOSED_SESSION_EXIT_PRICE_AGE() + 1);
        tslaAggregator.setAnswer(TSLA_PRICE);
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(tsla)));
        composite.getPriceForClosedSessionExit(address(tsla));
    }
}
