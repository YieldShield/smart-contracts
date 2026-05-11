// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { ICompositeOracle } from "../contracts/interfaces/ICompositeOracle.sol";
import { IOracleFeed } from "../contracts/interfaces/IOracleFeed.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CompositeOracleTest is Test {
    CompositeOracle public compositeOracle;
    MockOracle public mockOracle;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockUSDC public token6;
    MockERC20Decimals public token8;

    address public owner = address(this);
    address public authorizedCaller = address(0x1);
    address public unauthorized = address(0x2);

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        token6 = new MockUSDC();
        token8 = new MockERC20Decimals("Token 8", "TKN8", 8);

        // Deploy mock oracle and set prices
        mockOracle = new MockOracle();
        mockOracle.setPrice(address(tokenA), 1e8); // $1 per token
        mockOracle.setPrice(address(tokenB), 2e8); // $2 per token
        mockOracle.setPrice(address(token6), 1e8);
        mockOracle.setPrice(address(token8), 1e8);

        // Deploy composite oracle
        compositeOracle = new CompositeOracle();
    }

    // ============ Single-Feed Tests (Backward Compatibility) ============

    function testSetTokenOracleFeed() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertEq(compositeOracle.getTokenOracleFeed(address(tokenA)), address(mockOracle));
        assertTrue(compositeOracle.isTokenSupported(address(tokenA)));
    }

    function testSetTokenOracleFeedWithType() public {
        compositeOracle.setTokenOracleFeedWithType(address(tokenA), address(mockOracle), "mock");

        assertEq(compositeOracle.getTokenOracleFeed(address(tokenA)), address(mockOracle));
        assertEq(compositeOracle.getOracleType(address(tokenA)), "mock");
        assertTrue(compositeOracle.isTokenSupported(address(tokenA)));
    }

    function testRemoveTokenOracleFeed() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        assertTrue(compositeOracle.isTokenSupported(address(tokenA)));

        compositeOracle.removeTokenOracleFeed(address(tokenA));

        assertFalse(compositeOracle.isTokenSupported(address(tokenA)));
        assertEq(compositeOracle.getTokenOracleFeed(address(tokenA)), address(0));
    }

    function testGetPrice() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(tokenB), address(mockOracle));

        assertEq(compositeOracle.getPrice(address(tokenA)), 1e8);
        assertEq(compositeOracle.getPrice(address(tokenB)), 2e8);
    }

    function testGetValue() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        // 10 tokens * $1 = $10
        uint256 value = compositeOracle.getValue(address(tokenA), 10e18);
        assertEq(value, 10e8);
    }

    function testGetEquivalentAmount() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(tokenB), address(mockOracle));

        // 10 tokenA ($1 each = $10) -> tokenB ($2 each) = 5 tokenB
        uint256 equivalentAmount = compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(tokenB));
        assertEq(equivalentAmount, 5e18);
    }

    function testGetValue_SixDecimalToken() public {
        compositeOracle.setTokenOracleFeed(address(token6), address(mockOracle));

        uint256 value = compositeOracle.getValue(address(token6), 10e6);
        assertEq(value, 10e8);
    }

    function testGetEquivalentAmount_SixToEightDecimals() public {
        compositeOracle.setTokenOracleFeed(address(token6), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(token8), address(mockOracle));

        uint256 equivalentAmount = compositeOracle.getEquivalentAmount(address(token6), 10e6, address(token8));
        assertEq(equivalentAmount, 10e8);
    }

    function testEquivalentAmountWithCircuitBreaker_EighteenToSixDecimals() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(token6), address(mockOracle));

        uint256 equivalentAmount =
            compositeOracle.getEquivalentAmountWithCircuitBreaker(address(tokenA), 10e18, address(token6));
        assertEq(equivalentAmount, 10e6);
    }

    function testGetValueWithFallback_SixDecimalToken() public {
        compositeOracle.setTokenOracleFeed(address(token6), address(mockOracle));

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token6), 10e6);
        assertEq(value, 10e8);
        assertTrue(isReliable);
    }

    function testAuthorizedCaller() public {
        compositeOracle.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(authorizedCaller);
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertTrue(compositeOracle.isTokenSupported(address(tokenA)));
    }

    function testUnauthorizedCallerReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.UnauthorizedCaller.selector, unauthorized));
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
    }

    function testRevertGetPriceUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(ICompositeOracle.TokenNotSupported.selector, address(tokenA)));
        compositeOracle.getPrice(address(tokenA));
    }

    function testRevertSetTokenOracleFeedZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ICompositeOracle.InvalidTokenAddress.selector, address(0)));
        compositeOracle.setTokenOracleFeed(address(0), address(mockOracle));
    }

    function testRevertSetTokenOracleFeedZeroOracle() public {
        vm.expectRevert(abi.encodeWithSelector(ICompositeOracle.InvalidOracleFeed.selector, address(0)));
        compositeOracle.setTokenOracleFeed(address(tokenA), address(0));
    }

    function testOracleTypeDetection() public {
        compositeOracle.setTokenOracleFeedWithType(address(tokenA), address(mockOracle), "pyth");
        assertEq(compositeOracle.getOracleType(address(tokenA)), "pyth");

        compositeOracle.setTokenOracleFeedWithType(address(tokenB), address(mockOracle), "erc4626");
        assertEq(compositeOracle.getOracleType(address(tokenB)), "erc4626");
    }

    function testPriceWithCircuitBreaker() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertEq(compositeOracle.getPriceWithCircuitBreaker(address(tokenA)), compositeOracle.getPrice(address(tokenA)));
    }

    function testEquivalentAmountWithCircuitBreaker() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(tokenB), address(mockOracle));

        uint256 withCB = compositeOracle.getEquivalentAmountWithCircuitBreaker(address(tokenA), 10e18, address(tokenB));
        uint256 without = compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(tokenB));

        assertEq(withCB, without);
    }

    function testPriceWithCircuitBreaker_BubblesSupportedFeedRevert() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        mockOracle.setShouldRevertOnCircuitBreaker(true);

        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(tokenA)));
        compositeOracle.getPriceWithCircuitBreaker(address(tokenA));
    }

    function testPriceWithCircuitBreaker_RevertsForFeedWithoutSupport() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.getPriceWithCircuitBreaker(address(tokenA));
    }

    function testPriceWithStrictCircuitBreaker() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(tokenA)), 1e8);
    }

    function testPriceWithStrictCircuitBreaker_RevertsForFeedWithoutSupport() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.getPriceWithStrictCircuitBreaker(address(tokenA));
    }

    function testSetStrictCircuitBreakerRequired_AllowsSupportedSingleFeed() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        compositeOracle.setStrictCircuitBreakerRequired(address(tokenA), true);

        assertTrue(compositeOracle.strictCircuitBreakerRequired(address(tokenA)));
        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(tokenA)), 1e8);
    }

    function testSetStrictCircuitBreakerRequired_RevertsForUnsupportedSingleFeed() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);
        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setStrictCircuitBreakerRequired(address(tokenA), true);
    }

    function testSetTokenOracleFeed_RevertsWhenStrictTokenUsesUnsupportedFeed() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(tokenA), true);

        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));
    }

    function testIsPriceStale_UsesStaticcallSafeERC4626Feed() public {
        MockERC20 underlyingAsset = new MockERC20("Underlying", "UND");
        MockERC4626 vault = new MockERC4626(IERC20(address(underlyingAsset)), "Vault", "VLT");
        MockStalenessOracleFeed staleOracle = new MockStalenessOracleFeed();
        staleOracle.setPrice(address(underlyingAsset), 1e8);

        ERC4626OracleFeed erc4626Feed = new ERC4626OracleFeed(address(staleOracle));
        erc4626Feed.registerVault(address(vault), address(underlyingAsset));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(vault));
        underlyingAsset.mint(address(this), minSupply);
        underlyingAsset.approve(address(vault), minSupply);
        vault.deposit(minSupply, address(this));

        compositeOracle.setTokenOracleFeedWithType(address(vault), address(erc4626Feed), "erc4626");

        staleOracle.setStale(address(underlyingAsset), false);
        (bool isStaleFresh, uint64 freshPublishTime) = compositeOracle.isPriceStale(address(vault));
        assertFalse(isStaleFresh, "fresh underlying should stay fresh through composite");
        assertEq(freshPublishTime, uint64(block.timestamp));

        staleOracle.setStale(address(underlyingAsset), true);
        staleOracle.setPublishTime(address(underlyingAsset), uint64(block.timestamp - 1 hours));
        (bool isStaleNow, uint64 publishTimeNow) = compositeOracle.isPriceStale(address(vault));
        assertTrue(isStaleNow, "stale underlying should report stale through composite");
        assertEq(publishTimeNow, uint64(block.timestamp - 1 hours));
    }
}

