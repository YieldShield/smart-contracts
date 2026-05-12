// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Tests for USD-based utilization check in protector withdrawal
/// @notice Ensures protectors cannot withdraw if it causes USD-based undercollateralization
contract SplitRiskPoolUsdUtilizationTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector = address(0x1);
    address public shielded = address(0x2);
    address public governance = address(this);

    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool with 100% collateral ratio for simpler math
        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            10000, // 100% collateral ratio
            governance, // governance
            address(oracle), // oracle
            address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C), // protocol fee recipient
            address(shieldNFT),
            address(protectorNFT),
            address(this) // owner
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        // Set pool address on NFTs
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        // Fund accounts with underlying tokens first, then deposit into vaults
        shieldedBaseToken.mint(shielded, INITIAL_BALANCE);
        backingBaseToken.mint(protector, INITIAL_BALANCE);

        // Deposit underlying into vaults to get vault shares
        vm.startPrank(shielded);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded);
        vm.stopPrank();

        vm.startPrank(protector);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector);
        vm.stopPrank();

        // Approve pool to spend vault shares
        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector);
        backingToken.approve(address(pool), type(uint256).max);
    }

    /// @notice Test that getUtilizationRatioUsd returns correct value when prices are equal
    function test_getUtilizationRatioUsd_EqualPrices() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens (50% utilization)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // With equal prices and 100% collateral ratio, utilization should be 50%
        uint256 utilizationUsd = pool.getUtilizationRatioUsd();
        assertEq(utilizationUsd, 5000, "Utilization should be 50% (5000 basis points)");
    }

    /// @notice Test that getUtilizationRatioUsd uses original deposit value (not current price)
    function test_getUtilizationRatioUsd_PriceDivergence() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens at $1 each = $50 original value (totalValueAtDeposit)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Now change prices: shielded token worth $1.10, backing token worth $0.90
        oracle.setPrice(address(shieldedToken), 1.1e8); // $1.10
        oracle.setPrice(address(backingToken), 0.9e8); // $0.90

        // USD utilization uses ORIGINAL deposit value ($50), not current market value ($55)
        // Shielded original value: $50 (totalValueAtDeposit, fixed at deposit time)
        // Protector current value: 100 * $0.90 = $90
        // Required collateral (100% ratio): $50
        // USD utilization: $50 / $90 = 55.55%
        uint256 utilizationUsd = pool.getUtilizationRatioUsd();
        // 50 / 90 * 10000 = 5555 basis points
        assertApproxEqAbs(utilizationUsd, 5555, 1, "USD utilization uses original deposit value");
    }

    /// @notice Test that withdrawal is blocked when it would cause USD undercollateralization
    function test_protectorWithdraw_BlockedByUsdCheck() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens at $1 = $50 original value (totalValueAtDeposit)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Start unlock process
        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);

        // Warp past unlock duration
        vm.warp(block.timestamp + 28 days + 1);

        // Set backing token to very low price to trigger USD undercollateralization
        // Original shielded value: $50 (fixed at deposit time)
        // Backing token: $0.40
        oracle.setPrice(address(backingToken), 0.4e8);

        // At these prices:
        // Required collateral (original value): $50
        // Protector value: 100 * $0.40 = $40
        // If protector withdraws ANY tokens, collateral drops below $50
        // Even withdrawing 1 token: 99 * $0.40 = $39.60 < $50

        vm.prank(protector);
        vm.expectRevert(ErrorsLib.InsufficientUnlockedTokens.selector);
        pool.protectorWithdraw(protectorTokenId, 1e18, address(backingToken), 0);
    }

    /// @notice Test that withdrawal succeeds when USD collateralization is maintained
    function test_protectorWithdraw_SucceedsWhenCollateralized() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Start unlock process
        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);

        // Warp past unlock duration
        vm.warp(block.timestamp + 28 days + 1);

        // Prices diverge but protector can still make a small withdrawal
        oracle.setPrice(address(shieldedToken), 1.1e8);
        oracle.setPrice(address(backingToken), 0.9e8);

        // At these prices:
        // Shielded value: 50 * $1.10 = $55 (required collateral)
        // Protector value: 100 * $0.90 = $90
        // If protector withdraws 30 tokens:
        // New protector value: 70 * $0.90 = $63
        // This is more than required $55, so should succeed

        vm.prank(protector);
        pool.protectorWithdraw(protectorTokenId, 30e18, address(backingToken), 0);

        // Verify balance updated
        (uint256 amount,,,,,) = pool.getProtectorDepositInfo(protectorTokenId);
        assertEq(amount, 70e18, "Position should have 70 tokens remaining");
    }

    /// @notice Test that a matured unlock does not bypass current collateral checks
    function test_protectorWithdraw_MaturedUnlockStillRespectsCollateralLimit() public {
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);

        vm.warp(block.timestamp + 29 days);
        oracle.setPrice(address(backingToken), 0.4e8);

        vm.prank(protector);
        vm.expectRevert(ErrorsLib.InsufficientUnlockedTokens.selector);
        pool.protectorWithdraw(protectorTokenId, 1e18, address(backingToken), 0);
    }

    /// @notice Test that USD utilization uses original deposit value while protector value is dynamic
    function test_tokenBasedVsUsdBased_Comparison() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens at $1 = $50 original value (totalValueAtDeposit)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Token-based utilization is 50%
        uint256 tokenUtilization = pool.getUtilizationRatio();
        assertEq(tokenUtilization, 5000, "Token-based utilization should be 50%");

        // Change prices so shielded is worth more, backing worth less
        oracle.setPrice(address(shieldedToken), 1.2e8); // $1.20
        oracle.setPrice(address(backingToken), 0.8e8); // $0.80

        // Token-based utilization is still 50% (doesn't change with prices)
        tokenUtilization = pool.getUtilizationRatio();
        assertEq(tokenUtilization, 5000, "Token-based utilization should still be 50%");

        // USD-based utilization uses ORIGINAL deposit value ($50), not current ($60)
        // Original shielded value: $50 (fixed at deposit time)
        // Protector current value: 100 * $0.80 = $80
        // USD utilization: $50 / $80 = 62.5%
        uint256 usdUtilization = pool.getUtilizationRatioUsd();
        assertEq(usdUtilization, 6250, "USD utilization should be 62.5%");

        // Start unlock process
        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);
        vm.warp(block.timestamp + 28 days + 1);

        // With original $50 requirement and $0.80/token:
        // Minimum protector tokens needed: $50 / $0.80 = 62.5 tokens
        // Max withdrawable: 100 - 62.5 = 37.5 tokens
        // Withdrawing 38 tokens leaves 62 * $0.80 = $49.60 < $50 required

        vm.prank(protector);
        vm.expectRevert(ErrorsLib.InsufficientUnlockedTokens.selector);
        pool.protectorWithdraw(protectorTokenId, 38e18, address(backingToken), 0);

        // But 37 tokens should work (leaves 63 * $0.80 = $50.40 > $50)
        vm.prank(protector);
        pool.protectorWithdraw(protectorTokenId, 37e18, address(backingToken), 0);
    }

    /// @notice Test that shielded deposit is rejected when USD collateralization would be insufficient
    function test_depositShielded_BlockedByUsdCapacityCheck() public {
        // Protector deposits 100 tokens at $1 each = $100 protector value
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Change prices: shielded token is worth $2, backing still $1
        // This means each shielded token requires $2 worth of collateral
        oracle.setPrice(address(shieldedToken), 2e8); // $2
        oracle.setPrice(address(backingToken), 1e8); // $1

        // With 100% collateral ratio:
        // To deposit 60 shielded tokens worth $120, need $120 protector value
        // But we only have $100 protector value
        // Token-based check would pass: 60 < 100
        // USD-based check should fail: $120 required > $100 available

        vm.prank(shielded);
        vm.expectRevert(ErrorsLib.InsufficientProtectorTokenBalance.selector);
        pool.depositShieldedAsset(address(shieldedToken), 60e18, 0);
    }

    /// @notice Test that shielded deposit succeeds when USD collateralization is maintained
    function test_depositShielded_SucceedsWhenUsdCollateralized() public {
        // Protector deposits 100 tokens at $1 each = $100 protector value
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Change prices: shielded token is worth $2, backing still $1
        oracle.setPrice(address(shieldedToken), 2e8); // $2
        oracle.setPrice(address(backingToken), 1e8); // $1

        // With 100% collateral ratio:
        // To deposit 40 shielded tokens worth $80, need $80 protector value
        // We have $100 protector value, so this should succeed

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 40e18, 0);

        // Verify the deposit was successful
        uint256 totalShielded = pool.totalShieldedTokens();
        assertEq(totalShielded, 40e18, "Shielded tokens should be 40");
    }

    function test_depositShielded_RevertsWhenShieldedCircuitBreakerFails() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        vm.mockCallRevert(
            address(oracle),
            abi.encodeWithSelector(MockOracle.getPriceWithCircuitBreaker.selector, address(shieldedToken)),
            abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken))
        );

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken)));
        pool.depositShieldedAsset(address(shieldedToken), 40e18, 0);
    }

    /// @notice Test that token-based capacity check would allow undercollateralization but USD check prevents it
    function test_depositShielded_TokenVsUsdCapacityCheck() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Set shielded token worth MORE than backing token
        // Shielded: $1.50, Backing: $1.00
        oracle.setPrice(address(shieldedToken), 1.5e8);
        oracle.setPrice(address(backingToken), 1e8);

        // Token-based capacity (old logic):
        // With 100% collateral, can deposit up to 100 tokens
        // This would be 100 shielded tokens * $1.50 = $150 shielded value
        // But only have 100 backing tokens * $1.00 = $100 protector value
        // Pool would be undercollateralized!

        // USD-based capacity (new logic):
        // With $100 protector value and 100% collateral ratio
        // Can support shielded value of up to $100
        // $100 / $1.50 per token = ~66.67 tokens maximum

        // Try to deposit 70 tokens ($105 value) - should fail with USD check
        vm.prank(shielded);
        vm.expectRevert(ErrorsLib.InsufficientProtectorTokenBalance.selector);
        pool.depositShieldedAsset(address(shieldedToken), 70e18, 0);

        // Deposit 60 tokens ($90 value) - should succeed
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 60e18, 0);

        // Verify we're properly collateralized in USD terms
        uint256 usdUtilization = pool.getUtilizationRatioUsd();
        // Shielded value: 60 * $1.50 = $90
        // Protector value: 100 * $1.00 = $100
        // Utilization: $90 / $100 = 90%
        assertEq(usdUtilization, 9000, "USD utilization should be 90%");
    }

    /// @notice Test deposit with reversed price scenario (backing worth more)
    function test_depositShielded_BackingWorthMore() public {
        // Protector deposits 100 tokens
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Set backing token worth MORE than shielded token
        // Shielded: $0.80, Backing: $1.20
        oracle.setPrice(address(shieldedToken), 0.8e8);
        oracle.setPrice(address(backingToken), 1.2e8);

        // USD-based capacity:
        // Protector value: 100 * $1.20 = $120
        // With 100% collateral ratio, can support $120 of shielded value
        // $120 / $0.80 per token = 150 tokens maximum

        // Deposit 130 tokens ($104 value) - should succeed
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 130e18, 0);

        // Verify utilization
        uint256 usdUtilization = pool.getUtilizationRatioUsd();
        // Shielded value: 130 * $0.80 = $104
        // Protector value: 100 * $1.20 = $120
        // Utilization: $104 / $120 = 86.67%
        assertApproxEqAbs(usdUtilization, 8667, 1, "USD utilization should be ~86.67%");
    }
}
