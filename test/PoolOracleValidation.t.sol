// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { IOracleFeed } from "../contracts/interfaces/IOracleFeed.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

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
        factory = _deployFactory(address(this), governance, address(poolImpl));

        factory.setCompositeOracle(address(compositeOracle));
        compositeOracle.setAuthorizedCaller(address(factory), true);

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

    function _deployFallbackCompositeOracle() internal returns (CompositeOracle fallbackCompositeOracle) {
        fallbackCompositeOracle = new CompositeOracle();

        MockFeedWithoutCircuitBreaker noCircuitBreakerFeed = new MockFeedWithoutCircuitBreaker();
        noCircuitBreakerFeed.setPrice(address(backingToken), 1e8);

        fallbackCompositeOracle.setTokenOracleFeedWithType(address(shieldedToken), address(oracle), "mock");
        fallbackCompositeOracle.setTokenOracleFeedWithType(address(backingToken), address(noCircuitBreakerFeed), "mock");
        fallbackCompositeOracle.setAuthorizedCaller(address(factory), true);
    }

    function testCreatePoolRevertsWhenOracleLacksProtectedBackingPrice() public {
        factory.setCompositeOracle(address(priceOnlyOracle));

        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        factory.createPool(address(shieldedToken), "SHT", address(backingToken), "BKT", 1000, 200, 15000, 0);
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

    function testCreatePoolRevertsWhenCompositeBackingFeedLacksCircuitBreaker() public {
        CompositeOracle fallbackCompositeOracle = _deployFallbackCompositeOracle();
        factory.setCompositeOracle(address(fallbackCompositeOracle));

        _approveCreationBond();
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        factory.createPool(
            address(shieldedToken), "SHT", address(backingToken), "BKT", 1000, 200, 15000, _creationBondAmount()
        );
    }

    function testSetTokenRequiresStrictProtectedPriceRevertsWhenCurrentOracleUsesFallbackOnly() public {
        CompositeOracle fallbackCompositeOracle = _deployFallbackCompositeOracle();
        factory.setCompositeOracle(address(fallbackCompositeOracle));
        address backingFeed = fallbackCompositeOracle.getTokenOracleFeed(address(backingToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(backingToken), backingFeed
            )
        );
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
    }

    function testCreatePoolRevertsWhenStrictBackingPolicyRequiresUnsupportedCompositeFeed() public {
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        CompositeOracle fallbackCompositeOracle = _deployFallbackCompositeOracle();
        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        factory.setCompositeOracle(address(fallbackCompositeOracle));
    }

    function testPoolStrictProtectedPriceRequirementReflectsFactoryPolicyWithoutSync() public {
        assertFalse(pool.requiresStrictProtectedBackingPrice());
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);
        assertTrue(pool.requiresStrictProtectedBackingPrice());
    }

    function testUpdatePoolConfigRevertsWhenStrictPoolSwitchesToFallbackOnlyComposite() public {
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        CompositeOracle fallbackCompositeOracle = _deployFallbackCompositeOracle();

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
