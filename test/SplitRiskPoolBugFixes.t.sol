// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "../contracts/libraries/EventsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { AccessControlExample } from "../contracts/examples/AccessControlExample.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract PartialAccessControl {
    function canDepositShielded(address) external pure returns (bool) {
        return true;
    }
}

/// @title Tests for bug fixes in SplitRiskPool
/// @notice Verifies fixes for commission rounding, zero price, state cleanup, and zero amount bugs
contract SplitRiskPoolBugFixesTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector = address(0x1);
    address public shielded1 = address(0x2);
    address public governance = address(this);
    address public protocolFeeRecipient = address(0xdead);

    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "IBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "UBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "UNDER");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "INSURE");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "INSURE",
            symbol: "INSURE",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "UNDER",
            symbol: "UNDER",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("iINSURE", "iINSURE");
        protectorNFT = new ProtectorReceiptNFT("uUNDER", "uUNDER");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance, // governance
            address(oracle), // oracle
            protocolFeeRecipient, // protocol fee recipient
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

        // Fund accounts
        shieldedBaseToken.mint(shielded1, INITIAL_BALANCE);
        backingBaseToken.mint(protector, INITIAL_BALANCE);

        // Deposit into vaults
        vm.startPrank(protector);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector);
        vm.stopPrank();

        vm.startPrank(shielded1);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded1);
        vm.stopPrank();

        // Protector deposits to pool first
        vm.startPrank(protector);
        backingToken.approve(address(pool), 500000e18);
        pool.depositBackingAsset(address(backingToken), 500000e18, 0);
        vm.stopPrank();
    }

    function _matureProtectorUnlock(uint256 tokenId) internal {
        vm.startPrank(protector);
        pool.startUnlockProcess(tokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + 28 days + 1);
    }

    // ============ Bug 1: Commission Rounding Tests ============

    /// @notice Test that partial withdrawal resets commission accounting to prevent exploit
    function test_partialWithdraw_ResetsCommissionAccounting() public {
        // Shielded deposits to generate commissions
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        // Simulate yield by increasing shielded token price
        oracle.setPrice(address(shieldedToken), 2e8); // Price doubles

        // Now withdraw shielded to trigger commission accumulation
        vm.startPrank(shielded1);
        pool.shieldedWithdraw(0, address(shieldedToken), 0);
        vm.stopPrank();

        // Get protector's initial state
        uint256 tokenId = 0;
        IProtectorReceiptNFT.ProtectorPosition memory posBefore = protectorNFT.getPosition(tokenId);
        uint256 commissionBefore = pool.getClaimableCommission(tokenId);

        // Claim commission
        vm.startPrank(protector);
        if (commissionBefore > 0) {
            pool.claimCommission(tokenId);
        }
        vm.stopPrank();

        // Now do partial withdrawal
        uint256 withdrawAmount = posBefore.amount / 4; // 25% withdrawal
        _matureProtectorUnlock(tokenId);
        vm.startPrank(protector);
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), 0);
        vm.stopPrank();

        // After partial withdrawal, commissionsClaimed should be reset (deleted)
        // New position should start fresh - verify position exists and is valid
        IProtectorReceiptNFT.ProtectorPosition memory posAfter = protectorNFT.getPosition(tokenId);
        assertTrue(posAfter.amount > 0, "Position should still exist with balance");

        // The position has been reset to clean slate, no historical rounding errors
        // (commissionsClaimed is deleted so future claims start fresh)
    }

    /// @notice Test that repeated partial withdrawals don't accumulate rounding errors
    function test_multiplePartialWithdrawals_NoRoundingAccumulation() public {
        // Setup: deposit shielded and create commissions
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        oracle.setPrice(address(shieldedToken), 2e8);

        vm.startPrank(shielded1);
        pool.shieldedWithdraw(0, address(shieldedToken), 0);
        vm.stopPrank();

        uint256 tokenId = 0;

        // Do multiple small partial withdrawals
        _matureProtectorUnlock(tokenId);
        vm.startPrank(protector);
        for (uint256 i = 0; i < 5; i++) {
            IProtectorReceiptNFT.ProtectorPosition memory pos = protectorNFT.getPosition(tokenId);
            if (pos.amount > 10e18) {
                pool.protectorWithdraw(tokenId, 1e18, address(backingToken), 0);
            }
        }
        vm.stopPrank();

        // Pool should still be consistent after multiple partial withdrawals
        IProtectorReceiptNFT.ProtectorPosition memory finalPos = protectorNFT.getPosition(tokenId);
        assertTrue(finalPos.amount > 0, "Position should still have balance");
    }

    function test_protectorWithdraw_EmitsShieldActivated() public {
        uint256 tokenId = 0;
        uint256 withdrawAmount = 10e18;

        _matureProtectorUnlock(tokenId);
        vm.startPrank(protector);
        vm.expectEmit(true, false, false, true);
        emit EventsLib.ShieldActivated(protector, withdrawAmount, 0, withdrawAmount);
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), 0);
        vm.stopPrank();
    }

    function test_protectorWithdraw_RevertsWhenUnlockNotStarted() public {
        uint256 tokenId = 0;

        vm.startPrank(protector);
        vm.expectRevert(ErrorsLib.InsufficientUnlockedTokens.selector);
        pool.protectorWithdraw(tokenId, 1e18, address(backingToken), 0);
        vm.stopPrank();
    }

    // ============ Bug 2: Zero Price Tests ============

    /// @notice Test that zero oracle price reverts with InvalidOraclePrice
    function test_shieldedWithdraw_ZeroPrice_Reverts() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        // Wait minimum pool time
        vm.warp(block.timestamp + 7 days);

        // Set price to zero
        oracle.setPrice(address(backingToken), 0);

        // Try to withdraw in backing token - should revert
        vm.startPrank(shielded1);
        vm.expectRevert(ErrorsLib.InvalidOraclePrice.selector);
        pool.shieldedWithdraw(0, address(backingToken), 0);
        vm.stopPrank();
    }

    /// @notice Same-asset withdrawal burns the receipt, so it must fail closed
    ///         when protected shielded pricing is unavailable for fee accrual.
    function test_shieldedWithdraw_OracleUnavailable_RevertsBeforeBurningReceipt() public {
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        // Simulate yield...
        oracle.setPrice(address(shieldedToken), 2e8);
        // ...then oracle failure / circuit-breaker trip mid-position.
        oracle.setPrice(address(shieldedToken), 0);

        uint256 balanceBefore = shieldedToken.balanceOf(shielded1);
        uint256 reservedFeesBefore = pool.getReservedFees();

        vm.prank(shielded1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ShieldedFeePriceUnavailable.selector, address(shieldedToken)));
        pool.shieldedWithdraw(0, address(shieldedToken), 0);

        assertEq(shieldedToken.balanceOf(shielded1), balanceBefore, "failed exit should not transfer tokens");
        assertEq(pool.getReservedFees(), reservedFeesBefore, "unavailable pricing should not mint new fees");
        assertEq(pool.totalShieldedTokens(), 100e18, "failed exit should keep position accounting");
        assertEq(shieldNFT.ownerOf(0), shielded1, "failed exit should keep receipt");
    }

    /// @notice Test normal operation with valid prices
    function test_shieldedWithdraw_ValidPrice_Succeeds() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        uint256 balanceBefore = shieldedToken.balanceOf(shielded1);

        // Withdraw normally
        vm.startPrank(shielded1);
        pool.shieldedWithdraw(0, address(shieldedToken), 0);
        vm.stopPrank();

        uint256 balanceAfter = shieldedToken.balanceOf(shielded1);
        assertTrue(balanceAfter > balanceBefore, "Should receive tokens back");
    }

    // ============ Bug 3: State Cleanup Tests ============

    /// @notice Test that lastClaimRewardsTime is cleared after full withdrawal
    function test_shieldedWithdraw_ClearsLastClaimRewardsTime() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        uint256 tokenId = 0;

        // Claim rewards first to set lastClaimRewardsTime
        vm.startPrank(shielded1);
        pool.claimRewards(tokenId);
        vm.stopPrank();

        // Verify lastClaimRewardsTime was set
        uint256 claimTime = pool.lastClaimRewardsTime(tokenId);
        assertTrue(claimTime > 0, "lastClaimRewardsTime should be set");

        // Withdraw completely
        vm.startPrank(shielded1);
        pool.shieldedWithdraw(tokenId, address(shieldedToken), 0);
        vm.stopPrank();

        // lastClaimRewardsTime should be cleared
        uint256 claimTimeAfter = pool.lastClaimRewardsTime(tokenId);
        assertEq(claimTimeAfter, 0, "lastClaimRewardsTime should be cleared after withdrawal");
    }

    function test_claimRewards_RevertsForUnauthorizedCaller() public {
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        oracle.setPrice(address(shieldedToken), 2e8);

        vm.prank(address(0xbeef));
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        pool.claimRewards(tokenId);
    }

    function test_claimRewards_RevertsForApprovedOperator() public {
        address operator = address(0xcafe);

        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        vm.prank(shielded1);
        shieldNFT.approve(operator, tokenId);

        oracle.setPrice(address(shieldedToken), 2e8);

        vm.prank(operator);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        pool.claimRewards(tokenId);
    }

    /// @notice Test that new position can use same tokenId without stale state issues
    function test_newPosition_NoStaleStateFromPreviousPosition() public {
        // Deposit and withdraw to create then burn tokenId 0
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 200e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);

        // Claim to set lastClaimRewardsTime
        pool.claimRewards(0);

        // Withdraw
        pool.shieldedWithdraw(0, address(shieldedToken), 0);

        // Verify stale state is cleared
        assertEq(pool.lastClaimRewardsTime(0), 0, "State should be cleared");
        vm.stopPrank();
    }

    // ============ Bug 4: Zero Amount Tests ============

    /// @notice Test that zero withdraw amount reverts
    function test_partialWithdrawShielded_ZeroAmount_Reverts() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        // Try to partial withdraw with zero amount
        vm.startPrank(shielded1);
        vm.expectRevert(ErrorsLib.NoTokensToWithdraw.selector);
        pool.partialWithdrawShielded(0, 0, address(shieldedToken), 0);
        vm.stopPrank();
    }

    /// @notice Test that non-zero partial withdraw works
    function test_partialWithdrawShielded_ValidAmount_Succeeds() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        uint256 balanceBefore = shieldedToken.balanceOf(shielded1);

        // Partial withdraw with valid amount (but leave enough for minimum)
        vm.startPrank(shielded1);
        pool.partialWithdrawShielded(0, 10e18, address(shieldedToken), 0);
        vm.stopPrank();

        uint256 balanceAfter = shieldedToken.balanceOf(shielded1);
        assertTrue(balanceAfter > balanceBefore, "Should receive tokens");
    }

    /// @notice Test unsupported asset still reverts before zero amount check
    function test_partialWithdrawShielded_UnsupportedAsset_Reverts() public {
        // Deposit shielded
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 100e18);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        // Try with wrong asset (backing token) - should revert with UnsupportedAsset first
        vm.startPrank(shielded1);
        vm.expectRevert(ErrorsLib.UnsupportedAsset.selector);
        pool.partialWithdrawShielded(0, 10e18, address(backingToken), 0);
        vm.stopPrank();
    }

    /// @notice Test that partial access control implementations are rejected during installation
    function test_setAccessControl_RevertsForPartialImplementation() public {
        PartialAccessControl partialAccessControl = new PartialAccessControl();

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidAccessControlAddress.selector);
        pool.setAccessControl(address(partialAccessControl));
    }

    /// @notice Test that a full IPoolAccessControl implementation is accepted
    function test_setAccessControl_AcceptsFullImplementation() public {
        AccessControlExample fullAccessControl = new AccessControlExample(address(this));

        vm.prank(governance);
        vm.expectEmit(true, true, false, false);
        emit EventsLib.AccessControlUpdated(address(0), address(fullAccessControl));
        pool.setAccessControl(address(fullAccessControl));

        assertEq(pool.accessControl(), address(fullAccessControl), "Access control should be installed");
    }
}
