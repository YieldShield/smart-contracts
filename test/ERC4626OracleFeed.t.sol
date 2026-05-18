// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC4626WithDecimalsOffset } from "../contracts/mocks/MockERC4626WithDecimalsOffset.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC4626OracleFeedTest is Test {
    ERC4626OracleFeed public erc4626Feed;
    MockOracle public underlyingOracle;
    MockERC4626 public vault;
    MockERC20 public underlyingAsset;

    address public underlying = address(0x1111);
    uint256 public constant UNDERLYING_PRICE = 1e8; // $1.00

    event VaultRegistered(address indexed vault, address indexed underlying);
    event VaultRemoved(address indexed vault);
    event UnderlyingPriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event VaultSharePriceReferenceUpdated(
        address indexed vault, uint256 oldReferenceAssetsPerShare, uint256 newReferenceAssetsPerShare
    );

    function setUp() public {
        // Deploy underlying asset and vault
        underlyingAsset = new MockERC20("Underlying Asset", "UA");
        vault = new MockERC4626(IERC20(address(underlyingAsset)), "Vault", "VLT");

        // Deploy underlying price oracle
        underlyingOracle = new MockOracle();
        underlyingOracle.setPrice(address(underlyingAsset), UNDERLYING_PRICE);

        // Deploy ERC4626 oracle feed
        erc4626Feed = new ERC4626OracleFeed(address(underlyingOracle));

        // Register vault
        erc4626Feed.registerVault(address(vault), address(underlyingAsset));

        // Deposit enough to meet the native minimum share threshold for this vault.
        // This ensures basic tests pass the share inflation protection
        uint256 depositAmount = erc4626Feed.minimumVaultSupply(address(vault));
        underlyingAsset.mint(address(this), depositAmount);
        underlyingAsset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));
    }

    // ============ Initialization Tests ============

    function test_InitialState() public view {
        assertEq(address(erc4626Feed.underlyingPriceOracle()), address(underlyingOracle));
        assertEq(erc4626Feed.vaultToUnderlying(address(vault)), address(underlyingAsset));
        assertEq(erc4626Feed.decimals(), 8);
    }

    function test_Constructor_RevertsOnInvalidOracle() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.InvalidOracleAddress.selector, address(0)));
        new ERC4626OracleFeed(address(0));
    }

    // ============ Registration Tests ============

    function test_RegisterVault_Succeeds() public {
        MockERC20 newAsset = new MockERC20("New Asset", "NA");
        MockERC4626 newVault = new MockERC4626(IERC20(address(newAsset)), "New Vault", "NV");
        underlyingOracle.setPrice(address(newAsset), 1e8);

        vm.expectEmit(true, true, false, true);
        emit VaultRegistered(address(newVault), address(newAsset));

        erc4626Feed.registerVault(address(newVault), address(newAsset));

        assertEq(erc4626Feed.vaultToUnderlying(address(newVault)), address(newAsset));
    }

    function test_RegisterVault_RevertsOnInvalidVault() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.InvalidVaultAddress.selector, address(0)));
        erc4626Feed.registerVault(address(0), address(underlyingAsset));
    }

    function test_RegisterVault_RevertsOnInvalidUnderlying() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.InvalidUnderlyingAddress.selector, address(0)));
        erc4626Feed.registerVault(address(vault), address(0));
    }

    function test_RegisterVault_RevertsOnMismatchedUnderlying() public {
        MockERC20 wrongAsset = new MockERC20("Wrong Asset", "WA");
        MockERC4626 newVault = new MockERC4626(IERC20(address(wrongAsset)), "New Vault", "NV");

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626OracleFeed.InvalidUnderlyingAddress.selector, address(underlyingAsset))
        );
        // Try to register with wrong underlying
        erc4626Feed.registerVault(address(newVault), address(underlyingAsset));
    }

    function test_RemoveVault_Succeeds() public {
        // LOW-11 FIX: Now emits VaultRemoved instead of misleading VaultRegistered
        vm.expectEmit(true, false, false, true);
        emit VaultRemoved(address(vault));

        erc4626Feed.removeVault(address(vault));

        assertEq(erc4626Feed.vaultToUnderlying(address(vault)), address(0));
    }

    // ============ Price Calculation Tests ============

    function test_GetPrice_ReturnsCorrectNAV() public view {
        // For a new vault with 1:1 exchange rate, price should equal underlying price
        uint256 price = erc4626Feed.getPrice(address(vault));

        // convertToAssets(1e18) should return 1e18 for a 1:1 vault
        // Price = (1e18 * 1e8) / 1e18 = 1e8
        assertEq(price, UNDERLYING_PRICE);
    }

    function test_GetPriceWithCircuitBreaker_ReturnsCorrectNAV() public view {
        // After the safe-default rename, the protected price is exposed under `getPrice`.
        assertEq(erc4626Feed.getPrice(address(vault)), UNDERLYING_PRICE);
    }

    function test_GetPriceWithCircuitBreaker_UsesProtectedUnderlyingPrice() public {
        underlyingOracle.setShouldRevertOnCircuitBreaker(true);

        vm.expectRevert(
            abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(underlyingAsset))
        );
        erc4626Feed.getPrice(address(vault));

        assertEq(erc4626Feed.getPriceUnsafe(address(vault)), UNDERLYING_PRICE);
    }

    function test_GetPriceWithCircuitBreaker_RevertsWhenUnderlyingChallengePending() public {
        CompositeOracle compositeUnderlyingOracle = new CompositeOracle();
        MockOracle primary = new MockOracle();
        MockOracle backup = new MockOracle();
        primary.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        backup.setPrice(address(underlyingAsset), (UNDERLYING_PRICE * 10076) / 10000);
        compositeUnderlyingOracle.setTokenOracleFeedDual(address(underlyingAsset), address(primary), address(backup));

        ERC4626OracleFeed challengedFeed = new ERC4626OracleFeed(address(compositeUnderlyingOracle));
        challengedFeed.registerVault(address(vault), address(underlyingAsset));

        compositeUnderlyingOracle.challengeForToken(address(underlyingAsset));

        (bool isStale, uint64 publishTime) = challengedFeed.isPriceStale(address(vault));
        assertTrue(isStale);
        assertEq(publishTime, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.StaleUnderlyingPrice.selector, address(vault), address(underlyingAsset)
            )
        );
        challengedFeed.getPrice(address(vault));
    }

    function test_GetPriceUnsafe_BypassesUnderlyingCompositeChallengeGate() public {
        CompositeOracle compositeUnderlyingOracle = new CompositeOracle();
        MockOracle primary = new MockOracle();
        MockOracle backup = new MockOracle();
        primary.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        backup.setPrice(address(underlyingAsset), (UNDERLYING_PRICE * 10076) / 10000);
        compositeUnderlyingOracle.setTokenOracleFeedDual(address(underlyingAsset), address(primary), address(backup));

        ERC4626OracleFeed challengedFeed = new ERC4626OracleFeed(address(compositeUnderlyingOracle));
        challengedFeed.registerVault(address(vault), address(underlyingAsset));

        compositeUnderlyingOracle.challengeForToken(address(underlyingAsset));

        assertEq(challengedFeed.getPriceUnsafe(address(vault)), UNDERLYING_PRICE);
    }

    function test_GetPrice_CalculatesWithDeposit() public {
        // Deposit assets to properly initialize the vault
        underlyingAsset.mint(address(this), 1000e18);
        underlyingAsset.approve(address(vault), 1000e18);
        vault.deposit(1000e18, address(this));

        // With 1:1 deposit, price should equal underlying price
        uint256 price = erc4626Feed.getPrice(address(vault));

        // Price should equal the underlying price for a 1:1 vault
        assertEq(price, UNDERLYING_PRICE);
    }

    function test_GetPrice_WorksWithDifferentUnderlyingPrice() public {
        // Change underlying price
        uint256 newPrice = 2e8; // $2.00
        underlyingOracle.setPrice(address(underlyingAsset), newPrice);

        uint256 vaultPrice = erc4626Feed.getPrice(address(vault));

        // Should reflect new underlying price
        // For 1:1 vault: price should equal underlying price
        assertEq(vaultPrice, newPrice);
    }

    function test_GetPriceUnsafe_AlsoRevertsOnDonationShareRateSpike() public {
        // H-4: previously the *Unsafe path clamped to the upper deviation band,
        // silently under-pricing the share for as long as the deviation persisted
        // and making donation-driven inflation indistinguishable from organic
        // yield. Both paths now fail closed on the upper bound.
        uint256 donation = erc4626Feed.minimumVaultSupply(address(vault));
        underlyingAsset.mint(address(vault), donation);

        uint256 assetsPerShare = vault.convertToAssets(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.SharePriceDeviationTooHigh.selector,
                address(vault),
                assetsPerShare,
                1e18,
                erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS()
            )
        );
        erc4626Feed.getPriceUnsafe(address(vault));
    }

    function test_GetPriceWithCircuitBreaker_RevertsWhenShareRateRisesAboveReviewedBand() public {
        // After the safe-default rename, the fail-closed share-rate cap is enforced by `getPrice`.
        uint256 donation = erc4626Feed.minimumVaultSupply(address(vault));
        underlyingAsset.mint(address(vault), donation);

        uint256 assetsPerShare = vault.convertToAssets(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.SharePriceDeviationTooHigh.selector,
                address(vault),
                assetsPerShare,
                1e18,
                erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS()
            )
        );
        erc4626Feed.getPrice(address(vault));
    }

    function test_GetPrice_UsesRawShareRateAtUpperDeviationBoundary() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS())
                / 10_000;
        underlyingAsset.mint(address(vault), donation);

        uint256 expectedPrice = (vault.convertToAssets(1e18) * UNDERLYING_PRICE) / 1e18;
        // Exactly at the boundary the protected and unprotected paths agree (no clamp triggered).
        assertEq(erc4626Feed.getPrice(address(vault)), expectedPrice);
        assertEq(erc4626Feed.getPriceUnsafe(address(vault)), expectedPrice);
    }

    function test_GetPrice_RevertsWhenShareRateFallsBelowReviewedBand() public {
        uint256 loss =
            (erc4626Feed.minimumVaultSupply(address(vault))
                    * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() + 100)) / 10_000;
        underlyingAsset.burn(address(vault), loss);

        uint256 assetsPerShare = vault.convertToAssets(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.SharePriceDeviationTooHigh.selector,
                address(vault),
                assetsPerShare,
                1e18,
                erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS()
            )
        );
        erc4626Feed.getPrice(address(vault));
    }

    function test_RefreshVaultSharePriceReference_AllowsReviewedShareRate() public {
        uint256 donation = erc4626Feed.minimumVaultSupply(address(vault));
        underlyingAsset.mint(address(vault), donation);
        uint256 assetsPerShare = vault.convertToAssets(1e18);

        vm.expectEmit(true, false, false, true);
        emit VaultSharePriceReferenceUpdated(address(vault), 1e18, assetsPerShare);
        erc4626Feed.refreshVaultSharePriceReference(address(vault));

        assertApproxEqAbs(erc4626Feed.getPrice(address(vault)), 2e8, 1);
    }

    function test_GetPrice_RevertsOnUnregisteredVault() public {
        address unregisteredVault = address(0x9999);

        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.VaultNotRegistered.selector, unregisteredVault));
        erc4626Feed.getPrice(unregisteredVault);
    }

    // ============ Oracle Update Tests ============

    function test_SetUnderlyingPriceOracle_Succeeds() public {
        MockOracle newOracle = new MockOracle();
        newOracle.setPrice(address(underlyingAsset), 1e8);

        vm.expectEmit(true, true, false, true);
        emit UnderlyingPriceOracleUpdated(address(underlyingOracle), address(newOracle));

        erc4626Feed.setUnderlyingPriceOracle(address(newOracle));

        assertEq(address(erc4626Feed.underlyingPriceOracle()), address(newOracle));
    }

    function test_SetUnderlyingPriceOracle_RevertsOnInvalidAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.InvalidOracleAddress.selector, address(0)));
        erc4626Feed.setUnderlyingPriceOracle(address(0));
    }

    function test_SetUnderlyingPriceOracle_RevertsWhenNotOwner() public {
        MockOracle newOracle = new MockOracle();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        erc4626Feed.setUnderlyingPriceOracle(address(newOracle));
    }

    // ============ Decimals Tests ============

    function test_Decimals_Returns8() public view {
        assertEq(erc4626Feed.decimals(), 8);
    }

    function test_Description_ReturnsCorrectString() public view {
        string memory desc = erc4626Feed.description();
        assertEq(keccak256(bytes(desc)), keccak256(bytes("ERC4626 NAV Oracle Feed")));
    }

    // ============ Integration Tests ============

    function test_FullFlow_WithMultipleVaults() public {
        // Create second vault
        MockERC20 asset2 = new MockERC20("Asset 2", "A2");
        MockERC4626 vault2 = new MockERC4626(IERC20(address(asset2)), "Vault 2", "V2");
        underlyingOracle.setPrice(address(asset2), 2e8); // $2.00

        erc4626Feed.registerVault(address(vault2), address(asset2));

        // Fund vault2 to meet minimum supply requirement
        uint256 depositAmount = erc4626Feed.minimumVaultSupply(address(vault2));
        asset2.mint(address(this), depositAmount);
        asset2.approve(address(vault2), depositAmount);
        vault2.deposit(depositAmount, address(this));

        // Check prices
        uint256 price1 = erc4626Feed.getPrice(address(vault));
        uint256 price2 = erc4626Feed.getPrice(address(vault2));

        assertEq(price1, 1e8); // $1.00
        assertEq(price2, 2e8); // $2.00
    }

    // ============ MED-1 FIX: Share Inflation Protection Tests ============

    function test_GetPrice_RevertsOnInsufficientVaultLiquidity() public {
        // Create a new vault with very low supply (vulnerable to share inflation)
        MockERC20 lowSupplyAsset = new MockERC20("Low Supply Asset", "LSA");
        MockERC4626 lowSupplyVault = new MockERC4626(IERC20(address(lowSupplyAsset)), "Low Supply Vault", "LSV");
        underlyingOracle.setPrice(address(lowSupplyAsset), 1e8);

        erc4626Feed.registerVault(address(lowSupplyVault), address(lowSupplyAsset));

        // Deposit only 100 shares, below the native minimum supply threshold.
        uint256 smallDeposit = 100e18;
        lowSupplyAsset.mint(address(this), smallDeposit);
        lowSupplyAsset.approve(address(lowSupplyVault), smallDeposit);
        lowSupplyVault.deposit(smallDeposit, address(this));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(lowSupplyVault));

        // Should revert due to insufficient liquidity
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(lowSupplyVault), smallDeposit, minSupply
            )
        );
        erc4626Feed.getPrice(address(lowSupplyVault));
    }

    function test_GetPrice_RevertsOnEmptyVault() public {
        // Create an empty vault (0 shares)
        MockERC20 emptyAsset = new MockERC20("Empty Asset", "EA");
        MockERC4626 emptyVault = new MockERC4626(IERC20(address(emptyAsset)), "Empty Vault", "EV");
        underlyingOracle.setPrice(address(emptyAsset), 1e8);

        erc4626Feed.registerVault(address(emptyVault), address(emptyAsset));

        // Should revert due to insufficient liquidity (0 < minimum vault supply)
        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(emptyVault));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(emptyVault), 0, minSupply
            )
        );
        erc4626Feed.getPrice(address(emptyVault));
    }

    function test_GetPrice_SucceedsAtExactMinimumSupply() public {
        // Create vault with exactly the native minimum supply.
        MockERC20 minAsset = new MockERC20("Min Asset", "MA");
        MockERC4626 minVault = new MockERC4626(IERC20(address(minAsset)), "Min Vault", "MV");
        underlyingOracle.setPrice(address(minAsset), 1e8);

        erc4626Feed.registerVault(address(minVault), address(minAsset));

        uint256 exactMin = erc4626Feed.minimumVaultSupply(address(minVault));
        minAsset.mint(address(this), exactMin);
        minAsset.approve(address(minVault), exactMin);
        minVault.deposit(exactMin, address(this));

        // Should succeed at exact minimum
        uint256 price = erc4626Feed.getPrice(address(minVault));
        assertEq(price, 1e8); // $1.00
    }

    function test_ShareInflationAttack_IsBlocked() public {
        // This test demonstrates that share inflation attacks are blocked
        //
        // Attack scenario without protection:
        // 1. Attacker deposits 1 wei of assets, gets 1 wei of shares
        // 2. Attacker donates 1,000,000 USDC directly to vault
        // 3. convertToAssets(one share unit) returns astronomical value
        // 4. Oracle reports inflated price
        //
        // With minimum vault supply protection:
        // - Vault with only 1 wei of shares will be rejected
        // - Attacker would need 1000 native shares to pass, making attack economically infeasible

        MockERC20 attackAsset = new MockERC20("Attack Asset", "ATK");
        MockERC4626 attackVault = new MockERC4626(IERC20(address(attackAsset)), "Attack Vault", "AV");
        underlyingOracle.setPrice(address(attackAsset), 1e8);

        erc4626Feed.registerVault(address(attackVault), address(attackAsset));

        // Attacker deposits tiny amount (1 wei would be ideal, but we use 1e18 for realistic test)
        uint256 tinyDeposit = 1e18; // 1 share
        attackAsset.mint(address(this), tinyDeposit);
        attackAsset.approve(address(attackVault), tinyDeposit);
        attackVault.deposit(tinyDeposit, address(this));

        // Even with donation attack, oracle will reject due to low supply
        // Note: In real attack, attacker would donate assets to inflate ratio.
        // The oracle still rejects because the share supply is below the vault-specific threshold.
        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(attackVault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(attackVault), tinyDeposit, minSupply
            )
        );
        erc4626Feed.getPrice(address(attackVault));
    }

    function test_MIN_VAULT_SHARE_COUNT_Value() public view {
        assertEq(erc4626Feed.MIN_VAULT_SHARE_COUNT(), 1000);
    }

    // ============ INFO-5: ERC4626 Share Inflation Attack Scenarios ============

    /// @notice INFO-5: Test various minimum supply boundary values
    function testShareInflation_VariousMinimumSupplyValues() public {
        MockERC20 referenceAsset = new MockERC20("Reference Asset", "RA");
        MockERC4626 referenceVault = new MockERC4626(IERC20(address(referenceAsset)), "Reference Vault", "RV");
        underlyingOracle.setPrice(address(referenceAsset), 1e8);
        erc4626Feed.registerVault(address(referenceVault), address(referenceAsset));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(referenceVault));

        // Test with minimum supply - 1 (should revert)
        MockERC20 asset1 = new MockERC20("Asset 1", "A1");
        MockERC4626 vault1 = new MockERC4626(IERC20(address(asset1)), "Vault 1", "V1");
        underlyingOracle.setPrice(address(asset1), 1e8);
        erc4626Feed.registerVault(address(vault1), address(asset1));

        uint256 deposit1 = minSupply - 1;
        asset1.mint(address(this), deposit1);
        asset1.approve(address(vault1), deposit1);
        vault1.deposit(deposit1, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(vault1), deposit1, minSupply
            )
        );
        erc4626Feed.getPrice(address(vault1));

        // Test with exactly the minimum supply (should pass)
        MockERC20 asset2 = new MockERC20("Asset 2", "A2");
        MockERC4626 vault2 = new MockERC4626(IERC20(address(asset2)), "Vault 2", "V2");
        underlyingOracle.setPrice(address(asset2), 1e8);
        erc4626Feed.registerVault(address(vault2), address(asset2));

        uint256 deposit2 = minSupply;
        asset2.mint(address(this), deposit2);
        asset2.approve(address(vault2), deposit2);
        vault2.deposit(deposit2, address(this));

        uint256 price2 = erc4626Feed.getPrice(address(vault2));
        assertEq(price2, 1e8, "Should succeed at exact minimum");

        // Test with minimum supply + 1 (should pass)
        MockERC20 asset3 = new MockERC20("Asset 3", "A3");
        MockERC4626 vault3 = new MockERC4626(IERC20(address(asset3)), "Vault 3", "V3");
        underlyingOracle.setPrice(address(asset3), 1e8);
        erc4626Feed.registerVault(address(vault3), address(asset3));

        uint256 deposit3 = minSupply + 1;
        asset3.mint(address(this), deposit3);
        asset3.approve(address(vault3), deposit3);
        vault3.deposit(deposit3, address(this));

        uint256 price3 = erc4626Feed.getPrice(address(vault3));
        assertEq(price3, 1e8, "Should succeed at minimum + 1");

        // Test with 2x minimum supply (should pass)
        MockERC20 asset4 = new MockERC20("Asset 4", "A4");
        MockERC4626 vault4 = new MockERC4626(IERC20(address(asset4)), "Vault 4", "V4");
        underlyingOracle.setPrice(address(asset4), 1e8);
        erc4626Feed.registerVault(address(vault4), address(asset4));

        uint256 deposit4 = minSupply * 2;
        asset4.mint(address(this), deposit4);
        asset4.approve(address(vault4), deposit4);
        vault4.deposit(deposit4, address(this));

        uint256 price4 = erc4626Feed.getPrice(address(vault4));
        assertEq(price4, 1e8, "Should succeed at 2x minimum");

        // Test with 10x minimum supply (should pass)
        MockERC20 asset5 = new MockERC20("Asset 5", "A5");
        MockERC4626 vault5 = new MockERC4626(IERC20(address(asset5)), "Vault 5", "V5");
        underlyingOracle.setPrice(address(asset5), 1e8);
        erc4626Feed.registerVault(address(vault5), address(asset5));

        uint256 deposit5 = minSupply * 10;
        asset5.mint(address(this), deposit5);
        asset5.approve(address(vault5), deposit5);
        vault5.deposit(deposit5, address(this));

        uint256 price5 = erc4626Feed.getPrice(address(vault5));
        assertEq(price5, 1e8, "Should succeed at 10x minimum");
    }

    /// @notice INFO-5: Test share inflation attack with donation (should be blocked)
    function testShareInflation_AttackWithDonation() public {
        MockERC20 attackAsset = new MockERC20("Attack Asset", "ATK");
        MockERC4626 attackVault = new MockERC4626(IERC20(address(attackAsset)), "Attack Vault", "AV");
        underlyingOracle.setPrice(address(attackAsset), 1e8);
        erc4626Feed.registerVault(address(attackVault), address(attackAsset));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(attackVault));

        // Attacker deposits minimal amount (just below threshold)
        uint256 tinyDeposit = minSupply - 1;
        attackAsset.mint(address(this), tinyDeposit);
        attackAsset.approve(address(attackVault), tinyDeposit);
        attackVault.deposit(tinyDeposit, address(this));

        // Attacker attempts donation attack (direct transfer to vault)
        // This would inflate the share price in a vulnerable implementation
        uint256 donation = 1000000e18; // Large donation
        attackAsset.mint(address(attackVault), donation);

        // Verify oracle still rejects due to the minimum supply check.
        // The check happens on totalSupply, not on assets, so donation doesn't help
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector,
                address(attackVault),
                tinyDeposit, // totalSupply is still tinyDeposit
                minSupply
            )
        );
        erc4626Feed.getPrice(address(attackVault));

        // Verify that totalSupply check happens before price calculation
        // Even with inflated assets, low supply is caught first
        uint256 totalSupply = attackVault.totalSupply();
        assertLt(totalSupply, minSupply, "Total supply should still be below minimum");
    }

    /// @notice INFO-5: Test edge case precision at boundary
    function testShareInflation_EdgeCasePrecision() public {
        MockERC20 edgeAsset = new MockERC20("Edge Asset", "EA");
        MockERC4626 edgeVault = new MockERC4626(IERC20(address(edgeAsset)), "Edge Vault", "EV");
        underlyingOracle.setPrice(address(edgeAsset), 1e8);
        erc4626Feed.registerVault(address(edgeVault), address(edgeAsset));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(edgeVault));
        uint256 edgeDeposit = minSupply + 1; // Just above threshold
        edgeAsset.mint(address(this), edgeDeposit);
        edgeAsset.approve(address(edgeVault), edgeDeposit);
        edgeVault.deposit(edgeDeposit, address(this));

        // Should succeed at boundary
        uint256 price = erc4626Feed.getPrice(address(edgeVault));
        assertEq(price, 1e8, "Should calculate price correctly at boundary");

        // Verify price calculation accuracy
        // For a 1:1 vault, price should equal underlying price
        uint256 expectedPrice = underlyingOracle.getPrice(address(edgeAsset));
        assertEq(price, expectedPrice, "Price should match underlying price at boundary");

        // Test that rounding doesn't cause false positives
        // Even with minimal supply, price should be accurate
        uint256 totalSupply = edgeVault.totalSupply();
        assertGe(totalSupply, minSupply, "Total supply should meet minimum");
    }

    function test_MinimumVaultSupply_UsesVaultShareDecimals() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626 sixDecimalVault = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");
        MockERC4626WithDecimalsOffset offsetVault =
            new MockERC4626WithDecimalsOffset(IERC20(address(usdc)), "Offset Vault", "ovUSDC", 12);

        underlyingOracle.setPrice(address(usdc), UNDERLYING_PRICE);
        erc4626Feed.registerVault(address(sixDecimalVault), address(usdc));
        erc4626Feed.registerVault(address(offsetVault), address(usdc));

        assertEq(erc4626Feed.minimumVaultSupply(address(sixDecimalVault)), 1000e6);
        assertEq(erc4626Feed.minimumVaultSupply(address(offsetVault)), 1000e18);
    }

    function test_GetPrice_ReturnsCorrectNAV_ForSixDecimalVaultShares() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626 sixDecimalVault = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");

        underlyingOracle.setPrice(address(usdc), UNDERLYING_PRICE);
        erc4626Feed.registerVault(address(sixDecimalVault), address(usdc));

        uint256 depositAmount = erc4626Feed.minimumVaultSupply(address(sixDecimalVault));
        usdc.mint(address(this), depositAmount);
        usdc.approve(address(sixDecimalVault), depositAmount);
        sixDecimalVault.deposit(depositAmount, address(this));

        uint256 price = erc4626Feed.getPrice(address(sixDecimalVault));
        assertEq(price, UNDERLYING_PRICE);
    }

    function test_GetPrice_ReturnsCorrectNAV_ForVaultWithShareOffset() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626WithDecimalsOffset offsetVault =
            new MockERC4626WithDecimalsOffset(IERC20(address(usdc)), "Offset Vault", "ovUSDC", 12);

        underlyingOracle.setPrice(address(usdc), 2e8);
        erc4626Feed.registerVault(address(offsetVault), address(usdc));

        uint256 minimumShares = erc4626Feed.minimumVaultSupply(address(offsetVault));
        uint256 depositAmount = offsetVault.previewMint(minimumShares);

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(offsetVault), depositAmount);
        offsetVault.mint(minimumShares, address(this));

        uint256 price = erc4626Feed.getPrice(address(offsetVault));
        assertEq(price, 2e8);
    }

    function test_GetPrice_RevertsBelowMinimumSupply_ForSixDecimalVaultShares() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626 sixDecimalVault = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");

        underlyingOracle.setPrice(address(usdc), UNDERLYING_PRICE);
        erc4626Feed.registerVault(address(sixDecimalVault), address(usdc));

        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(sixDecimalVault));
        uint256 depositAmount = minSupply - 1;
        usdc.mint(address(this), depositAmount);
        usdc.approve(address(sixDecimalVault), depositAmount);
        sixDecimalVault.deposit(depositAmount, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector,
                address(sixDecimalVault),
                depositAmount,
                minSupply
            )
        );
        erc4626Feed.getPrice(address(sixDecimalVault));
    }
}
