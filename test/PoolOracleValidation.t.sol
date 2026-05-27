// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ProtocolAccessControlUpgradeable } from "../contracts/base/ProtocolAccessControlUpgradeable.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { PythEMAOracleFeed } from "../contracts/oracles/PythEMAOracleFeed.sol";
import { IOracleFeed } from "../contracts/interfaces/IOracleFeed.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract PoolOracleValidationTest is Test, FactoryProxyTestBase {
    SplitRiskPoolFactory public factory;
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC20 public backingToken;
    MockOracle public oracle;
    MockPriceOnlyOracle public priceOnlyOracle;

    address public governance = address(0xAAA);
    address public protocolFeeRecipient = address(0xBBB);

    function setUp() public {
        backingToken = new MockERC20("Backing Token", "BKT");
        shieldedToken = new MockERC4626(backingToken, "Shielded Token", "SHT");

        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        priceOnlyOracle = new MockPriceOnlyOracle();
        priceOnlyOracle.setPrice(address(shieldedToken), 1e8);
        priceOnlyOracle.setPrice(address(backingToken), 1e8);

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedWithType(address(shieldedToken), address(oracle), "mock");
        compositeOracle.setTokenOracleFeedWithType(address(backingToken), address(oracle), "mock");

        SplitRiskPool poolImpl = new SplitRiskPool();
        governance = address(_deployTestTimelock(address(this)));
        factory = _deployFactory(address(this), governance, address(poolImpl));

        compositeOracle.transferOwnership(address(factory));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setCompositeOracleAuthorizedCaller(address(this), true);

        factory.addTokenInitial(address(shieldedToken), "Shielded Token", "SHT", address(oracle), address(0), 10000);
        factory.addTokenInitial(address(backingToken), "Backing Token", "BKT", address(oracle), address(0), 10000);
        factory.setDefaultProtocolFeeRecipient(protocolFeeRecipient);

        _approveCreationBond();
        address poolAddress = factory.createPool(
            address(shieldedToken), "SHT", address(backingToken), "BKT", 1000, 200, 15000, _creationBondAmount()
        );
        pool = SplitRiskPool(payable(poolAddress));
    }

    function _createPool() internal returns (SplitRiskPool createdPool) {
        _approveCreationBond();
        address poolAddress = factory.createPool(
            address(shieldedToken), "SHT", address(backingToken), "BKT", 1000, 200, 15000, _creationBondAmount()
        );
        return SplitRiskPool(payable(poolAddress));
    }

    function _creationBondAmount() internal pure returns (uint256) {
        return 500e18;
    }

    function _approveCreationBond() internal {
        backingToken.approve(address(factory), _creationBondAmount());
    }

    function testSetCompositeOracleRevertsWhenOracleLacksFeedConfigurationInterface() public {
        vm.prank(governance);
        vm.expectRevert();
        factory.setCompositeOracle(address(priceOnlyOracle));
    }

    function testUpdatePoolConfigRevertsWhenOracleLacksProtectedBackingPrice() public {
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        pool.updatePoolConfig(
            1e18,
            1000e18,
            1e18,
            1000e18,
            1000000e8,
            1 days,
            28 days,
            100,
            protocolFeeRecipient,
            address(priceOnlyOracle)
        );
    }

    function testAddTokenRevertsWhenCompositeBackingFeedLacksCircuitBreaker() public {
        MockERC20 newBackingToken = new MockERC20("New Backing Token", "NBKT");
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(newBackingToken), 1e8);
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector,
                address(newBackingToken),
                address(noCircuitBreakerFeed)
            )
        );
        factory.addToken(
            address(newBackingToken), "New Backing Token", "NBKT", address(noCircuitBreakerFeed), address(0), 10000
        );
        vm.stopPrank();
    }

    function testAddTokenRevertsWhenCompositeShieldedFeedLacksCircuitBreaker() public {
        MockERC20 newShieldedToken = new MockERC20("New Shielded Token", "NSHT");
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(newShieldedToken), 1e8);
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector,
                address(newShieldedToken),
                address(noCircuitBreakerFeed)
            )
        );
        factory.addToken(
            address(newShieldedToken), "New Shielded Token", "NSHT", address(noCircuitBreakerFeed), address(0), 10000
        );
        vm.stopPrank();
    }

    function testAddTokenRevertsWhenCompositeShieldedFeedNormalizesToZero() public {
        MockERC20 newShieldedToken = new MockERC20("New Shielded Token", "NSHT");
        MockHighDecimalTinyFeed tinyFeed = new MockHighDecimalTinyFeed(18);
        tinyFeed.setPrice(address(newShieldedToken), 1);

        vm.startPrank(governance);
        factory.addToken(address(newShieldedToken), "New Shielded Token", "NSHT", address(tinyFeed), address(0), 10000);
        vm.stopPrank();

        _approveCreationBond();
        vm.expectRevert(ErrorsLib.InvalidOraclePrice.selector);
        factory.createPool(
            address(newShieldedToken), "NSHT", address(backingToken), "BKT", 1000, 200, 15000, _creationBondAmount()
        );
    }

    function testAddTokenRevertsWhenShieldedFeedIsPythEmaOnly() public {
        MockERC20 newShieldedToken = new MockERC20("New Shielded Token", "NSHT");
        MockPyth mockPyth = new MockPyth(60, 1e15);
        PythEMAOracleFeed emaFeed = new PythEMAOracleFeed(address(mockPyth), 60);
        emaFeed.setTokenPriceFeed(
            address(newShieldedToken), 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        );
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(newShieldedToken), address(emaFeed)
            )
        );
        factory.addToken(address(newShieldedToken), "New Shielded Token", "NSHT", address(emaFeed), address(0), 10000);
        vm.stopPrank();
    }

    function testAddTokenRevertsBeforeStrictPolicyCanUseFallbackOnlyFeed() public {
        MockERC20 newBackingToken = new MockERC20("New Backing Token", "NBKT");
        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(newBackingToken), 1e8);
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector,
                address(newBackingToken),
                address(noCircuitBreakerFeed)
            )
        );
        factory.addToken(
            address(newBackingToken), "New Backing Token", "NBKT", address(noCircuitBreakerFeed), address(0), 10000
        );
        vm.stopPrank();
    }

    function testSetCompositeOracleReplaysStrictBackingPolicy() public {
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        CompositeOracle newCompositeOracle = new CompositeOracle();
        newCompositeOracle.setTokenOracleFeedWithType(address(shieldedToken), address(oracle), "mock");
        newCompositeOracle.setTokenOracleFeedWithType(address(backingToken), address(oracle), "mock");
        newCompositeOracle.setStrictCircuitBreakerRequired(address(backingToken), true);

        (
            uint256 shieldedMinDepositAmount,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,
            uint256 maxTotalValueLockedUsd,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address currentProtocolFeeRecipient,
            uint96 protocolFee,
            address oldPriceOracle
        ) = pool.poolConfig();
        oldPriceOracle;
        vm.prank(governance);
        pool.updatePoolConfig(
            shieldedMinDepositAmount,
            shieldedMaxDepositAmount,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            maxTotalValueLockedUsd,
            minimumPoolTime,
            unlockDuration,
            protocolFee,
            currentProtocolFeeRecipient,
            address(newCompositeOracle)
        );

        newCompositeOracle.transferOwnership(address(factory));
        vm.prank(governance);
        factory.setCompositeOracle(address(newCompositeOracle));

        assertTrue(newCompositeOracle.strictCircuitBreakerRequired(address(backingToken)));
        assertEq(newCompositeOracle.getTokenOracleFeed(address(backingToken)), address(oracle));
    }

    function testOwnerCannotSetStrictProtectedPriceAfterPoolCreation() public {
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAccessControlUpgradeable.UnauthorizedGovernance.selector, address(this))
        );
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
    }

    function testPoolStrictProtectedPriceRequirementAutoAdoptsFactoryEnable() public {
        // H-5 follow-up: a pinned-false pool may auto-tighten when governance
        // enables strict pricing for its backing token, but factory policy alone
        // cannot auto-downgrade a pinned strict pool.
        assertFalse(pool.requiresStrictProtectedBackingPrice());
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
        assertTrue(pool.requiresStrictProtectedBackingPrice(), "factory enable should tighten existing pools");

        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();
        assertTrue(pool.requiresStrictProtectedBackingPrice(), "refresh should adopt the new policy");
    }

    function testPoolStrictProtectedPriceRefreshRevertsOnFactoryLookupFailure() public {
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();
        assertTrue(pool.requiresStrictProtectedBackingPrice(), "test starts from pinned strict=true");

        bytes memory lookup =
            abi.encodeWithSignature("tokenRequiresStrictProtectedPrice(address)", address(backingToken));
        vm.mockCallRevert(address(factory), lookup, "probe failed");

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        pool.refreshStrictProtectedBackingPriceFlag();

        assertTrue(pool.requiresStrictProtectedBackingPrice(), "failed refresh must preserve previous pin");
        vm.clearMockedCalls();
    }

    function testPoolStrictProtectedPriceRefreshCanAdoptExplicitFalse() public {
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();
        assertTrue(pool.requiresStrictProtectedBackingPrice());

        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), false);
        assertTrue(pool.requiresStrictProtectedBackingPrice(), "factory false should not auto-downgrade pinned strict");

        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();

        assertFalse(pool.requiresStrictProtectedBackingPrice(), "explicit factory false remains adoptable");
    }

    function testPoolStrictProtectedPriceRequirementSurvivesPoolOwnerTransfer() public {
        // H-5: pool snapshots the flag at init. To adopt a new factory policy,
        // governance must call refreshStrictProtectedBackingPriceFlag(). After
        // that, the pinned value persists across ownership changes (the whole
        // point of pinning is decoupling from runtime factory state).
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();

        vm.prank(address(factory));
        pool.transferOwnership(address(0xBEEF));

        assertTrue(pool.requiresStrictProtectedBackingPrice());
    }

    function testUpdatePoolConfigRevertsWhenStrictPoolSwitchesToFallbackOnlyComposite() public {
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(backingToken), 1e8);

        MockFallbackCompositeOracle fallbackCompositeOracle = new MockFallbackCompositeOracle();
        fallbackCompositeOracle.setTokenOracleFeed(address(shieldedToken), address(oracle));
        fallbackCompositeOracle.setTokenOracleFeed(address(backingToken), address(noCircuitBreakerFeed));

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        pool.updatePoolConfig(
            1e18,
            1000e18,
            1e18,
            1000e18,
            1000000e8,
            1 days,
            28 days,
            100,
            protocolFeeRecipient,
            address(fallbackCompositeOracle)
        );
    }

    function testUpdatePoolConfigRevertsWhenCompositeSubFeedNormalizesToZero() public {
        MockHighDecimalTinyFeed tinyFeed = new MockHighDecimalTinyFeed(18);
        tinyFeed.setPrice(address(shieldedToken), 1);

        MockFallbackCompositeOracle fallbackCompositeOracle = new MockFallbackCompositeOracle();
        fallbackCompositeOracle.setTokenOracleFeed(address(shieldedToken), address(tinyFeed));
        fallbackCompositeOracle.setTokenOracleFeed(address(backingToken), address(oracle));

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidOraclePrice.selector);
        pool.updatePoolConfig(
            1e18,
            1000e18,
            1e18,
            1000e18,
            1000000e8,
            1 days,
            28 days,
            100,
            protocolFeeRecipient,
            address(fallbackCompositeOracle)
        );
    }

    function testUpdatePoolConfigRevertsWhenStrictCompositeOmitsSupportSelector() public {
        vm.prank(governance);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
        vm.prank(governance);
        pool.refreshStrictProtectedBackingPriceFlag();

        MockFallbackCompositeOracle fallbackCompositeOracle = new MockFallbackCompositeOracle();
        fallbackCompositeOracle.setTokenOracleFeed(address(shieldedToken), address(oracle));
        fallbackCompositeOracle.setTokenOracleFeed(address(backingToken), address(oracle));

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        pool.updatePoolConfig(
            1e18,
            1000e18,
            1e18,
            1000e18,
            1000000e8,
            1 days,
            28 days,
            100,
            protocolFeeRecipient,
            address(fallbackCompositeOracle)
        );
    }
}

contract MockPriceOnlyOracle {
    mapping(address => uint256) internal prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }
}

contract MockFallbackCompositeOracle {
    mapping(address => address) internal feeds;

    function setTokenOracleFeed(address token, address feed) external {
        feeds[token] = feed;
    }

    function getTokenDualFeedStatus(address token)
        external
        view
        returns (
            bool isDualFeed,
            address primaryFeed,
            address backupFeed,
            bool isBackupActive,
            bool isChallengePending,
            uint256 challengeStartTime
        )
    {
        return (false, feeds[token], address(0), false, false, 0);
    }

    function getPrice(address token) external view returns (uint256) {
        return IOracleFeed(feeds[token]).getPrice(token);
    }

    function getPriceUnsafe(address) external pure returns (uint256) {
        return 1e8;
    }

    function getPriceWithStrictCircuitBreaker(address token) external view returns (uint256) {
        return IOracleFeed(feeds[token]).getPrice(token);
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

contract MockHighDecimalTinyFeed is IOracleFeed {
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
        return "Mock High Decimal Tiny Feed";
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
