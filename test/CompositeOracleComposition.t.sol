// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";

contract CompositeOracleCompositionTest is Test {
    CompositeOracle internal composite;
    MockOracle internal underlyingFeed;
    MockERC20 internal underlying;

    function setUp() public {
        composite = new CompositeOracle();
        underlyingFeed = new MockOracle();
        underlying = new MockERC20("Underlying", "UND");
        underlyingFeed.setPrice(address(underlying), 2e8);
        composite.setTokenOracleFeed(address(underlying), address(underlyingFeed));
    }

    function test_productionCompositePricesVaultUnderlying() public {
        assertEq(composite.decimals(), 8);
        ERC4626OracleFeed vaultFeed = new ERC4626OracleFeed(address(composite));
        MockERC4626 vault = new MockERC4626(underlying, "Vault", "VLT");
        underlying.approve(address(vault), 2_000e18);
        vault.deposit(2_000e18, address(this));
        vaultFeed.registerVault(address(vault), address(underlying));
        assertEq(vaultFeed.getPrice(address(vault)), 2e8);
    }

    function test_existingVaultFeedCanMigrateUnderlyingPricingToComposite() public {
        ERC4626OracleFeed vaultFeed = new ERC4626OracleFeed(address(underlyingFeed));
        MockERC4626 vault = new MockERC4626(underlying, "Vault", "VLT");
        underlying.approve(address(vault), 2_000e18);
        vault.deposit(2_000e18, address(this));
        vaultFeed.registerVault(address(vault), address(underlying));
        vaultFeed.setUnderlyingPriceOracle(address(composite));
        assertEq(vaultFeed.getPrice(address(vault)), 2e8);
    }

    function test_nestedCompositeRejectedOnEveryConfigurationPath() public {
        CompositeOracle outer = new CompositeOracle();
        bytes memory reason = abi.encodeWithSelector(
            CompositeOracle.NestedCompositeFeedUnsupported.selector, address(underlying), address(composite)
        );
        vm.expectRevert(reason);
        outer.setTokenOracleFeed(address(underlying), address(composite));
        vm.expectRevert(reason);
        outer.setTokenOracleFeedWithType(address(underlying), address(composite), "composite");
        vm.expectRevert(reason);
        outer.setTokenOracleFeedDual(address(underlying), address(composite), address(underlyingFeed));
        vm.expectRevert(reason);
        outer.setTokenOracleFeedDual(address(underlying), address(underlyingFeed), address(composite));
    }

    function test_selfReferentialCompositeRejectedBeforeCapabilityProbe() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.NestedCompositeFeedUnsupported.selector, address(underlying), address(composite)
            )
        );
        composite.setTokenOracleFeed(address(underlying), address(composite));
        assertEq(composite.getPrice(address(underlying)), 2e8);
    }
}
