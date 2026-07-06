// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC4626WithDecimalsOffset } from "../contracts/mocks/MockERC4626WithDecimalsOffset.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockSequencerUptimeFeed } from "../contracts/mocks/MockSequencerUptimeFeed.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract UnderlyingOracleWithoutDecimals {
    function getPrice(address) external pure returns (uint256) {
        return 1e8;
    }

    function getPriceUnsafe(address) external pure returns (uint256) {
        return 1e8;
    }

    function isPriceStale(address) external view returns (bool, uint64) {
        return (false, uint64(block.timestamp));
    }

    function description() external pure returns (string memory) {
        return "Underlying Oracle Without Decimals";
    }
}

contract UnderlyingOracleWithRevertingDecimals is UnderlyingOracleWithoutDecimals {
    function decimals() external pure returns (uint8) {
        revert("decimals unavailable");
    }
}

contract CompositeOracleWithDecimals is CompositeOracle {
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract MockERC4626WithRedeemFee is MockERC4626 {
    uint256 public redeemFeeBps;

    constructor(IERC20 asset, string memory name, string memory symbol, uint256 redeemFeeBps_)
        MockERC4626(asset, name, symbol)
    {
        redeemFeeBps = redeemFeeBps_;
    }

    function setRedeemFeeBps(uint256 redeemFeeBps_) external {
        redeemFeeBps = redeemFeeBps_;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - ((assets * redeemFeeBps) / 10_000);
    }
}

contract MutableAssetERC4626 is MockERC4626 {
    address private reportedAsset;
    bool private shouldRevertAsset;

    constructor(IERC20 initialAsset, string memory name, string memory symbol) MockERC4626(initialAsset, name, symbol) {
        reportedAsset = address(initialAsset);
    }

    function setReportedAsset(address asset_) external {
        reportedAsset = asset_;
    }

    function setShouldRevertAsset(bool shouldRevertAsset_) external {
        shouldRevertAsset = shouldRevertAsset_;
    }

    function asset() public view override returns (address) {
        if (shouldRevertAsset) revert("asset unavailable");
        return reportedAsset;
    }
}

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
    event VaultSharePriceReferenceRefreshScheduled(
        address indexed vault,
        uint256 oldReferenceAssetsPerShare,
        uint256 scheduledReferenceAssetsPerShare,
        uint256 executableAt,
        uint256 expiresAt
    );
    event VaultSharePriceReferenceRefreshCancelled(address indexed vault);

    function setUp() public {
        // Deploy underlying asset and vault
        underlyingAsset = new MockERC20("Underlying Asset", "UA");
        vault = new MockERC4626(IERC20(address(underlyingAsset)), "Vault", "VLT");

        // Deploy underlying price oracle
        underlyingOracle = new MockOracle();
        underlyingOracle.setPrice(address(underlyingAsset), UNDERLYING_PRICE);

        // Deploy ERC4626 oracle feed
        erc4626Feed = new ERC4626OracleFeed(address(underlyingOracle));

        _seedAndRegister(IERC20(address(underlyingAsset)), IERC4626(address(vault)));
    }

    function _minimumSupplyForVault(address targetVault) internal view returns (uint256) {
        return erc4626Feed.MIN_VAULT_SHARE_COUNT() * (10 ** IERC20Metadata(targetVault).decimals());
    }

    function _seedVaultToMinimum(IERC20 asset, IERC4626 targetVault) internal returns (uint256 minimumShares) {
        minimumShares = _minimumSupplyForVault(address(targetVault));
        _seedVaultShares(asset, targetVault, minimumShares);
    }

    function _seedVaultShares(IERC20 asset, IERC4626 targetVault, uint256 shares) internal {
        uint256 assets = targetVault.previewMint(shares);
        deal(address(asset), address(this), asset.balanceOf(address(this)) + assets);
        asset.approve(address(targetVault), assets);
        targetVault.mint(shares, address(this));
    }

    function _seedAndRegister(IERC20 asset, IERC4626 targetVault) internal returns (uint256 minimumShares) {
        minimumShares = _seedVaultToMinimum(asset, targetVault);
        erc4626Feed.registerVault(address(targetVault), address(asset));
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

    function test_Constructor_RevertsWhenUnderlyingOracleDecimalsMissing() public {
        UnderlyingOracleWithoutDecimals oracleWithoutDecimals = new UnderlyingOracleWithoutDecimals();

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InvalidUnderlyingPriceOracleDecimals.selector, address(oracleWithoutDecimals)
            )
        );
        new ERC4626OracleFeed(address(oracleWithoutDecimals));
    }

    // ============ Registration Tests ============

    function test_RegisterVault_Succeeds() public {
        MockERC20 newAsset = new MockERC20("New Asset", "NA");
        MockERC4626 newVault = new MockERC4626(IERC20(address(newAsset)), "New Vault", "NV");
        underlyingOracle.setPrice(address(newAsset), 1e8);

        _seedVaultToMinimum(IERC20(address(newAsset)), IERC4626(address(newVault)));
        vm.expectEmit(true, true, false, true);
        emit VaultRegistered(address(newVault), address(newAsset));
        erc4626Feed.registerVault(address(newVault), address(newAsset));

        assertEq(erc4626Feed.vaultToUnderlying(address(newVault)), address(newAsset));
    }

    function test_GetPrice_UsesPreviewRedeemWhenVaultChargesRedeemFee() public {
        MockERC20 feeAsset = new MockERC20("Fee Asset", "FEE");
        MockERC4626WithRedeemFee feeVault =
            new MockERC4626WithRedeemFee(IERC20(address(feeAsset)), "Fee Vault", "fVLT", 100);
        underlyingOracle.setPrice(address(feeAsset), 1e8);

        _seedAndRegister(IERC20(address(feeAsset)), IERC4626(address(feeVault)));

        assertEq(feeVault.convertToAssets(1e18), 1e18, "precondition: accounting share price is one asset");
        assertEq(feeVault.previewRedeem(1e18), 0.99e18, "precondition: redeem preview includes fee");
        assertEq(erc4626Feed.getPrice(address(feeVault)), 99_000_000, "oracle should price redeemable assets");
    }

    function test_GetPrice_RevertsWhenRedeemableShareRateFallsBelowReviewedBand() public {
        MockERC20 feeAsset = new MockERC20("Haircut Asset", "HAIR");
        MockERC4626WithRedeemFee feeVault =
            new MockERC4626WithRedeemFee(IERC20(address(feeAsset)), "Haircut Vault", "hVLT", 5_000);
        underlyingOracle.setPrice(address(feeAsset), 1e8);

        _seedAndRegister(IERC20(address(feeAsset)), IERC4626(address(feeVault)));

        assertEq(feeVault.convertToAssets(1e18), 1e18, "accounting share price remains in band");
        assertEq(feeVault.previewRedeem(1e18), 0.5e18, "redeem preview reflects withdrawal haircut");
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.SharePriceDeviationTooHigh.selector,
                address(feeVault),
                feeVault.previewRedeem(1e18),
                1e18,
                erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS()
            )
        );
        erc4626Feed.getPrice(address(feeVault));
    }

    function test_SupportsStrictProtectedPriceRequiresSequencerFeedOnKnownL2() public {
        vm.chainId(42161);
        ERC4626OracleFeed l2Feed = new ERC4626OracleFeed(address(underlyingOracle));
        l2Feed.registerVault(address(vault), address(underlyingAsset));

        assertFalse(
            l2Feed.supportsStrictProtectedPrice(address(vault)),
            "known L2 feed without sequencer feed must not advertise strict support"
        );

        MockSequencerUptimeFeed sequencerFeed = new MockSequencerUptimeFeed();
        l2Feed.setSequencerUptimeFeed(address(sequencerFeed));

        assertTrue(
            l2Feed.supportsStrictProtectedPrice(address(vault)),
            "strict support returns after required sequencer feed is configured"
        );
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
        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.VaultRemovalNotScheduled.selector, address(vault)));
        erc4626Feed.removeVault(address(vault));

        erc4626Feed.scheduleRemoveVault(address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultRemovalTooEarly.selector,
                address(vault),
                block.timestamp + erc4626Feed.VAULT_REMOVAL_DELAY()
            )
        );
        erc4626Feed.removeVault(address(vault));

        vm.warp(block.timestamp + erc4626Feed.VAULT_REMOVAL_DELAY());

        vm.expectEmit(true, false, false, true);
        emit VaultRemoved(address(vault));

        erc4626Feed.removeVault(address(vault));

        assertEq(erc4626Feed.vaultToUnderlying(address(vault)), address(0));
    }

    function test_RegisterVault_RevertsWhenAlreadyRegistered() public {
        erc4626Feed.scheduleRemoveVault(address(vault));

        vm.expectRevert(abi.encodeWithSelector(ERC4626OracleFeed.VaultAlreadyRegistered.selector, address(vault)));
        erc4626Feed.registerVault(address(vault), address(underlyingAsset));

        assertEq(
            erc4626Feed.scheduledVaultRemovalTime(address(vault)),
            block.timestamp + erc4626Feed.VAULT_REMOVAL_DELAY(),
            "failed re-registration should not clear scheduled removal"
        );
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

    function test_PriceReadsRevertWhenVaultAssetChangesAfterRegistration() public {
        MockERC20 mutableAsset = new MockERC20("Mutable Asset", "MA");
        MockERC20 replacementAsset = new MockERC20("Replacement Asset", "RA");
        MutableAssetERC4626 mutableVault =
            new MutableAssetERC4626(IERC20(address(mutableAsset)), "Mutable Vault", "mVLT");
        underlyingOracle.setPrice(address(mutableAsset), UNDERLYING_PRICE);

        _seedAndRegister(IERC20(address(mutableAsset)), IERC4626(address(mutableVault)));
        mutableVault.setReportedAsset(address(replacementAsset));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.getPrice(address(mutableVault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.getPriceUnsafe(address(mutableVault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.isPriceStale(address(mutableVault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.getPriceWithStaleness(address(mutableVault));
    }

    function test_ReferenceRefreshRevertsWhenVaultAssetChangesAfterScheduling() public {
        MockERC20 mutableAsset = new MockERC20("Mutable Asset", "MA");
        MockERC20 replacementAsset = new MockERC20("Replacement Asset", "RA");
        MutableAssetERC4626 mutableVault =
            new MutableAssetERC4626(IERC20(address(mutableAsset)), "Mutable Vault", "mVLT");
        underlyingOracle.setPrice(address(mutableAsset), UNDERLYING_PRICE);

        _seedAndRegister(IERC20(address(mutableAsset)), IERC4626(address(mutableVault)));
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(mutableVault));
        mutableVault.setReportedAsset(address(replacementAsset));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(mutableVault));

        vm.warp(block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultUnderlyingAssetMismatch.selector,
                address(mutableVault),
                address(mutableAsset),
                address(replacementAsset)
            )
        );
        erc4626Feed.refreshVaultSharePriceReference(address(mutableVault));
    }

    function test_GetPriceRevertsWhenVaultAssetRevertsAfterRegistration() public {
        MockERC20 mutableAsset = new MockERC20("Mutable Asset", "MA");
        MutableAssetERC4626 mutableVault =
            new MutableAssetERC4626(IERC20(address(mutableAsset)), "Mutable Vault", "mVLT");
        underlyingOracle.setPrice(address(mutableAsset), UNDERLYING_PRICE);

        _seedAndRegister(IERC20(address(mutableAsset)), IERC4626(address(mutableVault)));
        mutableVault.setShouldRevertAsset(true);

        vm.expectRevert(bytes("asset unavailable"));
        erc4626Feed.getPrice(address(mutableVault));
    }

    function test_GetPriceWithCircuitBreaker_RevertsWhenUnderlyingChallengePending() public {
        CompositeOracleWithDecimals compositeUnderlyingOracle = new CompositeOracleWithDecimals();
        MockOracle primary = new MockOracle();
        MockOracle backup = new MockOracle();
        primary.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        backup.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        compositeUnderlyingOracle.setTokenOracleFeedDual(address(underlyingAsset), address(primary), address(backup));

        ERC4626OracleFeed challengedFeed = new ERC4626OracleFeed(address(compositeUnderlyingOracle));
        challengedFeed.registerVault(address(vault), address(underlyingAsset));

        backup.setPrice(address(underlyingAsset), (UNDERLYING_PRICE * 10076) / 10000);
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
        CompositeOracleWithDecimals compositeUnderlyingOracle = new CompositeOracleWithDecimals();
        MockOracle primary = new MockOracle();
        MockOracle backup = new MockOracle();
        primary.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        backup.setPrice(address(underlyingAsset), UNDERLYING_PRICE);
        compositeUnderlyingOracle.setTokenOracleFeedDual(address(underlyingAsset), address(primary), address(backup));

        ERC4626OracleFeed challengedFeed = new ERC4626OracleFeed(address(compositeUnderlyingOracle));
        challengedFeed.registerVault(address(vault), address(underlyingAsset));

        backup.setPrice(address(underlyingAsset), (UNDERLYING_PRICE * 10076) / 10000);
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

    function test_GetPrice_ClampsInBandUpwardShareRateToReference() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() / 2))
                / 10_000;
        underlyingAsset.mint(address(vault), donation);

        uint256 expectedUnsafePrice = (vault.convertToAssets(1e18) * UNDERLYING_PRICE) / 1e18;

        assertEq(
            erc4626Feed.getPrice(address(vault)), UNDERLYING_PRICE, "protected price should use reviewed reference"
        );
        assertEq(erc4626Feed.getPriceUnsafe(address(vault)), expectedUnsafePrice, "unsafe price should expose live NAV");
    }

    function test_GetPriceForFeeAccrual_UsesLiveInBandShareRateWithProtectedUnderlying() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() / 2))
                / 10_000;
        underlyingAsset.mint(address(vault), donation);

        uint256 expectedFeePrice = (vault.convertToAssets(1e18) * UNDERLYING_PRICE) / 1e18;

        assertEq(erc4626Feed.getPrice(address(vault)), UNDERLYING_PRICE, "protected price remains clamped");
        assertEq(erc4626Feed.getPriceForFeeAccrual(address(vault)), expectedFeePrice, "fee price sees live NAV");

        underlyingOracle.setShouldRevertOnCircuitBreaker(true);
        vm.expectRevert();
        erc4626Feed.getPriceForFeeAccrual(address(vault));
        assertEq(
            erc4626Feed.getPriceUnsafe(address(vault)), expectedFeePrice, "unsafe path still bypasses underlying CB"
        );
    }

    function test_GetPriceForFeeAccrual_RevertsAboveReviewedBand() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() + 1))
                / 10_000;
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
        erc4626Feed.getPriceForFeeAccrual(address(vault));
    }

    function test_GetPriceWithStaleness_IsStaticcallSafe() public view {
        bytes memory callData = abi.encodeCall(ERC4626OracleFeed.getPriceWithStaleness, (address(vault)));

        (bool success, bytes memory returndata) = address(erc4626Feed).staticcall(callData);

        assertTrue(success, "getPriceWithStaleness should be callable from view contexts");
        (uint256 price, bool isStale) = abi.decode(returndata, (uint256, bool));
        assertEq(price, UNDERLYING_PRICE, "staticcall should return price");
        assertFalse(isStale, "fresh underlying should not be stale");
    }

    function test_GetPrice_ClampsShareRateAtUpperDeviationBoundary() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS())
                / 10_000;
        underlyingAsset.mint(address(vault), donation);

        uint256 expectedPrice = (vault.convertToAssets(1e18) * UNDERLYING_PRICE) / 1e18;
        // Exactly at the reviewed boundary, the protected path still lags upward moves.
        assertEq(erc4626Feed.getPrice(address(vault)), UNDERLYING_PRICE);
        assertEq(erc4626Feed.getPriceUnsafe(address(vault)), expectedPrice);
    }

    function test_GetPrice_AllowsInBandDownwardShareRateImmediately() public {
        _seedVaultShares(
            IERC20(address(underlyingAsset)), IERC4626(address(vault)), erc4626Feed.minimumVaultSupply(address(vault))
        );
        uint256 loss =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() / 2))
                / 10_000;
        underlyingAsset.burn(address(vault), loss);

        uint256 expectedPrice = (vault.convertToAssets(1e18) * UNDERLYING_PRICE) / 1e18;
        assertLt(expectedPrice, UNDERLYING_PRICE, "precondition: share rate moved down");
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
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS())
                / 10_000;
        underlyingAsset.mint(address(vault), donation);
        uint256 assetsPerShare = vault.convertToAssets(1e18);

        uint256 executableAt = block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY();
        uint256 expiresAt = executableAt + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_EXPIRY();
        vm.expectEmit(true, false, false, true);
        emit VaultSharePriceReferenceRefreshScheduled(address(vault), 1e18, assetsPerShare, executableAt, expiresAt);
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        vm.warp(executableAt);
        vm.expectEmit(true, false, false, true);
        emit VaultSharePriceReferenceUpdated(address(vault), 1e18, assetsPerShare);
        erc4626Feed.refreshVaultSharePriceReference(address(vault));

        assertApproxEqAbs(erc4626Feed.getPrice(address(vault)), 105e6, 1);
    }

    function test_ScheduleVaultSharePriceReferenceRefresh_RevertsBelowMinimumSupply() public {
        uint256 minSupply = erc4626Feed.minimumVaultSupply(address(vault));
        vault.burnShares(address(this), 1);
        underlyingAsset.mint(address(vault), minSupply);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(vault), minSupply - 1, minSupply
            )
        );
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));
    }

    function test_RefreshVaultSharePriceReference_RevertsWhenUnscheduled() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultSharePriceReferenceRefreshNotScheduled.selector, address(vault)
            )
        );
        erc4626Feed.refreshVaultSharePriceReference(address(vault));
    }

    function test_RefreshVaultSharePriceReference_RevertsBeforeDelay() public {
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        uint256 executableAt = block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY();
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultSharePriceReferenceRefreshTooEarly.selector, address(vault), executableAt
            )
        );
        erc4626Feed.refreshVaultSharePriceReference(address(vault));
    }

    function test_RefreshVaultSharePriceReference_RevertsAfterExpiry() public {
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        uint256 executableAt = block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY();
        uint256 expiresAt = executableAt + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_EXPIRY();
        vm.warp(expiresAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.VaultSharePriceReferenceRefreshExpired.selector, address(vault), expiresAt
            )
        );
        erc4626Feed.refreshVaultSharePriceReference(address(vault));

        (uint256 storedExecutableAt,,,,) = erc4626Feed.scheduledVaultSharePriceReferenceRefresh(address(vault));
        assertEq(storedExecutableAt, executableAt, "reverted expiry attempt should preserve schedule state");
    }

    function test_RefreshVaultSharePriceReference_UsesScheduledReference() public {
        uint256 scheduledDonation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS())
                / 10_000;
        underlyingAsset.mint(address(vault), scheduledDonation);

        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        uint256 laterDonation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS())
                / 10_000;
        underlyingAsset.mint(address(vault), laterDonation);
        vm.warp(block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY());

        erc4626Feed.refreshVaultSharePriceReference(address(vault));

        underlyingAsset.burn(address(vault), scheduledDonation + laterDonation);
        assertApproxEqAbs(erc4626Feed.getPrice(address(vault)), UNDERLYING_PRICE, 1);
    }

    function test_RefreshVaultSharePriceReference_RevertsWhenCurrentRateDriftsFromSchedule() public {
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() + 1))
                / 10_000;
        underlyingAsset.mint(address(vault), donation);
        uint256 assetsPerShare = vault.convertToAssets(1e18);
        vm.warp(block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.SharePriceDeviationTooHigh.selector,
                address(vault),
                assetsPerShare,
                1e18,
                erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS()
            )
        );
        erc4626Feed.refreshVaultSharePriceReference(address(vault));
    }

    function test_ScheduleVaultSharePriceReferenceRefresh_AllowsOutOfBandRecovery() public {
        uint256 donation =
            (erc4626Feed.minimumVaultSupply(address(vault)) * (erc4626Feed.DEFAULT_MAX_SHARE_PRICE_DEVIATION_BPS() + 1))
                / 10_000;
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

        uint256 executableAt = block.timestamp + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_DELAY();
        uint256 expiresAt = executableAt + erc4626Feed.SHARE_PRICE_REFERENCE_REFRESH_EXPIRY();
        vm.expectEmit(true, false, false, true);
        emit VaultSharePriceReferenceRefreshScheduled(address(vault), 1e18, assetsPerShare, executableAt, expiresAt);
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        vm.warp(executableAt);
        erc4626Feed.refreshVaultSharePriceReference(address(vault));

        assertApproxEqAbs(
            erc4626Feed.getPrice(address(vault)),
            (assetsPerShare * UNDERLYING_PRICE) / 1e18,
            1,
            "scheduled refresh should recover the protected path"
        );
    }

    function test_CancelScheduledVaultSharePriceReferenceRefresh_Succeeds() public {
        erc4626Feed.scheduleVaultSharePriceReferenceRefresh(address(vault));

        vm.expectEmit(true, false, false, true);
        emit VaultSharePriceReferenceRefreshCancelled(address(vault));
        erc4626Feed.cancelScheduledVaultSharePriceReferenceRefresh(address(vault));

        (uint256 executableAt,,,,) = erc4626Feed.scheduledVaultSharePriceReferenceRefresh(address(vault));
        assertEq(executableAt, 0, "cancel should clear schedule");
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

    function test_SetUnderlyingPriceOracle_RevertsWhenDecimalsFail() public {
        UnderlyingOracleWithRevertingDecimals badOracle = new UnderlyingOracleWithRevertingDecimals();

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626OracleFeed.InvalidUnderlyingPriceOracleDecimals.selector, address(badOracle))
        );
        erc4626Feed.setUnderlyingPriceOracle(address(badOracle));

        assertEq(address(erc4626Feed.underlyingPriceOracle()), address(underlyingOracle));
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

        _seedAndRegister(IERC20(address(asset2)), IERC4626(address(vault2)));

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

        uint256 minSupply = _seedAndRegister(IERC20(address(lowSupplyAsset)), IERC4626(address(lowSupplyVault)));
        uint256 smallDeposit = 100e18;
        lowSupplyVault.burnShares(address(this), minSupply - smallDeposit);

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

        uint256 minSupply = _seedAndRegister(IERC20(address(emptyAsset)), IERC4626(address(emptyVault)));
        emptyVault.burnShares(address(this), minSupply);
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

        _seedAndRegister(IERC20(address(minAsset)), IERC4626(address(minVault)));

        // Should succeed at exact minimum
        uint256 price = erc4626Feed.getPrice(address(minVault));
        assertEq(price, 1e8); // $1.00
    }

    function test_RegisterVault_RevertsBelowMinimumUsdValue() public {
        MockERC20 lowValueAsset = new MockERC20("Low Value Asset", "LVA");
        MockERC4626 lowValueVault = new MockERC4626(IERC20(address(lowValueAsset)), "Low Value Vault", "LVV");
        underlyingOracle.setPrice(address(lowValueAsset), 0.1e8);
        _seedVaultToMinimum(IERC20(address(lowValueAsset)), IERC4626(address(lowValueVault)));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultValue.selector,
                address(lowValueVault),
                100e8,
                erc4626Feed.MIN_VAULT_VALUE_USD()
            )
        );
        erc4626Feed.registerVault(address(lowValueVault), address(lowValueAsset));
    }

    function test_GetPrice_RevertsWhenVaultValueDropsBelowMinimumUsd() public {
        MockERC20 valueDropAsset = new MockERC20("Value Drop Asset", "VDA");
        MockERC4626 valueDropVault = new MockERC4626(IERC20(address(valueDropAsset)), "Value Drop Vault", "VDV");
        underlyingOracle.setPrice(address(valueDropAsset), 1e8);
        _seedAndRegister(IERC20(address(valueDropAsset)), IERC4626(address(valueDropVault)));

        underlyingOracle.setPrice(address(valueDropAsset), 0.5e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultValue.selector,
                address(valueDropVault),
                500e8,
                erc4626Feed.MIN_VAULT_VALUE_USD()
            )
        );
        erc4626Feed.getPrice(address(valueDropVault));
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

        // Attacker deposits tiny amount (1 wei would be ideal, but we use 1e18 for realistic test)
        uint256 tinyDeposit = 1e18; // 1 share
        attackAsset.mint(address(this), tinyDeposit);
        attackAsset.approve(address(attackVault), tinyDeposit);
        attackVault.deposit(tinyDeposit, address(this));

        uint256 minSupply = _minimumSupplyForVault(address(attackVault));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(attackVault), tinyDeposit, minSupply
            )
        );
        erc4626Feed.registerVault(address(attackVault), address(attackAsset));
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
        uint256 minSupply = _seedAndRegister(IERC20(address(referenceAsset)), IERC4626(address(referenceVault)));

        assertEq(erc4626Feed.minimumVaultSupply(address(referenceVault)), minSupply);

        // Test with minimum supply - 1 (should revert)
        MockERC20 asset1 = new MockERC20("Asset 1", "A1");
        MockERC4626 vault1 = new MockERC4626(IERC20(address(asset1)), "Vault 1", "V1");
        underlyingOracle.setPrice(address(asset1), 1e8);
        _seedAndRegister(IERC20(address(asset1)), IERC4626(address(vault1)));
        vault1.burnShares(address(this), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector, address(vault1), minSupply - 1, minSupply
            )
        );
        erc4626Feed.getPrice(address(vault1));

        // Test with exactly the minimum supply (should pass)
        MockERC20 asset2 = new MockERC20("Asset 2", "A2");
        MockERC4626 vault2 = new MockERC4626(IERC20(address(asset2)), "Vault 2", "V2");
        underlyingOracle.setPrice(address(asset2), 1e8);
        _seedAndRegister(IERC20(address(asset2)), IERC4626(address(vault2)));

        uint256 price2 = erc4626Feed.getPrice(address(vault2));
        assertEq(price2, 1e8, "Should succeed at exact minimum");

        // Test with minimum supply + 1 (should pass)
        MockERC20 asset3 = new MockERC20("Asset 3", "A3");
        MockERC4626 vault3 = new MockERC4626(IERC20(address(asset3)), "Vault 3", "V3");
        underlyingOracle.setPrice(address(asset3), 1e8);
        _seedVaultShares(IERC20(address(asset3)), IERC4626(address(vault3)), minSupply + 1);
        erc4626Feed.registerVault(address(vault3), address(asset3));

        uint256 price3 = erc4626Feed.getPrice(address(vault3));
        assertEq(price3, 1e8, "Should succeed at minimum + 1");

        // Test with 2x minimum supply (should pass)
        MockERC20 asset4 = new MockERC20("Asset 4", "A4");
        MockERC4626 vault4 = new MockERC4626(IERC20(address(asset4)), "Vault 4", "V4");
        underlyingOracle.setPrice(address(asset4), 1e8);
        _seedVaultShares(IERC20(address(asset4)), IERC4626(address(vault4)), minSupply * 2);
        erc4626Feed.registerVault(address(vault4), address(asset4));

        uint256 price4 = erc4626Feed.getPrice(address(vault4));
        assertEq(price4, 1e8, "Should succeed at 2x minimum");

        // Test with 10x minimum supply (should pass)
        MockERC20 asset5 = new MockERC20("Asset 5", "A5");
        MockERC4626 vault5 = new MockERC4626(IERC20(address(asset5)), "Vault 5", "V5");
        underlyingOracle.setPrice(address(asset5), 1e8);
        _seedVaultShares(IERC20(address(asset5)), IERC4626(address(vault5)), minSupply * 10);
        erc4626Feed.registerVault(address(vault5), address(asset5));

        uint256 price5 = erc4626Feed.getPrice(address(vault5));
        assertEq(price5, 1e8, "Should succeed at 10x minimum");
    }

    /// @notice INFO-5: Test share inflation attack with donation (should be blocked)
    function testShareInflation_AttackWithDonation() public {
        MockERC20 attackAsset = new MockERC20("Attack Asset", "ATK");
        MockERC4626 attackVault = new MockERC4626(IERC20(address(attackAsset)), "Attack Vault", "AV");
        underlyingOracle.setPrice(address(attackAsset), 1e8);

        uint256 minSupply = _minimumSupplyForVault(address(attackVault));

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
        erc4626Feed.registerVault(address(attackVault), address(attackAsset));

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
        uint256 minSupply = _minimumSupplyForVault(address(edgeVault));
        uint256 edgeDeposit = minSupply + 1; // Just above threshold
        _seedVaultShares(IERC20(address(edgeAsset)), IERC4626(address(edgeVault)), edgeDeposit);
        erc4626Feed.registerVault(address(edgeVault), address(edgeAsset));

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
        _seedVaultToMinimum(IERC20(address(usdc)), IERC4626(address(sixDecimalVault)));
        erc4626Feed.registerVault(address(sixDecimalVault), address(usdc));
        _seedVaultToMinimum(IERC20(address(usdc)), IERC4626(address(offsetVault)));
        erc4626Feed.registerVault(address(offsetVault), address(usdc));

        assertEq(erc4626Feed.minimumVaultSupply(address(sixDecimalVault)), 1000e6);
        assertEq(erc4626Feed.minimumVaultSupply(address(offsetVault)), 1000e18);
    }

    function test_GetPrice_ReturnsCorrectNAV_ForSixDecimalVaultShares() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626 sixDecimalVault = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");

        underlyingOracle.setPrice(address(usdc), UNDERLYING_PRICE);
        _seedAndRegister(IERC20(address(usdc)), IERC4626(address(sixDecimalVault)));

        uint256 price = erc4626Feed.getPrice(address(sixDecimalVault));
        assertEq(price, UNDERLYING_PRICE);
    }

    function test_GetPrice_ReturnsCorrectNAV_ForVaultWithShareOffset() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626WithDecimalsOffset offsetVault =
            new MockERC4626WithDecimalsOffset(IERC20(address(usdc)), "Offset Vault", "ovUSDC", 12);

        underlyingOracle.setPrice(address(usdc), 2e8);
        _seedAndRegister(IERC20(address(usdc)), IERC4626(address(offsetVault)));

        uint256 price = erc4626Feed.getPrice(address(offsetVault));
        assertEq(price, 2e8);
    }

    function test_GetPrice_RevertsBelowMinimumSupply_ForSixDecimalVaultShares() public {
        MockUSDC usdc = new MockUSDC();
        MockERC4626 sixDecimalVault = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");

        underlyingOracle.setPrice(address(usdc), UNDERLYING_PRICE);
        uint256 minSupply = _seedAndRegister(IERC20(address(usdc)), IERC4626(address(sixDecimalVault)));
        sixDecimalVault.burnShares(address(this), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626OracleFeed.InsufficientVaultLiquidity.selector,
                address(sixDecimalVault),
                minSupply - 1,
                minSupply
            )
        );
        erc4626Feed.getPrice(address(sixDecimalVault));
    }
}
