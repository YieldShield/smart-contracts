// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test, console } from "forge-std/Test.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { MockSequencerUptimeFeed } from "../contracts/mocks/MockSequencerUptimeFeed.sol";

/// @title MockChainlinkPriceFeed
/// @notice Mock Chainlink price feed for unit testing
contract MockChainlinkPriceFeed {
    int256 private _price;
    uint8 private _decimals;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor(int256 price, uint8 feedDecimals) {
        _price = price;
        _decimals = feedDecimals;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    function setPrice(int256 price) external {
        _price = price;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Price Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}

/// @title ChainlinkL2SequencerTest
/// @notice Tests for L2 sequencer uptime check in ChainlinkOracleFeed
contract ChainlinkL2SequencerTest is Test {
    ChainlinkOracleFeed public chainlinkFeed;
    MockChainlinkPriceFeed public mockPriceFeed;
    MockSequencerUptimeFeed public mockSequencerFeed;

    address public testToken = address(0x1234);
    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour
    int256 public constant ETH_PRICE = 2000e8; // $2000

    function setUp() public {
        chainlinkFeed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        mockPriceFeed = new MockChainlinkPriceFeed(ETH_PRICE, 8);
        mockSequencerFeed = new MockSequencerUptimeFeed();

        // Set up the price feed
        chainlinkFeed.setTokenFeed(testToken, address(mockPriceFeed));
    }

    function _deployFeedForCurrentChain() internal returns (ChainlinkOracleFeed feed) {
        feed = new ChainlinkOracleFeed(MAX_PRICE_AGE);
        feed.setTokenFeed(testToken, address(mockPriceFeed));
    }

    // ============ No Sequencer Feed (L1 or disabled) ============

    function test_GetPrice_WorksWithoutSequencerFeed() public view {
        // Without sequencer feed set, should work normally
        uint256 price = chainlinkFeed.getPrice(testToken);
        assertEq(price, uint256(ETH_PRICE));
    }

    function test_GetPrice_RevertsWithoutSequencerFeedOnKnownL2() public {
        vm.chainId(42161);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.SequencerUptimeFeedRequired.selector, 42161));
        l2Feed.getPrice(testToken);
    }

    function test_IsPriceStale_ReturnsTrueWithoutSequencerFeedOnKnownL2() public {
        vm.chainId(8453);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();

        (bool isStale, uint256 updatedAt) = l2Feed.isPriceStale(testToken);

        assertTrue(isStale);
        assertEq(updatedAt, 0);
    }

    function test_IsPriceStale_ReturnsTrueForInvalidPriceRound() public {
        mockPriceFeed.setPrice(0);

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);

        assertTrue(isStale);
        assertEq(updatedAt, block.timestamp);
    }

    function test_GetSequencerStatus_FailsClosedWithoutFeedOnKnownL2() public {
        vm.chainId(10);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();

        (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) = l2Feed.getSequencerStatus();

        assertFalse(isUp);
        assertFalse(gracePeriodPassed);
        assertEq(timeSinceUp, 0);
    }

    function test_GetPriceWithCircuitBreaker_UsesChainlinkValidation() public view {
        // After the safe-default rename, the protected price is exposed under `getPrice`.
        uint256 price = chainlinkFeed.getPrice(testToken);
        assertEq(price, uint256(ETH_PRICE));
        // The unsafe alias still returns the same value (Chainlink has no separate raw path).
        assertEq(chainlinkFeed.getPriceUnsafe(testToken), uint256(ETH_PRICE));
    }

    function test_CompositeOracleUsesChainlinkCircuitBreakerPrice() public {
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeed(testToken, address(chainlinkFeed));

        assertEq(compositeOracle.getPrice(testToken), uint256(ETH_PRICE));
    }

    function test_GetSequencerStatus_NoFeedConfigured() public view {
        (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) = chainlinkFeed.getSequencerStatus();
        assertTrue(isUp);
        assertTrue(gracePeriodPassed);
        assertEq(timeSinceUp, 0);
    }

    // ============ Setting Sequencer Feed ============

    function test_SetSequencerUptimeFeed() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        assertEq(address(chainlinkFeed.sequencerUptimeFeed()), address(mockSequencerFeed));
    }

    function test_SetSequencerUptimeFeed_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ChainlinkOracleFeed.SequencerUptimeFeedSet(address(0), address(mockSequencerFeed));

        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
    }

    function test_SetSequencerUptimeFeed_CanDisable() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        assertEq(address(chainlinkFeed.sequencerUptimeFeed()), address(mockSequencerFeed));

        // Disable by setting to zero
        chainlinkFeed.setSequencerUptimeFeed(address(0));
        assertEq(address(chainlinkFeed.sequencerUptimeFeed()), address(0));
    }

    function test_SetSequencerUptimeFeed_CannotDisableOnKnownL2() public {
        vm.chainId(42161);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();
        l2Feed.setSequencerUptimeFeed(address(mockSequencerFeed));

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.SequencerUptimeFeedRequired.selector, 42161));
        l2Feed.setSequencerUptimeFeed(address(0));
    }

    function test_Constructor_DefaultsSequencerRequiredOnKnownL2() public {
        vm.chainId(42161);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();
        assertTrue(l2Feed.sequencerUptimeFeedRequired());
    }

    function test_Constructor_DefaultsSequencerRequiredOnRobinhoodTestnet() public {
        vm.chainId(46630);
        ChainlinkOracleFeed l2Feed = _deployFeedForCurrentChain();
        assertTrue(l2Feed.sequencerUptimeFeedRequired());

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.SequencerUptimeFeedRequired.selector, 46630));
        l2Feed.getPrice(testToken);
    }

    function test_Constructor_DoesNotRequireSequencerOnUnlistedChainByDefault() public {
        vm.chainId(534_352);
        ChainlinkOracleFeed scrollFeed = _deployFeedForCurrentChain();
        assertFalse(scrollFeed.sequencerUptimeFeedRequired());
        assertEq(scrollFeed.getPrice(testToken), uint256(ETH_PRICE));
    }

    function test_SetSequencerUptimeFeedRequired_CanEnableUnlistedL2() public {
        vm.chainId(534_352);
        ChainlinkOracleFeed scrollFeed = _deployFeedForCurrentChain();

        vm.expectEmit(false, false, false, true);
        emit ChainlinkOracleFeed.SequencerUptimeFeedRequiredSet(false, true);
        scrollFeed.setSequencerUptimeFeedRequired(true);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.SequencerUptimeFeedRequired.selector, 534_352));
        scrollFeed.getPrice(testToken);

        scrollFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        vm.warp(block.timestamp + 3601);
        mockPriceFeed.setPrice(ETH_PRICE);
        assertEq(scrollFeed.getPrice(testToken), uint256(ETH_PRICE));
    }

    function test_SetSequencerUptimeFeedRequired_CanDisableConfiguredRequirement() public {
        chainlinkFeed.setSequencerUptimeFeedRequired(true);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.SequencerUptimeFeedRequired.selector, block.chainid));
        chainlinkFeed.getPrice(testToken);

        chainlinkFeed.setSequencerUptimeFeedRequired(false);
        assertEq(chainlinkFeed.getPrice(testToken), uint256(ETH_PRICE));
    }

    function test_SetSequencerUptimeFeedRequired_OnlyOwner() public {
        vm.prank(address(0x9999));
        vm.expectRevert();
        chainlinkFeed.setSequencerUptimeFeedRequired(true);
    }

    function test_SetSequencerUptimeFeed_OnlyOwner() public {
        address notOwner = address(0x9999);
        vm.prank(notOwner);
        vm.expectRevert();
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
    }

    function test_SetSequencerUptimeFeed_RevertsForZeroStartedAt() public {
        mockSequencerFeed.setStartedAt(0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracleFeed.InvalidFeedAddress.selector, address(mockSequencerFeed))
        );
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
    }

    function test_SetSequencerUptimeFeed_RevertsForFutureStartedAt() public {
        mockSequencerFeed.setStartedAt(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracleFeed.InvalidFeedAddress.selector, address(mockSequencerFeed))
        );
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
    }

    // ============ Sequencer Up - Normal Operation ============

    function test_GetPrice_SequencerUp_AfterGracePeriod() public {
        // Set sequencer feed
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        // Fast forward past grace period (1 hour + 1 second)
        vm.warp(block.timestamp + 3601);

        // Update price to keep it fresh after time warp
        mockPriceFeed.setPrice(ETH_PRICE);

        // Should work normally
        uint256 price = chainlinkFeed.getPrice(testToken);
        assertEq(price, uint256(ETH_PRICE));
    }

    function test_GetSequencerStatus_SequencerUp_AfterGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        vm.warp(block.timestamp + 3601);

        (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) = chainlinkFeed.getSequencerStatus();
        assertTrue(isUp);
        assertTrue(gracePeriodPassed);
        assertEq(timeSinceUp, 3601);
    }

    function test_GetSequencerStatus_FailsClosedWhenStartedAtBecomesZero() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        mockSequencerFeed.setStartedAt(0);

        (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) = chainlinkFeed.getSequencerStatus();

        assertFalse(isUp);
        assertFalse(gracePeriodPassed);
        assertEq(timeSinceUp, 0);

        vm.expectRevert(ChainlinkOracleFeed.SequencerDown.selector);
        chainlinkFeed.getPrice(testToken);

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);
        assertTrue(isStale);
        assertEq(updatedAt, 0);
    }

    // ============ Sequencer Up - Within Grace Period ============

    function test_GetPrice_RevertsInGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        // Still in grace period
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleFeed.GracePeriodNotOver.selector,
                0, // timeSinceUp
                3600 // gracePeriod
            )
        );
        chainlinkFeed.getPrice(testToken);
    }

    function test_GetPrice_RevertsAtExactlyGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        // At exactly grace period boundary (should still revert - need to be OVER, not equal)
        vm.warp(block.timestamp + 3600);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleFeed.GracePeriodNotOver.selector, 3600, 3600));
        chainlinkFeed.getPrice(testToken);
    }

    function test_GetSequencerStatus_SequencerUp_InGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        vm.warp(block.timestamp + 1800); // 30 minutes

        (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) = chainlinkFeed.getSequencerStatus();
        assertTrue(isUp);
        assertFalse(gracePeriodPassed);
        assertEq(timeSinceUp, 1800);
    }

    function test_IsPriceStale_ReturnsTrueInSequencerGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);

        assertTrue(isStale);
        assertEq(updatedAt, 0);
    }

    // ============ Sequencer Down ============

    function test_GetPrice_RevertsWhenSequencerDown() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        // Sequencer goes down
        mockSequencerFeed.setSequencerUp(false);

        // Even after grace period, should revert because sequencer is down
        vm.warp(block.timestamp + 7200);

        vm.expectRevert(ChainlinkOracleFeed.SequencerDown.selector);
        chainlinkFeed.getPrice(testToken);
    }

    function test_GetSequencerStatus_SequencerDown() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        mockSequencerFeed.setSequencerUp(false);
        vm.warp(block.timestamp + 3601);

        (bool isUp, bool gracePeriodPassed,) = chainlinkFeed.getSequencerStatus();
        assertFalse(isUp);
        assertTrue(gracePeriodPassed);
    }

    function test_IsPriceStale_ReturnsTrueWhenSequencerDown() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        mockSequencerFeed.setSequencerUp(false);
        vm.warp(block.timestamp + 7200);

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);

        assertTrue(isStale);
        assertEq(updatedAt, 0);
    }

    // ============ Sequencer Recovery Scenarios ============

    function test_GetPrice_AfterSequencerRecovery() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        uint256 baseTime = block.timestamp;

        // Step 1: Initial grace period passes (warp past initial sequencer setup)
        vm.warp(baseTime + 3601);
        mockPriceFeed.setPrice(ETH_PRICE); // Keep price fresh
        uint256 price = chainlinkFeed.getPrice(testToken);
        assertEq(price, uint256(ETH_PRICE));

        // Step 2: Sequencer goes down
        mockSequencerFeed.setSequencerUp(false);
        vm.expectRevert(ChainlinkOracleFeed.SequencerDown.selector);
        chainlinkFeed.getPrice(testToken);

        // Step 3: Sequencer comes back up - new grace period starts from NOW
        // Advance time a bit so the new startedAt is different
        vm.warp(baseTime + 3701); // 100 seconds later
        mockSequencerFeed.setSequencerUp(true);

        // Should revert because we're within the new grace period
        vm.expectRevert(); // Grace period not over
        chainlinkFeed.getPrice(testToken);

        // Step 4: Wait for the new grace period to pass (from when sequencer came up)
        vm.warp(baseTime + 3701 + 3601); // 1 hour + 1 second after sequencer came back up
        mockPriceFeed.setPrice(ETH_PRICE); // Keep price fresh
        price = chainlinkFeed.getPrice(testToken);
        assertEq(price, uint256(ETH_PRICE));
    }

    function test_IsPriceStale_ReturnsTrueForFutureSequencerStartedAt() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        vm.warp(block.timestamp + 3601);
        mockSequencerFeed.setStartedAt(block.timestamp + 1);

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);

        assertTrue(isStale);
        assertEq(updatedAt, 0);
    }

    // ============ GRACE_PERIOD_TIME Constant ============

    function test_GracePeriodTimeConstant() public view {
        assertEq(chainlinkFeed.GRACE_PERIOD_TIME(), 3600); // 1 hour
    }

    // ============ Integration with Price Staleness ============

    function test_SequencerCheckBeforePriceCheck() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        mockSequencerFeed.setSequencerUp(false);

        // Even if price is fresh, sequencer check should fail first
        vm.expectRevert(ChainlinkOracleFeed.SequencerDown.selector);
        chainlinkFeed.getPrice(testToken);
    }

    function test_BothSequencerAndPriceValid() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));

        // Wait for grace period
        vm.warp(block.timestamp + 3601);

        // Update price to keep it fresh
        mockPriceFeed.setPrice(2500e8);

        uint256 price = chainlinkFeed.getPrice(testToken);
        assertEq(price, 2500e8);
    }

    function test_IsPriceStale_ReturnsFeedFreshnessAfterSequencerGracePeriod() public {
        chainlinkFeed.setSequencerUptimeFeed(address(mockSequencerFeed));
        vm.warp(block.timestamp + 3601);
        mockPriceFeed.setPrice(2500e8);

        (bool isStale, uint256 updatedAt) = chainlinkFeed.isPriceStale(testToken);

        assertFalse(isStale);
        assertEq(updatedAt, block.timestamp);
    }
}
