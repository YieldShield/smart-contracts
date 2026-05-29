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

        // L-4: removal is timelocked. Schedule + wait + execute.
        compositeOracle.scheduleRemoveTokenOracleFeed(address(tokenA));
        vm.warp(block.timestamp + compositeOracle.FEED_REMOVAL_DELAY());
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

        uint256 equivalentAmount = compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(token6));
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
        assertEq(compositeOracle.authorizedCallerCount(), 1);
        assertEq(compositeOracle.authorizedCallerAt(0), authorizedCaller);

        vm.prank(authorizedCaller);
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertTrue(compositeOracle.isTokenSupported(address(tokenA)));
    }

    function testClearAuthorizedCallers() public {
        address secondCaller = address(0xCA11);
        compositeOracle.setAuthorizedCaller(authorizedCaller, true);
        compositeOracle.setAuthorizedCaller(secondCaller, true);

        compositeOracle.clearAuthorizedCallers();

        assertEq(compositeOracle.authorizedCallerCount(), 0);
        assertFalse(compositeOracle.authorizedCallers(authorizedCaller));
        assertFalse(compositeOracle.authorizedCallers(secondCaller));
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
        // After the safe-default rename, `getPrice` IS the protected variant. The protected
        // and unprotected getters must agree for a healthy single-feed mock token.
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertEq(compositeOracle.getPrice(address(tokenA)), compositeOracle.getPriceUnsafe(address(tokenA)));
    }

    function testEquivalentAmountWithCircuitBreaker() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(tokenB), address(mockOracle));

        uint256 withCB = compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(tokenB));
        uint256 without = compositeOracle.getEquivalentAmountUnsafe(address(tokenA), 10e18, address(tokenB));

        assertEq(withCB, without);
    }

    function testPriceWithCircuitBreaker_BubblesSupportedFeedRevert() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        mockOracle.setShouldRevertOnCircuitBreaker(true);

        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(tokenA)));
        compositeOracle.getPrice(address(tokenA));
    }

    function testSetTokenOracleFeed_RevertsForFeedWithoutCircuitBreakerSupport() public {
        // CompositeOracle now rejects feeds that do not advertise the safe/unsafe split at
        // configuration time, preventing a later governance/factory downgrade from quietly
        // removing the protected price path used by pools.
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));
    }

    function testSetTokenOracleFeed_RevertsForFallbackRevertDataWithoutUnsafeSelector() public {
        FallbackRevertDataFeed fallbackFeed = new FallbackRevertDataFeed();
        fallbackFeed.setPrice(address(tokenA), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(fallbackFeed)
            )
        );
        compositeOracle.setTokenOracleFeed(address(tokenA), address(fallbackFeed));
    }

    function testPriceWithStrictCircuitBreaker() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(tokenA)), 1e8);
    }

    function testSetTokenOracleFeedWithType_RevertsForFeedWithoutCircuitBreakerSupport() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeedWithType(address(tokenA), address(noCircuitBreakerFeed), "mock");
    }

    function testSetStrictCircuitBreakerRequired_AllowsSupportedSingleFeed() public {
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));

        compositeOracle.setStrictCircuitBreakerRequired(address(tokenA), true);

        assertTrue(compositeOracle.strictCircuitBreakerRequired(address(tokenA)));
        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(tokenA)), 1e8);
    }

    function testSetStrictCircuitBreakerRequired_RevertsBeforeUnsupportedSingleFeedCanBeConfigured() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(tokenA), 2e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(tokenA), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeed(address(tokenA), address(noCircuitBreakerFeed));
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
        uint256 minSupply = erc4626Feed.MIN_VAULT_SHARE_COUNT() * 1e18;
        underlyingAsset.mint(address(this), minSupply);
        underlyingAsset.approve(address(vault), minSupply);
        vault.deposit(minSupply, address(this));
        erc4626Feed.registerVault(address(vault), address(underlyingAsset));

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

contract FallbackRevertDataFeed is IOracleFeed {
    error UnsupportedSelector(bytes4 selector);

    mapping(address => uint256) internal prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    fallback() external {
        revert UnsupportedSelector(msg.sig);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Fallback Revert Data Feed";
    }
}

