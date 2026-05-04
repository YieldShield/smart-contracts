// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { MockGauntletUSDCPrime } from "../contracts/mocks/MockGauntletUSDCPrime.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GauntletUSDCPrimeTest
/// @notice Integration tests for MockGauntletUSDCPrime vault with ERC4626OracleFeed and CompositeOracle dual-feed
contract GauntletUSDCPrimeTest is Test {
    MockGauntletUSDCPrime public gtusdc;
    MockUSDC public usdc;
    MockOracle public mockOracle;
    ERC4626OracleFeed public erc4626Feed;
    CompositeOracle public compositeOracle;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public owner;

    uint256 public constant USDC_PRICE = 1e8; // $1.00 in 8 decimals
    uint256 public constant ANNUAL_YIELD_BPS = 500; // 5% APY
    uint256 public constant DEVIATION_THRESHOLD = 75; // 0.75%
    uint256 public constant CHALLENGE_DURATION = 16 hours;

    event YieldAccrued(uint256 newMultiplier, uint256 yieldAmount, uint256 timeElapsed);
    event AnnualYieldUpdated(uint256 oldYieldBps, uint256 newYieldBps);

    function setUp() public {
        owner = address(this);

        // Deploy USDC mock with 6 decimals (like real USDC)
        usdc = new MockUSDC();

        // Deploy Gauntlet USDC Prime vault
        gtusdc = new MockGauntletUSDCPrime(IERC20(address(usdc)), ANNUAL_YIELD_BPS);

        // Deploy MockOracle for underlying price
        mockOracle = new MockOracle();
        mockOracle.setPrice(address(usdc), USDC_PRICE);
        // Set initial gtUSDC market price (backup price)
        mockOracle.setPrice(address(gtusdc), USDC_PRICE);

        // Deploy ERC4626OracleFeed for NAV-based pricing
        erc4626Feed = new ERC4626OracleFeed(address(mockOracle));
        erc4626Feed.registerVault(address(gtusdc), address(usdc));

        // Deploy CompositeOracle with dual-feed support
        compositeOracle = new CompositeOracle();
        // Configure dual-feed: primary = NAV-based ERC4626, backup = market price from MockOracle
        compositeOracle.setTokenOracleFeedDual(address(gtusdc), address(erc4626Feed), address(mockOracle));

        // Fund test accounts with USDC
        usdc.mint(alice, 100000e6); // 100,000 USDC
        usdc.mint(bob, 100000e6);

        // Deposit enough to meet the vault's native minimum share threshold.
        // Since shares are 18 decimals and USDC is 6 decimals, at 1:1 rate:
        // 1000e18 shares needs 1000e6 USDC (1000 USDC).
        uint256 initialDepositUSDC = 1000e6;
        usdc.mint(owner, initialDepositUSDC);
        usdc.approve(address(gtusdc), initialDepositUSDC);
        gtusdc.deposit(initialDepositUSDC, owner);
    }

    // ============ Vault Basic Tests ============

    function test_VaultInitialState() public view {
        assertEq(gtusdc.name(), "Gauntlet USDC Prime");
        assertEq(gtusdc.symbol(), "gtUSDC");
        assertEq(gtusdc.decimals(), 18);
        assertEq(gtusdc.annualYieldBps(), ANNUAL_YIELD_BPS);
        assertEq(gtusdc.accumulatedYieldMultiplier(), 1e18);
        assertEq(address(gtusdc.asset()), address(usdc));
    }

    function test_VaultDeposit() public {
        uint256 depositAmount = 1000e6; // 1,000 USDC

        vm.startPrank(alice);
        usdc.approve(address(gtusdc), depositAmount);
        uint256 sharesMinted = gtusdc.deposit(depositAmount, alice);
        vm.stopPrank();

        // With 1:1 exchange rate and decimal adjustment (6 -> 18)
        // 1000e6 USDC should mint approximately 1000e18 shares
        assertGt(sharesMinted, 0);
        assertEq(gtusdc.balanceOf(alice), sharesMinted);
    }

    function test_VaultWithdraw() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(alice);
        usdc.approve(address(gtusdc), depositAmount);
        uint256 shares = gtusdc.deposit(depositAmount, alice);

        // Withdraw half
        uint256 withdrawShares = shares / 2;
        uint256 assetsReceived = gtusdc.redeem(withdrawShares, alice, alice);
        vm.stopPrank();

        assertGt(assetsReceived, 0);
        assertEq(gtusdc.balanceOf(alice), shares - withdrawShares);
    }

    // ============ Yield Accrual Tests ============

    function test_YieldAccrual_NoChangeWithZeroTime() public view {
        uint256 initialMultiplier = gtusdc.getCurrentMultiplier();
        assertEq(initialMultiplier, 1e18);
    }

    function test_YieldAccrual_IncreasesOverTime() public {
        uint256 initialMultiplier = gtusdc.getCurrentMultiplier();

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 newMultiplier = gtusdc.getCurrentMultiplier();

        // With 5% APY, multiplier should increase by ~5%
        // newMultiplier should be approximately 1.05e18
        assertGt(newMultiplier, initialMultiplier);

        // Allow 0.1% tolerance for rounding
        uint256 expectedMultiplier = initialMultiplier + (initialMultiplier * ANNUAL_YIELD_BPS / 10000);
        assertApproxEqRel(newMultiplier, expectedMultiplier, 0.001e18);
    }

    function test_YieldAccrual_EmitsEvent() public {
        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        vm.expectEmit(false, false, false, false);
        emit YieldAccrued(0, 0, 0); // We don't check exact values

        gtusdc.accrueYield();
    }

    function test_YieldAccrual_AffectsConvertToAssets() public {
        // Deposit some USDC
        vm.startPrank(alice);
        usdc.approve(address(gtusdc), 1000e6);
        gtusdc.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 sharesHeld = gtusdc.balanceOf(alice);
        uint256 initialAssets = gtusdc.convertToAssets(sharesHeld);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        uint256 newAssets = gtusdc.convertToAssets(sharesHeld);

        // Assets should have increased by ~5%
        assertGt(newAssets, initialAssets);
        uint256 expectedIncrease = initialAssets * ANNUAL_YIELD_BPS / 10000;
        assertApproxEqRel(newAssets, initialAssets + expectedIncrease, 0.01e18);
    }

    function test_SetAnnualYield() public {
        uint256 newYieldBps = 1000; // 10%

        vm.expectEmit(false, false, false, true);
        emit AnnualYieldUpdated(ANNUAL_YIELD_BPS, newYieldBps);

        gtusdc.setAnnualYield(newYieldBps);

        assertEq(gtusdc.annualYieldBps(), newYieldBps);
    }

    // ============ NAV Pricing Tests ============

    function test_NAVPricing_InitialPrice() public view {
        // Initial NAV = $1.00 (1 USDC per share at 1:1 rate)
        uint256 price = erc4626Feed.getPrice(address(gtusdc));

        // Price should be approximately $1.00 (in 8 decimals)
        // Note: Due to decimal conversion (shares 18 decimals, USDC 6 decimals),
        // the exact value may differ slightly
        assertApproxEqRel(price, USDC_PRICE, 0.01e18);
    }

    function test_NAVPricing_AfterYieldAccrual() public {
        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        uint256 price = erc4626Feed.getPrice(address(gtusdc));

        // NAV should now be ~$1.05
        uint256 expectedPrice = USDC_PRICE + (USDC_PRICE * ANNUAL_YIELD_BPS / 10000);
        assertApproxEqRel(price, expectedPrice, 0.01e18);
    }

    function test_NAVPricing_WithUSDCPriceChange() public {
        // If USDC depegs to $0.99
        uint256 newUsdcPrice = 99e6; // $0.99
        mockOracle.setPrice(address(usdc), newUsdcPrice);

        uint256 gtUsdcPrice = erc4626Feed.getPrice(address(gtusdc));

        // gtUSDC NAV should reflect USDC price change
        assertApproxEqRel(gtUsdcPrice, newUsdcPrice, 0.01e18);
    }

    // ============ Dual-Oracle Tests (via CompositeOracle) ============

    function test_CompositeOracle_UsesNAVByDefault() public view {
        // CompositeOracle should use NAV (primary) by default
        assertFalse(compositeOracle.isBackupActiveForToken(address(gtusdc)));

        uint256 price = compositeOracle.getPrice(address(gtusdc));
        uint256 navPrice = erc4626Feed.getPrice(address(gtusdc));

        assertEq(price, navPrice);
    }

    function test_CompositeOracle_Challenge_SucceedsOnDeviation() public {
        // Create deviation: accrue yield to increase NAV
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        // NAV is now ~$1.05, but market price is still $1.00
        uint256 navPrice = erc4626Feed.getPrice(address(gtusdc));
        uint256 marketPrice = mockOracle.getPrice(address(gtusdc));

        console.log("NAV Price:", navPrice);
        console.log("Market Price:", marketPrice);

        // Deviation should be ~5%, which exceeds 0.75% threshold
        uint256 deviation;
        if (navPrice > marketPrice) {
            deviation = ((navPrice - marketPrice) * 10000) / marketPrice;
        } else {
            deviation = ((marketPrice - navPrice) * 10000) / navPrice;
        }
        console.log("Deviation (bps):", deviation);
        assertGt(deviation, DEVIATION_THRESHOLD);

        // Challenge should succeed
        compositeOracle.challengeForToken(address(gtusdc));
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(gtusdc));
        assertTrue(isChallengePending);
    }

    function test_CompositeOracle_FinalizeChallenge() public {
        // Create deviation and initiate challenge
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        compositeOracle.challengeForToken(address(gtusdc));

        // Wait for challenge duration
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // Update market price to match NAV (simulating arbitrage)
        uint256 navPrice = erc4626Feed.getPrice(address(gtusdc));
        mockOracle.setPrice(address(gtusdc), navPrice);

        // Finalize challenge - deviation has resolved, should cancel
        compositeOracle.cancelChallenge(address(gtusdc));

        // Should remain on primary (NAV)
        assertFalse(compositeOracle.isBackupActiveForToken(address(gtusdc)));
    }

    function test_CompositeOracle_SwitchToBackupOnPersistentDeviation() public {
        // Create deviation
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        // Challenge
        compositeOracle.challengeForToken(address(gtusdc));

        // Wait for challenge duration (deviation persists because market price unchanged)
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // Finalize - should switch to backup since deviation persists
        compositeOracle.finalizeChallenge(address(gtusdc));

        assertTrue(compositeOracle.isBackupActiveForToken(address(gtusdc)));

        // Price should now come from backup (market price)
        uint256 price = compositeOracle.getPrice(address(gtusdc));
        uint256 marketPrice = mockOracle.getPrice(address(gtusdc));
        assertEq(price, marketPrice);
    }

    // ============ Edge Case Tests ============

    function test_VaultWithZeroYield() public {
        // Create a vault with 0% yield
        MockGauntletUSDCPrime zeroYieldVault = new MockGauntletUSDCPrime(
            IERC20(address(usdc)),
            0 // 0% APY
        );

        uint256 initialMultiplier = zeroYieldVault.getCurrentMultiplier();

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 newMultiplier = zeroYieldVault.getCurrentMultiplier();

        // Multiplier should not change
        assertEq(newMultiplier, initialMultiplier);
    }

    function test_ConvertToShares_ReverseCalculation() public {
        // Deposit and check conversion consistency
        vm.startPrank(alice);
        usdc.approve(address(gtusdc), 1000e6);
        uint256 shares = gtusdc.deposit(1000e6, alice);
        vm.stopPrank();

        // Fast forward to accrue yield
        vm.warp(block.timestamp + 180 days);
        gtusdc.accrueYield();

        uint256 assets = gtusdc.convertToAssets(shares);
        uint256 sharesBack = gtusdc.convertToShares(assets);

        // Should be approximately equal (may have small rounding differences)
        assertApproxEqRel(sharesBack, shares, 0.001e18);
    }

    function test_TotalAssets_ReflectsYield() public {
        // Deposit
        vm.startPrank(alice);
        usdc.approve(address(gtusdc), 1000e6);
        gtusdc.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 initialTotalAssets = gtusdc.totalAssets();

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        gtusdc.accrueYield();

        uint256 newTotalAssets = gtusdc.totalAssets();

        // Total assets should increase by ~5%
        assertGt(newTotalAssets, initialTotalAssets);
    }

    function test_MintShares_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gtusdc.mintShares(alice, 1000e18);

        // Owner can mint
        gtusdc.mintShares(alice, 1000e18);
        assertEq(gtusdc.balanceOf(alice), 1000e18);
    }

    function test_BurnShares_OnlyOwner() public {
        gtusdc.mintShares(alice, 1000e18);

        vm.prank(bob);
        vm.expectRevert();
        gtusdc.burnShares(alice, 500e18);

        // Owner can burn
        gtusdc.burnShares(alice, 500e18);
        assertEq(gtusdc.balanceOf(alice), 500e18);
    }
}
