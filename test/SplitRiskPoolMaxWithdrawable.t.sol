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
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Tests for max withdrawable calculation in protector positions
/// @notice Verifies that getAvailableForWithdrawal returns the maximum amount
///         that can be withdrawn in a single transaction, accounting for utilization changes
contract SplitRiskPoolMaxWithdrawableTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector1 = address(0x1);
    address public protector2 = address(0x2);
    address public shielded = address(0x3);
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
        backingBaseToken.mint(protector1, INITIAL_BALANCE);
        backingBaseToken.mint(protector2, INITIAL_BALANCE);

        // Deposit underlying into vaults to get vault shares
        vm.startPrank(shielded);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded);
        vm.stopPrank();

        vm.startPrank(protector1);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector1);
        vm.stopPrank();

        vm.startPrank(protector2);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector2);
        vm.stopPrank();

        // Approve pool to spend vault shares
        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector1);
        backingToken.approve(address(pool), type(uint256).max);
        vm.prank(protector2);
        backingToken.approve(address(pool), type(uint256).max);
    }

    /// @notice Test that full position is available when no shielded deposits exist
    function test_maxWithdrawableEqualsPositionWhenNoShielded() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // With no shielded deposits, full position should be available
        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        assertEq(available, DEPOSIT_AMOUNT, "Full position should be available when no shielded");

        // Locked amount should be 0
        uint256 locked = pool.getLockedAmount(tokenId);
        assertEq(locked, 0, "Nothing should be locked when no shielded");
    }

    /// @notice Test that max withdrawable is capped by pool-level max
    function test_maxWithdrawableCappedByPoolLevel() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 80 tokens (80% utilization with 100% collateral ratio)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 80e18, 0);

        // Pool-level max withdrawable = 100 - 80 = 20 tokens
        // Position = 100 tokens
        // Max withdrawable = min(100, 20) = 20
        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        assertEq(available, 20e18, "Available should be capped by pool-level max (100 - 80 = 20)");
    }

    /// @notice Test that max withdrawable is capped by position amount
    function test_maxWithdrawableCappedByPosition() public {
        // Protector1 deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Protector2 deposits 100 tokens
        vm.prank(protector2);
        pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens (25% utilization with 200 total protector tokens)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Pool-level max withdrawable = 200 - 50 = 150 tokens
        // Position1 = 100 tokens
        // Max withdrawable for position1 = min(100, 150) = 100
        uint256 available = pool.getAvailableForWithdrawal(tokenId1);
        assertEq(available, DEPOSIT_AMOUNT, "Available should be capped by position amount");
    }

    /// @notice Test that after withdrawing max, available becomes 0
    function test_singleWithdrawalExhaustsAvailable() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 80 tokens
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 80e18, 0);

        // Get max available
        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        assertEq(available, 20e18, "Initial available should be 20");

        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 28 days + 1);

        // Withdraw the max available
        vm.prank(protector1);
        pool.protectorWithdraw(tokenId, available, address(backingToken), 0);

        // After withdrawal, position is 80, shielded is 80, so utilization is 100%
        // Available should be 0
        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfter, 0, "Available should be 0 after withdrawing max");
    }

    /// @notice Test that multiple protectors get fair allocation of pool max
    function test_multiplePositionsFairAllocation() public {
        // Protector1 deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Protector2 deposits 100 tokens
        vm.prank(protector2);
        uint256 tokenId2 = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 150 tokens (75% utilization with 200 total)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 150e18, 0);

        // Pool-level max = 200 - 150 = 50 tokens
        // Both positions are 100 tokens, so both can withdraw up to 50 each
        // But total can only be 50, so first withdrawal takes priority
        uint256 available1 = pool.getAvailableForWithdrawal(tokenId1);
        uint256 available2 = pool.getAvailableForWithdrawal(tokenId2);

        // Both should see 50 available (pool max), capped by pool-level not position
        assertEq(available1, 50e18, "Position 1 should have 50 available");
        assertEq(available2, 50e18, "Position 2 should have 50 available");
    }

    /// @notice Test that one withdrawal updates available for others
    function test_withdrawalUpdatesAvailableForOthers() public {
        // Protector1 deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Protector2 deposits 100 tokens
        vm.prank(protector2);
        uint256 tokenId2 = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 150 tokens
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 150e18, 0);

        // Initial: pool max = 200 - 150 = 50
        uint256 available1Before = pool.getAvailableForWithdrawal(tokenId1);
        assertEq(available1Before, 50e18, "Position 1 should have 50 available initially");

        vm.prank(protector1);
        pool.startUnlockProcess(tokenId1);
        vm.warp(block.timestamp + 28 days + 1);

        // Protector1 withdraws 30 tokens
        vm.prank(protector1);
        pool.protectorWithdraw(tokenId1, 30e18, address(backingToken), 0);

        // After: totalProtector = 170, required = 150, pool max = 20
        // Position1 is now 70, Position2 is still 100
        uint256 available1After = pool.getAvailableForWithdrawal(tokenId1);
        uint256 available2After = pool.getAvailableForWithdrawal(tokenId2);

        assertEq(available1After, 20e18, "Position 1 should have 20 available after partial withdrawal");
        assertEq(available2After, 20e18, "Position 2 should have 20 available after other's withdrawal");
    }

    /// @notice Test that shielded token price changes do NOT affect available amounts (uses original deposit values)
    function test_oraclePriceChangeAffectsAvailable() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens (50% utilization at equal prices)
        // At $1 per token, valueAtDeposit = 50 * $1 = $50 USD
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // At equal prices: required = $50 USD, available = 100 - 50 = 50 tokens
        uint256 availableBefore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableBefore, 50e18, "Available should be 50 at equal prices");

        // Shielded token doubles in price - now worth $2 each
        // But collateralization is based on original valueAtDeposit ($50), not current value
        oracle.setPrice(address(shieldedToken), 2e8);

        // Required collateral = $50 USD (original valueAtDeposit) * 100% = $50 USD
        // Protector value = 100 tokens * $1 = $100 USD
        // Required in protector tokens = $50 / $1 = 50 tokens
        // Available = 100 - 50 = 50 (unchanged!)
        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfter, 50e18, "Available should remain 50 after shielded price doubles (uses original value)");
    }

    /// @notice Test that backing token price increase makes more available
    function test_backingPriceIncreaseIncreasesAvailable() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 80 tokens (80% utilization)
        // At $1 per token, valueAtDeposit = 80 * $1 = $80 USD
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 80e18, 0);

        // At equal prices: available = 100 - 80 = 20
        uint256 availableBefore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableBefore, 20e18, "Available should be 20 at equal prices");

        // Backing token doubles in price - now worth $2 each
        // This DOES affect available because collateral is in backing tokens
        oracle.setPrice(address(backingToken), 2e8);

        // Required collateral = $80 USD (original valueAtDeposit) * 100% = $80 USD
        // Protector value = 100 tokens * $2 = $200 USD
        // Required in protector tokens = $80 / $2 = 40 tokens
        // Available = 100 - 40 = 60
        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfter, 60e18, "Available should increase to 60 after backing price doubles");
    }

    /// @notice Test that when protected backing pricing fails, availability fails closed
    function test_circuitBreakerFailureFailsClosed() public {
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 80e18, 0);

        uint256 availableBefore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableBefore, 20e18, "Available should be 20 at equal prices");

        oracle.setPrice(address(backingToken), 2e8);
        oracle.setShouldRevertOnCircuitBreaker(true);

        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfter, 0, "Circuit-breaker failure should fail closed");
    }

    /// @notice Test locked amount is consistent with available
    function test_lockedPlusAvailableEqualsPosition() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 70 tokens
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 70e18, 0);

        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        uint256 locked = pool.getLockedAmount(tokenId);

        assertEq(available + locked, DEPOSIT_AMOUNT, "Available + Locked should equal position amount");
        assertEq(available, 30e18, "Available should be 30");
        assertEq(locked, 70e18, "Locked should be 70");
    }

    /// @notice Test behavior at exactly 100% utilization
    function test_exactlyFullUtilization() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 100 tokens (100% utilization)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), DEPOSIT_AMOUNT, 0);

        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        assertEq(available, 0, "Available should be 0 at 100% utilization");

        uint256 locked = pool.getLockedAmount(tokenId);
        assertEq(locked, DEPOSIT_AMOUNT, "Full position should be locked at 100% utilization");
    }

    /// @notice Test that shielded token appreciation does NOT cause undercollateralization
    function test_overFullUtilization() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 80 tokens (80% utilization)
        // At $1 per token, valueAtDeposit = 80 * $1 = $80 USD
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 80e18, 0);

        // Now shielded token price increases - but collateralization is based on original $80, not current value
        oracle.setPrice(address(shieldedToken), 1.5e8); // $1.50

        // Required = $80 USD (original valueAtDeposit) * 100% = $80 USD
        // Protector = 100 * $1 = $100 USD
        // Required in protector tokens = $80 / $1 = 80 tokens
        // Available = 100 - 80 = 20 tokens (still available!)
        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        assertEq(
            available, 20e18, "Available should be 20 (shielded price appreciation doesn't affect collateralization)"
        );
    }

    /// @notice Test oracle failure returns zero instead of unsafe mixed-unit availability
    function test_oracleFailureFailsClosed() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens (50% utilization)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        // Normal case with working oracle: pool max = 100 - 50 = 50
        uint256 availableWithOracle = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableWithOracle, 50e18, "Available should be 50 with working oracle");

        oracle.setShouldRevertOnCircuitBreaker(true);
        uint256 availableDuringFailure = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableDuringFailure, 0, "Availability should fail closed while protected pricing is unavailable");

        // Re-enable oracle and verify it works again
        oracle.setShouldRevertOnCircuitBreaker(false);
        uint256 availableAfterRestore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfterRestore, 50e18, "Available should be 50 after restoring oracle");
    }

    /// @notice Test that zero position returns zero available
    function test_zeroPositionReturnsZero() public view {
        // Try to get available for non-existent token (tokenId 999)
        // This should return 0 since position amount is 0
        uint256 available = pool.getAvailableForWithdrawal(999);
        assertEq(available, 0, "Non-existent position should return 0 available");

        uint256 locked = pool.getLockedAmount(999);
        assertEq(locked, 0, "Non-existent position should return 0 locked");
    }

    /// @notice Test that shielded token appreciation does not lock more collateral
    function test_shieldedTokenAppreciationDoesNotLockMoreCollateral() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 50 tokens at $1 each (valueAtDeposit = $50 USD)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);

        uint256 availableBefore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableBefore, 50e18, "Initial available should be 50");

        // Shielded tokens appreciate 2x ($1 -> $2)
        oracle.setPrice(address(shieldedToken), 2e8);

        // Available should remain the same (based on original $50 valueAtDeposit, not current $100 value)
        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(availableAfter, 50e18, "Available should remain 50 after token appreciation");
    }

    /// @notice Test that getLockedAmount uses original deposit values
    function test_getLockedAmount_UsesOriginalValues() public {
        // Protector deposits 100 tokens
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), DEPOSIT_AMOUNT, 0);

        // Shielded deposits 60 tokens at $1 each (valueAtDeposit = $60 USD)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 60e18, 0);

        uint256 lockedBefore = pool.getLockedAmount(tokenId);
        uint256 availableBefore = pool.getAvailableForWithdrawal(tokenId);
        assertEq(lockedBefore, 60e18, "Initial locked should be 60");
        assertEq(availableBefore, 40e18, "Initial available should be 40");

        // Shielded tokens appreciate 3x ($1 -> $3)
        oracle.setPrice(address(shieldedToken), 3e8);

        // Locked amount should remain the same (based on original $60 valueAtDeposit)
        uint256 lockedAfter = pool.getLockedAmount(tokenId);
        uint256 availableAfter = pool.getAvailableForWithdrawal(tokenId);
        assertEq(lockedAfter, 60e18, "Locked should remain 60 after token appreciation");
        assertEq(availableAfter, 40e18, "Available should remain 40 after token appreciation");
    }
}
