// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { AggregatorV3Interface, ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { IRobinhoodStockToken, RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";
import { ForkTestHelper } from "./helpers/ForkTestHelper.sol";

contract AlwaysOpenMarketSessionGate {
    function emergencyPaused() external pure returns (bool) {
        return false;
    }

    function isMarketOpen() external pure returns (bool) {
        return true;
    }
}

contract AlwaysClosedMarketSessionGate {
    function emergencyPaused() external pure returns (bool) {
        return false;
    }

    function isMarketOpen() external pure returns (bool) {
        return false;
    }
}

/// @notice Required push-time smoke test for the production Robinhood integration.
/// @dev The canonical addresses come from Robinhood's token registry and Chainlink's
///      Robinhood feed registry. The assertions deliberately do not require the feed
///      to be fresh or the token to be unpaused: both states are normal during closed
///      sessions and corporate actions. Instead, each observed state must produce the
///      protocol's exact fail-closed or live-price behavior.
contract RobinhoodMainnetForkTest is ForkTestHelper {
    uint256 internal constant ROBINHOOD_MAINNET_CHAIN_ID = 4_663;
    uint256 internal constant MAX_PRICE_AGE = 1 days;
    uint256 internal constant OPENING_MAX_PRICE_AGE = 1 hours;

    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant TSLA_USD_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;

    modifier onlyRobinhoodMainnet() {
        string memory forkUrl = _forkUrlOrSkip("ROBINHOOD_RPC_URL", "Robinhood mainnet");
        if (bytes(forkUrl).length == 0) {
            return;
        }
        vm.createSelectFork(forkUrl);
        _;
    }

    function testRobinhoodCanonicalStockAndFeedIntegration() public onlyRobinhoodMainnet {
        assertEq(block.chainid, ROBINHOOD_MAINNET_CHAIN_ID, "unexpected Robinhood chain ID");
        assertGt(TSLA.code.length, 0, "canonical TSLA token has no code");
        assertGt(TSLA_USD_FEED.code.length, 0, "canonical TSLA/USD feed has no code");

        (bool pauseProbeSucceeded, bytes memory pauseProbeData) =
            TSLA.staticcall(abi.encodeWithSelector(IRobinhoodStockToken.oraclePaused.selector));
        assertTrue(pauseProbeSucceeded, "canonical TSLA token is missing oraclePaused()");
        assertEq(pauseProbeData.length, 32, "oraclePaused() returned malformed data");
        bool oraclePaused = abi.decode(pauseProbeData, (bool));

        AggregatorV3Interface liveFeed = AggregatorV3Interface(TSLA_USD_FEED);
        assertEq(liveFeed.decimals(), 8, "TSLA/USD feed decimals changed");
        assertGt(bytes(liveFeed.description()).length, 0, "TSLA/USD feed description is empty");
        assertGt(liveFeed.version(), 0, "TSLA/USD feed version is invalid");

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            liveFeed.latestRoundData();
        assertGt(roundId, 0, "TSLA/USD feed has no round");
        assertGt(answer, 0, "TSLA/USD feed answer is non-positive");
        assertGt(startedAt, 0, "TSLA/USD feed round never started");
        assertGt(updatedAt, 0, "TSLA/USD feed round was never updated");
        assertLe(updatedAt, block.timestamp, "TSLA/USD feed update is future-dated");
        assertGe(answeredInRound, roundId, "TSLA/USD feed round is incomplete");

        ChainlinkOracleFeed innerFeed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        assertTrue(innerFeed.sequencerUptimeFeedRequired(), "Robinhood must default to sequencer protection");

        // The canonical sequencer uptime proxy is a separately enforced release
        // prerequisite. Disable that check only in this integration fixture so it
        // can independently detect stock-token and price-feed registry drift.
        innerFeed.setSequencerUptimeFeedRequired(false);
        innerFeed.setTokenFeed(TSLA, TSLA_USD_FEED);
        innerFeed.setProtectionOpeningMaxPriceAgeForToken(TSLA, OPENING_MAX_PRICE_AGE);

        AlwaysOpenMarketSessionGate marketGate = new AlwaysOpenMarketSessionGate();
        AlwaysClosedMarketSessionGate closedMarketGate = new AlwaysClosedMarketSessionGate();
        RobinhoodStockOracleFeed stockFeed = new RobinhoodStockOracleFeed(address(innerFeed), address(marketGate));
        RobinhoodStockOracleFeed closedMarketStockFeed =
            new RobinhoodStockOracleFeed(address(innerFeed), address(closedMarketGate));

        assertEq(address(innerFeed.tokenFeeds(TSLA)), TSLA_USD_FEED, "adapter feed address mismatch");
        assertTrue(stockFeed.supportsCircuitBreaker(TSLA), "circuit-breaker capability missing");
        assertTrue(stockFeed.supportsStrictProtectedPrice(TSLA), "strict-price capability missing");
        assertTrue(stockFeed.supportsCorporateActionPauseGuard(TSLA), "pause-guard capability missing");
        assertFalse(
            closedMarketStockFeed.isProtectionOpeningAllowed(TSLA), "closed market allowed a protection opening"
        );

        (bool isStale, uint256 adapterUpdatedAt) = stockFeed.isPriceStale(TSLA);
        (bool closedMarketIsStale, uint256 closedMarketUpdatedAt) = closedMarketStockFeed.isPriceStale(TSLA);
        assertEq(closedMarketIsStale, isStale, "market closure changed feed staleness");
        assertEq(closedMarketUpdatedAt, adapterUpdatedAt, "market closure changed the feed timestamp");
        if (oraclePaused) {
            assertTrue(isStale, "paused stock token must be stale");
            assertEq(adapterUpdatedAt, 0, "paused stock token must hide the feed timestamp");
            assertFalse(stockFeed.isProtectionOpeningAllowed(TSLA), "paused token allowed a protection opening");
            vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, TSLA));
            stockFeed.getPrice(TSLA);
            vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleFeed.StockTokenOraclePaused.selector, TSLA));
            closedMarketStockFeed.getPrice(TSLA);
            return;
        }

        assertEq(adapterUpdatedAt, updatedAt, "adapter returned the wrong feed timestamp");
        if (isStale) {
            assertFalse(stockFeed.isProtectionOpeningAllowed(TSLA), "stale token allowed a protection opening");
            vm.expectRevert(
                abi.encodeWithSelector(ChainlinkOracleFeed.StalePrice.selector, TSLA, updatedAt, MAX_PRICE_AGE)
            );
            stockFeed.getPrice(TSLA);
            vm.expectRevert(
                abi.encodeWithSelector(ChainlinkOracleFeed.StalePrice.selector, TSLA, updatedAt, MAX_PRICE_AGE)
            );
            closedMarketStockFeed.getPrice(TSLA);
        } else {
            bool openingFresh = block.timestamp - updatedAt <= OPENING_MAX_PRICE_AGE;
            assertEq(
                stockFeed.isProtectionOpeningAllowed(TSLA),
                openingFresh,
                "opening eligibility ignored equity-specific freshness"
            );
            assertEq(stockFeed.getPrice(TSLA), uint256(answer), "adapter changed the 8-decimal feed answer");
            assertEq(
                closedMarketStockFeed.getPrice(TSLA),
                uint256(answer),
                "market closure changed the 8-decimal feed answer"
            );
        }
    }
}
