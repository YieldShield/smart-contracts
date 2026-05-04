// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";

/// @title OracleForkTest
/// @notice Comprehensive fork tests for oracle integrations
/// @dev Run with: forge test --match-contract OracleForkTest --fork-url $MAINNET_RPC_URL -vvv
contract OracleForkTest is Test {
    // Mainnet addresses
    address constant PYTH_MAINNET = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Sepolia addresses (for testnet testing)
    address constant PYTH_SEPOLIA = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    // Pyth price feed IDs
    bytes32 constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant USDC_USD_FEED_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    // ============ Fork Test Helpers ============

    modifier onlyMainnet() {
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            emit log("Skipping mainnet fork test: MAINNET_RPC_URL not configured");
            return;
        }
        vm.createSelectFork(forkUrl);
        _;
    }

    modifier onlySepolia() {
        string memory forkUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            emit log("Skipping Sepolia fork test: SEPOLIA_RPC_URL not configured");
            return;
        }
        vm.createSelectFork(forkUrl);
        _;
    }

    // ============ Chainlink Fork Tests ============

    function testChainlinkFeedOnMainnet() public onlyMainnet {
        // Deploy Chainlink feed
        ChainlinkOracleFeed chainlinkFeed = new ChainlinkOracleFeed(3600); // 1 hour max age

        // Set ETH/USD feed
        chainlinkFeed.setTokenFeed(WETH, CHAINLINK_ETH_USD);

        // Get price
        uint256 ethPrice = chainlinkFeed.getPrice(WETH);

        // Sanity check: ETH should be between $100 and $100,000
        assertGt(ethPrice, 100 * 1e8, "ETH price too low");
        assertLt(ethPrice, 100000 * 1e8, "ETH price too high");

        console.log("ETH/USD price from Chainlink:", ethPrice);
    }

    function testChainlinkFeedStalenessCheck() public onlyMainnet {
        // Deploy Chainlink feed with very short max age
        ChainlinkOracleFeed chainlinkFeed = new ChainlinkOracleFeed(10); // 10 second max age (minimum allowed)

        chainlinkFeed.setTokenFeed(WETH, CHAINLINK_ETH_USD);

        // Should revert due to stale price (unless just updated)
        // Note: This test may pass if we're lucky and get a fresh update
        (bool isStale,) = chainlinkFeed.isPriceStale(WETH);
        if (isStale) {
            vm.expectRevert();
            chainlinkFeed.getPrice(WETH);
        }
    }

    // ============ CompositeOracle Dual-Feed Tests ============

    function testCompositeOracleDualFeedWithMockFeeds() public {
        // Create two mock feeds with same initial price
        MockOracle primaryFeed = new MockOracle();
        MockOracle backupFeed = new MockOracle();

        address testToken = address(0x1234);
        primaryFeed.setPrice(testToken, 1e8); // $1.00
        backupFeed.setPrice(testToken, 1e8); // $1.00

        // Create CompositeOracle with dual-feed
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(testToken, address(primaryFeed), address(backupFeed));

        // Should use primary feed
        uint256 price = compositeOracle.getPrice(testToken);
        assertEq(price, 1e8, "Should return primary feed price");
        assertFalse(compositeOracle.isBackupActiveForToken(testToken), "Backup should not be active");
    }

    function testCompositeOracleChallenge() public {
        MockOracle primaryFeed = new MockOracle();
        MockOracle backupFeed = new MockOracle();

        address testToken = address(0x1234);
        primaryFeed.setPrice(testToken, 1e8); // $1.00
        backupFeed.setPrice(testToken, 108e6); // $1.08 (8% deviation)

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(testToken, address(primaryFeed), address(backupFeed));

        // Challenge should succeed with high deviation
        compositeOracle.challengeForToken(testToken);
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(testToken);
        assertTrue(isChallengePending, "Challenge should be pending");

        // Fast forward past timelock (16 hours default)
        vm.warp(block.timestamp + 16 hours + 1);

        // Finalize should switch to backup
        compositeOracle.finalizeChallenge(testToken);
        assertTrue(compositeOracle.isBackupActiveForToken(testToken), "Backup should be active");

        // Now should return backup price
        uint256 price = compositeOracle.getPrice(testToken);
        assertEq(price, 108e6, "Should return backup feed price");
    }

    function testCompositeOracleRevertToPrimary() public {
        MockOracle primaryFeed = new MockOracle();
        MockOracle backupFeed = new MockOracle();

        address testToken = address(0x1234);
        primaryFeed.setPrice(testToken, 1e8);
        backupFeed.setPrice(testToken, 108e6); // High deviation

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(testToken, address(primaryFeed), address(backupFeed));

        // Challenge and finalize
        compositeOracle.challengeForToken(testToken);
        vm.warp(block.timestamp + 16 hours + 1);
        compositeOracle.finalizeChallenge(testToken);
        assertTrue(compositeOracle.isBackupActiveForToken(testToken));

        // Now deviation resolves
        backupFeed.setPrice(testToken, 1e8);

        // Anyone can revert to primary
        compositeOracle.revertToPrimary(testToken);
        assertFalse(compositeOracle.isBackupActiveForToken(testToken), "Should have reverted to primary");
    }

    // ============ Integration Tests ============

    function testFullOracleStackWithMocks() public {
        // 1. Create underlying oracle (for stablecoin like USDC)
        MockOracle underlyingOracle = new MockOracle();
        address usdc = address(0x1111111111111111111111111111111111111111);
        underlyingOracle.setPrice(usdc, 1e8); // $1.00

        // 2. Create ERC4626 NAV feed (primary - stability focused)
        new ERC4626OracleFeed(address(underlyingOracle));

        // 3. Create primary oracle
        MockOracle primaryOracle = new MockOracle();
        address vaultToken = address(0x2222222222222222222222222222222222222222);
        primaryOracle.setPrice(vaultToken, 105e6); // $1.05 (NAV)

        // 4. Create market-responsive backup oracle (must be different from primary)
        MockOracle backupOracle = new MockOracle();
        backupOracle.setPrice(vaultToken, 105e6); // Same price initially

        // 5. Create CompositeOracle with dual-feed
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(vaultToken, address(primaryOracle), address(backupOracle));

        // 6. Verify price retrieval
        uint256 price = compositeOracle.getPrice(vaultToken);
        assertEq(price, 105e6, "Should get correct price");

        // 7. Verify oracle info
        (bool isDualFeed, address primary, address backup, bool isBackupActive,,) =
            compositeOracle.getTokenDualFeedStatus(vaultToken);
        assertTrue(isDualFeed, "Should be dual-feed");
        assertEq(primary, address(primaryOracle));
        assertEq(backup, address(backupOracle));
        assertFalse(isBackupActive);
    }

    // ============ Pyth Fork Tests (requires Sepolia) ============

    function testPythOracleOnSepolia() public onlySepolia {
        // Deploy Pyth oracle
        PythOracle pythOracle = new PythOracle(PYTH_SEPOLIA, 3600); // 1 hour max age

        // Set ETH price feed
        pythOracle.setTokenPriceFeed(WETH, ETH_USD_FEED_ID);

        // Note: Pyth requires recent price updates, so this test may fail
        // if no one has updated prices recently on testnet
        // In production, a keeper would update prices before critical operations

        // Try to get price (may revert if stale)
        try pythOracle.getPrice(WETH) returns (uint256 price) {
            console.log("ETH/USD price from Pyth:", price);
            assertGt(price, 100 * 1e8, "ETH price too low");
        } catch {
            console.log("Pyth price stale - expected on testnet without keepers");
        }
    }

    // ============ Edge Case Tests ============

    function testOracleWithZeroPrice() public {
        MockOracle zeroPriceOracle = new MockOracle();
        // Mock oracle returns $1.00 by default for unset tokens
        // This tests that behavior

        uint256 price = zeroPriceOracle.getPrice(address(0x9999));
        assertEq(price, 1e8, "Should return default $1.00");
    }

    function testCompositeOracleDeviationCalculation() public {
        MockOracle primaryFeed = new MockOracle();
        MockOracle backupFeed = new MockOracle();

        address testToken = address(0x1234);

        // Test exactly at threshold (0.75%)
        primaryFeed.setPrice(testToken, 10000e4); // $100.00
        backupFeed.setPrice(testToken, 10075e4); // $100.75 (exactly 0.75% higher)

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(testToken, address(primaryFeed), address(backupFeed));

        // Should fail because deviation is exactly at threshold, not above
        vm.expectRevert();
        compositeOracle.challengeForToken(testToken);

        // Now test just above threshold (0.76%)
        backupFeed.setPrice(testToken, 10076e4); // $100.76 (0.76% higher)

        compositeOracle.challengeForToken(testToken);
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(testToken);
        assertTrue(isChallengePending, "Challenge should succeed above threshold");
    }
}