contract MockFeedWithoutCircuitBreaker is IOracleFeed {
    mapping(address => uint256) internal prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Feed Without Circuit Breaker";
    }
}

contract MockStalenessOracleFeed is IOracleFeed {
    mapping(address => uint256) internal prices;
    mapping(address => bool) internal stale;
    mapping(address => uint64) internal publishTimes;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function setStale(address token, bool isStale) external {
        stale[token] = isStale;
        if (publishTimes[token] == 0) {
            publishTimes[token] = uint64(block.timestamp);
        }
    }

    function setPublishTime(address token, uint64 publishTime) external {
        publishTimes[token] = publishTime;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Staleness Oracle Feed";
    }

    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        uint64 storedPublishTime = publishTimes[token];
        if (storedPublishTime == 0) {
            storedPublishTime = uint64(block.timestamp);
        }
        return (stale[token], storedPublishTime);
    }
}

contract MockRevertingPriceFeed is IOracleFeed {
    function getPrice(address) external pure returns (uint256) {
        revert("price unavailable");
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Reverting Price Feed";
    }
}

// ============ Dual-Feed Tests ============

contract CompositeOracleDualFeedTest is Test {
    CompositeOracle public compositeOracle;
    MockOracle public primaryOracle;
    MockOracle public backupOracle;
    MockERC20 public token;

    uint256 public constant PRIMARY_PRICE = 1e8; // $1.00
    uint256 public constant CHALLENGE_DURATION = 16 hours;

    event ChallengeInitiated(
        address indexed token, address indexed challenger, uint256 primaryPrice, uint256 backupPrice, uint256 deviation
    );
    event ChallengeFinalized(address indexed token, address indexed finalizer);
    event ChallengeCancelled(address indexed token, string reason);
    event OracleSwitched(address indexed token, bool isBackupActive);
    event RevertedToPrimary(address indexed token, address indexed caller, uint256 deviation);
    event CooldownApplied(address indexed token, address indexed trigger, uint256 cooldownUntil, string reason);

    function setUp() public {
        token = new MockERC20("Test Token", "TEST");

        primaryOracle = new MockOracle();
        backupOracle = new MockOracle();

        // Set initial prices (same price = no deviation)
        primaryOracle.setPrice(address(token), PRIMARY_PRICE);
        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        compositeOracle = new CompositeOracle();
    }

    // ============ Dual-Feed Configuration Tests ============

    function test_SetTokenOracleFeedDual() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        (
            bool isDualFeed,
            address primaryFeed,
            address backupFeed,
            bool isBackupActive,
            bool isChallengePending,
            uint256 challengeStartTime
        ) = compositeOracle.getTokenDualFeedStatus(address(token));

        assertTrue(isDualFeed);
        assertEq(primaryFeed, address(primaryOracle));
        assertEq(backupFeed, address(backupOracle));
        assertFalse(isBackupActive);
        assertFalse(isChallengePending);
        assertEq(challengeStartTime, 0);
    }

    function test_DualFeed_GetPrice_ReturnsPrimary() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        // Set different prices
        primaryOracle.setPrice(address(token), 1e8);
        backupOracle.setPrice(address(token), 2e8);

        // Should return primary price
        assertEq(compositeOracle.getPrice(address(token)), 1e8);
    }

    function test_SingleFeed_ClearsBackupWhenSetting() public {
        // First set dual-feed
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        (bool isDualFeed,,,,,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isDualFeed);

        // Now set single-feed
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));

        (isDualFeed,,,,,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isDualFeed);
    }

    // ============ Challenge Mechanism Tests ============

    function test_Challenge_SucceedsWhenDeviationExceedsThreshold() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        // Set backup price to create >0.75% deviation
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000; // 0.76% higher
        backupOracle.setPrice(address(token), deviatedPrice);

        vm.expectEmit(true, true, false, true);
        emit ChallengeInitiated(address(token), address(this), PRIMARY_PRICE, deviatedPrice, 76);
        compositeOracle.challengeForToken(address(token));

        (,,,, bool isChallengePending, uint256 challengeStartTime) =
            compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);
        assertEq(challengeStartTime, block.timestamp);
    }

    function test_Challenge_RevertsWhenNotDualFeed() public {
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Not a dual-feed token"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_Challenge_RevertsWhenDeviationBelowThreshold() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        // Set backup price within threshold (0.5% deviation)
        uint256 similarPrice = (PRIMARY_PRICE * 10050) / 10000;
        backupOracle.setPrice(address(token), similarPrice);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Deviation below threshold"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_Challenge_RevertsWhenAlreadyPending() public {
        _initiateChallenge();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Challenge already pending"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_Challenge_RevertsWhenBackupAlreadyActive() public {
        _challengeAndFinalize();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Backup oracle already active"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_Challenge_AllowsTimelockedFailoverWhenPrimaryReverts() public {
        MockRevertingPriceFeed revertingPrimary = new MockRevertingPriceFeed();
        compositeOracle.setTokenOracleFeedDual(address(token), address(revertingPrimary), address(backupOracle));

        compositeOracle.challengeForToken(address(token));
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);

        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPriceWithCircuitBreaker(address(token)), PRIMARY_PRICE);
    }

    function test_Challenge_RevertsDuringCooldown() public {
        _initiateChallenge();
        // Resolve deviation to allow cancel
        backupOracle.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.cancelChallenge(address(token));

        // Set deviation again
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Cooldown period not elapsed"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    // ============ Finalize Challenge Tests ============

    function test_FinalizeChallenge_SucceedsAfterTimelock() public {
        _initiateChallenge();

        // Fast forward past timelock
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.expectEmit(true, true, false, false);
        emit ChallengeFinalized(address(token), address(this));
        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), true);

        compositeOracle.finalizeChallenge(address(token));

        (,,, bool isBackupActive, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isBackupActive);
        assertFalse(isChallengePending);
    }

    function test_FinalizeChallenge_CancelsIfDeviationResolved() public {
        _initiateChallenge();

        // Fast forward past timelock
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // Resolve deviation before finalization
        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Deviation resolved during timelock");

        compositeOracle.finalizeChallenge(address(token));

        // Should NOT switch to backup
        (,,, bool isBackupActive, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isBackupActive);
        assertFalse(isChallengePending);
    }

    function test_FinalizeChallenge_RevertsBeforeTimelock() public {
        _initiateChallenge();

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.FinalizeNotPossible.selector, address(token), "Timelock not elapsed")
        );
        compositeOracle.finalizeChallenge(address(token));
    }

    function test_FinalizeChallenge_RevertsWhenNoChallengePending() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.FinalizeNotPossible.selector, address(token), "No challenge pending")
        );
        compositeOracle.finalizeChallenge(address(token));
    }

    // ============ Cancel Challenge Tests ============

    function test_CancelChallenge_SucceedsWhenDeviationResolved() public {
        _initiateChallenge();

        // Resolve deviation
        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        compositeOracle.cancelChallenge(address(token));

        (,,,, bool isChallengePending, uint256 challengeStartTime) =
            compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
        assertEq(challengeStartTime, 0);
    }

    function test_CancelChallenge_RevertsWhenDeviationStillHigh() public {
        _initiateChallenge();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CancelNotPossible.selector, address(token), "Deviation still exceeds threshold"
            )
        );
        compositeOracle.cancelChallenge(address(token));
    }

    function test_CancelChallenge_RevertsWhenNoChallengePending() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.CancelNotPossible.selector, address(token), "No challenge pending")
        );
        compositeOracle.cancelChallenge(address(token));
    }

    // ============ Revert To Primary Tests ============

    function test_RevertToPrimary_SucceedsWhenDeviationResolved() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        // Resolve deviation
        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        vm.expectEmit(true, true, false, true);
        emit RevertedToPrimary(address(token), address(this), 0);
        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.revertToPrimary(address(token));

        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
    }

    function test_RevertToPrimary_RevertsWhenDeviationStillHigh() public {
        _challengeAndFinalize();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Deviation still exceeds threshold"
            )
        );
        compositeOracle.revertToPrimary(address(token));
    }

    function test_RevertToPrimary_RevertsWhenPrimaryAlreadyActive() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Primary oracle already active"
            )
        );
        compositeOracle.revertToPrimary(address(token));
    }

    // ============ Force Reset Tests ============

    function test_ForceResetToPrimary_Succeeds() public {
        _challengeAndFinalize();

        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.forceResetToPrimary(address(token));

        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
    }

    function test_ForceResetToPrimary_RevertsWhenNotOwner() public {
        _challengeAndFinalize();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        compositeOracle.forceResetToPrimary(address(token));
    }

    // ============ Admin Config Tests ============

    function test_SetDeviationThreshold() public {
        compositeOracle.setDeviationThreshold(100);
        assertEq(compositeOracle.deviationThresholdBps(), 100);
    }

    function test_SetDeviationThreshold_RevertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidDeviationThreshold.selector, 0));
        compositeOracle.setDeviationThreshold(0);
    }

    function test_SetDeviationThreshold_RevertsOnTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidDeviationThreshold.selector, 10001));
        compositeOracle.setDeviationThreshold(10001);
    }

    function test_SetChallengeDuration() public {
        compositeOracle.setChallengeDuration(24 hours);
        assertEq(compositeOracle.challengeDurationSec(), 24 hours);
    }

    function test_SetChallengeDuration_RevertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidChallengeDuration.selector, 0));
        compositeOracle.setChallengeDuration(0);
    }

    // INFO-1 FIX: Test maximum challenge duration validation
    function test_SetChallengeDuration_RevertsOnTooLong() public {
        uint256 tooLong = compositeOracle.MAX_CHALLENGE_DURATION() + 1;
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidChallengeDuration.selector, tooLong));
        compositeOracle.setChallengeDuration(tooLong);
    }

    function test_SetChallengeDuration_SucceedsAtMax() public {
        uint256 maxDuration = compositeOracle.MAX_CHALLENGE_DURATION();
        compositeOracle.setChallengeDuration(maxDuration);
        assertEq(compositeOracle.challengeDurationSec(), maxDuration);
    }

    // ============ Integration Tests ============

    function test_FullChallengeFlow() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        // 1. Normal operation uses primary
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);

        // 2. Deviation occurs
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        // 3. Challenge initiated
        compositeOracle.challengeForToken(address(token));

        // 4. Still using primary during challenge
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);

        // 5. Timelock elapses
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // 6. Finalize switches to backup
        compositeOracle.finalizeChallenge(address(token));
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPrice(address(token)), deviatedPrice);
    }

    function test_FullRecoveryFlow() public {
        // 1. Switch to backup
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        // 2. Market stabilizes (deviation resolves)
        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        // 3. Anyone can revert to primary
        address randomUser = address(0xBEEF);
        vm.prank(randomUser);
        compositeOracle.revertToPrimary(address(token));

        // 4. Back to primary
        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);
    }

    // ============ Cooldown Tests ============

    function test_ChallengeSucceedsAfterCooldown() public {
        // Initiate and cancel a challenge
        _initiateChallenge();
        backupOracle.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.cancelChallenge(address(token));

        // Wait for cooldown to elapse
        vm.warp(block.timestamp + compositeOracle.COOLDOWN_PERIOD() + 1);

        // New challenge should now succeed
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        compositeOracle.challengeForToken(address(token));
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);
    }

    // ============ Bug Fix Tests ============

    // BUG-1 FIX: Test that same primary and backup feed reverts
    function test_SetDualFeed_RevertsWithSameFeed() public {
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.SameFeedNotAllowed.selector, address(primaryOracle)));
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(primaryOracle));
    }

    function test_SetStrictCircuitBreakerRequired_RevertsWhenBackupLacksSupport() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(token), PRIMARY_PRICE);

        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(noCircuitBreakerFeed));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);
    }

    function test_SetStrictCircuitBreakerRequired_RevertsWhenProtectedPriceReverts() public {
        primaryOracle.setShouldRevertOnCircuitBreaker(true);
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(primaryOracle)
            )
        );
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);
    }

    function test_SetDualFeed_RevertsWhenStrictTokenUsesUnsupportedBackup() public {
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(token), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(noCircuitBreakerFeed));
    }

    function test_StrictDualFeed_FinalizeChallengeKeepsStrictPricingAvailable() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        compositeOracle.challengeForToken(address(token));
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(token)), deviatedPrice);
    }

    function test_FinalizeChallenge_RevertsWhenBackupLacksCircuitBreaker() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        noCircuitBreakerFeed.setPrice(address(token), deviatedPrice);

        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(noCircuitBreakerFeed));
        compositeOracle.challengeForToken(address(token));
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.finalizeChallenge(address(token));

        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPriceWithCircuitBreaker(address(token)), PRIMARY_PRICE);
    }

    // BUG-2 FIX: Test reconfiguration emits challenge cancelled event
    function test_ReconfigureSingleFeed_EmitsChallengeCancel() public {
        _initiateChallenge();

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Reconfigured to single-feed");

        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));
    }

    function test_ReconfigureSingleFeedWithType_EmitsChallengeCancel() public {
        _initiateChallenge();

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Reconfigured to single-feed");

        compositeOracle.setTokenOracleFeedWithType(address(token), address(primaryOracle), "mock");
    }

    function test_ReconfigureDualFeed_EmitsChallengeCancel() public {
        _initiateChallenge();

        MockOracle newBackup = new MockOracle();
        newBackup.setPrice(address(token), PRIMARY_PRICE);

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Reconfigured to dual-feed");

        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(newBackup));
    }

    function test_ReconfigureSingleFeed_EmitsOracleSwitchedWhenBackupActive() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));
    }

    // BUG-3 FIX: Test emergency cancel challenge
    function test_EmergencyCancelChallenge_Succeeds() public {
        _initiateChallenge();
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Emergency cancelled by owner");

        compositeOracle.emergencyCancelChallenge(address(token));

        (,,,, isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
    }

    function test_EmergencyCancelChallenge_RevertsWhenNoChallengePending() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        vm.expectRevert(
            abi.encodeWithSelector(CompositeOracle.CancelNotPossible.selector, address(token), "No challenge pending")
        );
        compositeOracle.emergencyCancelChallenge(address(token));
    }

    function test_EmergencyCancelChallenge_RevertsWhenNotOwner() public {
        _initiateChallenge();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        compositeOracle.emergencyCancelChallenge(address(token));
    }

    // BUG-4 FIX: Test removeTokenOracleFeed emits proper events
    function test_RemoveFeed_EmitsChallengeCancelledIfPending() public {
        _initiateChallenge();

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Token oracle feed removed");

        compositeOracle.removeTokenOracleFeed(address(token));
    }

    function test_RemoveFeed_EmitsOracleSwitchedIfBackupActive() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.removeTokenOracleFeed(address(token));
    }

    // BUG-5 FIX: Test forceResetToPrimary emits ChallengeCancelled if pending
    function test_ForceResetToPrimary_EmitsChallengeCancelledIfPending() public {
        _initiateChallenge();
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Force reset by owner");
        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.forceResetToPrimary(address(token));

        (,,,, isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
    }

    // ============ Helper Functions ============

    function _initiateChallenge() internal {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);
        compositeOracle.challengeForToken(address(token));
    }

    function _challengeAndFinalize() internal {
        _initiateChallenge();
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));
    }
}
