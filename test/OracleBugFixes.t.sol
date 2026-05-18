// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

contract PythConfigHarness {
    function getFeedIdBySymbol(string memory symbol) external pure returns (bytes32) {
        return PythConfig.getFeedIdBySymbol(symbol);
    }

    function getQuoteFeedIdBySymbol(string memory symbol) external pure returns (bytes32) {
        return PythConfig.getQuoteFeedIdBySymbol(symbol);
    }
}

/// @title Tests for oracle and factory bug fixes
/// @notice Verifies fixes for division by zero and stale data cleanup
contract OracleBugFixesTest is Test, FactoryProxyTestBase {
    CompositeOracle public compositeOracle;
    MockOracle public mockOracle;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    SplitRiskPoolFactory public factory;
    MockERC4626 public vaultA;
    MockERC4626 public vaultB;

    address public owner = address(this);
    address public governanceTimelock;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        tokenC = new MockERC20("Token C", "TKNC");

        // Deploy vaults for factory tests
        vaultA = new MockERC4626(tokenA, "Vault A", "vTKNA");
        vaultB = new MockERC4626(tokenB, "Vault B", "vTKNB");

        // Deploy mock oracle with prices
        mockOracle = new MockOracle();
        mockOracle.setPrice(address(tokenA), 1e8); // $1 per token
        mockOracle.setPrice(address(tokenB), 2e8); // $2 per token
        mockOracle.setPrice(address(vaultA), 1e8);
        mockOracle.setPrice(address(vaultB), 2e8);

        // Deploy composite oracle
        compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeed(address(tokenA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(tokenB), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(vaultA), address(mockOracle));
        compositeOracle.setTokenOracleFeed(address(vaultB), address(mockOracle));

        // Deploy factory for tokenInfo cleanup tests
        SplitRiskPool poolImpl = new SplitRiskPool();
        governanceTimelock = address(_deployTestTimelock(address(this)));
        factory = _deployFactory(address(this), governanceTimelock, address(poolImpl));

        // Set up factory
        factory.setCompositeOracle(address(compositeOracle));
        compositeOracle.setAuthorizedCaller(address(factory), true);
        factory.setDefaultProtocolFeeRecipient(address(this));
    }

    // ============ Bug 5: CompositeOracle Division by Zero Tests ============

    /// @notice Test that getEquivalentAmount reverts with InvalidPrice when priceB is 0
    function test_getEquivalentAmount_ZeroPriceB_Reverts() public {
        // Set tokenC price to 0 (explicit zero, not unset)
        mockOracle.setPrice(address(tokenC), 0);
        compositeOracle.setTokenOracleFeed(address(tokenC), address(mockOracle));

        // Try to get equivalent amount with tokenC (zero price) as tokenB
        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidPrice.selector, address(tokenC), 0));
        compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(tokenC));
    }

    /// @notice Test that the unsafe equivalent-amount getter reverts with InvalidPrice when priceB is 0
    /// @dev After the safe-default rename, `getEquivalentAmount` IS the protected variant;
    ///      the old `getEquivalentAmountWithCircuitBreaker` test now exercises the explicit
    ///      `getEquivalentAmountUnsafe` getter that still needs to fail on a zero divisor.
    function test_getEquivalentAmountUnsafe_ZeroPriceB_Reverts() public {
        mockOracle.setPrice(address(tokenC), 0);
        compositeOracle.setTokenOracleFeed(address(tokenC), address(mockOracle));

        vm.expectRevert(abi.encodeWithSelector(CompositeOracle.InvalidPrice.selector, address(tokenC), 0));
        compositeOracle.getEquivalentAmountUnsafe(address(tokenA), 10e18, address(tokenC));
    }

    /// @notice Test that getEquivalentAmount works normally with non-zero prices
    function test_getEquivalentAmount_ValidPrices_Succeeds() public view {
        // 10 tokenA ($1 each = $10) -> tokenB ($2 each) = 5 tokenB
        uint256 equivalentAmount = compositeOracle.getEquivalentAmount(address(tokenA), 10e18, address(tokenB));
        assertEq(equivalentAmount, 5e18, "Should return correct equivalent amount");
    }

    /// @notice Test that the unsafe equivalent-amount getter agrees with the safe one for healthy feeds
    function test_getEquivalentAmountUnsafe_ValidPrices_Succeeds() public view {
        uint256 equivalentAmount =
            compositeOracle.getEquivalentAmountUnsafe(address(tokenA), 10e18, address(tokenB));
        assertEq(equivalentAmount, 5e18, "Should return correct equivalent amount");
    }

    function test_PythConfig_Usd0UsesDirectFeed() public {
        PythConfigHarness harness = new PythConfigHarness();

        bytes32 usd0FeedId = harness.getFeedIdBySymbol("USD0");
        assertEq(usd0FeedId, PythConfig.USD0_USD_FEED_ID, "USD0 should use direct Pyth feed");
        assertEq(harness.getFeedIdBySymbol("usd0"), PythConfig.USD0_USD_FEED_ID, "lowercase USD0 should work");
        assertTrue(usd0FeedId != PythConfig.USDC_USD_FEED_ID, "USD0 should not reuse USDC feed");
    }

    function test_PythConfig_SusdsUsesComposedUsdsFeed() public {
        PythConfigHarness harness = new PythConfigHarness();

        bytes32 susdsFeedId = harness.getFeedIdBySymbol("SUSDS");
        assertEq(susdsFeedId, PythConfig.SUSDS_USDS_FEED_ID, "SUSDS should use redemption-rate feed");
        assertEq(harness.getQuoteFeedIdBySymbol("SUSDS"), PythConfig.USDS_USD_FEED_ID, "SUSDS should compose USDS/USD");
        assertEq(harness.getFeedIdBySymbol("susds"), PythConfig.SUSDS_USDS_FEED_ID, "lowercase SUSDS should work");
        assertEq(harness.getQuoteFeedIdBySymbol("susds"), PythConfig.USDS_USD_FEED_ID, "lowercase quote should work");
        assertTrue(susdsFeedId != PythConfig.USDC_USD_FEED_ID, "SUSDS should not reuse USDC feed");
    }

    // ============ Bug 7: Factory removeToken Cleanup Tests ============

    /// @notice Test that removeToken clears tokenInfo mapping
    function test_removeToken_ClearsTokenInfo() public {
        // First add a token
        factory.addTokenInitial(address(vaultA), "Vault A", "vTKNA", address(mockOracle), address(0), 15000);

        // Verify token is whitelisted and has tokenInfo
        assertTrue(factory.isWhitelisted(address(vaultA)), "Token should be whitelisted");

        (
            string memory name,
            string memory symbol,
            address token,
            address primaryOracleFeed,
            address backupOracleFeed,
            uint256 minCollateral
        ) = factory.tokenInfo(address(vaultA));
        assertEq(token, address(vaultA), "Token address should be set");
        assertEq(minCollateral, 15000, "Min collateral should be set");
        assertTrue(bytes(name).length > 0, "Name should be set");
        assertTrue(bytes(symbol).length > 0, "Symbol should be set");

        vm.prank(governanceTimelock);
        factory.removeToken(address(vaultA));

        // Verify token is no longer whitelisted
        assertFalse(factory.isWhitelisted(address(vaultA)), "Token should not be whitelisted");

        // Verify tokenInfo is cleared
        (name, symbol, token, primaryOracleFeed, backupOracleFeed, minCollateral) = factory.tokenInfo(address(vaultA));
        assertEq(token, address(0), "Token address should be cleared");
        assertEq(primaryOracleFeed, address(0), "Primary oracle feed should be cleared");
        assertEq(backupOracleFeed, address(0), "Backup oracle feed should be cleared");
        assertEq(minCollateral, 0, "Min collateral should be cleared");
        assertEq(bytes(name).length, 0, "Name should be cleared");
        assertEq(bytes(symbol).length, 0, "Symbol should be cleared");
    }

    /// @notice Test that re-whitelisting a token with new parameters works correctly
    function test_removeToken_ThenReAdd_UsesNewParams() public {
        // Add token with initial params
        factory.addTokenInitial(address(vaultA), "Vault A", "vTKNA", address(mockOracle), address(0), 15000);

        // Verify initial params
        (,,,,, uint256 minCollateral1) = factory.tokenInfo(address(vaultA));
        assertEq(minCollateral1, 15000, "Initial min collateral should be 15000");

        // Remove the token
        vm.prank(governanceTimelock);
        factory.removeToken(address(vaultA));

        // Re-add with different params
        factory.addTokenInitial(address(vaultA), "Vault A v2", "vTKNA2", address(mockOracle), address(0), 20000);

        // Verify new params are used
        (string memory name, string memory symbol,,,, uint256 minCollateral2) = factory.tokenInfo(address(vaultA));
        assertEq(minCollateral2, 20000, "New min collateral should be 20000");
        assertEq(name, "Vault A v2", "New name should be used");
        assertEq(symbol, "vTKNA2", "New symbol should be used");
    }

    /// @notice Test that multiple tokens can be added and removed independently
    function test_removeToken_IndependentOfOtherTokens() public {
        // Add two tokens
        factory.addTokenInitial(address(vaultA), "Vault A", "vTKNA", address(mockOracle), address(0), 15000);
        factory.addTokenInitial(address(vaultB), "Vault B", "vTKNB", address(mockOracle), address(0), 12000);

        // Verify both are whitelisted
        assertTrue(factory.isWhitelisted(address(vaultA)), "VaultA should be whitelisted");
        assertTrue(factory.isWhitelisted(address(vaultB)), "VaultB should be whitelisted");

        // Remove only vaultA
        vm.prank(governanceTimelock);
        factory.removeToken(address(vaultA));

        // Verify vaultA is removed but vaultB is unaffected
        assertFalse(factory.isWhitelisted(address(vaultA)), "VaultA should not be whitelisted");
        assertTrue(factory.isWhitelisted(address(vaultB)), "VaultB should still be whitelisted");

        // Verify vaultB's tokenInfo is intact
        (,, address token,,, uint256 minCollateral) = factory.tokenInfo(address(vaultB));
        assertEq(token, address(vaultB), "VaultB token should still be set");
        assertEq(minCollateral, 12000, "VaultB min collateral should still be 12000");

        // Verify vaultA's tokenInfo is cleared
        (,, token,,, minCollateral) = factory.tokenInfo(address(vaultA));
        assertEq(token, address(0), "VaultA token should be cleared");
        assertEq(minCollateral, 0, "VaultA min collateral should be cleared");
    }
}