contract MutableCircuitBreakerSelectorFeed is IOracleFeed {
    bytes4 private constant GET_PRICE_UNSAFE_SELECTOR = bytes4(keccak256("getPriceUnsafe(address)"));
    mapping(address => uint256) internal prices;
    bool public unsafeSelectorEnabled = true;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function setUnsafeSelectorEnabled(bool enabled) external {
        unsafeSelectorEnabled = enabled;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    fallback() external {
        if (msg.sig != GET_PRICE_UNSAFE_SELECTOR || !unsafeSelectorEnabled) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        address token = abi.decode(msg.data[4:], (address));
        uint256 price = prices[token];
        if (price == 0) {
            price = 1e8;
        }
        assembly ("memory-safe") {
            mstore(0, price)
            return(0, 32)
        }
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mutable Circuit Breaker Selector Feed";
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

    function getPriceUnsafe(address token) external view returns (uint256) {
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

    function getPriceUnsafe(address) external pure returns (uint256) {
        return 1e8;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Reverting Price Feed";
    }
}

contract FreshUnsafeOnlyFeed is IOracleFeed {
    mapping(address => uint256) internal prices;
    mapping(address => bool) internal stale;
    mapping(address => uint64) internal publishTimes;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function setStale(address token, bool isStale) external {
        stale[token] = isStale;
    }

    function setPublishTime(address token, uint64 publishTime) external {
        publishTimes[token] = publishTime;
    }

    function getPrice(address) external pure returns (uint256) {
        revert("protected price unavailable");
    }

    function getPriceUnsafe(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Fresh Unsafe Only Feed";
    }

    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        publishTime = publishTimes[token];
        if (publishTime == 0) {
            publishTime = uint64(block.timestamp);
        }
        return (stale[token], publishTime);
    }

    function supportsCircuitBreaker(address token) external pure returns (bool) {
        token;
        return true;
    }
}

contract HighDecimalTinyFeed is IOracleFeed {
    uint8 internal immutable feedDecimals;
    mapping(address => uint256) internal prices;

    constructor(uint8 decimals_) {
        feedDecimals = decimals_;
    }

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        return prices[token];
    }

    function getPriceUnsafe(address token) external view returns (uint256) {
        return prices[token];
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function description() external pure returns (string memory) {
        return "High Decimal Tiny Feed";
    }

    function supportsCircuitBreaker(address token) external pure returns (bool) {
        token;
        return true;
    }

    function supportsStrictProtectedPrice(address token) external pure returns (bool) {
        token;
        return true;
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

        // Set divergent prices. After the H-2 safe-default rename, `getPrice` honours the
        // dual-feed challenge gate and reverts with `OraclePriceDisputed` because the feeds
        // disagree above threshold. Only the explicit `getPriceUnsafe` getter still returns
        // the active (primary) feed's value during a disputed window.
        primaryOracle.setPrice(address(token), 1e8);
        backupOracle.setPrice(address(token), 2e8);

        assertEq(compositeOracle.getPriceUnsafe(address(token)), 1e8);
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));
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

    function test_Challenge_MakesProtectedPricingUnavailableUntilResolved() public {
        _initiateChallenge();

        (bool isStale, uint64 publishTime) = compositeOracle.isPriceStale(address(token));
        assertTrue(isStale);
        assertEq(publishTime, 0);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getPrice(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
    }

    function test_ChallengeableDeviationBlocksProtectedPricingBeforeChallenge() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        assertTrue(compositeOracle.isTokenChallengeable(address(token)));

        // After H-2 fix, the safe-default `getPrice` honours the challenge gate and
        // fails closed when the dual feeds disagree above threshold. Only the explicit
        // `getPriceUnsafe` getter still returns the disputed primary's value.
        assertEq(compositeOracle.getPriceUnsafe(address(token)), PRIMARY_PRICE);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
    }

    function test_ChallengeableDeviationRejectsUnsafeBackupWhenProtectedBackupReverts() public {
        FreshUnsafeOnlyFeed flakyBackup = new FreshUnsafeOnlyFeed();
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        flakyBackup.setPrice(address(token), deviatedPrice);

        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(flakyBackup));

        assertFalse(compositeOracle.isTokenChallengeable(address(token)));
        assertEq(compositeOracle.getCurrentDeviation(address(token)), type(uint256).max);
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Backup oracle unavailable"
            )
        );
        compositeOracle.challengeForToken(address(token));

        (,,,, bool isChallengePending, uint256 challengeStartTime) =
            compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
        assertEq(challengeStartTime, 0);
    }

    function test_ChallengeIgnoresUnsafeBackupWhenProtectedBackupRevertsEvenIfFreshnessChanges() public {
        FreshUnsafeOnlyFeed flakyBackup = new FreshUnsafeOnlyFeed();
        flakyBackup.setPrice(address(token), (PRIMARY_PRICE * 10076) / 10000);
        flakyBackup.setStale(address(token), true);

        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(flakyBackup));

        assertFalse(compositeOracle.isTokenChallengeable(address(token)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Backup oracle unavailable"
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_FinalizeChallengeRejectsUnsafeBackupWhenProtectedBackupReverts() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        backupOracle.setPrice(address(token), (PRIMARY_PRICE * 10076) / 10000);
        compositeOracle.challengeForToken(address(token));
        backupOracle.setShouldRevertOnCircuitBreaker(true);

        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.FinalizeNotPossible.selector, address(token), "Backup oracle unavailable"
            )
        );
        compositeOracle.finalizeChallenge(address(token));

        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
    }

    function test_ChallengeableDeviationClearsWhenFeedsConverge() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        backupOracle.setPrice(address(token), (PRIMARY_PRICE * 10076) / 10000);

        assertTrue(compositeOracle.isTokenChallengeable(address(token)));

        backupOracle.setPrice(address(token), PRIMARY_PRICE);

        assertFalse(compositeOracle.isTokenChallengeable(address(token)));
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);
    }

    function test_ActiveBackupFailsClosedWhenPrimaryStillDisagrees() public {
        _challengeAndFinalize();

        assertTrue(compositeOracle.isTokenChallengeable(address(token)));
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));
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
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);
    }

    function test_Challenge_AllowsFailoverWhenPrimaryProtectedPriceRevertsDespiteMatchingSpot() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        primaryOracle.setShouldRevertOnCircuitBreaker(true);

        compositeOracle.challengeForToken(address(token));
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);

        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);

        // After the safe-default rename, the feed's `getPrice` IS the protected variant.
        // A primary feed that reverts on its protected path therefore makes the price
        // unavailable through `_tryGetNormalizedFeedPrice`, so `revertToPrimary` fails closed
        // with "Primary oracle unavailable" — semantically equivalent to the old "Deviation still
        // exceeds threshold" outcome (the unsafe primary stays disabled either way).
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Primary oracle unavailable"
            )
        );
        compositeOracle.revertToPrimary(address(token));
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

    function test_RevertToPrimary_RevertsWhenBackupUnavailableAndPrimaryHealthy() public {
        _challengeAndFinalize();
        backupOracle.setPrice(address(token), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Backup oracle unavailable"
            )
        );
        compositeOracle.revertToPrimary(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
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

        // M-8: schedule + wait for the emergency-override delay before executing.
        compositeOracle.scheduleForceResetToPrimary(address(token));
        vm.warp(block.timestamp + compositeOracle.EMERGENCY_OVERRIDE_DELAY());

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

        // 4. During challenge, safe-default `getPrice` fails closed (H-2). The primary feed's
        //    last reading is still observable through the explicit `getPriceUnsafe` getter.
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getPrice(address(token));
        assertEq(compositeOracle.getPriceUnsafe(address(token)), PRIMARY_PRICE);

        // 5. Timelock elapses
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // 6. Finalize switches to backup, but protected reads still fail closed
        //    while a healthy protected primary materially disagrees with it.
        compositeOracle.finalizeChallenge(address(token));
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertTrue(compositeOracle.isTokenChallengeable(address(token)));
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));

        // A live-but-divergent backup stays disputed; governance can use the timelocked
        // emergency reset after deciding which feed is wrong.
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Deviation still exceeds threshold"
            )
        );
        compositeOracle.revertToPrimary(address(token));
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

    function test_SetDualFeed_RevertsWhenBackupLacksCircuitBreaker() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(token), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(noCircuitBreakerFeed));
    }

    function test_SetDualFeed_RevertsForFallbackRevertDataWithoutUnsafeSelector() public {
        FallbackRevertDataFeed fallbackFeed = new FallbackRevertDataFeed();
        fallbackFeed.setPrice(address(token), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(fallbackFeed)
            )
        );
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(fallbackFeed));
    }

    function test_SetStrictCircuitBreakerRequired_AllowsSupportedFeedWhenProtectedPriceReverts() public {
        primaryOracle.setShouldRevertOnCircuitBreaker(true);
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));

        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        assertTrue(compositeOracle.strictCircuitBreakerRequired(address(token)));
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(token)));
        compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
    }

    function test_SetStrictCircuitBreakerRequired_RevertsWhenFeedOmitsStrictSupportSelector() public {
        MockStalenessOracleFeed missingStrictSupportFeed = new MockStalenessOracleFeed();
        missingStrictSupportFeed.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.setTokenOracleFeed(address(token), address(missingStrictSupportFeed));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(missingStrictSupportFeed)
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

    function test_StrictDualFeed_FinalizedBackupFailsClosedWhenPrimaryDisagrees() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);

        compositeOracle.challengeForToken(address(token));
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertTrue(compositeOracle.isTokenChallengeable(address(token)));
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
    }

    function test_StrictDualFeed_FinalizeChallengeSucceedsWhenPrimaryProtectedPriceReverts() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), deviatedPrice);
        primaryOracle.setShouldRevertOnCircuitBreaker(true);

        compositeOracle.challengeForToken(address(token));
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        compositeOracle.finalizeChallenge(address(token));

        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));
        assertEq(compositeOracle.getPriceWithStrictCircuitBreaker(address(token)), deviatedPrice);
    }

    function test_ActiveBackupFallbackDoesNotUseInactivePrimaryWhenBackupFails() public {
        _challengeAndFinalize();
        backupOracle.setShouldRevertOnCircuitBreaker(true);

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);

        assertEq(value, 0, "fallback must not use inactive primary after failover");
        assertFalse(isReliable);
    }

    function test_Challenge_RevertsWhenBackupLacksCircuitBreaker() public {
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        noCircuitBreakerFeed.setPrice(address(token), deviatedPrice);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(noCircuitBreakerFeed)
            )
        );
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(noCircuitBreakerFeed));

        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
    }

    function test_TransientBackupFailureDoesNotDoSProtectedPrimary() public {
        // A2 (2026-05-19): a transient backup failure must NOT mark the token
        // as disputed and DoS every protected reader, PROVIDED the primary
        // itself has its own circuit breaker. The primary's CB still applies,
        // and `challengeForToken` independently requires a working backup
        // before a real dispute can land — so the only consequence of a backup
        // outage on a CB-supporting primary should be that no new challenge
        // can be filed, NOT that protected reads revert.
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        compositeOracle.setStrictCircuitBreakerRequired(address(token), true);

        backupOracle.setShouldRevertOnCircuitBreaker(true);

        assertFalse(
            compositeOracle.isTokenChallengeable(address(token)),
            "transient backup failure must not surface as challengeable"
        );

        uint256 price = compositeOracle.getPrice(address(token));
        assertEq(price, PRIMARY_PRICE, "protected primary must still serve while backup is transiently down");

        uint256 strictPrice = compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
        assertEq(strictPrice, PRIMARY_PRICE, "strict-CB getter must still serve while backup is transiently down");
    }

    function test_MutableBackupLosingCircuitBreakerDoesNotDisputeProtectedPrimary() public {
        MutableCircuitBreakerSelectorFeed mutableBackup = new MutableCircuitBreakerSelectorFeed();
        mutableBackup.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(mutableBackup));

        uint256 deviatedPrice = (PRIMARY_PRICE * 10076) / 10000;
        mutableBackup.setPrice(address(token), deviatedPrice);
        mutableBackup.setUnsafeSelectorEnabled(false);

        assertFalse(
            compositeOracle.isTokenChallengeable(address(token)),
            "backup marker loss should not dispute a protected primary"
        );
        assertEq(compositeOracle.getPrice(address(token)), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(mutableBackup)
            )
        );
        compositeOracle.challengeForToken(address(token));
    }

    function test_SetDualFeed_RevertsWhenPrimaryLacksCircuitBreaker() public {
        // Feeds without the safe/unsafe split are now rejected before they can become
        // either side of a CompositeOracle pair, so a backup outage can no longer leave
        // the system serving an unverified primary.
        MockFeedWithoutCircuitBreaker primaryNoCb = new MockFeedWithoutCircuitBreaker();
        primaryNoCb.setPrice(address(token), PRIMARY_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(token), address(primaryNoCb)
            )
        );
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryNoCb), address(backupOracle));
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

        // M-8: schedule + wait for override delay.
        compositeOracle.scheduleEmergencyCancelChallenge(address(token));
        vm.warp(block.timestamp + compositeOracle.EMERGENCY_OVERRIDE_DELAY());

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Emergency cancelled by owner");

        compositeOracle.emergencyCancelChallenge(address(token));

        (,,,, isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
    }

    function test_EmergencyCancelChallenge_RevertsWhenNoChallengePending() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));

        // Codex P1 follow-up: scheduling itself now requires a pending
        // challenge as precondition, so an attempt to schedule a cancel
        // when there is nothing to cancel reverts up front (no stale
        // schedule is created and consumable later).
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.EmergencyOverridePreconditionNotMet.selector,
                address(token),
                keccak256("emergencyCancelChallenge"),
                "No challenge pending"
            )
        );
        compositeOracle.scheduleEmergencyCancelChallenge(address(token));
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

        // L-4: removal is timelocked. Schedule + wait.
        compositeOracle.scheduleRemoveTokenOracleFeed(address(token));
        vm.warp(block.timestamp + compositeOracle.FEED_REMOVAL_DELAY());

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Token oracle feed removed");

        compositeOracle.removeTokenOracleFeed(address(token));
    }

    function test_RemoveFeed_EmitsOracleSwitchedIfBackupActive() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        compositeOracle.scheduleRemoveTokenOracleFeed(address(token));
        vm.warp(block.timestamp + compositeOracle.FEED_REMOVAL_DELAY());

        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.removeTokenOracleFeed(address(token));
    }

    // BUG-5 FIX: Test forceResetToPrimary emits ChallengeCancelled if pending
    function test_ForceResetToPrimary_EmitsChallengeCancelledIfPending() public {
        _initiateChallenge();
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertTrue(isChallengePending);

        // M-8: schedule + wait.
        compositeOracle.scheduleForceResetToPrimary(address(token));
        vm.warp(block.timestamp + compositeOracle.EMERGENCY_OVERRIDE_DELAY());

        vm.expectEmit(true, false, false, true);
        emit ChallengeCancelled(address(token), "Force reset by owner");
        vm.expectEmit(true, false, false, true);
        emit OracleSwitched(address(token), false);

        compositeOracle.forceResetToPrimary(address(token));

        (,,,, isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(token));
        assertFalse(isChallengePending);
    }

    // ============ H-2 / H-3 / L-3 Safe-Default Regressions ============

    /// @notice H-2: every non-strict price entry point honours the dual-feed challenge gate.
    /// @dev Before the safe-default rename only `getPriceWithCircuitBreaker` reverted with
    ///      `OracleChallengePending` during an open challenge; `getPrice`, `getValue` and
    ///      `getEquivalentAmount` silently kept serving the disputed primary. The rename
    ///      moves the gate into `_getPrice` itself so every safe entry inherits it.
    function test_H2_AllSafeEntryPointsRevertDuringPendingChallenge() public {
        _initiateChallenge();

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getPrice(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getValue(address(token), 1e18);

        (uint256 fallbackValue, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(fallbackValue, 0, "fallback must not serve active disputed feed during challenge");
        assertFalse(isReliable);

        // For `getEquivalentAmount` the gate must fire on either side of the conversion.
        // Configure a second token with a single (challenge-free) feed so the disputed
        // side dominates.
        MockERC20 tokenB = new MockERC20("Other Token", "OTH");
        primaryOracle.setPrice(address(tokenB), PRIMARY_PRICE);
        compositeOracle.setTokenOracleFeed(address(tokenB), address(primaryOracle));
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OracleChallengePending.selector, address(token)));
        compositeOracle.getEquivalentAmount(address(token), 1e18, address(tokenB));

        // The explicit `*Unsafe` getters keep working — they are the documented escape
        // hatch for the rare callers that consciously opt out of the challenge gate.
        assertEq(compositeOracle.getPriceUnsafe(address(token)), PRIMARY_PRICE);
        assertGt(compositeOracle.getValueUnsafe(address(token), 1e18), 0);
        assertGt(compositeOracle.getEquivalentAmountUnsafe(address(token), 1e18, address(tokenB)), 0);
    }

    /// @notice H-2: unresolved dual-feed deviation also flips the safe entry points.
    function test_H2_SafeEntryPointsFailWhenDeviationUnresolved() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        // Set a wide deviation but never call `challengeForToken` — the helper
        // `_hasUnresolvedDualFeedDeviation` must still flag the price as disputed.
        backupOracle.setPrice(address(token), (PRIMARY_PRICE * 10076) / 10000);

        assertTrue(compositeOracle.isTokenChallengeable(address(token)));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getValue(address(token), 1e18);

        (uint256 fallbackValue, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(fallbackValue, 0, "fallback must not serve active disputed feed");
        assertFalse(isReliable);

        // Unsafe path still serves the active feed.
        assertEq(compositeOracle.getPriceUnsafe(address(token)), PRIMARY_PRICE);
    }

    /// @notice H-3: backup-active pricing fails closed when a healthy primary disagrees.
    function test_H3_BackupActiveFailsClosedWhenHealthyPrimaryDisagrees() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        uint256 backupPrice = (PRIMARY_PRICE * 10076) / 10000;
        // Backup briefly fails.
        backupOracle.setPrice(address(token), 0);

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0, "must not silently fall back to the disabled primary");
        assertFalse(isReliable);

        // Once the backup recovers, the healthy-primary disagreement keeps the
        // protected/fallback paths disputed instead of serving the active backup.
        backupOracle.setPrice(address(token), backupPrice);
        (value, isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0, "backup-active disagreement should fail closed");
        assertFalse(isReliable);

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.OraclePriceDisputed.selector, address(token)));
        compositeOracle.getPrice(address(token));

        // The feeds still disagree, so public recovery remains fail-closed.
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Deviation still exceeds threshold"
            )
        );
        compositeOracle.revertToPrimary(address(token));
    }

    function test_H3_BackupActiveServesWhenPrimaryUnhealthy() public {
        _challengeAndFinalize();
        assertTrue(compositeOracle.isBackupActiveForToken(address(token)));

        uint256 backupPrice = (PRIMARY_PRICE * 10076) / 10000;
        primaryOracle.setShouldRevertOnCircuitBreaker(true);

        assertFalse(compositeOracle.isTokenChallengeable(address(token)));
        assertEq(compositeOracle.getPrice(address(token)), backupPrice);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.RevertNotPossible.selector, address(token), "Primary oracle unavailable"
            )
        );
        compositeOracle.revertToPrimary(address(token));

        primaryOracle.setShouldRevertOnCircuitBreaker(false);
        primaryOracle.setPrice(address(token), backupPrice);
        compositeOracle.revertToPrimary(address(token));
        assertFalse(compositeOracle.isBackupActiveForToken(address(token)));
    }

    /// @notice H-3: `getValueWithFallback` skips the inactive feed when the dual feeds disagree
    ///         (even before a public challenge has been started).
    function test_H3_FallbackSkipsInactiveFeedWhenDeviationUnresolved() public {
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(backupOracle));
        uint256 backupPrice = (PRIMARY_PRICE * 10076) / 10000;
        backupOracle.setPrice(address(token), backupPrice);

        // Force the active feed (primary) to fail. The inactive backup feed remains usable —
        // but because there is an unresolved deviation, we must NOT silently promote it.
        primaryOracle.setPrice(address(token), 0);

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0, "must not silently fall back to a disputed inactive feed");
        assertFalse(isReliable);
    }

    /// @notice L-3: the safe-default `getPrice` is the protected variant on the leaf feed.
    function test_L3_SafeDefaultGetPriceUsesProtectedVariantOnLeafFeed() public {
        compositeOracle.setTokenOracleFeed(address(token), address(primaryOracle));
        primaryOracle.setShouldRevertOnCircuitBreaker(true);

        // After the rename, the safe-default `getPrice` flows to the feed's safe `getPrice`,
        // so a feed-level circuit-breaker revert surfaces by default.
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(token)));
        compositeOracle.getPrice(address(token));

        // The explicit unsafe getter is unaffected by the feed-level circuit breaker.
        assertEq(compositeOracle.getPriceUnsafe(address(token)), PRIMARY_PRICE);
    }

    function test_FallbackRejectsActiveFeedWhenCircuitBreakerSupportRemoved() public {
        MutableCircuitBreakerSelectorFeed mutableFeed = new MutableCircuitBreakerSelectorFeed();
        mutableFeed.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.setTokenOracleFeed(address(token), address(mutableFeed));

        mutableFeed.setUnsafeSelectorEnabled(false);

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0, "fallback must not serve active feed after marker removal");
        assertFalse(isReliable);
    }

    function test_FallbackRejectsInactiveFeedWhenCircuitBreakerSupportRemoved() public {
        MockRevertingPriceFeed activeFailingFeed = new MockRevertingPriceFeed();
        MutableCircuitBreakerSelectorFeed mutableBackup = new MutableCircuitBreakerSelectorFeed();
        mutableBackup.setPrice(address(token), PRIMARY_PRICE);
        compositeOracle.setTokenOracleFeedDual(address(token), address(activeFailingFeed), address(mutableBackup));

        mutableBackup.setUnsafeSelectorEnabled(false);

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0, "fallback must not serve inactive feed after marker removal");
        assertFalse(isReliable);
    }

    function test_NormalizedZeroPriceRevertsForProtectedAndUnsafeReads() public {
        HighDecimalTinyFeed tinyFeed = new HighDecimalTinyFeed(18);
        tinyFeed.setPrice(address(token), 1);
        compositeOracle.setTokenOracleFeed(address(token), address(tinyFeed));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidPrice.selector, address(token), 0));
        compositeOracle.getPrice(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidPrice.selector, address(token), 0));
        compositeOracle.getPriceUnsafe(address(token));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidPrice.selector, address(token), 0));
        compositeOracle.getPriceWithStrictCircuitBreaker(address(token));
    }

    function test_NormalizedZeroFallbackIsNotReliable() public {
        HighDecimalTinyFeed tinyFeed = new HighDecimalTinyFeed(18);
        tinyFeed.setPrice(address(token), 1);
        compositeOracle.setTokenOracleFeed(address(token), address(tinyFeed));

        (uint256 value, bool isReliable) = compositeOracle.getValueWithFallback(address(token), 1e18);
        assertEq(value, 0);
        assertFalse(isReliable);
    }

    function test_NormalizedZeroBackupCannotTriggerChallenge() public {
        HighDecimalTinyFeed tinyBackup = new HighDecimalTinyFeed(18);
        tinyBackup.setPrice(address(token), 1);
        compositeOracle.setTokenOracleFeedDual(address(token), address(primaryOracle), address(tinyBackup));

        assertFalse(compositeOracle.isTokenChallengeable(address(token)));
        assertEq(compositeOracle.getCurrentDeviation(address(token)), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.ChallengeNotPossible.selector, address(token), "Backup oracle unavailable"
            )
        );
        compositeOracle.challengeForToken(address(token));
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
